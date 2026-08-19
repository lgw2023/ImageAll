import AppKit
import CryptoKit
import Foundation
import Photos

private let toolVersion = "0.1.0"
private let manifestSchemaVersion = 1

private enum ExporterError: Error {
    case usage(String)
    case authorizationDenied
    case libraryUnavailable
    case unsafeOutput
    case outputExists
    case outputNotEmpty
    case manifestWriteFailed
    case resourceWriteFailed
    case invalidResume
}

private enum Command {
    case help
    case authorize
    case count
    case inventory(manifest: URL)
    case export(outputRoot: URL, allowNetworkAccess: Bool, resume: Bool)
}

private struct HeaderRecord: Encodable {
    let recordType = "header"
    let schemaVersion = manifestSchemaVersion
    let exporter = "photos-exit-exporter"
    let exporterVersion = toolVersion
    let mode: String
    let networkAccessAllowed: Bool
    let createdAtMs: Int64
}

private struct ResourceRecord: Encodable {
    let index: Int
    let type: String
    let uniformTypeIdentifier: String
    let originalFilename: String
    let relativePath: String?
    let byteSize: Int64?
    let sha256: String?
    let status: String
}

private struct AssetRecord: Encodable {
    let recordType = "asset"
    let schemaVersion = manifestSchemaVersion
    let localIdentifier: String
    let mediaType: String
    let mediaSubtypes: UInt64
    let pixelWidth: Int
    let pixelHeight: Int
    let durationMs: Int64?
    let creationDateMs: Int64?
    let modificationDateMs: Int64?
    let isFavorite: Bool
    let isHidden: Bool
    let primaryResourceIndex: Int?
    let resources: [ResourceRecord]
    let status: String
}

private struct ResumeState {
    let completedIdentifiers: Set<String>
}

private final class ManifestWriter {
    private let handle: FileHandle
    private let encoder: JSONEncoder

    init(url: URL, header: HeaderRecord) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw ExporterError.outputExists
        }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw ExporterError.manifestWriteFailed
        }
        do {
            handle = try FileHandle(forWritingTo: url)
        } catch {
            throw ExporterError.manifestWriteFailed
        }
        encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try append(header)
    }

    init(resuming url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ExporterError.outputExists
        }
        do {
            handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
        } catch {
            throw ExporterError.manifestWriteFailed
        }
        encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    deinit {
        try? handle.close()
    }

    func append<T: Encodable>(_ value: T) throws {
        do {
            var data = try encoder.encode(value)
            data.append(0x0A)
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            throw ExporterError.manifestWriteFailed
        }
    }
}

@main
private struct PhotosExitExporter {
    static func main() async {
        do {
            let command = try parseCommand(Array(CommandLine.arguments.dropFirst()))
            switch command {
            case .help:
                printHelp()
            case .authorize:
                try await requirePhotoAuthorization()
                print("photos_access=authorized network_access=0 writes=0")
            case .count:
                try await requirePhotoAuthorization()
                countAssets()
            case let .inventory(manifest):
                try validateOutputURL(manifest)
                try await requirePhotoAuthorization()
                try inventory(to: manifest)
            case let .export(outputRoot, allowNetworkAccess, resume):
                if resume {
                    try validateExistingOutputRoot(outputRoot)
                } else {
                    try prepareNewOutputRoot(outputRoot)
                }
                try await requirePhotoAuthorization()
                try await exportResources(
                    to: outputRoot,
                    allowNetworkAccess: allowNetworkAccess,
                    resume: resume
                )
            }
        } catch let error as ExporterError {
            fputs("error=\(errorCode(error))\n", stderr)
            Foundation.exit(EXIT_FAILURE)
        } catch {
            fputs("error=unexpected_exporter_failure\n", stderr)
            Foundation.exit(EXIT_FAILURE)
        }
    }

