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

/// Exact positions removed by one optimistic command. Rollback replays only
/// these assets, so unrelated realtime changes are never overwritten.
nonisolated struct TimelineRemoval {
    fileprivate struct Placement {
        let section: TimelineSection
        let sectionIndex: Int
        let day: DayGroup
        let dayIndex: Int
        let asset: Asset
        let assetIndex: Int
    }

    fileprivate let operationID: UUID?
    fileprivate let placements: [Placement]
    var isEmpty: Bool { placements.isEmpty }
}

nonisolated struct TimelineClear {
    fileprivate let operationID: UUID
    fileprivate let sections: [TimelineSection]
}

nonisolated struct TimelineFavoriteMutation {
    fileprivate let operationID: UUID
    fileprivate let value: Bool
    fileprivate let previousValues: [String: Bool]

    fileprivate var ids: Set<String> { Set(previousValues.keys) }
}

/// The asset snapshot and bucket identity needed to keep one removal projected
/// while an older bucket request is still in flight.
nonisolated struct TimelineProjectionSource {
    let bucketID: String
    let asset: Asset
}

nonisolated struct TimelineBucketFetch {
    fileprivate let bucketID: String
    fileprivate let sequence: UInt64
}

nonisolated struct TimelineBucketResolution {
    let assets: [Asset]
    /// False when a local mutation had to be replayed over an older response.
    /// Those bytes must not replace the authoritative offline cache.
    let isAuthoritative: Bool
}

/// Operation-scoped projections layered over bucket responses. Resolution of
/// an operation advances that bucket's acceptance floor, so every request that
/// started before commit or rollback is ignored without touching current UI.
nonisolated struct TimelineMutationOverlay {
    private struct FavoriteProjection {
        let operationID: UUID
        let value: Bool
        let bucketID: String
    }

    private struct RemovalProjection {
        let operationID: UUID
        var source: TimelineProjectionSource
    }

    private var nextFetchSequence: UInt64 = 0
    private var latestAppliedFetchByBucket: [String: UInt64] = [:]
    private var favoritesByAssetID: [String: FavoriteProjection] = [:]
    private var removalsByAssetID: [String: RemovalProjection] = [:]

    mutating func beginFetch(bucketID: String) -> TimelineBucketFetch {
        nextFetchSequence &+= 1
        return TimelineBucketFetch(bucketID: bucketID, sequence: nextFetchSequence)
    }

    mutating func rejectFetchesStartedBeforeNextRequest(bucketIDs: Set<String>) {
        let nextAcceptedSequence = nextFetchSequence &+ 1
        for bucketID in bucketIDs {
            latestAppliedFetchByBucket[bucketID] = max(
                latestAppliedFetchByBucket[bucketID] ?? 0,
                nextAcceptedSequence
            )
        }
    }

    mutating func beginFavorite(
        operationID: UUID,
        value: Bool,
        bucketIDsByAssetID: [String: String]
    ) {
        for (assetID, bucketID) in bucketIDsByAssetID {
            favoritesByAssetID[assetID] = FavoriteProjection(
                operationID: operationID,
                value: value,
                bucketID: bucketID
            )
        }
    }

    mutating func commitFavorite(operationID: UUID, ids: Set<String>) {
        var bucketIDs = Set<String>()
        for id in ids where favoritesByAssetID[id]?.operationID == operationID {
            if let bucketID = favoritesByAssetID[id]?.bucketID {
                bucketIDs.insert(bucketID)
            }
            favoritesByAssetID[id] = nil
        }
        rejectFetchesStartedBeforeNextRequest(bucketIDs: bucketIDs)
    }

    mutating func rollbackFavorite(operationID: UUID, ids: Set<String>) -> Set<String> {
        var rolledBack = Set<String>()
        for id in ids where favoritesByAssetID[id]?.operationID == operationID {
            favoritesByAssetID[id] = nil
            rolledBack.insert(id)
        }
        return rolledBack
    }

    func favoriteValue(for id: String) -> Bool? {
        favoritesByAssetID[id]?.value
    }

    mutating func beginRemoval(
        operationID: UUID,
        sourcesByAssetID: [String: TimelineProjectionSource]
    ) {
        for (assetID, source) in sourcesByAssetID {
            removalsByAssetID[assetID] = RemovalProjection(
                operationID: operationID,
                source: source
            )
        }
    }

    mutating func commitRemoval(operationID: UUID, ids: Set<String>) {
        var bucketIDs = Set<String>()
        for id in ids where removalsByAssetID[id]?.operationID == operationID {
            if let bucketID = removalsByAssetID[id]?.source.bucketID {
                bucketIDs.insert(bucketID)
            }
            removalsByAssetID[id] = nil
        }
        rejectFetchesStartedBeforeNextRequest(bucketIDs: bucketIDs)
    }

    mutating func rollbackRemoval(operationID: UUID, ids: Set<String>) -> [String: Asset] {
        var restored: [String: Asset] = [:]
        for id in ids where removalsByAssetID[id]?.operationID == operationID {
            restored[id] = removalsByAssetID[id]?.source.asset
            removalsByAssetID[id] = nil
        }
        return restored
    }

    mutating func resolve(
        _ fetchedAssets: [Asset],
        for fetch: TimelineBucketFetch
    ) -> TimelineBucketResolution? {
        let latest = latestAppliedFetchByBucket[fetch.bucketID] ?? 0
        guard fetch.sequence >= latest else { return nil }
        latestAppliedFetchByBucket[fetch.bucketID] = fetch.sequence

        var assets = fetchedAssets
        var projected = favoritesByAssetID.values.contains { $0.bucketID == fetch.bucketID }
        for asset in assets {
            guard var removal = removalsByAssetID[asset.id],
                  removal.source.bucketID == fetch.bucketID
            else { continue }
            removal.source = TimelineProjectionSource(bucketID: fetch.bucketID, asset: asset)
            removalsByAssetID[asset.id] = removal
        }
        for index in assets.indices {
            let id = assets[index].id
            guard let favorite = favoritesByAssetID[id],
                  favorite.bucketID == fetch.bucketID
            else { continue }
            assets[index].isFavorite = favorite.value
            projected = true
        }

        let removals: Set<String> = Set(removalsByAssetID.compactMap { id, projection -> String? in
            guard projection.source.bucketID == fetch.bucketID else { return nil }
            return id
        })
        if !removals.isEmpty {
            assets.removeAll { removals.contains($0.id) }
            projected = true
        }

        return TimelineBucketResolution(assets: assets, isAuthoritative: !projected)
    }
}

