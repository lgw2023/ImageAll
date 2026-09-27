import AVFoundation
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
    let mediaKind: MediaKind
    let mediaType: String
    let durationMs: Int64?
    let width: Int?
    let height: Int?
    let mediaCreatedAtMs: Int64?
    let videoTechnicalMetadata: VideoTechnicalMetadata?
    let videoMetadataVersion: Int
    let location: AssetLocationCoordinate?
    let sizeBytes: Int64?
    let modifiedAtNs: Int64?
    let resourceID: Data?
    let classificationFailureReason: FolderMediaClassificationFailureReason?

    init(
        mediaType: String,
        mediaKind: MediaKind = .image,
        durationMs: Int64? = nil,
        width: Int?,
        height: Int?,
        mediaCreatedAtMs: Int64?,
        location: AssetLocationCoordinate? = nil,
        videoMetadataVersion: Int = 0,
        videoTechnicalMetadata: VideoTechnicalMetadata? = nil,
        sizeBytes: Int64?,
        modifiedAtNs: Int64?,
        resourceID: Data?,
        classificationFailureReason: FolderMediaClassificationFailureReason? = nil
    ) {
        self.mediaKind = mediaKind
        self.mediaType = mediaType
        self.durationMs = durationMs
        self.width = width
        self.height = height
        self.mediaCreatedAtMs = mediaCreatedAtMs
        self.location = location
        self.videoMetadataVersion = videoMetadataVersion
        self.videoTechnicalMetadata = videoTechnicalMetadata
        self.sizeBytes = sizeBytes
        self.modifiedAtNs = modifiedAtNs
        self.resourceID = resourceID
        self.classificationFailureReason = classificationFailureReason
    }

    var hasProvenFingerprint: Bool {
        sizeBytes != nil && modifiedAtNs != nil
    }
}

struct FolderVideoMetadata: Equatable, Sendable {
    let mediaType: String
    let width: Int
    let height: Int
    let durationMs: Int64
    let mediaCreatedAtMs: Int64?
    var location: AssetLocationCoordinate? = nil
    var technicalMetadata: VideoTechnicalMetadata? = nil
}

protocol FolderVideoMetadataReading: Sendable {
    func metadata(fileURL: URL, declaredType: String) -> FolderVideoMetadata?
}

struct AVFoundationFolderVideoMetadataReader: FolderVideoMetadataReading {
    static let policyVersion = 2
    func metadata(fileURL: URL, declaredType: String) -> FolderVideoMetadata? {
        autoreleasepool {
            let asset = AVURLAsset(url: fileURL)
            let durationSeconds = CMTimeGetSeconds(asset.duration)
            guard durationSeconds.isFinite, durationSeconds > 0,
                  durationSeconds <= Double(Int64.max) / 1_000,
                  let track = asset.tracks(withMediaType: .video).first
            else {
                return nil
            }

            let transformedSize = track.naturalSize.applying(track.preferredTransform)
            let width = Int(abs(transformedSize.width).rounded())
            let height = Int(abs(transformedSize.height).rounded())
            guard width > 0, height > 0 else {
                return nil
            }

            return FolderVideoMetadata(
                mediaType: declaredType,
                width: width,
                height: height,
                durationMs: max(1, Int64((durationSeconds * 1_000).rounded())),
                mediaCreatedAtMs: Self.embeddedDate(asset.metadata),
                location: Self.embeddedLocation(asset.metadata),
                technicalMetadata: VideoTechnicalMetadata(
                    codec: (track.formatDescriptions as? [CMFormatDescription])?.first.map {
                        let code = CMFormatDescriptionGetMediaSubType($0)
                        return String(bytes: [UInt8((code >> 24) & 255), UInt8((code >> 16) & 255),
                                              UInt8((code >> 8) & 255), UInt8(code & 255)], encoding: .ascii)
                    } ?? nil,
                    nominalFrameRate: Self.positiveFinite(track.nominalFrameRate),
                    estimatedDataRate: Self.positiveFinite(track.estimatedDataRate),
                    audioTrackCount: asset.tracks(withMediaType: .audio).count
                )
            )
        }
    }

    private static func positiveFinite(_ value: Float) -> Double? {
        value.isFinite && value > 0 ? Double(value) : nil
    }

    // Only explicit, timezone-qualified container dates represent capture time.
    // No filesystem date or local-timezone fallback is used.
    static func parseEmbeddedDate(_ raw: String) -> Int64? {
        guard raw.count <= 128,
              raw.range(of: #"(Z|[+-][0-9]{2}:?[0-9]{2})$"#, options: .regularExpression) != nil else { return nil }
        let formatter = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
            formatter.formatOptions = options
            if let date = formatter.date(from: raw) {
                let ms = date.timeIntervalSince1970 * 1_000
                guard ms.isFinite, ms > Double(Int64.min), ms < Double(Int64.max) else { return nil }
                return Int64(ms.rounded())
            }
        }
        return nil
    }

    static func parseISO6709(_ raw: String) -> AssetLocationCoordinate? {
        // Decimal degrees only. Optional altitude is ignored; malformed suffixes
        // and degrees/minutes variants are not guessed into coordinates.
        guard raw.count <= 128,
              let regex = try? NSRegularExpression(pattern: #"^([+-][0-9]{2}(?:\.[0-9]+)?)([+-][0-9]{3}(?:\.[0-9]+)?)(?:[+-][0-9]+(?:\.[0-9]+)?)?/$"#),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              let latRange = Range(match.range(at: 1), in: raw),
              let lonRange = Range(match.range(at: 2), in: raw),
              let latitude = Double(raw[latRange]), let longitude = Double(raw[lonRange]),
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        return AssetLocationCoordinate(latitude: latitude, longitude: longitude)
    }

    private static func embeddedDate(_ items: [AVMetadataItem]) -> Int64? {
        for identifier in [AVMetadataIdentifier.quickTimeMetadataCreationDate, .commonIdentifierCreationDate] {
            for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier) {
                if let value = item.stringValue, let date = parseEmbeddedDate(value) { return date }
            }
        }
        return nil
    }

