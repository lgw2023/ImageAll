import CoreGraphics
import Foundation
import ImageIO

enum PerceptualImageHashError: Error, Equatable {
    case decodeFailed
}

struct PerceptualImageAnalysis: Sendable, Equatable {
    let dHash: UInt64
    let verificationSignature: Data
    let pixelWidth: Int
    let pixelHeight: Int
}

enum PerceptualImageHash {
    /// 64-bit difference hash over a 9×8 grayscale thumbnail.
    static func dHash64(sourceBytes: Data, expectedMediaType: String?) throws -> UInt64 {
        try analyze(sourceBytes: sourceBytes, expectedMediaType: expectedMediaType).dHash
    }

    /// dHash candidate key plus a compact normalized RGB signature used to
    /// verify deletion-grade near duplicates.
    static func analyze(
        sourceBytes: Data,
        expectedMediaType: String?
    ) throws -> PerceptualImageAnalysis {
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

        let signatureWidth = 16
        let signatureHeight = 16
        var rgba = [UInt8](repeating: 0, count: signatureWidth * signatureHeight * 4)
        guard let signatureContext = CGContext(
            data: &rgba,
            width: signatureWidth,
            height: signatureHeight,
            bitsPerComponent: 8,
            bytesPerRow: signatureWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        ) else {
            throw PerceptualImageHashError.decodeFailed
        }
        signatureContext.interpolationQuality = .high
        signatureContext.draw(
            thumb,
            in: CGRect(x: 0, y: 0, width: signatureWidth, height: signatureHeight)
        )
        var rgb = Data(capacity: signatureWidth * signatureHeight * 3)
        for offset in stride(from: 0, to: rgba.count, by: 4) {
            rgb.append(rgba[offset])
            rgb.append(rgba[offset + 1])
            rgb.append(rgba[offset + 2])
        }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(
            prepared.source,
            frameIndex,
            nil
        ) as? [CFString: Any],
            let rawWidth = properties[kCGImagePropertyPixelWidth] as? Int,
            let rawHeight = properties[kCGImagePropertyPixelHeight] as? Int,
            rawWidth > 0,
            rawHeight > 0
        else {
            throw PerceptualImageHashError.decodeFailed
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? UInt32) ?? 1
        let swapsAxes = (5...8).contains(orientation)
        return PerceptualImageAnalysis(
            dHash: hash,
            verificationSignature: rgb,
            pixelWidth: swapsAxes ? rawHeight : rawWidth,
            pixelHeight: swapsAxes ? rawWidth : rawHeight
        )
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

    static func verificationMatches(
        _ left: PerceptualImageAnalysis,
        _ right: PerceptualImageAnalysis
    ) -> Bool {
        verificationMatches(
            leftSignature: left.verificationSignature,
            leftWidth: left.pixelWidth,
            leftHeight: left.pixelHeight,
            rightSignature: right.verificationSignature,
            rightWidth: right.pixelWidth,
            rightHeight: right.pixelHeight
        )
    }

    static func verificationMatches(
        leftSignature: Data,
        leftWidth: Int,
        leftHeight: Int,
        rightSignature: Data,
        rightWidth: Int,
        rightHeight: Int
    ) -> Bool {
        guard leftSignature.count == 768,
              rightSignature.count == 768,
              leftWidth > 0,
              leftHeight > 0,
              rightWidth > 0,
              rightHeight > 0
        else {
            return false
        }
        let crossLeft = Double(leftWidth) * Double(rightHeight)
        let crossRight = Double(rightWidth) * Double(leftHeight)
        let aspectDelta = abs(crossLeft - crossRight) / max(crossLeft, crossRight)
        guard aspectDelta <= 0.01 else { return false }

        let totalDifference = zip(leftSignature, rightSignature).reduce(into: 0) { total, pair in
            total += abs(Int(pair.0) - Int(pair.1))
        }
        let meanAbsoluteDifference = Double(totalDifference) / Double(leftSignature.count)
        return meanAbsoluteDifference <= 12
    }
}