/// one day group's title inside a shared title band, pinned to the columns
/// its tiles occupy below.
nonisolated struct TitleSegment: Hashable {
    let dayID: String
    let title: String
    let colStart: Int
    let colWidth: Int
    /// server assets of the day, for the select-all toggle.
    let selectableIDs: [String]
}

/// contiguous tiles within one row band, starting at a column offset. rows
/// shared by several days carry one run per day.
nonisolated struct TileRun: Hashable {
    let colStart: Int
    let assets: [Asset]
}

/// per-month row tallies captured at build time so the scrubber overlay can
/// map months to exact offsets without walking rows.
nonisolated struct TimelineSectionSpan: Hashable {
    let id: String
    let title: String
    let year: Int
    let titleBands: Int
    let tileRows: Int
}

/// flat list element with a deterministic height. fixed heights are what keep
/// lazyvstack from re-measuring and jumping while scrolling backwards.
nonisolated enum TimelineRow: Identifiable, Hashable {
    case titleBand(String, [TitleSegment])
    case tiles(String, [TileRun])
    case placeholder(String, String, Int, Int)

    var id: String {
        switch self {
        case .titleBand(let id, _): id
        case .tiles(let id, _): id
        case .placeholder(let id, _, _, _): id
        }
    }

    func height(tileSide: CGFloat) -> CGFloat {
        switch self {
        case .titleBand: 36
        case .tiles: tileSide + 2
        case .placeholder(_, _, let rows, let bands):
            CGFloat(bands) * 36 + CGFloat(rows) * (tileSide + 2)
        }
    }
}

/// drives any bucketed grid screen: main timeline, favorites, archive, trash, person, album.
@Observable
final class TimelineModel {
    private struct SectionProjection {
        let source: TimelineSection
        let columns: Int
        let placeholderRatio: Double?
        let rows: [TimelineRow]
        let firstAssetIDByRowID: [String: String]
        let span: TimelineSectionSpan?
        let titleBandCount: Int
        let tileRowCount: Int
        let assetCount: Int
        let dayCount: Int

        func canReuse(
            for section: TimelineSection,
            columns: Int,
            placeholderRatio: Double
        ) -> Bool {
            guard self.columns == columns,
                  source.id == section.id,
                  source.monthTitle == section.monthTitle
            else { return false }
            if source.isLoaded, section.isLoaded {
                return source.days == section.days
            }
            return source == section && self.placeholderRatio == placeholderRatio
        }
    }

    let filter: TimelineFilter
    /// main timeline only: device photos not yet on the server appear in the
    /// grid with backup badges, google-photos style.
    let mergesLocal: Bool
    private(set) var sections: [TimelineSection] = []
    private(set) var rows: [TimelineRow] = []
    /// bumped when row geometry changes so the screen's exact row-offset cache
    /// knows to rebuild. metadata patches keep the existing offsets.
    @ObservationIgnored private(set) var rowsLayoutVersion = 0
    /// the month each row belongs to. the scrubber names its month from the
    /// row actually at the viewport top rather than from offset arithmetic,
    /// so the label is right even while unloaded months are still estimates.
    private(set) var monthByRowID: [String: String] = [:]
    /// anchors a visible row back into `flatAssets` so the prefetcher can size
    /// its window in assets rather than rows.
    private(set) var firstAssetIDByRowID: [String: String] = [:]
    private(set) var isLoading = false
    private(set) var loadError: String?
    private(set) var flatAssets: [Asset] = []
    private(set) var projectedRemovalIDs = Set<String>()
    /// bumped when flat asset ordering changes. metadata patches keep the
    /// prefetch window valid without comparing every asset.
    @ObservationIgnored private(set) var flatAssetsVersion = 0

    /// row tallies kept in sync by rebuildRows so screens can do o(1) height
    /// math instead of summing thousands of rows.
    private(set) var titleBandCount = 0
    private(set) var tileRowCount = 0
    /// months in display order with their row tallies, for scrubber markers.
    private(set) var sectionSpans: [TimelineSectionSpan] = []

    /// how many photos a day holds on average in this library, the one number
    /// an unloaded month needs to be laid out like a loaded one. measured from
    /// the months already in hand and persisted, so the very first frame after
    /// launch places every month about where it will finally sit instead of
    /// letting the grid stretch bucket by bucket as the prefetch lands.
    private var assetsPerDay = TimelineModel.defaultAssetsPerDay
    private var persistedAssetsPerDay = TimelineModel.defaultAssetsPerDay

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
    /// buckets whose days came from the offline cache or were flagged changed
    /// by a fresh list. they render immediately but refetch when reachable.
    private var staleBucketIDs: Set<String> = []
    /// one offline thumbnail sweep per model lifetime, after the first
    /// complete online prefetch pass.
    private var hasSwept = false
    private var flatAssetIndexByID: [String: Int] = [:]
    private var bucketIDByAssetID: [String: String] = [:]
    private var rowAssetLocationByID: [String: TimelineAssetProjection.Location] = [:]
    private var sectionProjectionByID: [String: SectionProjection] = [:]
    private var prefetchTask: Task<Void, Never>?
    private var prefetchID: UUID?
    private var rebuildTask: Task<Void, Never>?
    private var restoreTask: Task<Void, Never>?
    private var hasLoaded = false
    private var isViewerSuspended = false
    private var isRebuildDeferred = false
    private var rebuildPending = false
    private var pendingRebuildAnimated = false
    /// device assets paired with backup status, merged during row building.
    private var localItems: [LocalTimelineItem] = []
    private var resyncTask: Task<Void, Never>?
    private var resyncAgain = false
    private var resyncPending = false
    private var mutationOverlay = TimelineMutationOverlay()
    private var externalFavoriteRollbacks: [String: TimelineFavoriteMutation] = [:]
    private var externalRemovalRollbacks: [String: TimelineRemoval] = [:]
    /// realtime events buffered per asset, applied in one walk. a bulk action
    /// from another client arrives as hundreds of single-asset events, and
    /// paying a full row rebuild for each froze large libraries.
    private var pendingRealtimeDetails: [String: AssetDetail] = [:]
    private var pendingRealtimeRemovals: Set<String> = []
    private var realtimeFlushTask: Task<Void, Never>?

