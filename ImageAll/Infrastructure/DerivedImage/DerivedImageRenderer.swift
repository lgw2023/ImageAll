import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct DerivedImageRenderer: Sendable {
    static var supportedSourceMediaTypes: Set<String> {
        ApprovedSourceMediaTypes.exactIdentifiers
    }

    static func isSupportedSourceMediaType(_ mediaType: String) -> Bool {
        ApprovedSourceMediaTypes.contains(mediaType)
    }

    private let cascade: MediaDecodeCascade

    init(cascade: MediaDecodeCascade = MediaDecodeCascade()) {
        self.cascade = cascade
    }

    private static let jpegQuality: CGFloat = 0.85
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Upper bound passed to ImageIO before aspect-fill/fit. Slightly above the
    /// final variant size so orientation + crop still have enough source pixels.
    static func thumbnailMaxPixelSize(for variant: DerivedImageVariant) -> Int {
        switch variant {
        case .gridSmall: return 512
        case .gridRegular: return 1_024
        case .preview: return 2_048
        }
    }

    func render(
        sourceBytes: Data,
        variant: DerivedImageVariant,
        expectedMediaType: String? = nil
    ) throws -> DerivedImageEncodedArtifact {
        let prepared = try cascade.preparedImageIOSource(
            sourceBytes: sourceBytes,
            expectedMediaType: expectedMediaType
        )
        let source = prepared.source
        let type = prepared.type
        let isCameraRaw = ApprovedSourceMediaTypes.isCameraRaw(type)
            || (expectedMediaType.map(ApprovedSourceMediaTypes.isCameraRaw) ?? false)
        let count = CGImageSourceGetCount(source)
        guard count > 0 else {
            throw DerivedImageError.derivedDecodeFailed
        }
        if !isCameraRaw, cascade.isAnimatedStaticDisallowed(source: source, type: type) {
            throw DerivedImageError.derivedDecodeFailed
        }
        let frameIndex = cascade.primaryFrameIndex(source: source, isCameraRaw: isCameraRaw)

        // Cap decode size before crop/fit so concurrent grid loads do not full-decode
        // multi‑megapixel originals into memory (a common cause of blank thumbnails).
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.thumbnailMaxPixelSize(for: variant),
        ]
        guard let oriented = CGImageSourceCreateThumbnailAtIndex(
            source,
            frameIndex,
            thumbOptions as CFDictionary
        ) else {
            throw DerivedImageError.derivedDecodeFailed
        }

        let sourceHasAlpha = sourceImageHasAlpha(source: source, index: frameIndex)

        let outputImage: CGImage
        switch variant {
        case .gridSmall:
            outputImage = try aspectFill(image: oriented, targetWidth: 256, targetHeight: 256)
        case .gridRegular:
            outputImage = try aspectFill(image: oriented, targetWidth: 512, targetHeight: 512)
        case .preview:
            outputImage = try aspectFit(image: oriented, maxEdge: 2048, allowUpscale: false)
        }

        let hasMeaningfulAlpha = sourceHasAlpha && imageHasNonOpaqueAlpha(outputImage)
        let format: DerivedImageStorageFormat = hasMeaningfulAlpha ? .png : .jpeg
        let encoded = try encode(image: outputImage, format: format)
        try validateEncoded(
            encoded,
            expectedFormat: format,
            expectedWidth: outputImage.width,
            expectedHeight: outputImage.height
        )
        return encoded
    }

    func validateEncoded(
        _ artifact: DerivedImageEncodedArtifact,
        expectedFormat: DerivedImageStorageFormat,
        expectedWidth: Int,
        expectedHeight: Int
    ) throws {
        guard artifact.storageFormat == expectedFormat else {
            throw DerivedImageError.derivedEncodeFailed
        }
        guard artifact.pixelWidth == expectedWidth, artifact.pixelHeight == expectedHeight else {
            throw DerivedImageError.derivedEncodeFailed
        }
        guard artifact.bytes.count == artifact.byteSize else {
            throw DerivedImageError.derivedEncodeFailed
        }
        let digest = SHA256.hash(data: artifact.bytes)
        guard Data(digest) == artifact.sha256 else {
            throw DerivedImageError.derivedEncodeFailed
        }
        guard try decodesAsSingleImage(
            artifact.bytes,
            format: expectedFormat,
            width: expectedWidth,
            height: expectedHeight,
            sha256: artifact.sha256
        ) else {
            throw DerivedImageError.derivedEncodeFailed
        }
    }

    func validateStoredBytes(
        _ bytes: Data,
        entry: DerivedImageCacheEntryRow
    ) throws -> Bool {
        guard Int64(bytes.count) == entry.byteSize else { return false }
        let digest = SHA256.hash(data: bytes)
        guard Data(digest) == entry.encodedSHA256 else { return false }
        return try decodesAsSingleImage(
            bytes,
            format: entry.storageFormat,
            width: entry.pixelWidth,
            height: entry.pixelHeight,
            sha256: entry.encodedSHA256
        )
    }

    private func encode(image: CGImage, format: DerivedImageStorageFormat) throws -> DerivedImageEncodedArtifact {
        let data = NSMutableData()
        let uti = (format == .jpeg ? UTType.jpeg : UTType.png).identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(data, uti, 1, nil) else {
            throw DerivedImageError.derivedEncodeFailed
        }
        if format == .jpeg {
            let props = [kCGImageDestinationLossyCompressionQuality: Self.jpegQuality] as CFDictionary
            CGImageDestinationAddImage(destination, image, props)
        } else {
            CGImageDestinationAddImage(destination, image, nil)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw DerivedImageError.derivedEncodeFailed
        }
        let bytes = data as Data
        let digest = SHA256.hash(data: bytes)
        return DerivedImageEncodedArtifact(
            bytes: bytes,
            byteSize: Int64(bytes.count),
            sha256: Data(digest),
            storageFormat: format,
            pixelWidth: image.width,
            pixelHeight: image.height
        )
    }

    private func aspectFill(image: CGImage, targetWidth: Int, targetHeight: Int) throws -> CGImage {
        let srcWidth = CGFloat(image.width)
        let srcHeight = CGFloat(image.height)
        let scale = max(CGFloat(targetWidth) / srcWidth, CGFloat(targetHeight) / srcHeight)
        let drawWidth = srcWidth * scale
        let drawHeight = srcHeight * scale
        let x = (CGFloat(targetWidth) - drawWidth) / 2
        let y = (CGFloat(targetHeight) - drawHeight) / 2

        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: Self.sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw DerivedImageError.derivedEncodeFailed
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: x, y: y, width: drawWidth, height: drawHeight))
        guard let output = context.makeImage() else {
            throw DerivedImageError.derivedEncodeFailed
        }
        return output
    }

    private func aspectFit(image: CGImage, maxEdge: Int, allowUpscale: Bool) throws -> CGImage {
        let srcWidth = CGFloat(image.width)
        let srcHeight = CGFloat(image.height)
        let srcMax = max(srcWidth, srcHeight)
        let scale = allowUpscale ? CGFloat(maxEdge) / srcMax : min(1, CGFloat(maxEdge) / srcMax)
        let targetWidth = max(1, Int((srcWidth * scale).rounded()))
        let targetHeight = max(1, Int((srcHeight * scale).rounded()))

        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: Self.sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw DerivedImageError.derivedEncodeFailed
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        guard let output = context.makeImage() else {
            throw DerivedImageError.derivedEncodeFailed
        }
        return output
    }

    private func decodesAsSingleImage(
        _ bytes: Data,
        format: DerivedImageStorageFormat,
        width: Int,
        height: Int,
        sha256: Data
    ) throws -> Bool {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil) else {
            return false
        }
        guard CGImageSourceGetCount(source) == 1 else { return false }
        let expectedUTI = (format == .jpeg ? UTType.jpeg : UTType.png).identifier
        guard (CGImageSourceGetType(source) as String?) == expectedUTI else { return false }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
        guard image.width == width, image.height == height else { return false }
        let digest = SHA256.hash(data: bytes)
        return Data(digest) == sha256
    }

    private func sourceImageHasAlpha(source: CGImageSource, index: Int) -> Bool {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else {
            return false
        }
        if let hasAlpha = properties[kCGImagePropertyHasAlpha] as? Bool {
            return hasAlpha
        }
        if let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any],
           let hasAlpha = png["HasAlpha" as CFString] as? Bool
        {
            return hasAlpha
        }
        return false
    }

    private func imageHasNonOpaqueAlpha(_ image: CGImage) -> Bool {
        guard let dataProvider = image.dataProvider, let data = dataProvider.data as Data? else {
            return false
        }
        let bytes = [UInt8](data)
        guard image.bitsPerPixel >= 32, image.bitsPerComponent == 8 else { return false }
        let bytesPerPixel = image.bitsPerPixel / 8
        let alphaIndex: Int
        switch image.alphaInfo {
        case .premultipliedLast, .last, .alphaOnly:
            alphaIndex = bytesPerPixel - 1
        case .premultipliedFirst, .first:
            alphaIndex = 0
        default:
            return false
        }
        for row in 0 ..< image.height {
            for col in 0 ..< image.width {
                let offset = row * image.bytesPerRow + col * bytesPerPixel + alphaIndex
                guard offset < bytes.count else { continue }
                if bytes[offset] < 255 {
                    return true
                }
            }
        }
        return false
    }
}

extension DerivedImageRenderer {
    static func outputHasMetadata(from bytes: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            return false
        }
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any], !exif.isEmpty {
            return true
        }
        if properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] != nil { return true }
        if properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] != nil { return true }
        return false
    }
}
