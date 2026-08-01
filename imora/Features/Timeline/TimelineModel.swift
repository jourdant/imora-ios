import Foundation
import Observation

nonisolated struct DayGroup: Identifiable, Hashable {
    let id: String
    let title: String
    let assets: [Asset]
}

nonisolated struct TimelineSection: Identifiable, Hashable {
    let id: String
    let monthTitle: String
    let count: Int
    var days: [DayGroup]?

    var isLoaded: Bool { days != nil }
}

/// flat list element with a deterministic height. fixed heights are what keep
/// lazyvstack from re-measuring and jumping while scrolling backwards.
nonisolated enum TimelineRow: Identifiable, Hashable {
    case monthHeader(String, String)
    case dayHeader(String, String, [String])
    case tiles(String, [Asset])
    case placeholder(String, String, Int)

    var id: String {
        switch self {
        case .monthHeader(let id, _): id
        case .dayHeader(let id, _, _): id
        case .tiles(let id, _): id
        case .placeholder(let id, _, _): id
        }
    }

    func height(tileSide: CGFloat) -> CGFloat {
        switch self {
        case .monthHeader: 56
        case .dayHeader: 36
        case .tiles: tileSide + 2
        case .placeholder(_, _, let rows): CGFloat(rows) * (tileSide + 2)
        }
    }

    var monthTitle: String? {
        if case .monthHeader(_, let title) = self { return title }
        return nil
    }
}

/// drives any bucketed grid screen: main timeline, favorites, archive, trash, person, album.
@Observable
final class TimelineModel {
    let filter: TimelineFilter
    /// main timeline only: device photos not yet on the server appear in the
    /// grid with backup badges, google-photos style.
    let mergesLocal: Bool
    private(set) var sections: [TimelineSection] = []
    private(set) var rows: [TimelineRow] = []
    private(set) var monthByRowID: [String: String] = [:]
    /// anchors a visible row back into `flatAssets` so the prefetcher can size
    /// its window in assets rather than rows.
    private(set) var firstAssetIDByRowID: [String: String] = [:]
    private(set) var isLoading = false
    private(set) var loadError: String?
    private(set) var flatAssets: [Asset] = []

    /// row tallies kept in sync by rebuildRows so screens can do o(1) height
    /// math instead of summing thousands of rows.
    private(set) var monthCount = 0
    private(set) var dayHeaderCount = 0
    private(set) var tileRowCount = 0
    /// day headers and tile rows belonging to the last month only.
    private(set) var tailDayHeaders = 0
    private(set) var tailTileRows = 0

    var columns: Int = 3 {
        didSet { if columns != oldValue { rebuildRows() } }
    }

    /// screen-injected hook that decides how a realtime rows swap lands:
    /// animated reflow when the change is visible, or an instant apply plus
    /// scroll compensation when it happens above the viewport. nil applies
    /// directly. the apply closure must run synchronously.
    @ObservationIgnored var applyRowsUpdate: ((_ old: [TimelineRow], _ new: [TimelineRow], _ apply: () -> Void) -> Void)?

    private var client: ImmichClient?
    private var backup: BackupManager?
    private var inflightBuckets: Set<String> = []
    private var flatAssetIndexByID: [String: Int] = [:]
    private var prefetchTask: Task<Void, Never>?
    private var prefetchID: UUID?
    private var rebuildTask: Task<Void, Never>?
    private var hasLoaded = false
    private var isViewerSuspended = false
    private var rebuildPending = false
    /// device assets paired with backup status, merged during row building.
    private var localItems: [LocalTimelineItem] = []
    private var resyncTask: Task<Void, Never>?
    private var resyncAgain = false
    private var resyncPending = false

    init(filter: TimelineFilter, mergesLocal: Bool = false) {
        self.filter = filter
        self.mergesLocal = mergesLocal
        // built in init, not in load(): a task runs after the first frame, and
        // that frame is exactly the spinner this is here to avoid.
        if let host = UserDefaults.standard.url(forKey: "imora.serverURL")?.host(),
           let cached = TimelineCache.buckets(for: filter, account: SessionCache.accountKey(host: host)) {
            sections = Self.sections(from: cached)
            rebuildRows(rebuildAssets: true)
        }
    }