    init(filter: TimelineFilter, mergesLocal: Bool = false) {
        self.filter = filter
        self.mergesLocal = mergesLocal
        // read before the first rebuild below - that rebuild lays out every
        // month the cache knows about, and it needs last launch's ratio to
        // place them where they will stay.
        if let key = Self.assetsPerDayKey(for: filter) {
            let stored = UserDefaults.standard.double(forKey: key)
            if stored > 0 {
                assetsPerDay = stored
                persistedAssetsPerDay = stored
            }
        }
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
        realtimeFlushTask?.cancel()
        restoreTask?.cancel()
    }

    /// rows cover both server sections and merged device photos.
    var isEmpty: Bool { !isLoading && rows.isEmpty }

    func flatAssetIndex(for id: String) -> Int? {
        flatAssetIndexByID[id]
    }

    var viewerAssetIndexByID: [String: Int] {
        flatAssetIndexByID
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

        // paint everything the offline store has before touching the network,
        // so the grid is browsable instantly - and stays that way offline.
        await restoreCachedBuckets(using: client)

        do {
            try await reloadSections(using: client)
            hasLoaded = true
            await refreshLocalItems()
            // small libraries finish inside reloadSections with no prefetch
            // pass left to trigger the sweep, so it is offered here too.
            sweepThumbnailsIfNeeded()
        } catch is CancellationError {
            return
        } catch {
            loadError = error.localizedDescription
            // device photos still belong in the grid when the server is away.
            await refreshLocalItems()
        }
    }

    private func account(for client: ImmichClient) -> String? {
        client.apiURL.host().map { SessionCache.accountKey(host: $0) }
    }

    /// fills placeholder sections with their last fetched assets from disk.
    /// restored buckets are marked stale so the next reachable pass refetches
    /// them, keeping freshness identical to an uncached launch.
    ///
    /// split in two so a huge cached library paints fast: the newest months -
    /// what the first frame shows - decode and land before this returns, and
    /// the long tail decodes across cores while the network load already
    /// runs, applying in one debounced pass.
    private func restoreCachedBuckets(using client: ImmichClient) async {
        guard let account = account(for: client) else { return }
        let missing = sections.filter { $0.days == nil }.map(\.id)
        guard !missing.isEmpty else { return }
        let filter = filter

        let head = Array(missing.prefix(6))
        let restoredHead = await TimelineCache.restoreBucketsConcurrently(
            head, filter: filter, account: account
        )
        applyRestoredBuckets(restoredHead)
        if !restoredHead.isEmpty {
            rebuildRows(rebuildAssets: true)
        }

        let tail = Array(missing.dropFirst(6))
        guard !tail.isEmpty else { return }
        restoreTask?.cancel()
        restoreTask = Task { [weak self] in
            let restored = await TimelineCache.restoreBucketsConcurrently(
                tail, filter: filter, account: account
            )
            guard let self, !Task.isCancelled, !restored.isEmpty else { return }
            self.applyRestoredBuckets(restored)
            self.scheduleRebuild()
        }
    }

    /// only fills placeholders, so a bucket the network answered while the
    /// decode ran keeps its fresh days.
    private func applyRestoredBuckets(_ restored: [String: [Asset]]) {
        guard !restored.isEmpty else { return }
        for index in sections.indices where sections[index].days == nil {
            guard let assets = restored[sections[index].id] else { continue }
            sections[index].days = Self.groupByDay(assets, byUploadDate: filter.groupsByUploadDate)
            staleBucketIDs.insert(sections[index].id)
        }
    }

    /// persists a fetched bucket for offline browsing. fire and forget, off
    /// the main actor - a lost write only costs a refetch next launch.
    private func cacheBucket(_ id: String, assets: [Asset]) {
        guard let client, let account = account(for: client) else { return }
        let filter = filter
        Task.detached(priority: .utility) {
            TimelineCache.storeBucketAssets(assets, bucketID: id, filter: filter, account: account)
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
        if let account = account(for: client) {
            TimelineCache.store(buckets, for: filter, account: account)
        }
        // diff instead of wipe: days already on screen - restored from disk or
        // fetched live - stay put, and only what the fresh list says changed
        // gets flagged for refetch.
        let existingByID = Dictionary(sections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var fresh: [TimelineSection] = []
        for bucket in buckets {
            if let existing = existingByID[bucket.timeBucket] {
                if existing.count != bucket.count, existing.isLoaded {
                    staleBucketIDs.insert(bucket.timeBucket)
                }
                fresh.append(TimelineSection(
                    id: existing.id,
                    monthTitle: existing.monthTitle,
                    count: bucket.count,
                    days: existing.days
                ))
            } else {
                fresh.append(TimelineSection(
                    id: bucket.timeBucket,
                    monthTitle: Self.monthTitle(for: bucket.timeBucket),
                    count: bucket.count,
                    days: nil
                ))
            }
        }
        let changed = sections != fresh
        sections = fresh
        staleBucketIDs.formIntersection(buckets.map(\.timeBucket))
        if changed {
            rebuildRows(rebuildAssets: true)
        }
        // the first bucket lands before the prefetch, and it is what calibrates
        // the estimate for every month still unloaded.
        if let first = sections.first { await loadBucket(first.id) }
        startPrefetch()
    }

    func loadBucket(_ id: String, immediateRows: Bool = true, refresh: Bool = false) async {
        guard !isViewerSuspended,
              let client,
              let index = sections.firstIndex(where: { $0.id == id }),
              sections[index].days == nil || refresh,
              !inflightBuckets.contains(id)
        else { return }
        inflightBuckets.insert(id)
        defer { inflightBuckets.remove(id) }
        let fetch = mutationOverlay.beginFetch(bucketID: id)
        do {
            let assets = try await client.timeBucket(id, filter: filter)
            try Task.checkCancellation()
            guard !isViewerSuspended,
                  let current = sections.firstIndex(where: { $0.id == id })
            else { return }
            guard let resolution = mutationOverlay.resolve(assets, for: fetch) else { return }
            staleBucketIDs.remove(id)
            let days = Self.groupByDay(
                resolution.assets,
                byUploadDate: filter.groupsByUploadDate
            )
            let changed = sections[current].days != days
            sections[current].days = days
            if resolution.isAuthoritative {
                cacheBucket(id, assets: resolution.assets)
            }
            guard changed else { return }
            if immediateRows {
                rebuildRows(rebuildAssets: true)
            } else {
                scheduleRebuild()
            }
        } catch is CancellationError {
            // leave the placeholder; a retry happens next time it scrolls in.
        } catch {
            // offline, most likely. the disk copy beats an empty placeholder,
            // and a live retry happens next time the row scrolls into view.
            await fallBackToCachedBucket(id)
        }
    }

    /// offline fallback for a single bucket whose fetch just failed. only
    /// fills placeholders - a failed refresh keeps the days it already had.
    private func fallBackToCachedBucket(_ id: String) async {
        guard let client, let account = account(for: client),
              sections.first(where: { $0.id == id })?.days == nil
        else { return }
        let filter = filter
        let cached = await Task.detached(priority: .utility) {
            TimelineCache.bucketAssets(id, filter: filter, account: account)
        }.value
        guard let cached, !cached.isEmpty,
              !isViewerSuspended,
              let current = sections.firstIndex(where: { $0.id == id }),
              sections[current].days == nil
        else { return }
        staleBucketIDs.insert(id)
        sections[current].days = Self.groupByDay(cached, byUploadDate: filter.groupsByUploadDate)
        scheduleRebuild()
    }

    /// loads every remaining bucket in the background so heights become exact
    /// and the scrubber can jump anywhere without triggering churn. buckets
    /// restored from disk count as remaining - they refetch here, so cached
    /// launches end up exactly as fresh as uncached ones.
    private func startPrefetch() {
        guard !isViewerSuspended, prefetchTask == nil else { return }
        let bucketIDs = sections.filter { !$0.isLoaded || staleBucketIDs.contains($0.id) }.map(\.id)
        guard !bucketIDs.isEmpty else {
            sweepThumbnailsIfNeeded()
            return
        }
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
                await self.loadBucket(
                    bucketID,
                    immediateRows: false,
                    refresh: self.staleBucketIDs.contains(bucketID)
                )
            }
            guard !Task.isCancelled, !self.isViewerSuspended else { return }
            if self.rebuildPending {
                self.rebuildRows(rebuildAssets: true)
            }
            // cleared here rather than left to the defer so the sweep sees a
            // finished pass; the defer then has nothing left to reset.
            if self.prefetchID == id {
                self.prefetchTask = nil
                self.prefetchID = nil
            }
            self.sweepThumbnailsIfNeeded()
        }
    }

