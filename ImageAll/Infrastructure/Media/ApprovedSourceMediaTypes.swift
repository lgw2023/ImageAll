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
        "com.fuji.raw-image",
        "com.adobe.raw-image",
    ]

    static let fujiRawIdentifier = "com.fuji.raw-image"
    static let adobeRawIdentifier = "com.adobe.raw-image"
    static let jpeg2000Identifier = "public.jpeg-2000"

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
}

enum FolderMediaClassificationFailureReason: String, Equatable, Sendable {
    case sourceCreateFailed
    case zeroFrames
    case missingDimensions
    case cascadeProbeFailed
}
