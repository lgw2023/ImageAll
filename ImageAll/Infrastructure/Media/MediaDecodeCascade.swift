import CoreImage
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct MediaDecodeProbe: Equatable, Sendable {
    let mediaType: String
    let width: Int
    let height: Int
    let decoder: MediaDecodeStage
}

enum MediaDecodeStage: String, Equatable, Sendable {
    case imageIO
    case coreImage
    case libRaw
}

protocol LibRawPreviewDecoding: Sendable {
    func probe(path: String) -> (width: Int, height: Int)?
    func probe(bytes: Data) -> (width: Int, height: Int)?
    func decodeThumbJPEG(path: String) -> Data?
    func decodeThumbJPEG(bytes: Data) -> Data?
}

struct LibRawPreviewDecoder: LibRawPreviewDecoding {
    func probe(path: String) -> (width: Int, height: Int)? {
        var width: Int32 = 0
        var height: Int32 = 0
        let code = path.withCString { ImageAll_LibRawProbePath($0, &width, &height) }
        guard code == 0, width > 0, height > 0 else { return nil }
        return (Int(width), Int(height))
    }

    func probe(bytes: Data) -> (width: Int, height: Int)? {
        var width: Int32 = 0
        var height: Int32 = 0
        let code = bytes.withUnsafeBytes { buffer -> Int32 in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return ImageAll_LibRawProbeBuffer(base, buffer.count, &width, &height)
        }
        guard code == 0, width > 0, height > 0 else { return nil }
        return (Int(width), Int(height))
    }

    func decodeThumbJPEG(path: String) -> Data? {
        var pointer: UnsafeMutablePointer<UInt8>?
        var length: Int = 0
        var width: Int32 = 0
        var height: Int32 = 0
        let code = path.withCString {
            ImageAll_LibRawDecodeThumbFromPath($0, &pointer, &length, &width, &height)
        }
        defer { ImageAll_LibRawFree(pointer) }
        guard code == 0, let pointer, length > 0 else { return nil }
        return Data(bytes: pointer, count: length)
    }

    func decodeThumbJPEG(bytes: Data) -> Data? {
        var pointer: UnsafeMutablePointer<UInt8>?
        var length: Int = 0
        var width: Int32 = 0
        var height: Int32 = 0
        let code = bytes.withUnsafeBytes { buffer -> Int32 in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return ImageAll_LibRawDecodeThumbFromBuffer(base, buffer.count, &pointer, &length, &width, &height)
        }
        defer { ImageAll_LibRawFree(pointer) }
        guard code == 0, let pointer, length > 0 else { return nil }
        return Data(bytes: pointer, count: length)
    }
}

struct MediaDecodeCascade: Sendable {
    var libRaw: any LibRawPreviewDecoding = LibRawPreviewDecoder()