    /// hands the whole library to the offline thumbnail sweep once the first
    /// complete online pass settles. main merged timeline only - it is the
    /// grid that spans everything. assets with a paired device copy render
    /// from photokit and need no network, so they are skipped.
    private func sweepThumbnailsIfNeeded() {
        guard mergesLocal, hasLoaded, !hasSwept, prefetchTask == nil, let client else { return }
        hasSwept = true
        let urls = flatAssets.compactMap { asset -> URL? in
            guard asset.localIdentifier == nil,
                  backup?.localIdentifierByRemoteId[asset.id] == nil
            else { return nil }
            return client.thumbnailURL(assetID: asset.id, cacheKey: asset.thumbhash)
        }
        ImageLoader.shared.sweepThumbnails(urls: urls)
    }

    // MARK: - rows

    private func rebuildRows(rebuildAssets: Bool = false, animated: Bool = false) {
        if rebuildAssets {
            rebuildTask?.cancel()
            rebuildTask = nil
            rebuildPending = false
            pendingRebuildAnimated = false
        }
        var result: [TimelineRow] = []
        var spans: [TimelineSectionSpan] = []
        var monthByRowID: [String: String] = [:]
        var firstAssetIDByRowID: [String: String] = [:]
        var flattened: [Asset] = []
        var flattenedIndex: [String: Int] = [:]
        var bucketByAssetID: [String: String] = [:]
        result.reserveCapacity(rows.count + 16)
        if rebuildAssets {
            flattened.reserveCapacity(sections.reduce(0) { $0 + $1.count })
        }

        var titleBands = 0
        var tileRows = 0
        // grows as loaded months are walked, so placeholders further down get
        // a ratio measured on this very rebuild; the value kept from the last
        // one - or from the last launch - covers the months above them.
        var assetTally = 0
        var dayTally = 0
        var ratio = assetsPerDay

        var nextSectionProjectionByID: [String: SectionProjection] = [:]
        let projectedSections = mergedSections()
        nextSectionProjectionByID.reserveCapacity(projectedSections.count)

        for section in projectedSections {
            let projection: SectionProjection
            if let cached = sectionProjectionByID[section.id],
               cached.canReuse(for: section, columns: columns, placeholderRatio: ratio) {
                projection = cached
            } else {
                projection = makeSectionProjection(section, placeholderRatio: ratio)
            }
            nextSectionProjectionByID[section.id] = projection

            result.append(contentsOf: projection.rows)
            for row in projection.rows {
                monthByRowID[row.id] = section.monthTitle
            }
            firstAssetIDByRowID.merge(projection.firstAssetIDByRowID) { _, new in new }
            if let span = projection.span {
                spans.append(span)
            }
            titleBands += projection.titleBandCount
            tileRows += projection.tileRowCount

            if rebuildAssets, let days = section.days {
                for day in days {
                    for asset in day.assets {
                        flattenedIndex[asset.id] = flattened.count
                        bucketByAssetID[asset.id] = section.id
                        flattened.append(asset)
                    }
                }
            }

            assetTally += projection.assetCount
            dayTally += projection.dayCount
            if dayTally > 0 { ratio = Double(assetTally) / Double(dayTally) }
        }

        if dayTally > 0, assetTally > 0 {
            assetsPerDay = ratio
            // rebuilds are frequent; only a ratio that actually moved is
            // worth writing out for the next launch.
            if abs(ratio - persistedAssetsPerDay) > 0.25, let key = Self.assetsPerDayKey(for: filter) {
                persistedAssetsPerDay = ratio
                UserDefaults.standard.set(ratio, forKey: key)
            }
        }

        let commit = {
            self.rows = result
            self.rowsLayoutVersion &+= 1
            self.rowAssetLocationByID = TimelineAssetProjection.locations(in: result)
            self.sectionProjectionByID = nextSectionProjectionByID
            self.sectionSpans = spans
            self.monthByRowID = monthByRowID
            self.firstAssetIDByRowID = firstAssetIDByRowID
            if rebuildAssets {
                self.flatAssets = flattened
                self.flatAssetIndexByID = flattenedIndex
                self.bucketIDByAssetID = bucketByAssetID
                self.projectedRemovalIDs.formIntersection(flattenedIndex.keys)
                self.flatAssetsVersion &+= 1
            }
            self.titleBandCount = titleBands
            self.tileRowCount = tileRows
        }
        if animated, rows != result, !rows.isEmpty, let applyRowsUpdate {
            applyRowsUpdate(rows, result, commit)
        } else {
            commit()
        }
    }

