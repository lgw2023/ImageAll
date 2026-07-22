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
    let sizeBytes: Int64?
    let modifiedAtNs: Int64?
    let resourceID: Data?
    let classificationFailureReason: FolderMediaClassificationFailureReason?

    init(
        mediaType: String,
        width: Int?,
        height: Int?,
        mediaCreatedAtMs: Int64?,
        sizeBytes: Int64?,
        modifiedAtNs: Int64?,
        resourceID: Data?,
        classificationFailureReason: FolderMediaClassificationFailureReason? = nil
    ) {
        self.mediaType = mediaType
        self.width = width
        self.height = height
        self.mediaCreatedAtMs = mediaCreatedAtMs
        self.sizeBytes = sizeBytes
        self.modifiedAtNs = modifiedAtNs
        self.resourceID = resourceID
        self.classificationFailureReason = classificationFailureReason
    }

    var hasProvenFingerprint: Bool {
        sizeBytes != nil && modifiedAtNs != nil
    }
}

struct FolderMediaClassifier: Sendable {
    private let resourceReader: any FolderFileResourceReading
    private let cascade: MediaDecodeCascade

    init(
        resourceReader: any FolderFileResourceReading = FoundationFolderFileResourceReader(),
        cascade: MediaDecodeCascade = MediaDecodeCascade()
    ) {
        self.resourceReader = resourceReader
        self.cascade = cascade
    }

    func classify(fileURL: URL, fileName: String, relativePath: String? = nil) -> FolderMediaClassification {
        let rel = relativePath ?? fileName
        let ext = (fileName as NSString).pathExtension
        guard let declaredType = UTType(filenameExtension: ext), declaredType.conforms(to: .image) else {
            return .ignored
        }

        let candidateUTI = declaredType.identifier
        let fingerprint = (
            sizeBytes: fileSizeBytes(fileURL, relativePath: rel),
            modifiedAtNs: modifiedAtNs(fileURL, relativePath: rel),
            resourceID: resourceIdentifier(fileURL)
        )

        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
            return classifyWithCascadeFallback(
                fileURL: fileURL,
                candidateUTI: candidateUTI,
                fingerprint: fingerprint,
                failureReason: .sourceCreateFailed
            )
        }

        let actualType = (CGImageSourceGetType(source) as String?) ?? candidateUTI
        let isCameraRaw = ApprovedSourceMediaTypes.isCameraRaw(actualType)
            || ApprovedSourceMediaTypes.isCameraRaw(candidateUTI)
        let count = CGImageSourceGetCount(source)
        if count == 0 {
            return classifyWithCascadeFallback(
                fileURL: fileURL,
                candidateUTI: actualType,
                fingerprint: fingerprint,
                failureReason: .zeroFrames
            )
        }

        if !isCameraRaw {
            if count != 1 || cascade.isAnimatedStaticDisallowed(source: source, type: actualType) {
                return .unsupported(
                    metadataOrFallback(
                        fileURL: fileURL,
                        mediaType: actualType,
                        source: source,
                        index: 0,
                        relativePath: rel
                    )
                )
            }
        }

        guard ApprovedSourceMediaTypes.contains(actualType) || isCameraRaw else {
            return .unsupported(
                metadataOrFallback(
                    fileURL: fileURL,
                    mediaType: actualType,
                    source: source,
                    index: 0,
                    relativePath: rel
                )
            )
        }

        let frameIndex = cascade.primaryFrameIndex(source: source, isCameraRaw: isCameraRaw)
        guard let metadata = makeMetadata(
            fileURL: fileURL,
            mediaType: actualType,
            source: source,
            index: frameIndex,
            allowNilDimensions: false,
            relativePath: rel
        ), metadata.width != nil, metadata.height != nil
        else {
            if isCameraRaw {
                return classifyWithCascadeFallback(
                    fileURL: fileURL,
                    candidateUTI: actualType,
                    fingerprint: fingerprint,
                    failureReason: .missingDimensions
                )
            }
            return .unreadable(
                FolderMediaMetadata(
                    mediaType: actualType,
                    width: nil,
                    height: nil,
                    mediaCreatedAtMs: mediaCreatedAtMs(source: source, index: frameIndex),
                    sizeBytes: fingerprint.sizeBytes,
                    modifiedAtNs: fingerprint.modifiedAtNs,
                    resourceID: fingerprint.resourceID,
                    classificationFailureReason: .missingDimensions
                )
            )
        }

