import Foundation
import Observation

nonisolated struct SearchRemoval {
    fileprivate let generation: Int
    fileprivate let placements: [(index: Int, asset: Asset)]
    var isEmpty: Bool { placements.isEmpty }
}

/// paginated search state, the swift twin of the flutter
/// PaginatedSearchNotifier: nextPage nil means exhausted, an error or an
/// empty page stops pagination but keeps what already loaded.
@Observable
final class SearchModel {
    private(set) var filter = SearchFilter()
    private(set) var assets: [Asset] = []
    private(set) var nextPage: Int? = 1
    private(set) var isLoading = false
    private(set) var hasActiveSearch = false
    /// the last page request failed with nothing loaded. distinguishes a
    /// timed-out search from a genuine zero-result answer, which used to
    /// render the same confident "no results".
    private(set) var loadFailed = false

    private var client: ImmichClient?
    private var searchTask: Task<Void, Never>?
    /// bumped on every apply so stale responses and their defers are ignored.
    private var generation = 0
    private var externalRemovalRollbacks: [String: SearchRemoval] = [:]

    func attach(_ client: ImmichClient) {
        guard self.client == nil else { return }
        self.client = client
        // a filter applied while the session was still signing in silently
        // no-opped; run it now that requests can actually go out.
        if hasActiveSearch, assets.isEmpty, nextPage != nil {
            loadMore()
        }
    }

    /// applies a new filter: identical filters are a no-op, empty filters
    /// reset to the suggestions state, anything else restarts the search.
    /// allowEmpty turns an empty filter into a whole-library query instead,
    /// used by pickers that page over everything.
    func apply(_ newFilter: SearchFilter, allowEmpty: Bool = false) {
        let searchable = allowEmpty || !newFilter.isEmpty
        guard newFilter != filter || searchable != hasActiveSearch else { return }
        filter = newFilter
        generation += 1
        externalRemovalRollbacks = [:]
        searchTask?.cancel()
        assets = []
        nextPage = 1
        loadFailed = false
        // set before the task runs, not inside it: the task body lands a
        // runloop turn later, and the frame in between rendered a false
        // "no results" flash on every submit.
        isLoading = searchable
        hasActiveSearch = searchable
        guard hasActiveSearch else { return }
        let requested = generation
        searchTask = Task { await loadNextPage(requested, initial: true) }
    }

    func loadMore() {
        guard nextPage != nil, !isLoading else { return }
        loadFailed = false
        let requested = generation
        searchTask = Task { await loadNextPage(requested) }
    }

    func clear() {
        generation += 1
        externalRemovalRollbacks = [:]
        searchTask?.cancel()
        filter = SearchFilter()
        assets = []
        nextPage = 1
        isLoading = false
        loadFailed = false
        hasActiveSearch = false
    }

    /// in-place mutation used when the viewer reports favorite changes.
    func updateAssets(ids: Set<String>, _ transform: (inout Asset) -> Void) {
        for index in assets.indices where ids.contains(assets[index].id) {
            transform(&assets[index])
        }
    }

    func removeAssets(ids: Set<String>) {
        _ = removeAssetsForOptimisticAction(ids: ids)
    }

    func beginExternalOptimisticRemoval(id: String) {
        guard externalRemovalRollbacks[id] == nil else { return }
        externalRemovalRollbacks[id] = removeAssetsForOptimisticAction(ids: [id])
    }

    func commitExternalOptimisticRemoval(id: String) {
        externalRemovalRollbacks[id] = nil
        removeAssets(ids: [id])
    }

    func rollbackExternalOptimisticRemoval(id: String) {
        guard let removal = externalRemovalRollbacks.removeValue(forKey: id) else { return }
        restore(removal, ids: [id])
    }

    func removeAssetsForOptimisticAction(ids: Set<String>) -> SearchRemoval {
        let placements = assets.enumerated().compactMap { index, asset in
            ids.contains(asset.id) ? (index, asset) : nil
        }
        assets.removeAll { ids.contains($0.id) }
        return SearchRemoval(generation: generation, placements: placements)
    }

    /// A token from an old query must never inject assets into a new result.
    func restore(_ removal: SearchRemoval, ids: Set<String>? = nil) {
        guard removal.generation == generation else { return }
        let wanted = ids
        for placement in removal.placements
            .filter({ wanted?.contains($0.asset.id) ?? true })
            .sorted(by: { $0.index < $1.index })
        where !assets.contains(where: { $0.id == placement.asset.id }) {
            assets.insert(placement.asset, at: min(placement.index, assets.count))
        }
    }

    /// initial passes the isLoading gate apply() already raised for the
    /// first page of a fresh search.
    private func loadNextPage(_ requested: Int, initial: Bool = false) async {
        guard let client, requested == generation, let page = nextPage, initial || !isLoading else {
            // apply() raised the spinner before this task ran; a bail here -
            // typically no client yet - must lower it again or it spins
            // forever. attach() retries once the client lands.
            if initial, requested == generation {
                isLoading = false
                loadFailed = self.client == nil
            }
            return
        }
        isLoading = true
        defer {
            // a superseded load must not clear the successor's spinner.
            if requested == generation { isLoading = false }
        }

        do {
            let response = try await client.search(filter, page: page)
            guard requested == generation else { return }
            loadFailed = false
            guard !response.assets.items.isEmpty else {
                nextPage = nil
                return
            }
            assets.append(contentsOf: response.assets.items.map { $0.asAsset() })
            nextPage = response.assets.nextPage.flatMap { Int($0) }
        } catch {
            // pagination stays retryable, matching the flutter behavior of
            // swallowing errors and letting the user scroll to retry. with
            // nothing loaded there is no tail row to scroll back onto, so the
            // grid offers an explicit retry through loadFailed instead.
            guard requested == generation, !Task.isCancelled else { return }
            loadFailed = true
        }
    }
}
