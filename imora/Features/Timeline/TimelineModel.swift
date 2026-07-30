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

    var columns: Int = 3 {
        didSet { if columns != oldValue { rebuildRows() } }
    }

    private var client: ImmichClient?
    private var inflightBuckets: Set<String> = []
    private var prefetchTask: Task<Void, Never>?
    private var rebuildScheduled = false

    init(filter: TimelineFilter) {
        self.filter = filter
    }

    deinit {
        prefetchTask?.cancel()
    }

    var isEmpty: Bool { !isLoading && sections.isEmpty }

    /// all loaded assets in timeline order, for the viewer pager.
    var flatAssets: [Asset] {
        sections.flatMap { $0.days ?? [] }.flatMap(\.assets)
    }

    func attach(_ client: ImmichClient) {
        guard self.client == nil else { return }
        self.client = client
    }

    func load() async {
        guard let client, !isLoading else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            try await reloadSections(using: client)
        } catch {
            loadError = error.localizedDescription
        }
    }

    func refresh() async {
        guard let client else { return }
        prefetchTask?.cancel()
        prefetchTask = nil
        inflightBuckets.removeAll()
        loadError = nil

        do {
            try await reloadSections(using: client)
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
        rebuildRows()
        if let first = sections.first { await loadBucket(first.id) }
        startPrefetch()
    }

    func loadBucket(_ id: String, immediateRows: Bool = true) async {
        guard let client,
              let index = sections.firstIndex(where: { $0.id == id }),
              sections[index].days == nil,
              !inflightBuckets.contains(id)
        else { return }
        inflightBuckets.insert(id)
        defer { inflightBuckets.remove(id) }
        do {
            let assets = try await client.timeBucket(id, filter: filter)
            guard let current = sections.firstIndex(where: { $0.id == id }) else { return }
            sections[current].days = Self.groupByDay(assets)
            if immediateRows {
                rebuildRows()
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
        guard prefetchTask == nil else { return }
        let bucketIDs = sections.filter { !$0.isLoaded }.map(\.id)
        prefetchTask = Task { [weak self] in
            for bucketID in bucketIDs {
                guard !Task.isCancelled, let self else { return }
                await self.loadBucket(bucketID, immediateRows: false)
            }
            guard !Task.isCancelled, let self else { return }
            self.rebuildRows()
        }
    }

    // MARK: - rows

    private func rebuildRows() {
        var result: [TimelineRow] = []
        var monthByRowID: [String: String] = [:]
        result.reserveCapacity(rows.count + 16)

        for section in sections {
            let monthID = "m-\(section.id)"
            result.append(.monthHeader(monthID, section.monthTitle))
            monthByRowID[monthID] = section.monthTitle

            if let days = section.days {
                for day in days {
                    let dayID = "d-\(section.id)-\(day.id)"
                    result.append(.dayHeader(dayID, day.title, day.assets.map(\.id)))
                    monthByRowID[dayID] = section.monthTitle

                    var start = 0
                    var rowIndex = 0
                    while start < day.assets.count {
                        let end = min(start + columns, day.assets.count)
                        let tileID = "t-\(section.id)-\(day.id)-\(rowIndex)"
                        result.append(.tiles(tileID, Array(day.assets[start..<end])))
                        monthByRowID[tileID] = section.monthTitle
                        start = end
                        rowIndex += 1
                    }
                }
            } else {
                let tileRows = max(1, Int((Double(section.count) / Double(columns)).rounded(.up)))
                let placeholderID = "p-\(section.id)"
                result.append(.placeholder(placeholderID, section.id, tileRows))
                monthByRowID[placeholderID] = section.monthTitle
            }
        }

        rows = result
        self.monthByRowID = monthByRowID
    }

    private func scheduleRebuild() {
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self else { return }
            rebuildScheduled = false
            rebuildRows()
        }
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
        rebuildRows()
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
        rebuildRows()
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
