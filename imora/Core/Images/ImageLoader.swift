import UIKit

/// downloads and caches asset thumbnails. memory cache holds decoded images,
/// urlcache persists encoded bytes on disk across launches.
/// unchecked because nscache is documented thread-safe.
nonisolated final class ImageLoader: @unchecked Sendable {
    static let shared = ImageLoader()

    private let memory: NSCache<NSString, UIImage>
    private let store: SessionBox

    private final class SessionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _session: URLSession

        init(session: URLSession) { _session = session }

        var session: URLSession {
            lock.lock()
            defer { lock.unlock() }
            return _session
        }

        func replace(_ session: URLSession) {
            lock.lock()
            defer { lock.unlock() }
            _session = session
        }
    }

    private init() {
        memory = NSCache()
        memory.totalCostLimit = 256 * 1024 * 1024
        store = SessionBox(session: Self.makeSession(headers: [:]))
    }

    private static func makeSession(headers: [String: String]) -> URLSession {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = headers
        config.urlCache = URLCache(
            memoryCapacity: 64 * 1024 * 1024,
            diskCapacity: 1024 * 1024 * 1024,
            diskPath: "imora-images"
        )
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: config)
    }

    /// call after login so image requests carry the token.
    func configure(headers: [String: String]) {
        store.replace(Self.makeSession(headers: headers))
    }

    func cachedImage(for url: URL) -> UIImage? {
        memory.object(forKey: url.absoluteString as NSString)
    }

    func image(for url: URL, targetPixelSize: CGFloat) async throws -> UIImage {
        let key = url.absoluteString as NSString
        if let cached = memory.object(forKey: key) { return cached }

        let (data, response) = try await store.session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ImmichError.http(http.statusCode, "")
        }
        guard let image = Self.downsample(data: data, targetPixelSize: targetPixelSize) else {
            throw ImmichError.decoding("not an image")
        }
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        memory.setObject(image, forKey: key, cost: cost)
        return image
    }

    /// decodes at reduced resolution to keep memory flat while scrolling.
    private static func downsample(data: Data, targetPixelSize: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: targetPixelSize,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgImage)
    }
}