        return .available(metadata)
    }

    private func classifyWithCascadeFallback(
        fileURL: URL,
        candidateUTI: String,
        fingerprint: (sizeBytes: Int64?, modifiedAtNs: Int64?, resourceID: Data?),
        failureReason: FolderMediaClassificationFailureReason
    ) -> FolderMediaClassification {
        let rawLikely = ApprovedSourceMediaTypes.isCameraRaw(candidateUTI)
            || ApprovedSourceMediaTypes.isLikelyCameraRawFileName(fileURL.lastPathComponent)
        if rawLikely, let probe = cascade.probeFile(fileURL: fileURL, candidateUTI: candidateUTI) {
            return .available(
                FolderMediaMetadata(
                    mediaType: probe.mediaType,
                    width: probe.width,
                    height: probe.height,
                    mediaCreatedAtMs: nil,
                    sizeBytes: fingerprint.sizeBytes,
                    modifiedAtNs: fingerprint.modifiedAtNs,
                    resourceID: fingerprint.resourceID
                )
            )
        }
        return .unreadable(
            FolderMediaMetadata(
                mediaType: candidateUTI,
                width: nil,
                height: nil,
                mediaCreatedAtMs: nil,
                sizeBytes: fingerprint.sizeBytes,
                modifiedAtNs: fingerprint.modifiedAtNs,
                resourceID: fingerprint.resourceID,
                classificationFailureReason: rawLikely ? .cascadeProbeFailed : failureReason
            )
        )
    }

    private func metadataOrFallback(
        fileURL: URL,
        mediaType: String,
        source: CGImageSource,
        index: Int,
        relativePath: String
    ) -> FolderMediaMetadata {
        makeMetadata(
            fileURL: fileURL,
            mediaType: mediaType,
            source: source,
            index: index,
            allowNilDimensions: true,
            relativePath: relativePath
        ) ?? FolderMediaMetadata(
            mediaType: mediaType,
            width: nil,
            height: nil,
            mediaCreatedAtMs: mediaCreatedAtMs(source: source, index: index),
            sizeBytes: fileSizeBytes(fileURL, relativePath: relativePath),
            modifiedAtNs: modifiedAtNs(fileURL, relativePath: relativePath),
            resourceID: resourceIdentifier(fileURL)
        )
    }

    private func makeMetadata(
        fileURL: URL,
        mediaType: String,
        source: CGImageSource,
        index: Int,
        allowNilDimensions: Bool,
        relativePath: String
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
            sizeBytes: fileSizeBytes(fileURL, relativePath: relativePath),
            modifiedAtNs: modifiedAtNs(fileURL, relativePath: relativePath),
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
        if dateString.hasSuffix("Z") {
            return parseUTCDateTime(dateString)
        }
        if let range = dateString.range(of: #"([+-]\d{2}:?\d{2})$"#, options: .regularExpression) {
            let offset = String(dateString[range.lowerBound...])
            let trimmed = String(dateString[..<range.lowerBound])
            return parseFixedOffset(trimmed + offset.replacingOccurrences(of: ":", with: ""))
        }
        if let offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String {
            return parseFixedOffset(dateString + offset.replacingOccurrences(of: ":", with: ""))
        }
        return nil
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

    private func fileSizeBytes(_ url: URL, relativePath: String) -> Int64? {
        _ = relativePath
        return resourceReader.fileSizeBytes(for: url)
    }

    private func modifiedAtNs(_ url: URL, relativePath: String) -> Int64? {
        _ = relativePath
        return resourceReader.modifiedAtNs(for: url)
    }

    private func resourceIdentifier(_ url: URL) -> Data? {
        resourceReader.resourceIdentifier(for: url)
    }
}
