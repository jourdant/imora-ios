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

    private init() {
        // an aggressive data cache instead of urlcache: immich thumbnails are
        // immutable per cache key, so revalidating them is wasted latency.
        var configuration = ImagePipeline.Configuration.withDataCache(
            name: "imora-images",
            sizeLimit: 1 << 30
        )
        configuration.imageCache = ImageCache(costLimit: 256 << 20)
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