    private func makeSectionProjection(
        _ section: TimelineSection,
        placeholderRatio: Double
    ) -> SectionProjection {
        var rows: [TimelineRow] = []
        var firstAssetIDByRowID: [String: String] = [:]
        var titleBands = 0
        var tileRows = 0
        var assetCount = 0
        var dayCount = 0

        if let days = section.days {
            assetCount = days.reduce(0) { $0 + $1.assets.count }
            dayCount = days.count
            for band in TimelineFlowLayout.pack(counts: days.map(\.assets.count), columns: columns) {
                guard let firstBlock = band.blocks.first else { continue }
                let firstDay = days[firstBlock.dayIndex]
                let bandID = "b-\(section.id)-\(firstDay.id)"
                let segments = band.blocks.map { block in
                    let day = days[block.dayIndex]
                    return TitleSegment(
                        dayID: day.id,
                        title: day.title,
                        colStart: block.colStart,
                        colWidth: block.colWidth,
                        selectableIDs: day.assets.filter { !$0.isLocal }.map(\.id)
                    )
                }
                rows.append(.titleBand(bandID, segments))
                titleBands += 1

                for rowIndex in 0..<band.rowCount {
                    var runs: [TileRun] = []
                    for block in band.blocks where rowIndex < block.rowCount {
                        let assets = days[block.dayIndex].assets
                        let start = rowIndex * block.colWidth
                        guard start < assets.count else { continue }
                        let end = min(start + block.colWidth, assets.count)
                        runs.append(TileRun(
                            colStart: block.colStart,
                            assets: Array(assets[start..<end])
                        ))
                    }
                    guard let firstRun = runs.first else { continue }
                    let tileID = "t-\(section.id)-\(firstDay.id)-\(rowIndex)"
                    rows.append(.tiles(tileID, runs))
                    firstAssetIDByRowID[tileID] = firstRun.assets[0].id
                    tileRows += 1
                }
            }
        } else {
            let estimate = Self.placeholderEstimate(
                count: section.count,
                columns: columns,
                assetsPerDay: placeholderRatio
            )
            rows.append(.placeholder(
                "p-\(section.id)",
                section.id,
                estimate.tileRows,
                estimate.titleBands
            ))
            titleBands = estimate.titleBands
            tileRows = estimate.tileRows
        }

        let span = rows.isEmpty ? nil : TimelineSectionSpan(
            id: section.id,
            title: section.monthTitle,
            year: Self.year(for: section.id),
            titleBands: titleBands,
            tileRows: tileRows
        )
        return SectionProjection(
            source: section,
            columns: columns,
            placeholderRatio: section.isLoaded ? nil : placeholderRatio,
            rows: rows,
            firstAssetIDByRowID: firstAssetIDByRowID,
            span: span,
            titleBandCount: titleBands,
            tileRowCount: tileRows,
            assetCount: assetCount,
            dayCount: dayCount
        )
    }

    /// how tall an unloaded month renders, in the row units the real layout
    /// uses. the month's photos are spread over a plausible number of days and
    /// run through the very packer the loaded path uses, so day titles and
    /// imperfect packing are both priced in and the answer follows the column
    /// count through a pinch. a month cannot span more than 31 days, which is
    /// what keeps a busy month from being estimated as hundreds of tiny ones.
    private static func placeholderEstimate(
        count: Int,
        columns: Int,
        assetsPerDay: Double
    ) -> (tileRows: Int, titleBands: Int) {
        guard count > 0, columns > 0 else { return (1, 0) }
        let perDay = max(1, assetsPerDay)
        let days = min(31, max(1, Int((Double(count) / perDay).rounded())))
        let base = count / days
        let remainder = count % days
        let counts = (0..<days).map { $0 < remainder ? base + 1 : base }
        let bands = TimelineFlowLayout.pack(counts: counts.filter { $0 > 0 }, columns: columns)
        guard !bands.isEmpty else {
            return (max(1, Int((Double(count) / Double(columns)).rounded(.up))), 0)
        }
        return (bands.reduce(0) { $0 + $1.rowCount }, bands.count)
    }

    static let defaultAssetsPerDay: Double = 6

    /// scoped to the grid, since an album's photos-per-day says nothing about
    /// the main timeline's. grids the cache deliberately skips - albums,
    /// people, map areas - keep the ratio in memory only.
    private static func assetsPerDayKey(for filter: TimelineFilter) -> String? {
        TimelineCache.key(for: filter).map { "imora.timeline.assetsPerDay.\($0)" }
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
        CGFloat(titleBandCount) * 36
            + CGFloat(tileRowCount) * (tileSide + 2)
    }