    private static func parseCommand(_ arguments: [String]) throws -> Command {
        guard let verb = arguments.first else { return .help }
        if verb == "--help" || verb == "-h" || verb == "help" {
            return .help
        }
        switch verb {
        case "authorize":
            guard arguments.count == 1 else {
                throw ExporterError.usage("authorize has no options")
            }
            return .authorize
        case "count":
            guard arguments.count == 1 else {
                throw ExporterError.usage("count has no options")
            }
            return .count
        case "inventory":
            guard arguments.count == 3, arguments[1] == "--manifest" else {
                throw ExporterError.usage("inventory requires --manifest")
            }
            return .inventory(
                manifest: URL(fileURLWithPath: arguments[2]).standardizedFileURL
            )
        case "export":
            var outputRoot: URL?
            var allowNetworkAccess = false
            var resume = false
            var index = 1
            while index < arguments.count {
                switch arguments[index] {
                case "--output-root":
                    guard outputRoot == nil, index + 1 < arguments.count else {
                        throw ExporterError.usage("export requires one output root")
                    }
                    outputRoot = URL(fileURLWithPath: arguments[index + 1])
                        .standardizedFileURL
                    index += 2
                case "--allow-network-access":
                    guard !allowNetworkAccess else {
                        throw ExporterError.usage("network option repeats")
                    }
                    allowNetworkAccess = true
                    index += 1
                case "--resume":
                    guard !resume else {
                        throw ExporterError.usage("resume option repeats")
                    }
                    resume = true
                    index += 1
                default:
                    throw ExporterError.usage("unknown export option")
                }
            }
            guard let outputRoot else {
                throw ExporterError.usage("export requires --output-root")
            }
            return .export(
                outputRoot: outputRoot,
                allowNetworkAccess: allowNetworkAccess,
                resume: resume
            )
        default:
            throw ExporterError.usage("unknown command")
        }
    }

    private static func printHelp() {
        print(
            """
            Usage:
              photos-exit-exporter authorize
              photos-exit-exporter count
              photos-exit-exporter inventory --manifest <new-jsonl-path>
              photos-exit-exporter export --output-root <new-or-empty-directory>
                  [--allow-network-access] [--resume]

            authorize only requests Photos permission and does not enumerate assets.
            count prints aggregate PhotoKit metadata and writes nothing.
            inventory reads PhotoKit metadata only and never requests media bytes.
            export writes all public PHAsset resources and photos-exit-manifest.jsonl.
            Network access is disabled unless the separately authorized flag is supplied.
            Resume retries incomplete staging assets and skips completed manifest records.
            PhotoKit accesses only the System Photo Library selected by the user in Photos.
            """
        )
    }

    private static func validateOutputURL(_ url: URL) throws {
        guard url.isFileURL,
              !url.pathComponents.contains(where: {
                  $0.lowercased().hasSuffix(".photoslibrary")
              })
        else {
            throw ExporterError.unsafeOutput
        }
        if FileManager.default.fileExists(atPath: url.path) {
            throw ExporterError.outputExists
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: url.deletingLastPathComponent().path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw ExporterError.unsafeOutput
        }
    }

