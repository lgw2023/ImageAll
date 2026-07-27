import CoreGraphics
import Foundation
import ImageIO

enum PerceptualImageHashError: Error, Equatable {
    case decodeFailed
}

enum PerceptualImageHash {
    /// 64-bit difference hash over a 9×8 grayscale thumbnail.
    static func dHash64(sourceBytes: Data, expectedMediaType: String?) throws -> UInt64 {
        let cascade = MediaDecodeCascade()
        let prepared: (source: CGImageSource, type: String, stage: MediaDecodeStage)
        do {
            prepared = try cascade.preparedImageIOSource(
                sourceBytes: sourceBytes,
                expectedMediaType: expectedMediaType
            )
        } catch {
            throw PerceptualImageHashError.decodeFailed
        }
        let isCameraRaw = ApprovedSourceMediaTypes.isCameraRaw(prepared.type)
            || (expectedMediaType.map(ApprovedSourceMediaTypes.isCameraRaw) ?? false)
        let frameIndex = cascade.primaryFrameIndex(source: prepared.source, isCameraRaw: isCameraRaw)

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 32,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(
            prepared.source,
            frameIndex,
            options as CFDictionary
        ) else {
            throw PerceptualImageHashError.decodeFailed
        }

        let width = 9
        let height = 8
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            throw PerceptualImageHashError.decodeFailed
        }
        context.interpolationQuality = .high
        context.draw(thumb, in: CGRect(x: 0, y: 0, width: width, height: height))

        var hash: UInt64 = 0
        var bitIndex = 0
        for row in 0..<height {
            let rowStart = row * width
            for col in 0..<(width - 1) {
                if pixels[rowStart + col] > pixels[rowStart + col + 1] {
                    hash |= (UInt64(1) << (63 - bitIndex))
                }
                bitIndex += 1
            }
        }
        return hash
    }

    static func hammingDistance(_ left: UInt64, _ right: UInt64) -> Int {
        (left ^ right).nonzeroBitCount
    }

    static func encodeHash(_ value: UInt64) -> Data {
        var be = value.bigEndian
        return Data(bytes: &be, count: MemoryLayout<UInt64>.size)
    }

    static func decodeHash(_ data: Data) -> UInt64? {
        guard data.count == MemoryLayout<UInt64>.size else { return nil }
        return data.withUnsafeBytes { raw in
            UInt64(bigEndian: raw.load(as: UInt64.self))
        }
    }
}
