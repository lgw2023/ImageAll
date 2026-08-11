import Foundation
import UniformTypeIdentifiers

enum ApprovedSourceMediaTypes: Sendable {
    static let exactIdentifiers: Set<String> = [
        UTType.jpeg.identifier,
        UTType.png.identifier,
        UTType.heic.identifier,
        UTType.heif.identifier,
        UTType.tiff.identifier,
        UTType.webP.identifier,
        "public.jpeg-2000",
        UTType.gif.identifier,
        "public.svg-image",
        UTType.pdf.identifier,
        "com.adobe.illustrator.ai-image",
        "com.fuji.raw-image",
        "com.adobe.raw-image",
    ]

    static let fujiRawIdentifier = "com.fuji.raw-image"
    static let adobeRawIdentifier = "com.adobe.raw-image"
    static let jpeg2000Identifier = "public.jpeg-2000"
    static let svgIdentifier = "public.svg-image"
    static let pdfIdentifier = UTType.pdf.identifier
    static let illustratorIdentifier = "com.adobe.illustrator.ai-image"

    static func contains(_ mediaType: String) -> Bool {
        let lowered = mediaType.lowercased()
        if exactIdentifiers.contains(lowered) || exactIdentifiers.contains(mediaType) {
            return true
        }
        return isCameraRaw(mediaType)
    }

    static func isCameraRaw(_ mediaType: String) -> Bool {
        let lowered = mediaType.lowercased()
        if lowered == fujiRawIdentifier || lowered == adobeRawIdentifier {
            return true
        }
        if lowered.contains("raw-image") {
            return true
        }
        guard let type = UTType(lowered) ?? UTType(mediaType) else {
            return false
        }
        if let cameraRaw = UTType("public.camera-raw-image"), type.conforms(to: cameraRaw) {
            return true
        }
        return type.conforms(to: .rawImage)
    }

    static func isLikelyCameraRawFileName(_ fileName: String) -> Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "raf", "dng", "cr2", "cr3", "nef", "arw", "orf", "rw2", "pef", "srw", "raw":
            return true
        default:
            return false
        }
    }

    static func isVectorDocumentMediaType(_ mediaType: String) -> Bool {
        switch mediaType.lowercased() {
        case svgIdentifier, pdfIdentifier, illustratorIdentifier:
            return true
        default:
            return false
        }
    }

    static func isPDFCompatibleVectorMediaType(_ mediaType: String) -> Bool {
        switch mediaType.lowercased() {
        case pdfIdentifier, illustratorIdentifier:
            return true
        default:
            return false
        }
    }

    /// Folder enumeration may skip unsupported files before classification to
    /// avoid unnecessary metadata work on large sources.
    static func shouldSkipUnsupportedFileName(_ fileName: String) -> Bool {
        if isLikelyCameraRawFileName(fileName) {
            return false
        }
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else {
            return true
        }
        guard let type = UTType(filenameExtension: ext) else {
            return true
        }
        if isVideoUTI(type) {
            return false
        }
        if isVectorDocumentMediaType(type.identifier) {
            return false
        }
        return !type.conforms(to: .image)
    }

    static func isVideoMediaType(_ mediaType: String) -> Bool {
        let lowered = mediaType.lowercased()
        if let type = UTType(lowered) ?? UTType(mediaType), isVideoUTI(type) {
            return true
        }
        return false
    }

    private static func isVideoUTI(_ type: UTType) -> Bool {
        type.conforms(to: .movie) || type.conforms(to: .video)
    }
}

enum FolderMediaClassificationFailureReason: String, Equatable, Sendable {
    case sourceCreateFailed
    case zeroFrames
    case missingDimensions
    case cascadeProbeFailed
}
