import Nuke
import Synchronization
import UIKit

/// downloads and caches asset thumbnails on top of a nuke pipeline. beyond the
/// memory and disk caches, the library brings request coalescing, a rate
/// limiter tuned for fast scrolling, resumable downloads and the prefetcher
/// the grids use to load tiles before they come on screen.
nonisolated final class ImageLoader: Sendable {
    static let shared = ImageLoader()

    private let pipeline: ImagePipeline
    private let authorization = AuthorizingDelegate()
    private let prefetcher: ImagePrefetcher
    /// held directly so storage settings can measure and wipe it.
    private let dataCache: DataCache?

    private init() {
        // an aggressive data cache instead of urlcache: immich thumbnails are
        // immutable per cache key, so revalidating them is wasted latency.
        let dataCache = try? DataCache(name: "imora-images")
        dataCache?.sizeLimit = 1 << 30
        self.dataCache = dataCache

        var configuration = ImagePipeline.Configuration()
        configuration.dataLoader = {
            let config = URLSessionConfiguration.default
            config.urlCache = nil
            return DataLoader(configuration: config)
        }()
        configuration.dataCache = dataCache
        configuration.imageCache = ImageCache(costLimit: 96 << 20)
        // the sanitized key drops the thumbnail size, so one download serves
        // every pixel size the grid and the viewer ask for.
        configuration.dataCachePolicy = .storeOriginalData
        pipeline = ImagePipeline(configuration: configuration, delegate: authorization)
        prefetcher = ImagePrefetcher(pipeline: pipeline, maxConcurrentRequestCount: 4)
    }

    /// call after login so image requests carry the token.
    func configure(headers: [String: String]) {
        authorization.headers.withLock { $0 = headers }
    }

    func requestKey(for url: URL, targetPixelSize: CGFloat) -> String {
        "\(url.absoluteString)#\(Self.normalizedPixelSize(targetPixelSize))"
    }

    func cachedImage(for url: URL, targetPixelSize: CGFloat) -> UIImage? {
        pipeline.cache[request(for: url, targetPixelSize: targetPixelSize)]?.image
    }

    func image(for url: URL, targetPixelSize: CGFloat) async throws -> UIImage {
        try await pipeline.image(for: request(for: url, targetPixelSize: targetPixelSize))
    }

    // MARK: - prefetching

    /// warms the caches for tiles about to scroll into view. prefetches run at
    /// a lower priority than visible requests and coalesce with them, so a tile
    /// that appears mid-flight reuses the download already in progress.
    func startPrefetching(urls: [URL], targetPixelSize: CGFloat) {
        prefetcher.startPrefetching(with: requests(for: urls, targetPixelSize: targetPixelSize))
    }

    func stopPrefetching(urls: [URL], targetPixelSize: CGFloat) {
        prefetcher.stopPrefetching(with: requests(for: urls, targetPixelSize: targetPixelSize))
    }

    // MARK: - offline sweep

    /// tail of thumbnails a sweep will fetch; roughly what fits the disk cache.
    private static let sweepLimit = 20_000

    /// background pass that fills the disk cache with every thumbnail not yet
    /// stored, so offline browsing shows photos beyond the regions already
    /// visited. bytes land on disk without decoding, at a priority visible
    /// tiles always beat. best effort: failures are skipped and a new sweep
    /// replaces the previous one.
    func sweepThumbnails(urls: [URL]) {
        let pipeline = pipeline
        let task = Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                var iterator = urls.prefix(Self.sweepLimit).makeIterator()
                func nextRequest() -> ImageRequest? {
                    while let url = iterator.next() {
                        var request = ImageRequest(url: url)
                        request.priority = .veryLow
                        if !pipeline.cache.containsData(for: request) { return request }
                    }
                    return nil
                }
                // two lanes are slow enough to never crowd out visible tiles
                // and still cover a large library over a session.
                for _ in 0..<2 {
                    guard let request = nextRequest() else { break }
                    group.addTask { _ = try? await pipeline.data(for: request) }
                }
                for await _ in group {
                    guard !Task.isCancelled, let request = nextRequest() else { continue }
                    group.addTask { _ = try? await pipeline.data(for: request) }
                }
            }
        }
        sweepTask.withLock { current in
            current?.cancel()
            current = task
        }
    }

    private let sweepTask = Mutex<Task<Void, Never>?>(nil)

    // MARK: - storage

    /// bytes the downloaded images occupy on disk. disk io, keep off main.
    func diskUsage() -> Int64 {
        Int64(dataCache?.totalAllocatedSize ?? 0)
    }

    /// wipes downloaded images from memory and disk. cancels a running sweep
    /// first, otherwise it would quietly refill what was just reclaimed.
    func clearCache() {
        sweepTask.withLock { current in
            current?.cancel()
            current = nil
        }
        pipeline.cache.removeAll()
        // deletions are queued; waiting makes the recount deterministic.
        dataCache?.flush()
    }

    // MARK: - requests

    /// decoding straight to a thumbnail keeps memory flat while scrolling -
    /// the full-size bitmap never exists.
    private func request(for url: URL, targetPixelSize: CGFloat) -> ImageRequest {
        var request = ImageRequest(url: url)
        request.thumbnail = ImageRequest.ThumbnailOptions(
            maxPixelSize: Float(Self.normalizedPixelSize(targetPixelSize))
        )
        return request
    }

    private func requests(for urls: [URL], targetPixelSize: CGFloat) -> [ImageRequest] {
        urls.map { request(for: $0, targetPixelSize: targetPixelSize) }
    }

    private static func normalizedPixelSize(_ value: CGFloat) -> Int {
        max(1, Int(value.rounded(.up)))
    }
}

/// injects the session token as the request leaves the pipeline. keeping it out
/// of the request itself means the cache keys never mention the token, so
/// signing back in still hits a warm cache.
private final class AuthorizingDelegate: ImagePipeline.Delegate {
    let headers = Mutex<[String: String]>([:])

    @ImagePipelineActor
    func willLoadData(
        for request: ImageRequest,
        urlRequest: URLRequest,
        pipeline: ImagePipeline
    ) async throws -> URLRequest {
        var urlRequest = urlRequest
        for (field, value) in headers.withLock({ $0 }) {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        return urlRequest
    }
}
