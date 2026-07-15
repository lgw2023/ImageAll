import Foundation
import ImageIO
import UniformTypeIdentifiers

enum FolderMediaClassification: Equatable, Sendable {
    case ignored
    case available(FolderMediaMetadata)
    case unsupported(FolderMediaMetadata)
    case unreadable(FolderMediaMetadata)
}

struct FolderMediaMetadata: Equatable, Sendable {
    let mediaType: String
    let width: Int?
    let height: Int?
    let mediaCreatedAtMs: Int64?
    let sizeBytes: Int64
    let modifiedAtNs: Int64
    let resourceID: Data?
}

struct FolderMediaClassifier: Sendable {
    private static let allowedTypes: Set<String> = [
        UTType.jpeg.identifier,
        UTType.png.identifier,
        UTType.heic.identifier,
        UTType.heif.identifier,
        UTType.tiff.identifier,
        UTType.webP.identifier,
    ]

    func classify(fileURL: URL, fileName: String) -> FolderMediaClassification {
        let ext = (fileName as NSString).pathExtension
        guard let declaredType = UTType(filenameExtension: ext), declaredType.conforms(to: .image) else {
            return .ignored
        }

        let candidateUTI = declaredType.identifier
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
            return .unreadable(
                FolderMediaMetadata(
                    mediaType: candidateUTI,
                    width: nil,
                    height: nil,
                    mediaCreatedAtMs: nil,
                    sizeBytes: fileSizeBytes(fileURL),
                    modifiedAtNs: modifiedAtNs(fileURL),
                    resourceID: resourceIdentifier(fileURL)
                )
            )
        }

        let actualType = (CGImageSourceGetType(source) as String?) ?? candidateUTI
        let count = CGImageSourceGetCount(source)
        guard count == 1 else {
            return .unsupported(
                metadataOrFallback(
                    fileURL: fileURL,
                    mediaType: actualType,
                    source: source,
                    index: 0
                )
            )
        }

        if isAnimated(source: source, type: actualType) {
            return .unsupported(
                metadataOrFallback(
                    fileURL: fileURL,
                    mediaType: actualType,
                    source: source,
                    index: 0
                )
            )
        }

        guard Self.allowedTypes.contains(actualType) else {
            return .unsupported(
                metadataOrFallback(
                    fileURL: fileURL,
                    mediaType: actualType,
                    source: source,
                    index: 0
                )
            )
        }

        guard let metadata = makeMetadata(
            fileURL: fileURL,
            mediaType: actualType,
            source: source,
            index: 0,
            allowNilDimensions: false
        ), metadata.width != nil, metadata.height != nil
        else {
            return .unreadable(
                FolderMediaMetadata(
                    mediaType: actualType,
                    width: nil,
                    height: nil,
                    mediaCreatedAtMs: mediaCreatedAtMs(source: source, index: 0),
                    sizeBytes: fileSizeBytes(fileURL),
                    modifiedAtNs: modifiedAtNs(fileURL),
                    resourceID: resourceIdentifier(fileURL)
                )
            )
        }

        return .available(metadata)
    }

    private func isAnimated(source: CGImageSource, type: String) -> Bool {
        if type == UTType.gif.identifier {
            return true
        }
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any],
           let loopCount = gif[kCGImagePropertyGIFLoopCount] as? Int,
           loopCount != 1
        {
            return true
        }
        if CGImageSourceGetCount(source) > 1 {
            return true
        }
        return false
    }

    private func metadataOrFallback(
        fileURL: URL,
        mediaType: String,
        source: CGImageSource,
        index: Int
    ) -> FolderMediaMetadata {
        makeMetadata(
            fileURL: fileURL,
            mediaType: mediaType,
            source: source,
            index: index,
            allowNilDimensions: true
        ) ?? FolderMediaMetadata(
            mediaType: mediaType,
            width: nil,
            height: nil,
            mediaCreatedAtMs: mediaCreatedAtMs(source: source, index: index),
            sizeBytes: fileSizeBytes(fileURL),
            modifiedAtNs: modifiedAtNs(fileURL),
            resourceID: resourceIdentifier(fileURL)
        )
    }

    private func makeMetadata(
        fileURL: URL,
        mediaType: String,
        source: CGImageSource,
        index: Int,
        allowNilDimensions: Bool
    ) -> FolderMediaMetadata? {
        let dimensions = logicalDimensions(source: source, index: index)
        if !allowNilDimensions, dimensions.width == nil || dimensions.height == nil {
            return nil
        }
        return FolderMediaMetadata(
            mediaType: mediaType,
            width: dimensions.width,
            height: dimensions.height,
            mediaCreatedAtMs: mediaCreatedAtMs(source: source, index: index),
            sizeBytes: fileSizeBytes(fileURL),
            modifiedAtNs: modifiedAtNs(fileURL),
            resourceID: resourceIdentifier(fileURL)
        )
    }

    private func logicalDimensions(source: CGImageSource, index: Int) -> (width: Int?, height: Int?) {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            return (nil, nil)
        }

        let orientationValue = (properties[kCGImagePropertyOrientation] as? Int) ?? 1
        if (5 ... 8).contains(orientationValue) {
            return (height, width)
        }
        return (width, height)
    }

    private func mediaCreatedAtMs(source: CGImageSource, index: Int) -> Int64? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let dateString = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        else {
            return nil
        }
        return parseUTCDateTime(dateString)
    }

    private func parseUTCDateTime(_ value: String) -> Int64? {
        if value.hasSuffix("Z") {
            let trimmed = String(value.dropLast())
            return parseFixedOffset(trimmed + "+0000")
        }
        if let range = value.range(of: #"([+-]\d{2}:?\d{2})$"#, options: .regularExpression) {
            let offset = String(value[range.lowerBound...])
            let trimmed = String(value[..<range.lowerBound])
            return parseFixedOffset(trimmed + offset.replacingOccurrences(of: ":", with: ""))
        }
        return nil
    }

    private func parseFixedOffset(_ value: String) -> Int64? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ssZ"
        guard let date = formatter.date(from: value) else {
            return nil
        }
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    private func fileSizeBytes(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    private func modifiedAtNs(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        guard let date = values?.contentModificationDate else {
            return 0
        }
        return Int64(date.timeIntervalSince1970 * 1_000_000_000)
    }

    private func resourceIdentifier(_ url: URL) -> Data? {
        let values = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey])
        guard let object = values?.fileResourceIdentifier else {
            return nil
        }
        if let data = object as? Data {
            return data
        }
        if let number = object as? NSNumber {
            return number.stringValue.data(using: .utf8)
        }
        return nil
    }
}
