import UIKit

/// decodes immich thumbhash strings into tiny placeholder images.
/// port of the reference thumbhash implementation.
nonisolated enum Thumbhash {
    static func image(fromBase64 base64: String) -> UIImage? {
        var normalized = base64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while normalized.count % 4 != 0 { normalized.append("=") }
        guard let data = Data(base64Encoded: normalized) else { return nil }
        return image(from: [UInt8](data))
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

        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                var fx = [Double](repeating: 0, count: max(lx, hasAlpha ? 5 : 3))
                var fy = [Double](repeating: 0, count: max(ly, hasAlpha ? 5 : 3))
                for cx in fx.indices { fx[cx] = cos(.pi / Double(width) * (Double(x) + 0.5) * Double(cx)) }
                for cy in fy.indices { fy[cy] = cos(.pi / Double(height) * (Double(y) + 0.5) * Double(cy)) }

                func accumulate(_ dc: Double, _ ac: [Double], _ nx: Int, _ ny: Int) -> Double {
                    var value = dc
                    var j = 0
                    for cy in 0..<ny {
                        var cx = cy > 0 ? 0 : 1
                        let fy2 = fy[cy] * 2
                        while cx * ny < nx * (ny - cy), j < ac.count {
                            value += ac[j] * fx[cx] * fy2
                            j += 1
                            cx += 1
                        }
                    }
                    return value
                }

                let l = accumulate(lDC, lAC, lx, ly)
                let p = accumulate(pDC, pAC, 3, 3)
                let q = accumulate(qDC, qAC, 3, 3)
                let a = hasAlpha ? accumulate(aDC, aAC, 5, 5) : 1

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
