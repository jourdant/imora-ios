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

/// drives any bucketed grid screen: main timeline, favorites, archive, trash, person, album.
@Observable
final class TimelineModel {
    let filter: TimelineFilter
    private(set) var sections: [TimelineSection] = []
    private(set) var isLoading = false
    private(set) var loadError: String?
    private var client: ImmichClient?
    private var inflightBuckets: Set<String> = []

    init(filter: TimelineFilter) {
        self.filter = filter
    }

    var isEmpty: Bool { !isLoading && sections.isEmpty }

    /// all loaded assets in timeline order, for the viewer pager.
    var flatAssets: [Asset] {
        sections.flatMap { $0.days ?? [] }.flatMap(\.assets)
    }

    var totalCount: Int { sections.reduce(0) { $0 + $1.count } }

    func attach(_ client: ImmichClient) {
        guard self.client == nil else { return }
        self.client = client
    }

    func load() async {
        guard let client, !isLoading else { return }
        isLoading = true
        loadError = nil
        do {
            let buckets = try await client.timeBuckets(filter)
            sections = buckets.map { bucket in
                TimelineSection(
                    id: bucket.timeBucket,
                    monthTitle: Self.monthTitle(for: bucket.timeBucket),
                    count: bucket.count,
                    days: nil
                )
            }
            // preload the first screenful so the ui never starts blank.
            if let first = sections.first { await loadBucket(first.id) }
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    func refresh() async {
        guard client != nil else { return }
        inflightBuckets.removeAll()
        let previouslyLoaded = Set(sections.filter(\.isLoaded).map(\.id))
        do {
            let buckets = try await client!.timeBuckets(filter)
            sections = buckets.map { bucket in
                TimelineSection(
                    id: bucket.timeBucket,
                    monthTitle: Self.monthTitle(for: bucket.timeBucket),
                    count: bucket.count,
                    days: nil
                )
            }
            for id in previouslyLoaded.union(sections.prefix(1).map(\.id)) {
                await loadBucket(id)
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    func loadBucket(_ id: String) async {
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
        } catch {
            // leave the placeholder; a retry happens next time it scrolls into view.
        }
    }

    /// applies an in-place mutation, used after favorite and archive actions.
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