    private func scheduleRebuild(
        animated: Bool = false,
        after delay: Duration = .milliseconds(250),
        replacesPending: Bool = false
    ) {
        rebuildPending = true
        pendingRebuildAnimated = pendingRebuildAnimated || animated
        guard !isViewerSuspended, !isRebuildDeferred else { return }
        if replacesPending {
            rebuildTask?.cancel()
            rebuildTask = nil
        }
        guard rebuildTask == nil else { return }
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.rebuildTask = nil
            guard !self.isViewerSuspended, !self.isRebuildDeferred else { return }
            self.rebuildPending = false
            let animated = self.pendingRebuildAnimated
            self.pendingRebuildAnimated = false
            self.rebuildRows(rebuildAssets: true, animated: animated)
        }
    }

    private func scheduleOptimisticRebuild() {
        scheduleRebuild(
            animated: true,
            after: .milliseconds(140),
            replacesPending: true
        )
    }

    /// held for the length of a scrubber drag. buckets the drag passes still
    /// load and keep their days, but reflowing the whole library every 250ms
    /// under a finger that is about to be somewhere else is work nobody sees -
    /// and the scrubber freezes its own month layout for the same reason.
    func deferRebuilds() {
        guard !isRebuildDeferred else { return }
        isRebuildDeferred = true
        rebuildTask?.cancel()
        rebuildTask = nil
    }

    func resumeRebuilds() {
        guard isRebuildDeferred else { return }
        isRebuildDeferred = false
        if rebuildPending { scheduleRebuild() }
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
            if let account = account(for: client) {
                TimelineCache.store(buckets, for: filter, account: account)
            }
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
                        // an unchanged count does not clear a stale restore -
                        // this is where offline-restored buckets get their
                        // refetch once the server answers again.
                        if staleBucketIDs.contains(bucket.timeBucket), existing.isLoaded {
                            dirty = true
                            toFetch.append(bucket.timeBucket)
                        }
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
            var projectionChanged = sections != fresh
            sections = fresh
            for id in toFetch {
                guard !isViewerSuspended else {
                    resyncPending = true
                    break
                }
                let fetch = mutationOverlay.beginFetch(bucketID: id)
                if let assets = try? await client.timeBucket(id, filter: filter),
                   let resolution = mutationOverlay.resolve(assets, for: fetch),
                   let index = sections.firstIndex(where: { $0.id == id }) {
                    staleBucketIDs.remove(id)
                    let days = Self.groupByDay(
                        resolution.assets,
                        byUploadDate: filter.groupsByUploadDate
                    )
                    projectionChanged = projectionChanged || sections[index].days != days
                    sections[index].days = days
                    if resolution.isAuthoritative {
                        cacheBucket(id, assets: resolution.assets)
                    }
                }
            }
            projectionChanged = await updateLocalItems() || projectionChanged
            guard projectionChanged else { return }
            guard !isViewerSuspended else {
                rebuildPending = true
                return
            }
            rebuildRows(rebuildAssets: true, animated: true)
        } catch {
            // stale is fine; the next event, tick or foreground pass retries.
        }
    }

    // MARK: - local merge

    /// re-reads device assets and their backup status, then rebuilds rows.
    func refreshLocalItems() async {
        guard await updateLocalItems() else { return }
        if isViewerSuspended {
            rebuildPending = true
        } else {
            rebuildRows(rebuildAssets: true, animated: true)
        }
    }

    @discardableResult
    private func updateLocalItems() async -> Bool {
        guard mergesLocal, let backup else { return false }
        let items = await backup.localTimelineAssets()
        guard items != localItems else { return false }
        localItems = items
        return true
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

    private static func dayIndex(for date: Date) -> Int {
        Int((date.timeIntervalSince1970 / 86_400).rounded(.down))
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
            let key = String(dayIndex(for: asset.localDate))
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

    /// applies metadata without rebuilding row geometry or the viewer index.
    func updateAssets(ids: Set<String>, _ transform: (inout Asset) -> Void) {
        let targetBucketIDs = bucketIDs(containing: ids)
        var changedBucketIDs = Set<String>()
        var changedAssets: [String: Asset] = [:]
        for s in sections.indices where targetBucketIDs.contains(sections[s].id) {
            guard var days = sections[s].days else { continue }
            var sectionChanged = false
            for d in days.indices {
                var assets = days[d].assets
                var dayChanged = false
                for a in assets.indices where ids.contains(assets[a].id) {
                    let before = assets[a]
                    transform(&assets[a])
                    if assets[a] != before {
                        changedAssets[assets[a].id] = assets[a]
                        dayChanged = true
                    }
                }
                if dayChanged {
                    days[d] = DayGroup(id: days[d].id, title: days[d].title, assets: assets)
                    sectionChanged = true
                }
            }
            if sectionChanged {
                sections[s].days = days
                changedBucketIDs.insert(sections[s].id)
            }
        }
        guard !changedBucketIDs.isEmpty else { return }
        mutationOverlay.rejectFetchesStartedBeforeNextRequest(bucketIDs: changedBucketIDs)
        TimelineAssetProjection.patchRows(
            &rows,
            assetsByID: changedAssets,
            locations: rowAssetLocationByID
        )
        TimelineAssetProjection.patchFlatAssets(
            &flatAssets,
            assetsByID: changedAssets,
            indicesByID: flatAssetIndexByID
        )
    }

    func setFavoriteForOptimisticAction(
        ids: Set<String>,
        value: Bool
    ) -> TimelineFavoriteMutation {
        let operationID = UUID()
        var previousValues: [String: Bool] = [:]
        var bucketsByAssetID: [String: String] = [:]
        let targetBucketIDs = bucketIDs(containing: ids)
        for section in sections where targetBucketIDs.contains(section.id) {
            for day in section.days ?? [] {
                for asset in day.assets where ids.contains(asset.id) {
                    previousValues[asset.id] = asset.isFavorite
                    bucketsByAssetID[asset.id] = section.id
                }
            }
        }
        mutationOverlay.beginFavorite(
            operationID: operationID,
            value: value,
            bucketIDsByAssetID: bucketsByAssetID
        )
        updateAssets(ids: ids) { $0.isFavorite = value }
        return TimelineFavoriteMutation(
            operationID: operationID,
            value: value,
            previousValues: previousValues
        )
    }

    func commit(_ favorite: TimelineFavoriteMutation) {
        mutationOverlay.commitFavorite(operationID: favorite.operationID, ids: favorite.ids)
    }

    func restore(_ favorite: TimelineFavoriteMutation) {
        let ids = mutationOverlay.rollbackFavorite(
            operationID: favorite.operationID,
            ids: favorite.ids
        )
        guard !ids.isEmpty else { return }
        updateAssets(ids: ids) { asset in
            guard asset.isFavorite == favorite.value,
                  let previous = favorite.previousValues[asset.id]
            else { return }
            asset.isFavorite = previous
        }
    }

    func beginExternalOptimisticFavorite(id: String, value: Bool) {
        guard externalFavoriteRollbacks[id] == nil else {
            guard externalFavoriteRollbacks[id]?.value != value,
                  let favorite = externalFavoriteRollbacks.removeValue(forKey: id)
            else { return }
            restore(favorite)
            return
        }
        externalFavoriteRollbacks[id] = setFavoriteForOptimisticAction(ids: [id], value: value)
    }

    func commitExternalOptimisticFavorite(id: String) {
        guard let favorite = externalFavoriteRollbacks.removeValue(forKey: id) else { return }
        commit(favorite)
    }

    /// drops assets from the grid for authoritative realtime/legacy events.
    func removeAssets(ids: Set<String>) {
        _ = removeAssetsNow(ids: ids, operationID: nil)
    }

    func beginExternalOptimisticRemoval(id: String) {
        guard externalRemovalRollbacks[id] == nil else { return }
        externalRemovalRollbacks[id] = removeAssetsForOptimisticAction(ids: [id])
    }

    func commitExternalOptimisticRemoval(id: String) {
        guard let removal = externalRemovalRollbacks.removeValue(forKey: id) else { return }
        commit(removal, ids: [id])
    }

    func rollbackExternalOptimisticRemoval(id: String) {
        guard let removal = externalRemovalRollbacks.removeValue(forKey: id) else { return }
        restore(removal, ids: [id])
    }

    func clearForOptimisticAction() -> TimelineClear {
        let operationID = UUID()
        let snapshot = TimelineClear(operationID: operationID, sections: sections)
        mutationOverlay.rejectFetchesStartedBeforeNextRequest(
            bucketIDs: Set(sections.map(\.id))
        )
        mutationOverlay.beginRemoval(
            operationID: operationID,
            sourcesByAssetID: projectionSources(in: sections)
        )
        sections = []
        rebuildRows(rebuildAssets: true, animated: !isViewerSuspended)
        return snapshot
    }

    func commit(_ clear: TimelineClear) {
        mutationOverlay.commitRemoval(
            operationID: clear.operationID,
            ids: assetIDs(in: clear.sections)
        )
    }

    func restore(_ clear: TimelineClear) {
        let ids = assetIDs(in: clear.sections)
        let restored = mutationOverlay.rollbackRemoval(operationID: clear.operationID, ids: ids)
        guard !clear.sections.isEmpty else { return }
        mutationOverlay.rejectFetchesStartedBeforeNextRequest(
            bucketIDs: Set(clear.sections.map(\.id))
        )
        for (sectionIndex, original) in clear.sections.enumerated() {
            var snapshot = original
            if let originalDays = original.days {
                snapshot.days = originalDays.compactMap { day in
                    let assets = day.assets.compactMap { restored[$0.id] }
                    guard !assets.isEmpty else { return nil }
                    return DayGroup(id: day.id, title: day.title, assets: assets)
                }
            }
            guard original.days == nil || snapshot.days?.isEmpty == false else { continue }
            guard let existingIndex = sections.firstIndex(where: { $0.id == snapshot.id }) else {
                sections.insert(snapshot, at: min(sectionIndex, sections.count))
                continue
            }
            guard let snapshotDays = snapshot.days else { continue }
            guard var currentDays = sections[existingIndex].days else {
                sections[existingIndex].days = snapshotDays
                continue
            }
            for (dayIndex, snapshotDay) in snapshotDays.enumerated() {
                guard let currentDayIndex = currentDays.firstIndex(where: { $0.id == snapshotDay.id }) else {
                    currentDays.insert(snapshotDay, at: min(dayIndex, currentDays.count))
                    continue
                }
                var currentAssets = currentDays[currentDayIndex].assets
                for (assetIndex, asset) in snapshotDay.assets.enumerated()
                where !currentAssets.contains(where: { $0.id == asset.id }) {
                    currentAssets.insert(asset, at: min(assetIndex, currentAssets.count))
                }
                currentDays[currentDayIndex] = DayGroup(
                    id: currentDays[currentDayIndex].id,
                    title: currentDays[currentDayIndex].title,
                    assets: currentAssets
                )
            }
            sections[existingIndex].days = currentDays
        }
        rebuildRows(rebuildAssets: true, animated: !isViewerSuspended)
    }

    /// Removes now and returns a narrow, position-preserving undo token.
    func removeAssetsForOptimisticAction(ids: Set<String>) -> TimelineRemoval {
        removeAssetsNow(ids: ids, operationID: UUID())
    }

    private func removeAssetsNow(ids: Set<String>, operationID: UUID?) -> TimelineRemoval {
        let targetBucketIDs = bucketIDs(containing: ids)
        mutationOverlay.rejectFetchesStartedBeforeNextRequest(
            bucketIDs: targetBucketIDs
        )
        var placements: [TimelineRemoval.Placement] = []
        for (sectionIndex, section) in sections.enumerated()
        where targetBucketIDs.contains(section.id) {
            guard let days = section.days else { continue }
            for (dayIndex, day) in days.enumerated() {
                for (assetIndex, asset) in day.assets.enumerated() where ids.contains(asset.id) {
                    placements.append(.init(
                        section: section,
                        sectionIndex: sectionIndex,
                        day: day,
                        dayIndex: dayIndex,
                        asset: asset,
                        assetIndex: assetIndex
                    ))
                }
            }
        }
        if let operationID {
            projectedRemovalIDs.formUnion(placements.map(\.asset.id))
            let sources = Dictionary(uniqueKeysWithValues: placements.map {
                ($0.asset.id, TimelineProjectionSource(bucketID: $0.section.id, asset: $0.asset))
            })
            mutationOverlay.beginRemoval(operationID: operationID, sourcesByAssetID: sources)
        }
        for s in sections.indices where targetBucketIDs.contains(sections[s].id) {
            guard let days = sections[s].days else { continue }
            let filtered = days.compactMap { day -> DayGroup? in
                let remaining = day.assets.filter { !ids.contains($0.id) }
                return remaining.isEmpty ? nil : DayGroup(id: day.id, title: day.title, assets: remaining)
            }
            sections[s].days = filtered
        }
        for id in placements.map(\.asset.id) {
            bucketIDByAssetID[id] = nil
        }
        sections.removeAll { $0.isLoaded && ($0.days?.isEmpty ?? false) }
        if operationID == nil {
            rebuildRows(rebuildAssets: true, animated: !isViewerSuspended)
        } else {
            scheduleOptimisticRebuild()
        }
        return TimelineRemoval(operationID: operationID, placements: placements)
    }

    func commit(_ removal: TimelineRemoval, ids: Set<String>? = nil) {
        guard let operationID = removal.operationID else { return }
        mutationOverlay.commitRemoval(
            operationID: operationID,
            ids: ids ?? Set(removal.placements.map(\.asset.id))
        )
    }

    /// Replays only a failed command's removals, leaving later mutations and
    /// realtime additions intact.
    func restore(_ removal: TimelineRemoval, ids: Set<String>? = nil) {
        let requested = ids ?? Set(removal.placements.map(\.asset.id))
        let restoredAssets: [String: Asset]
        if let operationID = removal.operationID {
            restoredAssets = mutationOverlay.rollbackRemoval(
                operationID: operationID,
                ids: requested
            )
        } else {
            restoredAssets = [:]
        }
        let wanted = removal.operationID == nil ? requested : Set(restoredAssets.keys)
        let placements = removal.placements
            .filter { wanted.contains($0.asset.id) }
            .sorted {
                ($0.sectionIndex, $0.dayIndex, $0.assetIndex)
                    < ($1.sectionIndex, $1.dayIndex, $1.assetIndex)
            }
        guard !placements.isEmpty else { return }
        mutationOverlay.rejectFetchesStartedBeforeNextRequest(
            bucketIDs: Set(placements.map(\.section.id))
        )

        for placement in placements where !containsAsset(placement.asset.id) {
            let sectionIndex = restoreSection(for: placement)
            var days = sections[sectionIndex].days ?? []
            let dayIndex: Int
            if let existing = days.firstIndex(where: { $0.id == placement.day.id }) {
                dayIndex = existing
            } else {
                dayIndex = min(placement.dayIndex, days.count)
                days.insert(
                    DayGroup(id: placement.day.id, title: placement.day.title, assets: []),
                    at: dayIndex
                )
            }
            var assets = days[dayIndex].assets
            let asset = restoredAssets[placement.asset.id] ?? placement.asset
            assets.insert(asset, at: min(placement.assetIndex, assets.count))
            days[dayIndex] = DayGroup(
                id: days[dayIndex].id,
                title: days[dayIndex].title,
                assets: assets
            )
            sections[sectionIndex].days = days
            bucketIDByAssetID[placement.asset.id] = placement.section.id
        }
        projectedRemovalIDs.subtract(wanted)
        scheduleOptimisticRebuild()
    }

    private func projectionSources(in sections: [TimelineSection]) -> [String: TimelineProjectionSource] {
        var sources: [String: TimelineProjectionSource] = [:]
        for section in sections {
            for day in section.days ?? [] {
                for asset in day.assets {
                    sources[asset.id] = TimelineProjectionSource(bucketID: section.id, asset: asset)
                }
            }
        }
        return sources
    }

    private func assetIDs(in sections: [TimelineSection]) -> Set<String> {
        Set(sections.lazy.flatMap { section in
            (section.days ?? []).lazy.flatMap(\.assets).map(\.id)
        })
    }

    private func bucketIDs(containing assetIDs: Set<String>) -> Set<String> {
        Set(assetIDs.compactMap { bucketIDByAssetID[$0] })
    }

    private func containsAsset(_ id: String) -> Bool {
        sections.contains { section in
            section.days?.contains { day in day.assets.contains { $0.id == id } } ?? false
        }
    }

    private func restoreSection(for placement: TimelineRemoval.Placement) -> Int {
        if let existing = sections.firstIndex(where: { $0.id == placement.section.id }) {
            return existing
        }
        let index = min(placement.sectionIndex, sections.count)
        sections.insert(TimelineSection(
            id: placement.section.id,
            monthTitle: placement.section.monthTitle,
            count: placement.section.count,
            days: []
        ), at: index)
        return index
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

    /// short month plus year, the label format both immich clients use for
    /// their scrubbers.
    private static func monthTitle(for raw: String) -> String {
        guard let date = bucketDate(raw) else { return raw }
        return date.formatted(.dateTime.month(.abbreviated).year().utc())
    }

    private static func year(for raw: String) -> Int {
        guard let date = bucketDate(raw) else { return Int(raw.prefix(4)) ?? 0 }
        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.component(.year, from: date)
    }

    private static func groupByDay(_ assets: [Asset], byUploadDate: Bool = false) -> [DayGroup] {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var groups: [DayGroup] = []
        var currentKey = Int.min
        var currentAssets: [Asset] = []
        var currentDate = Date()

        func flush() {
            guard !currentAssets.isEmpty else { return }
            groups.append(DayGroup(id: String(currentKey), title: dayTitle(currentDate, calendar: calendar), assets: currentAssets))
            currentAssets = []
        }

        for asset in assets {
            let local = byUploadDate ? asset.uploadLocalDate : asset.localDate
            // day index rather than calendar components: both of those dates
            // are already shifted into utc space, where a day is exactly
            // 86400 seconds, and asking the calendar per asset was most of
            // what a bucket load cost.
            let key = dayIndex(for: local)
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
        let shifted = nowShifted()
        if calendar.isDate(date, inSameDayAs: shifted) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: shifted),
           calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        // the rest of the past week reads as the weekday alone.
        if let daysBack = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: shifted)
        ).day, daysBack > 1, daysBack < 7 {
            return date.formatted(.dateTime.weekday(.wide).utc())
        }
        let sameYear = calendar.component(.year, from: date) == localCalendar.component(.year, from: now)
        // other years trade the weekday for the year so the title still fits
        // a single-column block.
        return date.formatted(
            sameYear
                ? .dateTime.weekday(.abbreviated).month(.abbreviated).day().utc()
                : .dateTime.month(.abbreviated).day().year().utc()
        )
    }

    private static func nowShifted() -> Date {
        Date().addingTimeInterval(TimeInterval(TimeZone.current.secondsFromGMT()))
    }
}

