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
    private(set) var sections: [TimelineSection] = []
    private(set) var rows: [TimelineRow] = []
    private(set) var monthByRowID: [String: String] = [:]
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

    private var client: ImmichClient?
    private var inflightBuckets: Set<String> = []
    private var flatAssetIndexByID: [String: Int] = [:]
    private var prefetchTask: Task<Void, Never>?
    private var prefetchID: UUID?
    private var rebuildTask: Task<Void, Never>?
    private var hasLoaded = false
    private var isViewerSuspended = false
    private var rebuildPending = false

    init(filter: TimelineFilter) {
        self.filter = filter
    }

    deinit {
        prefetchTask?.cancel()
        rebuildTask?.cancel()
    }

    var isEmpty: Bool { !isLoading && sections.isEmpty }

    func flatAssetIndex(for id: String) -> Int? {
        flatAssetIndexByID[id]
    }

    func attach(_ client: ImmichClient) {
        guard self.client == nil else { return }
        self.client = client
    }

    func load() async {
        guard let client, !hasLoaded, !isLoading else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            try await reloadSections(using: client)
            hasLoaded = true
        } catch is CancellationError {
            return
        } catch {
            loadError = error.localizedDescription
        }
    }

    func refresh() async {
        guard let client else { return }
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchID = nil
        rebuildTask?.cancel()
        rebuildTask = nil
        rebuildPending = false
        inflightBuckets.removeAll()
        loadError = nil

        do {
            try await reloadSections(using: client)
            hasLoaded = true
        } catch is CancellationError {
            return
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func reloadSections(using client: ImmichClient) async throws {
        let buckets = try await client.timeBuckets(filter)
        sections = buckets.map { bucket in
            TimelineSection(
                id: bucket.timeBucket,
                monthTitle: Self.monthTitle(for: bucket.timeBucket),
                count: bucket.count,
                days: nil
            )
        }
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
            sections[current].days = Self.groupByDay(assets)
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

    private func rebuildRows(rebuildAssets: Bool = false) {
        var result: [TimelineRow] = []
        var monthByRowID: [String: String] = [:]
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

        for section in sections {
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
                    result.append(.dayHeader(dayID, day.title, day.assets.map(\.id)))
                    monthByRowID[dayID] = section.monthTitle
                    sectionDayHeaders += 1

                    var start = 0
                    var rowIndex = 0
                    while start < day.assets.count {
                        let end = min(start + columns, day.assets.count)
                        let tileID = "t-\(section.id)-\(day.id)-\(rowIndex)"
                        result.append(.tiles(tileID, Array(day.assets[start..<end])))
                        monthByRowID[tileID] = section.monthTitle
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

        rows = result
        self.monthByRowID = monthByRowID
        if rebuildAssets {
            flatAssets = flattened
            flatAssetIndexByID = flattenedIndex
        }
        monthCount = months
        dayHeaderCount = dayHeaders
        tileRowCount = tileRows
        tailDayHeaders = sectionDayHeaders
        tailTileRows = sectionTileRows
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
        if rebuildPending {
            rebuildPending = false
            rebuildRows(rebuildAssets: true)
        }
        startPrefetch()
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
        rebuildRows(rebuildAssets: true)
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

    private static func groupByDay(_ assets: [Asset]) -> [DayGroup] {
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
            let local = asset.localDate
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