    func primaryFrameIndex(source: CGImageSource, isCameraRaw: Bool) -> Int {
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return 0 }
        guard isCameraRaw, count > 1 else { return 0 }
        var bestIndex = 0
        var bestPixels = -1
        for index in 0 ..< count {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int
            else {
                continue
            }
            let pixels = width * height
            if pixels > bestPixels {
                bestPixels = pixels
                bestIndex = index
            }
        }
        return bestIndex
    }

    func isAnimatedStaticDisallowed(source: CGImageSource, type: String) -> Bool {
        if ApprovedSourceMediaTypes.isCameraRaw(type) {
            return false
        }
        let count = CGImageSourceGetCount(source)
        if type == UTType.gif.identifier {
            return count > 1
        }
        if count > 1 {
            return true
        }
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any],
           let loopCount = gif[kCGImagePropertyGIFLoopCount] as? Int,
           loopCount != 1
        {
            return true
        }
        return false
    }

    func probeFile(fileURL: URL, candidateUTI: String) -> MediaDecodeProbe? {
        if let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
           let type = CGImageSourceGetType(source) as String?,
           CGImageSourceGetCount(source) > 0
        {
            let isRaw = ApprovedSourceMediaTypes.isCameraRaw(type)
                || ApprovedSourceMediaTypes.isCameraRaw(candidateUTI)
            if isRaw || !isAnimatedStaticDisallowed(source: source, type: type) {
                let index = primaryFrameIndex(source: source, isCameraRaw: isRaw)
                if let size = logicalSize(source: source, index: index),
                   ApprovedSourceMediaTypes.contains(type) || isRaw
                {
                    return MediaDecodeProbe(
                        mediaType: type,
                        width: size.width,
                        height: size.height,
                        decoder: .imageIO
                    )
                }
            }
        }

        let rawCandidate = ApprovedSourceMediaTypes.isCameraRaw(candidateUTI)
            || ApprovedSourceMediaTypes.isLikelyCameraRawFileName(fileURL.lastPathComponent)
        guard rawCandidate else { return nil }

        if let probe = probeCoreImage(url: fileURL, mediaType: candidateUTI) {
            return probe
        }
        if let size = libRaw.probe(path: fileURL.path) {
            let mediaType = ApprovedSourceMediaTypes.isCameraRaw(candidateUTI)
                ? candidateUTI
                : ApprovedSourceMediaTypes.fujiRawIdentifier
            return MediaDecodeProbe(
                mediaType: mediaType,
                width: size.width,
                height: size.height,
                decoder: .libRaw
            )
        }
        return nil
    }

    /// Returns an Image I/O source suitable for thumbnail extraction, possibly after Core Image / LibRaw preview materialization.
    func preparedImageIOSource(
        sourceBytes: Data,
        expectedMediaType: String?,
        libRawSpy: (any LibRawPreviewDecoding)? = nil
    ) throws -> (source: CGImageSource, type: String, stage: MediaDecodeStage) {
        let rawDecoder = libRawSpy ?? libRaw
        if let source = CGImageSourceCreateWithData(sourceBytes as CFData, nil),
           let type = CGImageSourceGetType(source) as String?
        {
            let isRaw = ApprovedSourceMediaTypes.isCameraRaw(type)
                || (expectedMediaType.map(ApprovedSourceMediaTypes.isCameraRaw) ?? false)
            if (ApprovedSourceMediaTypes.contains(type) || isRaw),
               (isRaw || !isAnimatedStaticDisallowed(source: source, type: type)),
               CGImageSourceGetCount(source) > 0
            {
                return (source, type, .imageIO)
            }
        }

        let expectsRaw = expectedMediaType.map(ApprovedSourceMediaTypes.isCameraRaw) ?? false
            || looksLikeRawBytes(sourceBytes)
        guard expectsRaw else {
            throw DerivedImageError.derivedDecodeFailed
        }

        if let jpeg = decodeCoreImageJPEGPreview(bytes: sourceBytes),
           let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
           let type = CGImageSourceGetType(source) as String?
        {
            return (source, type, .coreImage)
        }
        if let jpeg = rawDecoder.decodeThumbJPEG(bytes: sourceBytes),
           let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
           let type = CGImageSourceGetType(source) as String?
        {
            return (source, type, .libRaw)
        }
        throw DerivedImageError.derivedDecodeFailed
    }

    private func looksLikeRawBytes(_ data: Data) -> Bool {
        if data.count > 16 {
            let prefix = String(data: data.prefix(16), encoding: .ascii) ?? ""
            if prefix.contains("FUJIFILM") { return true }
        }
        return false
    }

    private func probeCoreImage(url: URL, mediaType: String) -> MediaDecodeProbe? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        guard let output = filter.outputImage else { return nil }
        let width = Int(output.extent.width.rounded())
        let height = Int(output.extent.height.rounded())
        guard width > 0, height > 0 else { return nil }
        let type = ApprovedSourceMediaTypes.isCameraRaw(mediaType)
            ? mediaType
            : ApprovedSourceMediaTypes.fujiRawIdentifier
        return MediaDecodeProbe(mediaType: type, width: width, height: height, decoder: .coreImage)
    }

    private func decodeCoreImageJPEGPreview(bytes: Data) -> Data? {
        // Tiny/synthetic buffers are not camera RAW; CIRAWFilter can stall on garbage.
        guard bytes.count > 4_096 else { return nil }
        guard let filter = CIRAWFilter(imageData: bytes) else { return nil }
        filter.isGamutMappingEnabled = true
        guard let output = filter.outputImage else { return nil }
        let context = CIContext(options: [.useSoftwareRenderer: false])
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return context.jpegRepresentation(of: output, colorSpace: colorSpace, options: [:])
    }

    private func logicalSize(source: CGImageSource, index: Int) -> (width: Int, height: Int)? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            return nil
        }
        let orientationValue = (properties[kCGImagePropertyOrientation] as? Int) ?? 1
        if (5 ... 8).contains(orientationValue) {
            return (height, width)
        }
        return (width, height)
    }
}

@_silgen_name("ImageAll_LibRawProbePath")
func ImageAll_LibRawProbePath(
    _ path: UnsafePointer<CChar>,
    _ outWidth: UnsafeMutablePointer<Int32>,
    _ outHeight: UnsafeMutablePointer<Int32>
) -> Int32

@_silgen_name("ImageAll_LibRawProbeBuffer")
func ImageAll_LibRawProbeBuffer(
    _ bytes: UnsafePointer<UInt8>,
    _ length: Int,
    _ outWidth: UnsafeMutablePointer<Int32>,
    _ outHeight: UnsafeMutablePointer<Int32>
) -> Int32

@_silgen_name("ImageAll_LibRawDecodeThumbFromPath")
func ImageAll_LibRawDecodeThumbFromPath(
    _ path: UnsafePointer<CChar>,
    _ outBytes: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
    _ outLength: UnsafeMutablePointer<Int>,
    _ outWidth: UnsafeMutablePointer<Int32>,
    _ outHeight: UnsafeMutablePointer<Int32>
) -> Int32

@_silgen_name("ImageAll_LibRawDecodeThumbFromBuffer")
func ImageAll_LibRawDecodeThumbFromBuffer(
    _ bytes: UnsafePointer<UInt8>,
    _ length: Int,
    _ outBytes: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
    _ outLength: UnsafeMutablePointer<Int>,
    _ outWidth: UnsafeMutablePointer<Int32>,
    _ outHeight: UnsafeMutablePointer<Int32>
) -> Int32

@_silgen_name("ImageAll_LibRawFree")
func ImageAll_LibRawFree(_ pointer: UnsafeMutableRawPointer?)