    deinit {
        prefetchTask?.cancel()
        rebuildTask?.cancel()
        resyncTask?.cancel()
    }

    /// rows cover both server sections and merged device photos.
    var isEmpty: Bool { !isLoading && rows.isEmpty }

    func flatAssetIndex(for id: String) -> Int? {
        flatAssetIndexByID[id]
    }

    func attach(_ client: ImmichClient, backup: BackupManager? = nil, hub: RealtimeHub? = nil) {
        if self.client == nil {
            self.client = client
        }
        if mergesLocal, self.backup == nil {
            self.backup = backup
        }
        hub?.addListener(self)
    }

    func load() async {
        guard let client, !hasLoaded, !isLoading else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            try await reloadSections(using: client)
            hasLoaded = true
            await refreshLocalItems()
        } catch is CancellationError {
            return
        } catch {
            loadError = error.localizedDescription
        }
    }

    private static func sections(from buckets: [TimeBucket]) -> [TimelineSection] {
        buckets.map { bucket in
            TimelineSection(
                id: bucket.timeBucket,
                monthTitle: Self.monthTitle(for: bucket.timeBucket),
                count: bucket.count,
                days: nil
            )
        }
    }

    private func reloadSections(using client: ImmichClient) async throws {
        let buckets = try await client.timeBuckets(filter)
        if let host = client.apiURL.host() {
            TimelineCache.store(buckets, for: filter, account: SessionCache.accountKey(host: host))
        }
        sections = Self.sections(from: buckets)
        rebuildRows(rebuildAssets: true)
        if let first = sections.first { await loadBucket(first.id) }
        startPrefetch()
    }

    func loadBucket(_ id: String, immediateRows: Bool = true) async {
        guard !isViewerSuspended,
              let client,
              let index = sections.firstIndex(where: { $0.id == id }),
              sections[index].days == nil,
              !inflightBuckets.contains(id)
        else { return }
        inflightBuckets.insert(id)
        defer { inflightBuckets.remove(id) }
        do {
            let assets = try await client.timeBucket(id, filter: filter)
            try Task.checkCancellation()
            guard !isViewerSuspended,
                  let current = sections.firstIndex(where: { $0.id == id })
            else { return }
            sections[current].days = Self.groupByDay(assets, byUploadDate: filter.groupsByUploadDate)
            if immediateRows {
                rebuildRows(rebuildAssets: true)
            } else {
                scheduleRebuild()
            }
        } catch {
            // leave the placeholder; a retry happens next time it scrolls into view.
        }
    }

    /// loads every remaining bucket in the background so heights become exact
    /// and the scrubber can jump anywhere without triggering churn.
    private func startPrefetch() {
        guard !isViewerSuspended, prefetchTask == nil else { return }
        let bucketIDs = sections.filter { !$0.isLoaded }.map(\.id)
        guard !bucketIDs.isEmpty else { return }
        let id = UUID()
        prefetchID = id
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.prefetchID == id {
                    self.prefetchTask = nil
                    self.prefetchID = nil
                }
            }
            for bucketID in bucketIDs {
                guard !Task.isCancelled, !self.isViewerSuspended else { return }
                await self.loadBucket(bucketID, immediateRows: false)
            }
            guard !Task.isCancelled, !self.isViewerSuspended else { return }
            self.rebuildPending = false
            self.rebuildRows(rebuildAssets: true)
        }
    }

    // MARK: - rows

    private func rebuildRows(rebuildAssets: Bool = false, animated: Bool = false) {
        var result: [TimelineRow] = []
        var monthByRowID: [String: String] = [:]
        var firstAssetIDByRowID: [String: String] = [:]
        var flattened: [Asset] = []
        var flattenedIndex: [String: Int] = [:]
        result.reserveCapacity(rows.count + 16)
        if rebuildAssets {
            flattened.reserveCapacity(sections.reduce(0) { $0 + $1.count })
        }

        var months = 0
        var dayHeaders = 0
        var tileRows = 0
        var sectionDayHeaders = 0
        var sectionTileRows = 0

        for section in mergedSections() {
            let monthID = "m-\(section.id)"
            result.append(.monthHeader(monthID, section.monthTitle))
            monthByRowID[monthID] = section.monthTitle
            months += 1
            sectionDayHeaders = 0
            sectionTileRows = 0

            if let days = section.days {
                for day in days {
                    if rebuildAssets {
                        for asset in day.assets {
                            flattenedIndex[asset.id] = flattened.count
                            flattened.append(asset)
                        }
                    }

                    let dayID = "d-\(section.id)-\(day.id)"
                    // select-all only targets server assets; local tiles are
                    // outside selection until they are backed up.
                    result.append(.dayHeader(dayID, day.title, day.assets.filter { !$0.isLocal }.map(\.id)))
                    monthByRowID[dayID] = section.monthTitle
                    sectionDayHeaders += 1

                    var start = 0
                    var rowIndex = 0
                    while start < day.assets.count {
                        let end = min(start + columns, day.assets.count)
                        let tileID = "t-\(section.id)-\(day.id)-\(rowIndex)"
                        result.append(.tiles(tileID, Array(day.assets[start..<end])))
                        monthByRowID[tileID] = section.monthTitle
                        firstAssetIDByRowID[tileID] = day.assets[start].id
                        sectionTileRows += 1
                        start = end
                        rowIndex += 1
                    }
                }
            } else {
                let estimated = max(1, Int((Double(section.count) / Double(columns)).rounded(.up)))
                let placeholderID = "p-\(section.id)"
                result.append(.placeholder(placeholderID, section.id, estimated))
                monthByRowID[placeholderID] = section.monthTitle
                sectionTileRows += estimated
            }

            dayHeaders += sectionDayHeaders
            tileRows += sectionTileRows
        }

        let commit = {
            self.rows = result
            self.monthByRowID = monthByRowID
            self.firstAssetIDByRowID = firstAssetIDByRowID
            if rebuildAssets {
                self.flatAssets = flattened
                self.flatAssetIndexByID = flattenedIndex
            }
            self.monthCount = months
            self.dayHeaderCount = dayHeaders
            self.tileRowCount = tileRows
            self.tailDayHeaders = sectionDayHeaders
            self.tailTileRows = sectionTileRows
        }
        if animated, rows != result, !rows.isEmpty, let applyRowsUpdate {
            applyRowsUpdate(rows, result, commit)
        } else {
            commit()
        }
    }

    /// offset of a row's top edge within the rows stack. deterministic heights
    /// make this exact, which is what scroll compensation relies on.
    static func rowStart(of id: String, in rows: [TimelineRow], tileSide: CGFloat) -> CGFloat? {
        var y: CGFloat = 0
        for row in rows {
            if row.id == id { return y }
            y += row.height(tileSide: tileSide)
        }
        return nil
    }

    /// exact grid height thanks to deterministic row heights.
    func contentHeight(tileSide: CGFloat) -> CGFloat {
        CGFloat(monthCount) * 56
            + CGFloat(dayHeaderCount) * 36
            + CGFloat(tileRowCount) * (tileSide + 2)
    }

    /// the last month header plus everything under it. the screen pads the
    /// scroll bottom so this tail can fill the viewport, letting the scrubber
    /// actually land on the final month even when it holds few photos.
    func tailHeight(tileSide: CGFloat) -> CGFloat {
        guard monthCount > 0 else { return 0 }
        return 56
            + CGFloat(tailDayHeaders) * 36
            + CGFloat(tailTileRows) * (tileSide + 2)
    }

    private func scheduleRebuild() {
        rebuildPending = true
        guard !isViewerSuspended, rebuildTask == nil else { return }
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            self.rebuildTask = nil
            guard !self.isViewerSuspended else { return }
            self.rebuildPending = false
            self.rebuildRows(rebuildAssets: true)
        }
    }

    func suspendForViewer() {
        guard !isViewerSuspended else { return }
        isViewerSuspended = true
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchID = nil
        rebuildTask?.cancel()
        rebuildTask = nil
    }

    func resumeAfterViewer() {
        guard isViewerSuspended else { return }
        isViewerSuspended = false
        // debounced rather than immediate: an o(library) rebuild the instant
        // the cover leaves lands on the first frames the grid is touchable
        // again, and reads as the viewer refusing to let go.
        if rebuildPending {
            scheduleRebuild()
        }
        startPrefetch()
        if resyncPending {
            resyncPending = false
            requestResync()
        }
    }

    // MARK: - realtime resync

    /// diffs bucket counts against the server and refetches only what
    /// changed. cheap enough to run on every websocket burst.
    func requestResync() {
        guard client != nil else { return }
        guard hasLoaded else {
            // a failed first load retries here, e.g. app started offline.
            if !isLoading { Task { await load() } }
            return
        }
        guard !isViewerSuspended else {
            resyncPending = true
            return
        }
        guard resyncTask == nil else {
            resyncAgain = true
            return
        }
        resyncTask = Task { [weak self] in
            await self?.resync()
            guard let self else { return }
            self.resyncTask = nil
            if self.resyncAgain {
                self.resyncAgain = false
                self.requestResync()
            }
        }
    }

    private func resync() async {
        guard let client else { return }
        do {
            let buckets = try await client.timeBuckets(filter)
            guard !isViewerSuspended else {
                resyncPending = true
                return
            }
            let existingByID = Dictionary(sections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var fresh: [TimelineSection] = []
            var toFetch: [String] = []
            var dirty = buckets.count != sections.count
            for bucket in buckets {
                if let existing = existingByID[bucket.timeBucket] {
                    if existing.count == bucket.count {
                        fresh.append(existing)
                    } else {
                        dirty = true
                        fresh.append(TimelineSection(
                            id: existing.id,
                            monthTitle: existing.monthTitle,
                            count: bucket.count,
                            days: existing.days
                        ))
                        if existing.isLoaded { toFetch.append(bucket.timeBucket) }
                    }
                } else {
                    // a brand-new month, straight to the top: fetch eagerly.
                    dirty = true
                    fresh.append(TimelineSection(
                        id: bucket.timeBucket,
                        monthTitle: Self.monthTitle(for: bucket.timeBucket),
                        count: bucket.count,
                        days: nil
                    ))
                    toFetch.append(bucket.timeBucket)
                }
            }
            guard dirty else { return }
            sections = fresh
            for id in toFetch {
                guard !isViewerSuspended else {
                    resyncPending = true
                    break
                }
                if let assets = try? await client.timeBucket(id, filter: filter),
                   let index = sections.firstIndex(where: { $0.id == id }) {
                    sections[index].days = Self.groupByDay(assets, byUploadDate: filter.groupsByUploadDate)
                }
            }
            rebuildRows(rebuildAssets: true, animated: !isViewerSuspended)
            await refreshLocalItems()
        } catch {
            // stale is fine; the next event, tick or foreground pass retries.
        }
    }

    // MARK: - local merge

    /// re-reads device assets and their backup status, then rebuilds rows.
    func refreshLocalItems() async {
        guard mergesLocal, let backup else { return }
        let items = await backup.localTimelineAssets()
        localItems = items
        if isViewerSuspended {
            rebuildPending = true
        } else {
            rebuildRows(rebuildAssets: true, animated: true)
        }
    }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static func monthKey(for date: Date) -> String {
        let comps = utcCalendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d-01", comps.year ?? 0, comps.month ?? 0)
    }

    /// server sections with device-only assets woven in. server data stays
    /// untouched in `sections`; the merge is recomputed on every rebuild.
    private func mergedSections() -> [TimelineSection] {
        guard mergesLocal, !localItems.isEmpty else { return sections }

        // server assets already in the grid hide their device twins, so an
        // upload swaps tiles without ever showing the photo twice.
        var loadedServerIDs: Set<String> = []
        for section in sections {
            guard let days = section.days else { continue }
            for day in days {
                for asset in day.assets { loadedServerIDs.insert(asset.id) }
            }
        }

        var byMonth: [String: [Asset]] = [:]
        for item in localItems {
            if let remoteId = item.remoteId, loadedServerIDs.contains(remoteId) { continue }
            let asset = item.device.asAsset(backedUp: item.backedUp)
            byMonth[Self.monthKey(for: asset.localDate), default: []].append(asset)
        }
        guard !byMonth.isEmpty else { return sections }
        for key in byMonth.keys {
            byMonth[key]?.sort { $0.localDate > $1.localDate }
        }

        var merged: [TimelineSection] = []
        var remainingMonths = Set(byMonth.keys)
        for section in sections {
            let key = Self.bucketDate(section.id).map { Self.monthKey(for: $0) } ?? section.id
            if let locals = byMonth[key], section.days != nil {
                merged.append(Self.mergeSection(section, locals: locals))
                remainingMonths.remove(key)
            } else {
                // unloaded buckets keep their placeholder; their local
                // photos appear once the prefetch loads the month.
                if section.days == nil { remainingMonths.remove(key) }
                merged.append(section)
            }
        }

        // months that only exist on the device get sections of their own.
        for key in remainingMonths.sorted(by: >) {
            guard let locals = byMonth[key], let monthDate = Self.bucketDate(key) else { continue }
            let days = Self.groupByDay(locals)
            let section = TimelineSection(id: key, monthTitle: Self.monthTitle(for: key), count: locals.count, days: days)
            let index = merged.firstIndex { existing in
                guard let date = Self.bucketDate(existing.id) else { return false }
                return date < monthDate
            } ?? merged.count
            merged.insert(section, at: index)
        }
        return merged
    }

    private static func mergeSection(_ section: TimelineSection, locals: [Asset]) -> TimelineSection {
        guard var days = section.days else { return section }

        var localsByDay: [String: [Asset]] = [:]
        for asset in locals {
            let comps = utcCalendar.dateComponents([.year, .month, .day], from: asset.localDate)
            let key = "\(comps.year ?? 0)-\(comps.month ?? 0)-\(comps.day ?? 0)"
            localsByDay[key, default: []].append(asset)
        }

        for i in days.indices {
            guard let extra = localsByDay.removeValue(forKey: days[i].id) else { continue }
            days[i] = DayGroup(
                id: days[i].id,
                title: days[i].title,
                assets: mergeSortedByLocalDate(days[i].assets, extra)
            )
        }
        for (key, assets) in localsByDay {
            guard let date = assets.first?.localDate else { continue }
            let day = DayGroup(id: key, title: dayTitle(date, calendar: utcCalendar), assets: assets)
            let index = days.firstIndex { existing in
                guard let existingDate = existing.assets.first?.localDate else { return false }
                return existingDate < date
            } ?? days.count
            days.insert(day, at: index)
        }

        return TimelineSection(
            id: section.id,
            monthTitle: section.monthTitle,
            count: section.count + locals.count,
            days: days
        )
    }

    /// merges two lists already sorted newest-first, preserving each side's
    /// internal order on ties.
    private static func mergeSortedByLocalDate(_ a: [Asset], _ b: [Asset]) -> [Asset] {
        var result: [Asset] = []
        result.reserveCapacity(a.count + b.count)
        var i = 0
        var j = 0
        while i < a.count && j < b.count {
            if a[i].localDate >= b[j].localDate {
                result.append(a[i])
                i += 1
            } else {
                result.append(b[j])
                j += 1
            }
        }
        result.append(contentsOf: a[i...])
        result.append(contentsOf: b[j...])
        return result
    }

    // MARK: - mutations

    /// applies an in-place mutation, used after favorite actions.
    func updateAssets(ids: Set<String>, _ transform: (inout Asset) -> Void) {
        for s in sections.indices {
            guard var days = sections[s].days else { continue }
            for d in days.indices {
                var assets = days[d].assets
                var changed = false
                for a in assets.indices where ids.contains(assets[a].id) {
                    transform(&assets[a])
                    changed = true
                }
                if changed {
                    days[d] = DayGroup(id: days[d].id, title: days[d].title, assets: assets)
                }
            }
            sections[s].days = days
        }
        rebuildRows(rebuildAssets: true)
    }

    /// drops assets from the grid, used after trash, archive or delete.
    func removeAssets(ids: Set<String>) {
        for s in sections.indices {
            guard let days = sections[s].days else { continue }
            let filtered = days.compactMap { day -> DayGroup? in
                let remaining = day.assets.filter { !ids.contains($0.id) }
                return remaining.isEmpty ? nil : DayGroup(id: day.id, title: day.title, assets: remaining)
            }
            sections[s].days = filtered
        }
        sections.removeAll { $0.isLoaded && ($0.days?.isEmpty ?? false) }
        rebuildRows(rebuildAssets: true, animated: !isViewerSuspended)
    }

    // MARK: - grouping helpers

    private static let bucketParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static func bucketDate(_ raw: String) -> Date? {
        bucketParser.date(from: String(raw.prefix(10)))
    }

    private static func monthTitle(for raw: String) -> String {
        guard let date = bucketDate(raw) else { return raw }
        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date()
        let sameYear = calendar.component(.year, from: date) == Calendar.current.component(.year, from: now)
        return date.formatted(
            sameYear
                ? .dateTime.month(.wide).utc()
                : .dateTime.month(.wide).year().utc()
        )
    }

    private static func groupByDay(_ assets: [Asset], byUploadDate: Bool = false) -> [DayGroup] {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var groups: [DayGroup] = []
        var currentKey = ""
        var currentAssets: [Asset] = []
        var currentDate = Date()

        func flush() {
            guard !currentAssets.isEmpty else { return }
            groups.append(DayGroup(id: currentKey, title: dayTitle(currentDate, calendar: calendar), assets: currentAssets))
            currentAssets = []
        }

        for asset in assets {
            let local = byUploadDate ? asset.uploadLocalDate : asset.localDate
            let components = calendar.dateComponents([.year, .month, .day], from: local)
            let key = "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
            if key != currentKey {
                flush()
                currentKey = key
                currentDate = local
            }
            currentAssets.append(asset)
        }
        flush()
        return groups
    }

    private static func dayTitle(_ date: Date, calendar: Calendar) -> String {
        let now = Date()
        var localCalendar = Calendar.current
        localCalendar.timeZone = .current
        // compare using utc calendar since local dates are shifted into utc space.
        if calendar.isDate(date, inSameDayAs: nowShifted()) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: nowShifted()),
           calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        let sameYear = calendar.component(.year, from: date) == localCalendar.component(.year, from: now)
        return date.formatted(
            sameYear
                ? .dateTime.weekday(.abbreviated).month(.abbreviated).day().utc()
                : .dateTime.weekday(.abbreviated).month(.abbreviated).day().year().utc()
        )
    }

    private static func nowShifted() -> Date {
        Date().addingTimeInterval(TimeInterval(TimeZone.current.secondsFromGMT()))
    }
}

// MARK: - realtime

extension TimelineModel: RealtimeListener {
    func realtimeAssetsRemoved(_ ids: Set<String>) {
        guard ids.contains(where: { flatAssetIndex(for: $0) != nil }) else { return }
        removeAssets(ids: ids)
    }

    func realtimeAssetUpdated(_ detail: AssetDetail) {
        guard flatAssetIndex(for: detail.id) != nil else { return }
        let fresh = detail.asAsset()
        updateAssets(ids: [detail.id]) { asset in
            asset.isFavorite = fresh.isFavorite
            asset.isTrashed = fresh.isTrashed
            asset.visibility = fresh.visibility
        }
        // membership changes, like unfavoriting on the favorites grid,
        // resolve through the resync that follows the same event.
    }

    func realtimeResync() {
        requestResync()
    }

    func realtimeAlbumsChanged() {
        if filter.albumId != nil { requestResync() }
    }

    func realtimeLocalChanged() {
        Task { await refreshLocalItems() }
    }
}