    private static func embeddedLocation(_ items: [AVMetadataItem]) -> AssetLocationCoordinate? {
        for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .quickTimeMetadataLocationISO6709) {
            if let value = item.stringValue, let coordinate = parseISO6709(value) { return coordinate }
        }
        return nil
    }
}

struct FolderMediaClassifier: Sendable {
    private let resourceReader: any FolderFileResourceReading
    private let cascade: MediaDecodeCascade
    private let videoMetadataReader: any FolderVideoMetadataReading

    init(
        resourceReader: any FolderFileResourceReading = FoundationFolderFileResourceReader(),
        cascade: MediaDecodeCascade = MediaDecodeCascade(),
        videoMetadataReader: any FolderVideoMetadataReading = AVFoundationFolderVideoMetadataReader()
    ) {
        self.resourceReader = resourceReader
        self.cascade = cascade
        self.videoMetadataReader = videoMetadataReader
    }

    func classify(fileURL: URL, fileName: String, relativePath: String? = nil) -> FolderMediaClassification {
        let rel = relativePath ?? fileName
        let ext = (fileName as NSString).pathExtension
        guard let declaredType = UTType(filenameExtension: ext) else {
            return .ignored
        }

        let candidateUTI = declaredType.identifier
        let fingerprint = (
            sizeBytes: fileSizeBytes(fileURL, relativePath: rel),
            modifiedAtNs: modifiedAtNs(fileURL, relativePath: rel),
            resourceID: resourceIdentifier(fileURL)
        )

        if ApprovedSourceMediaTypes.isVideoMediaType(candidateUTI) {
            if let video = videoMetadataReader.metadata(
                fileURL: fileURL,
                declaredType: candidateUTI
            ) {
                return .available(
                    FolderMediaMetadata(
                        mediaType: video.mediaType,
                        mediaKind: .video,
                        durationMs: video.durationMs,
                        width: video.width,
                        height: video.height,
                        mediaCreatedAtMs: video.mediaCreatedAtMs,
                        location: video.location,
                        videoMetadataVersion: AVFoundationFolderVideoMetadataReader.policyVersion,
                        videoTechnicalMetadata: video.technicalMetadata,
                        sizeBytes: fingerprint.sizeBytes,
                        modifiedAtNs: fingerprint.modifiedAtNs,
                        resourceID: fingerprint.resourceID
                    )
                )
            }
            return .unreadable(
                FolderMediaMetadata(
                    mediaType: candidateUTI,
                    mediaKind: .video,
                    width: nil,
                    height: nil,
                    mediaCreatedAtMs: nil,
                    videoMetadataVersion: AVFoundationFolderVideoMetadataReader.policyVersion,
                    sizeBytes: fingerprint.sizeBytes,
                    modifiedAtNs: fingerprint.modifiedAtNs,
                    resourceID: fingerprint.resourceID,
                    classificationFailureReason: .sourceCreateFailed
                )
            )
        }

        guard declaredType.conforms(to: .image)
            || ApprovedSourceMediaTypes.isVectorDocumentMediaType(candidateUTI)
        else {
            return .ignored
        }

        if ApprovedSourceMediaTypes.isVectorDocumentMediaType(candidateUTI) {
            if ApprovedSourceMediaTypes.isPDFCompatibleVectorMediaType(candidateUTI),
               let pageCount = cascade.pdfCompatiblePageCount(fileURL: fileURL),
               pageCount != 1 {
                return .unsupported(
                    FolderMediaMetadata(
                        mediaType: candidateUTI,
                        width: nil,
                        height: nil,
                        mediaCreatedAtMs: nil,
                        sizeBytes: fingerprint.sizeBytes,
                        modifiedAtNs: fingerprint.modifiedAtNs,
                        resourceID: fingerprint.resourceID
                    )
                )
            }
            return classifyWithCascadeFallback(
                fileURL: fileURL,
                candidateUTI: candidateUTI,
                fingerprint: fingerprint,
                failureReason: .cascadeProbeFailed
            )
        }

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
                    location: location(source: source, index: frameIndex),
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
        let cascadeEligible = rawLikely
            || ApprovedSourceMediaTypes.isVectorDocumentMediaType(candidateUTI)
        if cascadeEligible, let probe = cascade.probeFile(fileURL: fileURL, candidateUTI: candidateUTI) {
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
                classificationFailureReason: cascadeEligible ? .cascadeProbeFailed : failureReason
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
            location: location(source: source, index: index),
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
            location: location(source: source, index: index),
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

    private func location(source: CGImageSource, index: Int) -> AssetLocationCoordinate? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
            as? [CFString: Any],
            let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
            let rawLatitude = numericValue(gps[kCGImagePropertyGPSLatitude]),
            let rawLongitude = numericValue(gps[kCGImagePropertyGPSLongitude])
        else {
            return nil
        }

        let latitudeRef = (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased()
        let longitudeRef = (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased()
        let latitude = latitudeRef == "S" ? -abs(rawLatitude) : rawLatitude
        let longitude = longitudeRef == "W" ? -abs(rawLongitude) : rawLongitude
        let coordinate = AssetLocationCoordinate(latitude: latitude, longitude: longitude)
        return coordinate.isValid ? coordinate : nil
    }

    private func numericValue(_ value: Any?) -> Double? {
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        return value as? Double
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
