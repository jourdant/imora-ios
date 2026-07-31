import Foundation
import Observation

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

    private var client: ImmichClient?
    private var searchTask: Task<Void, Never>?
    /// bumped on every apply so stale responses and their defers are ignored.
    private var generation = 0

    func attach(_ client: ImmichClient) {
        guard self.client == nil else { return }
        self.client = client
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
        searchTask?.cancel()
        assets = []
        nextPage = 1
        isLoading = false
        hasActiveSearch = searchable
        guard hasActiveSearch else { return }
        let requested = generation
        searchTask = Task { await loadNextPage(requested) }
    }

    func loadMore() {
        guard nextPage != nil, !isLoading else { return }
        let requested = generation
        searchTask = Task { await loadNextPage(requested) }
    }

    func clear() {
        generation += 1
        searchTask?.cancel()
        filter = SearchFilter()
        assets = []
        nextPage = 1
        isLoading = false
        hasActiveSearch = false
    }

    /// in-place mutation used when the viewer reports favorite changes.
    func updateAssets(ids: Set<String>, _ transform: (inout Asset) -> Void) {
        for index in assets.indices where ids.contains(assets[index].id) {
            transform(&assets[index])
        }
    }

    func removeAssets(ids: Set<String>) {
        assets.removeAll { ids.contains($0.id) }
    }

    private func loadNextPage(_ requested: Int) async {
        guard let client, requested == generation, let page = nextPage, !isLoading else { return }
        isLoading = true
        defer {
            // a superseded load must not clear the successor's spinner.
            if requested == generation { isLoading = false }
        }

        do {
            let response = try await client.search(filter, page: page)
            guard requested == generation else { return }
            guard !response.assets.items.isEmpty else {
                nextPage = nil
                return
            }
            assets.append(contentsOf: response.assets.items.map { $0.asAsset() })
            nextPage = response.assets.nextPage.flatMap { Int($0) }
        } catch {
            // pagination stays retryable, matching the flutter behavior of
            // swallowing errors and letting the user scroll to retry.
        }
    }
}