    private static func prepareNewOutputRoot(_ url: URL) throws {
        guard url.isFileURL,
              !url.pathComponents.contains(where: {
                  $0.lowercased().hasSuffix(".photoslibrary")
              })
        else {
            throw ExporterError.unsafeOutput
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw ExporterError.unsafeOutput }
            let entries = try FileManager.default.contentsOfDirectory(atPath: url.path)
            guard entries.isEmpty else { throw ExporterError.outputNotEmpty }
        } else {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: false
            )
        }
    }

    private static func validateExistingOutputRoot(_ url: URL) throws {
        guard url.isFileURL,
              !url.pathComponents.contains(where: {
                  $0.lowercased().hasSuffix(".photoslibrary")
              })
        else {
            throw ExporterError.unsafeOutput
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw ExporterError.unsafeOutput
        }
    }

    private static func requirePhotoAuthorization(showPrimer: Bool = false) async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        emitProgress("photos_authorization_status_initial=\(authorizationStatusName(status))")
        let resolved: PHAuthorizationStatus
        if status == .notDetermined {
            let shouldContinue = await MainActor.run {
                let application = NSApplication.shared
                application.setActivationPolicy(.regular)
                application.activate()
                guard showPrimer else { return true }
                let alert = NSAlert()
                alert.messageText = "授权只读导出"
                alert.informativeText = "下一步 macOS 会询问照片权限。本工具此刻不会枚举、下载、修改或删除任何照片。"
                alert.addButton(withTitle: "继续")
                alert.addButton(withTitle: "取消")
                return alert.runModal() == .alertFirstButtonReturn
            }
            guard shouldContinue else { throw ExporterError.authorizationDenied }
            resolved = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        } else {
            resolved = status
        }
        emitProgress("photos_authorization_status_resolved=\(authorizationStatusName(resolved))")
        guard resolved == .authorized || resolved == .limited else {
            throw ExporterError.authorizationDenied
        }
        guard PHPhotoLibrary.shared().unavailabilityReason == nil else {
            throw ExporterError.libraryUnavailable
        }
    }

    private static func inventory(to manifestURL: URL) throws {
        let writer = try ManifestWriter(
            url: manifestURL,
            header: HeaderRecord(
                mode: "inventory",
                networkAccessAllowed: false,
                createdAtMs: nowMs()
            )
        )
        let assets = fetchAssets()
        var inventoried = 0
        var ambiguous = 0
        assets.enumerateObjects { asset, _, _ in
            let resources = PHAssetResource.assetResources(for: asset)
            let primary = primaryResourceIndex(mediaType: asset.mediaType, resources: resources)
            let status = primary == nil ? "ambiguous" : "inventory"
            if primary == nil { ambiguous += 1 }
            let records = resources.enumerated().map { index, resource in
                ResourceRecord(
                    index: index,
                    type: resourceTypeName(resource.type),
                    uniformTypeIdentifier: resource.uniformTypeIdentifier,
                    originalFilename: sanitizedFilename(resource.originalFilename),
                    relativePath: nil,
                    byteSize: nil,
                    sha256: nil,
                    status: "inventory"
                )
            }
            do {
                try writer.append(
                    assetRecord(
                        asset: asset,
                        primaryResourceIndex: primary,
                        resources: records,
                        status: status
                    )
                )
                inventoried += 1
            } catch {
                // Stop enumeration at the first manifest durability failure.
                thrower.store(error)
            }
        }
        if let error = thrower.take() { throw error }
        print("assets=\(inventoried) ambiguous=\(ambiguous) network_access=0")
    }

    private static func countAssets() {
        let assets = fetchAssets()
        var images = 0
        var videos = 0
        var other = 0
        var resourceCount = 0
        var ambiguous = 0
        emitProgress("count_progress=0 assets_total=\(assets.count) network_access=0 writes=0")
        for index in 0 ..< assets.count {
            let asset = assets.object(at: index)
            switch asset.mediaType {
            case .image: images += 1
            case .video: videos += 1
            default: other += 1
            }
            let resources = PHAssetResource.assetResources(for: asset)
            resourceCount += resources.count
            if primaryResourceIndex(mediaType: asset.mediaType, resources: resources) == nil {
                ambiguous += 1
            }
            let processed = index + 1
            if processed.isMultiple(of: 1_000) || processed == assets.count {
                emitProgress(
                    "count_progress=\(processed) assets_total=\(assets.count) "
                        + "resources=\(resourceCount) ambiguous=\(ambiguous)"
                )
            }
        }
        print(
            "assets=\(assets.count) images=\(images) videos=\(videos) other=\(other) "
                + "resources=\(resourceCount) ambiguous=\(ambiguous) network_access=0 writes=0"
        )
    }

    private static let thrower = DeferredError()

    private static func exportResources(
        to outputRoot: URL,
        allowNetworkAccess: Bool,
        resume: Bool
    ) async throws {
        let assetsRoot = outputRoot.appendingPathComponent("assets", isDirectory: true)
        let resourcesRoot = outputRoot.appendingPathComponent(
            ".photos-exit-resources",
            isDirectory: true
        )
        let stagingRoot = outputRoot.appendingPathComponent(
            ".photos-exit-staging",
            isDirectory: true
        )
        let manifestURL = outputRoot.appendingPathComponent("photos-exit-manifest.jsonl")
        let resumeState: ResumeState
        let writer: ManifestWriter
        if resume {
            resumeState = try readResumeState(
                manifestURL: manifestURL,
                allowNetworkAccess: allowNetworkAccess
            )
            writer = try ManifestWriter(resuming: manifestURL)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: assetsRoot.path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue else {
                throw ExporterError.invalidResume
            }
            if !FileManager.default.fileExists(atPath: resourcesRoot.path) {
                try FileManager.default.createDirectory(
                    at: resourcesRoot,
                    withIntermediateDirectories: false
                )
            }
        } else {
            resumeState = ResumeState(completedIdentifiers: [])
            try FileManager.default.createDirectory(
                at: assetsRoot,
                withIntermediateDirectories: false
            )
            try FileManager.default.createDirectory(
                at: resourcesRoot,
                withIntermediateDirectories: false
            )
            writer = try ManifestWriter(
                url: manifestURL,
                header: HeaderRecord(
                    mode: "export",
                    networkAccessAllowed: allowNetworkAccess,
                    createdAtMs: nowMs()
                )
            )
        }
        if !FileManager.default.fileExists(atPath: stagingRoot.path) {
            try FileManager.default.createDirectory(
                at: stagingRoot,
                withIntermediateDirectories: false
            )
        }
        let assets = fetchAssets()
        var completed = 0
        var incomplete = 0
        emitProgress(
            "export_progress=0 assets_total=\(assets.count) complete=0 incomplete=0 "
                + "network_access=\(allowNetworkAccess ? 1 : 0)"
        )
        for index in 0 ..< assets.count {
            let asset = assets.object(at: index)
            if resumeState.completedIdentifiers.contains(asset.localIdentifier) {
                completed += 1
                let processed = index + 1
                if processed.isMultiple(of: 100) || processed == assets.count {
                    emitProgress(
                        "export_progress=\(processed) assets_total=\(assets.count) "
                            + "complete=\(completed) incomplete=\(incomplete)"
                    )
                }
                continue
            }
            let sourceResources = PHAssetResource.assetResources(for: asset)
            let primary = primaryResourceIndex(
                mediaType: asset.mediaType,
                resources: sourceResources
            )
            let assetDirectoryName = identifierDigest(asset.localIdentifier)
            let assetDirectory = assetsRoot.appendingPathComponent(
                assetDirectoryName,
                isDirectory: true
            )
            let stagingDirectory = stagingRoot.appendingPathComponent(
                assetDirectoryName,
                isDirectory: true
            )
            let ancillaryDirectory = resourcesRoot.appendingPathComponent(
                assetDirectoryName,
                isDirectory: true
            )
            var records: [ResourceRecord] = []
            var status = primary == nil ? "ambiguous" : "complete"
            do {
                for previouslyIncompleteDirectory in [assetDirectory, ancillaryDirectory] {
                    if FileManager.default.fileExists(atPath: previouslyIncompleteDirectory.path) {
                        guard resume else { throw ExporterError.invalidResume }
                        try FileManager.default.removeItem(at: previouslyIncompleteDirectory)
                    }
                }
                if FileManager.default.fileExists(atPath: stagingDirectory.path) {
                    try FileManager.default.removeItem(at: stagingDirectory)
                }
                try FileManager.default.createDirectory(
                    at: stagingDirectory,
                    withIntermediateDirectories: false
                )
                let primaryStagingDirectory = stagingDirectory.appendingPathComponent(
                    "primary",
                    isDirectory: true
                )
                let ancillaryStagingDirectory = stagingDirectory.appendingPathComponent(
                    "ancillary",
                    isDirectory: true
                )
                for (resourceIndex, resource) in sourceResources.enumerated() {
                    let filename = String(format: "%03d-", resourceIndex)
                        + sanitizedFilename(resource.originalFilename)
                    let isPrimary = resourceIndex == primary
                    let stagingResourceDirectory = isPrimary
                        ? primaryStagingDirectory
                        : ancillaryStagingDirectory
                    if !FileManager.default.fileExists(atPath: stagingResourceDirectory.path) {
                        try FileManager.default.createDirectory(
                            at: stagingResourceDirectory,
                            withIntermediateDirectories: false
                        )
                    }
                    let destination = stagingResourceDirectory.appendingPathComponent(filename)
                    try await write(
                        resource: resource,
                        to: destination,
                        allowNetworkAccess: allowNetworkAccess
                    )
                    let values = try destination.resourceValues(forKeys: [.fileSizeKey])
                    let byteSize = Int64(values.fileSize ?? 0)
                    let relativePath = isPrimary
                        ? "assets/\(assetDirectoryName)/\(filename)"
                        : ".photos-exit-resources/\(assetDirectoryName)/\(filename)"
                    records.append(
                        ResourceRecord(
                            index: resourceIndex,
                            type: resourceTypeName(resource.type),
                            uniformTypeIdentifier: resource.uniformTypeIdentifier,
                            originalFilename: sanitizedFilename(resource.originalFilename),
                            relativePath: relativePath,
                            byteSize: byteSize,
                            sha256: try fileSHA256(destination),
                            status: "complete"
                        )
                    )
                }
                if status == "complete" {
                    if FileManager.default.fileExists(atPath: ancillaryStagingDirectory.path) {
                        try FileManager.default.moveItem(
                            at: ancillaryStagingDirectory,
                            to: ancillaryDirectory
                        )
                    }
                    guard FileManager.default.fileExists(atPath: primaryStagingDirectory.path)
                    else {
                        throw ExporterError.resourceWriteFailed
                    }
                    try FileManager.default.moveItem(
                        at: primaryStagingDirectory,
                        to: assetDirectory
                    )
                    try FileManager.default.removeItem(at: stagingDirectory)
                }
            } catch {
                status = "incomplete"
            }
            try writer.append(
                assetRecord(
                    asset: asset,
                    primaryResourceIndex: primary,
                    resources: records,
                    status: status
                )
            )
            if status == "complete" {
                completed += 1
            } else {
                incomplete += 1
            }
            let processed = index + 1
            if processed.isMultiple(of: 100) || processed == assets.count {
                emitProgress(
                    "export_progress=\(processed) assets_total=\(assets.count) "
                        + "complete=\(completed) incomplete=\(incomplete)"
                )
            }
        }
        if incomplete == 0,
           (try? FileManager.default.contentsOfDirectory(atPath: stagingRoot.path).isEmpty) == true
        {
            try? FileManager.default.removeItem(at: stagingRoot)
        }
        print(
            "assets=\(assets.count) complete=\(completed) incomplete=\(incomplete) "
                + "network_access=\(allowNetworkAccess ? 1 : 0)"
        )
    }

    private static func readResumeState(
        manifestURL: URL,
        allowNetworkAccess: Bool
    ) throws -> ResumeState {
        guard let text = try? String(contentsOf: manifestURL, encoding: .utf8) else {
            throw ExporterError.invalidResume
        }
        var sawHeader = false
        var statusByIdentifier: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let recordType = object["record_type"] as? String
            else {
                throw ExporterError.invalidResume
            }
            if recordType == "header" {
                guard !sawHeader, statusByIdentifier.isEmpty,
                      object["schema_version"] as? Int == manifestSchemaVersion,
                      object["mode"] as? String == "export",
                      object["network_access_allowed"] as? Bool == allowNetworkAccess
                else {
                    throw ExporterError.invalidResume
                }
                sawHeader = true
            } else if recordType == "asset" {
                guard sawHeader,
                      let identifier = object["local_identifier"] as? String,
                      let status = object["status"] as? String,
                      statusByIdentifier[identifier] != "complete"
                else {
                    throw ExporterError.invalidResume
                }
                statusByIdentifier[identifier] = status
            } else {
                throw ExporterError.invalidResume
            }
        }
        guard sawHeader else { throw ExporterError.invalidResume }
        return ResumeState(
            completedIdentifiers: Set(
                statusByIdentifier.compactMap { key, value in
                    value == "complete" ? key : nil
                }
            )
        )
    }

    private static func fetchAssets() -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.sortDescriptors = [
            NSSortDescriptor(key: "creationDate", ascending: true),
        ]
        return PHAsset.fetchAssets(with: options)
    }

    private static func emitProgress(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    private static func authorizationStatusName(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "not_determined"
        case .restricted: "restricted"
        case .denied: "denied"
        case .authorized: "authorized"
        case .limited: "limited"
        @unknown default: "unknown"
        }
    }

    private static func assetRecord(
        asset: PHAsset,
        primaryResourceIndex: Int?,
        resources: [ResourceRecord],
        status: String
    ) -> AssetRecord {
        AssetRecord(
            localIdentifier: asset.localIdentifier,
            mediaType: mediaTypeName(asset.mediaType),
            mediaSubtypes: UInt64(asset.mediaSubtypes.rawValue),
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            durationMs: asset.mediaType == .video ? Int64(asset.duration * 1_000) : nil,
            creationDateMs: dateMs(asset.creationDate),
            modificationDateMs: dateMs(asset.modificationDate),
            isFavorite: asset.isFavorite,
            isHidden: asset.isHidden,
            primaryResourceIndex: primaryResourceIndex,
            resources: resources,
            status: status
        )
    }

    private static func primaryResourceIndex(
        mediaType: PHAssetMediaType,
        resources: [PHAssetResource]
    ) -> Int? {
        let preferences: [PHAssetResourceType]
        switch mediaType {
        case .image:
            preferences = [.fullSizePhoto, .photo, .alternatePhoto]
        case .video:
            preferences = [.fullSizeVideo, .video]
        default:
            return nil
        }
        for preference in preferences {
            if let index = resources.firstIndex(where: { $0.type == preference }) {
                return index
            }
        }
        return nil
    }

    private static func write(
        resource: PHAssetResource,
        to destination: URL,
        allowNetworkAccess: Bool
    ) async throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ExporterError.outputExists
        }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = allowNetworkAccess
        try await withCheckedThrowingContinuation { continuation in
            PHAssetResourceManager.default().writeData(
                for: resource,
                toFile: destination,
                options: options
            ) { error in
                if error == nil {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: ExporterError.resourceWriteFailed)
                }
            }
        }
    }

    private static func fileSHA256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func identifierDigest(_ identifier: String) -> String {
        SHA256.hash(data: Data(identifier.utf8))
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func sanitizedFilename(_ filename: String) -> String {
        let basename = URL(fileURLWithPath: filename).lastPathComponent
        let scalars = basename.unicodeScalars.prefix(160).map { scalar -> Character in
            if scalar.value < 0x20 || scalar.value == 0x7F || scalar == "/" || scalar == ":" {
                return "_"
            }
            return Character(String(scalar))
        }
        let result = String(scalars)
        return result.isEmpty || result == "." || result == ".." ? "resource" : result
    }

    private static func mediaTypeName(_ type: PHAssetMediaType) -> String {
        switch type {
        case .image: "image"
        case .video: "video"
        case .audio: "audio"
        case .unknown: "unknown"
        @unknown default: "unknown"
        }
    }

    private static func resourceTypeName(_ type: PHAssetResourceType) -> String {
        switch type {
        case .photo: "photo"
        case .video: "video"
        case .audio: "audio"
        case .alternatePhoto: "alternatePhoto"
        case .fullSizePhoto: "fullSizePhoto"
        case .fullSizeVideo: "fullSizeVideo"
        case .adjustmentData: "adjustmentData"
        case .adjustmentBasePhoto: "adjustmentBasePhoto"
        case .pairedVideo: "pairedVideo"
        case .fullSizePairedVideo: "fullSizePairedVideo"
        case .adjustmentBasePairedVideo: "adjustmentBasePairedVideo"
        case .adjustmentBaseVideo: "adjustmentBaseVideo"
        case .photoProxy: "photoProxy"
        @unknown default: "unknown-\(type.rawValue)"
        }
    }

    private static func dateMs(_ date: Date?) -> Int64? {
        date.map { Int64($0.timeIntervalSince1970 * 1_000) }
    }

    private static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }

    private static func errorCode(_ error: ExporterError) -> String {
        switch error {
        case .usage: "invalid_usage"
        case .authorizationDenied: "photos_authorization_denied"
        case .libraryUnavailable: "photos_library_unavailable"
        case .unsafeOutput: "unsafe_output"
        case .outputExists: "output_exists"
        case .outputNotEmpty: "output_not_empty"
        case .manifestWriteFailed: "manifest_write_failed"
        case .resourceWriteFailed: "resource_write_failed"
        case .invalidResume: "invalid_resume"
        }
    }
}

private final class DeferredError: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?

    func store(_ newError: Error) {
        lock.lock()
        if error == nil { error = newError }
        lock.unlock()
    }

    func take() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        let result = error
        error = nil
        return result
    }
}
