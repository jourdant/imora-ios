import UIKit

private nonisolated final class ThumbhashImageCache: @unchecked Sendable {
    let images: NSCache<NSString, UIImage>

    init() {
        images = NSCache()
        images.totalCostLimit = 8 << 20
    }
}

/// decodes immich thumbhash strings into tiny placeholder images.
/// port of the reference thumbhash implementation.
nonisolated enum Thumbhash {
    private static let cache = ThumbhashImageCache()

    private static var isCancelled: Bool {
        withUnsafeCurrentTask { $0?.isCancelled ?? false }
    }

    static func image(fromBase64 base64: String) -> UIImage? {
        guard !isCancelled else { return nil }
        let key = base64 as NSString
        if let cached = cache.images.object(forKey: key) { return cached }
        var normalized = base64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while normalized.count % 4 != 0 { normalized.append("=") }
        guard let data = Data(base64Encoded: normalized) else { return nil }
        guard let image = image(from: [UInt8](data)) else { return nil }
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        cache.images.setObject(image, forKey: key, cost: cost)
        return image
    }

    static func image(from hash: [UInt8]) -> UIImage? {
        guard hash.count >= 5 else { return nil }
        let header24 = Int(hash[0]) | (Int(hash[1]) << 8) | (Int(hash[2]) << 16)
        let header16 = Int(hash[3]) | (Int(hash[4]) << 8)
        let lDC = Double(header24 & 63) / 63
        let pDC = Double((header24 >> 6) & 63) / 31.5 - 1
        let qDC = Double((header24 >> 12) & 63) / 31.5 - 1
        let lScale = Double((header24 >> 18) & 31) / 31
        let hasAlpha = (header24 >> 23) != 0
        let pScale = Double((header16 >> 3) & 63) / 63
        let qScale = Double((header16 >> 9) & 63) / 63
        let isLandscape = (header16 >> 15) != 0
        let lx = max(3, isLandscape ? (hasAlpha ? 5 : 7) : header16 & 7)
        let ly = max(3, isLandscape ? header16 & 7 : (hasAlpha ? 5 : 7))
        var aDC = 1.0
        var aScale = 1.0
        if hasAlpha {
            guard hash.count >= 6 else { return nil }
            aDC = Double(hash[5] & 15) / 15
            aScale = Double(hash[5] >> 4) / 15
        }

        let acStart = hasAlpha ? 6 : 5
        var acIndex = 0
        func decodeChannel(_ nx: Int, _ ny: Int, _ scale: Double) -> [Double] {
            var ac: [Double] = []
            for cy in 0..<ny {
                var cx = cy > 0 ? 0 : 1
                while cx * ny < nx * (ny - cy) {
                    let byteIndex = acStart + (acIndex >> 1)
                    guard byteIndex < hash.count else { return ac }
                    let nibble = (Int(hash[byteIndex]) >> ((acIndex & 1) << 2)) & 15
                    ac.append((Double(nibble) / 7.5 - 1) * scale)
                    acIndex += 1
                    cx += 1
                }
            }
            return ac
        }

        let lAC = decodeChannel(lx, ly, lScale)
        let pAC = decodeChannel(3, 3, pScale * 1.25)
        let qAC = decodeChannel(3, 3, qScale * 1.25)
        let aAC = hasAlpha ? decodeChannel(5, 5, aScale) : []

        let ratio = Double(lx) / Double(ly)
        let width = ratio > 1 ? 32 : Int((32 * ratio).rounded())
        let height = ratio > 1 ? Int((32 / ratio).rounded()) : 32

        let componentWidth = max(lx, hasAlpha ? 5 : 3)
        let componentHeight = max(ly, hasAlpha ? 5 : 3)
        var xBasis = [Double](repeating: 0, count: width * componentWidth)
        var yBasis = [Double](repeating: 0, count: height * componentHeight)
        for x in 0..<width {
            for cx in 0..<componentWidth {
                xBasis[x * componentWidth + cx] = cos(
                    .pi / Double(width) * (Double(x) + 0.5) * Double(cx)
                )
            }
        }
        for y in 0..<height {
            for cy in 0..<componentHeight {
                yBasis[y * componentHeight + cy] = cos(
                    .pi / Double(height) * (Double(y) + 0.5) * Double(cy)
                )
            }
        }

        func accumulate(
            _ dc: Double,
            _ ac: [Double],
            _ nx: Int,
            _ ny: Int,
            x: Int,
            y: Int
        ) -> Double {
            var value = dc
            var index = 0
            for cy in 0..<ny {
                var cx = cy > 0 ? 0 : 1
                let fy = yBasis[y * componentHeight + cy] * 2
                while cx * ny < nx * (ny - cy), index < ac.count {
                    value += ac[index] * xBasis[x * componentWidth + cx] * fy
                    index += 1
                    cx += 1
                }
            }
            return value
        }

        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            guard !isCancelled else { return nil }
            for x in 0..<width {
                let l = accumulate(lDC, lAC, lx, ly, x: x, y: y)
                let p = accumulate(pDC, pAC, 3, 3, x: x, y: y)
                let q = accumulate(qDC, qAC, 3, 3, x: x, y: y)
                let a = hasAlpha ? accumulate(aDC, aAC, 5, 5, x: x, y: y) : 1

                let b = l - 2.0 / 3.0 * p
                let r = (3 * l - b + q) / 2
                let g = r - q

                let offset = (y * width + x) * 4
                rgba[offset] = UInt8(max(0, min(1, r)) * 255)
                rgba[offset + 1] = UInt8(max(0, min(1, g)) * 255)
                rgba[offset + 2] = UInt8(max(0, min(1, b)) * 255)
                rgba[offset + 3] = UInt8(max(0, min(1, a)) * 255)
            }
        }

        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              )
        else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