// MARK: - realtime

extension TimelineModel: RealtimeListener {
    func realtimeAssetsRemoved(_ ids: Set<String>) {
        let present = ids.filter { flatAssetIndex(for: $0) != nil }
        guard !present.isEmpty else { return }
        pendingRealtimeRemovals.formUnion(present)
        scheduleRealtimeFlush()
    }

    func realtimeAssetUpdated(_ detail: AssetDetail) {
        guard flatAssetIndex(for: detail.id) != nil else { return }
        pendingRealtimeDetails[detail.id] = detail
        scheduleRealtimeFlush()
        // membership changes, like unfavoriting on the favorites grid,
        // resolve through the resync that follows the same event.
    }

    /// short buffer, then one walk applies everything that arrived. the delay
    /// is invisible next to the network but turns an event storm into a
    /// single rebuild.
    private func scheduleRealtimeFlush() {
        guard realtimeFlushTask == nil else { return }
        realtimeFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, !Task.isCancelled else { return }
            self.realtimeFlushTask = nil
            self.flushRealtimeChanges()
        }
    }

    private func flushRealtimeChanges() {
        let removals = pendingRealtimeRemovals
        pendingRealtimeRemovals = []
        var details = pendingRealtimeDetails
        pendingRealtimeDetails = [:]
        if !removals.isEmpty {
            for id in removals { details[id] = nil }
            removeAssets(ids: removals)
        }
        guard !details.isEmpty else { return }
        var fresh: [String: Asset] = [:]
        var projected: [String: Bool] = [:]
        for (id, detail) in details {
            fresh[id] = detail.asAsset()
            projected[id] = mutationOverlay.favoriteValue(for: id)
        }
        updateAssets(ids: Set(details.keys)) { asset in
            guard let value = fresh[asset.id] else { return }
            asset.isFavorite = projected[asset.id] ?? value.isFavorite
            asset.isTrashed = value.isTrashed
            asset.visibility = value.visibility
        }
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
