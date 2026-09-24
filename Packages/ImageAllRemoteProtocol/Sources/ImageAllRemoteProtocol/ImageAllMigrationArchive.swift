import CryptoKit
import Foundation

/// Portable domain manifest for a selected iPhone source scope. Media bytes live
/// beside this JSONL file; neither a PhotoKit locator nor a Mac bookmark is a
/// substitute for an independently readable resource.
public struct ImageAllMigrationHeader: Codable, Sendable, Equatable {
    public let recordType: String
    public let formatVersion: Int
    public let migrationID: UUID
    public let sourceDeviceID: UUID
    public let sourceEpoch: UUID
    public let scopeRevision: Int64
    public let inventoryWatermark: Int64
    public let declaredItemCount: Int

    public init(
        migrationID: UUID, sourceDeviceID: UUID, sourceEpoch: UUID,
        scopeRevision: Int64, inventoryWatermark: Int64, declaredItemCount: Int
    ) {
        recordType = "header"
        formatVersion = 1
        self.migrationID = migrationID
        self.sourceDeviceID = sourceDeviceID
        self.sourceEpoch = sourceEpoch
        self.scopeRevision = scopeRevision
        self.inventoryWatermark = inventoryWatermark
        self.declaredItemCount = declaredItemCount
    }
}

public enum ImageAllMigrationResourceStatus: String, Codable, Sendable {
    case present
    case notLocal
    case permissionDenied
    case unsupported
}

public struct ImageAllMigrationResource: Codable, Sendable, Equatable {
    public let id: UUID
    public let role: String
    public let version: Int64
    public let uniformTypeIdentifier: String
    public let required: Bool
    public let status: ImageAllMigrationResourceStatus
    public let relativePath: String?
    public let byteCount: Int64?
    public let sha256: String?

    public init(
        id: UUID, role: String, version: Int64,
        uniformTypeIdentifier: String,
        required: Bool, status: ImageAllMigrationResourceStatus,
        relativePath: String?, byteCount: Int64?, sha256: String?
    ) {
        self.id = id
        self.role = role
        self.version = version
        self.uniformTypeIdentifier = uniformTypeIdentifier
        self.required = required
        self.status = status
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public struct ImageAllMigrationTagDecision: Codable, Sendable, Equatable {
    public let tagID: UUID
    public let tagName: String
    public let decision: RemoteLocalLibraryDecision

    public init(tagID: UUID, tagName: String, decision: RemoteLocalLibraryDecision) {
        self.tagID = tagID
        self.tagName = tagName
        self.decision = decision
    }
}

public struct ImageAllMigrationCollectionMembership: Codable, Sendable, Equatable {
    public let collectionID: UUID
    public let collectionName: String
    public let included: Bool

    public init(collectionID: UUID, collectionName: String, included: Bool) {
        self.collectionID = collectionID
        self.collectionName = collectionName
        self.included = included
    }
}

public struct ImageAllMigrationItem: Codable, Sendable, Equatable {
    public let recordType: String
    public let mediaID: UUID
    public let sourceLocalIdentifier: String
    public let mediaKind: RemoteAssetMediaKind
    public let createdAtMs: Int64?
    public let favoriteTarget: Bool?
    public let observedFavorite: Bool
    public let factRevision: Int64
    public let tagDecisions: [ImageAllMigrationTagDecision]
    public let collections: [ImageAllMigrationCollectionMembership]
    public let resources: [ImageAllMigrationResource]

    public init(
        mediaID: UUID, sourceLocalIdentifier: String,
        mediaKind: RemoteAssetMediaKind, createdAtMs: Int64?,
        favoriteTarget: Bool?, observedFavorite: Bool, factRevision: Int64,
        tagDecisions: [ImageAllMigrationTagDecision],
        collections: [ImageAllMigrationCollectionMembership],
        resources: [ImageAllMigrationResource]
    ) {
        recordType = "item"
        self.mediaID = mediaID
        self.sourceLocalIdentifier = sourceLocalIdentifier
        self.mediaKind = mediaKind
        self.createdAtMs = createdAtMs
        self.favoriteTarget = favoriteTarget
        self.observedFavorite = observedFavorite
        self.factRevision = factRevision
        self.tagDecisions = tagDecisions
        self.collections = collections
        self.resources = resources
    }
}

public enum ImageAllMigrationArchiveError: Error, Equatable, Sendable {
    case invalidManifest
    case unsupportedVersion
    case duplicateIdentity
    case unsafeResourcePath
    case resourceMissing
    case resourceChanged
    case destinationOverlap
    case destinationCollision
    case publicationFailed
}

public struct ImageAllMigrationVerification: Sendable, Equatable {
    public let migrationID: UUID
    public let manifestSHA256: String
    public let itemCount: Int
    public let resourceCount: Int
    public let verifiedBytes: Int64
    public let incompleteMediaIDs: [UUID]

    public var isComplete: Bool { incompleteMediaIDs.isEmpty }
}

public enum ImageAllMigrationArchive {
    public static let manifestFilename = "manifest.jsonl"
    private static let maximumLineBytes = 1_048_576
    private static let readBlockBytes = 1_048_576

    /// The caller can append one item at a time without loading the whole
    /// gallery into memory. A partially written manifest always fails verify.
    public static func write(
        header: ImageAllMigrationHeader,
        items: any Sequence<ImageAllMigrationItem>,
        to archiveRoot: URL
    ) throws {
        let url = archiveRoot.appendingPathComponent(manifestFilename)
        guard !FileManager.default.fileExists(atPath: url.path),
              FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw ImageAllMigrationArchiveError.invalidManifest
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        func append<T: Encodable>(_ value: T) throws {
            var line = try encoder.encode(value)
            guard line.count < maximumLineBytes else {
                throw ImageAllMigrationArchiveError.invalidManifest
            }
            line.append(0x0A)
            try handle.write(contentsOf: line)
        }
        try append(header)
        for item in items { try append(item) }
        try handle.synchronize()
    }

    public static func verify(at archiveRoot: URL) throws -> ImageAllMigrationVerification {
        let manager = FileManager.default
        let root = archiveRoot.standardizedFileURL
        guard try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true,
              try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw ImageAllMigrationArchiveError.unsafeResourcePath
        }
        let manifestURL = root.appendingPathComponent(manifestFilename)
        guard try manifestURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile == true,
              try manifestURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw ImageAllMigrationArchiveError.invalidManifest
        }
        let handle = try FileHandle(forReadingFrom: manifestURL)
        defer { try? handle.close() }
        var buffer = Data()
        var manifestHash = SHA256()
        var header: ImageAllMigrationHeader?
        var itemCount = 0
        var resourceCount = 0
        var verifiedBytes: Int64 = 0
        var incomplete: [UUID] = []
        var mediaIDs: Set<UUID> = []
        var sourceLocators: Set<String> = []
        var resourceIDs: Set<UUID> = []
        var paths: Set<String> = []
        let decoder = JSONDecoder()
        while let block = try handle.read(upToCount: readBlockBytes), !block.isEmpty {
            manifestHash.update(data: block)
            buffer.append(block)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                guard !line.isEmpty, line.count < maximumLineBytes else {
                    throw ImageAllMigrationArchiveError.invalidManifest
                }
                if header == nil {
                    let decoded = try decoder.decode(ImageAllMigrationHeader.self, from: line)
                    guard decoded.recordType == "header", decoded.formatVersion == 1,
                          decoded.scopeRevision >= 0, decoded.inventoryWatermark >= 0,
                          decoded.declaredItemCount >= 0 else {
                        throw ImageAllMigrationArchiveError.unsupportedVersion
                    }
                    header = decoded
                    continue
                }
                let item = try decoder.decode(ImageAllMigrationItem.self, from: line)
                guard item.recordType == "item", !item.sourceLocalIdentifier.isEmpty,
                      item.factRevision >= 0, !item.resources.isEmpty,
                      item.resources.contains(where: {
                          $0.role == "original" && $0.required
                      }),
                      item.tagDecisions.allSatisfy({ !$0.tagName.isEmpty }),
                      item.collections.allSatisfy({ !$0.collectionName.isEmpty }),
                      Set(item.tagDecisions.map(\.tagID)).count == item.tagDecisions.count,
                      Set(item.collections.map(\.collectionID)).count == item.collections.count else {
                    throw ImageAllMigrationArchiveError.invalidManifest
                }
                guard mediaIDs.insert(item.mediaID).inserted,
                      sourceLocators.insert(item.sourceLocalIdentifier).inserted else {
                    throw ImageAllMigrationArchiveError.duplicateIdentity
                }
                var itemComplete = true
                for resource in item.resources {
                    guard resourceIDs.insert(resource.id).inserted else {
                        throw ImageAllMigrationArchiveError.duplicateIdentity
                    }
                    guard !resource.role.isEmpty, resource.version > 0,
                          !resource.uniformTypeIdentifier.isEmpty else {
                        throw ImageAllMigrationArchiveError.invalidManifest
                    }
                    if resource.status == .present {
                        guard let path = resource.relativePath,
                              let count = resource.byteCount, count >= 0,
                              let hash = resource.sha256,
                              hash.count == 64, hash.allSatisfy({ $0.isHexDigit }),
                              paths.insert(path.lowercased()).inserted else {
                            throw ImageAllMigrationArchiveError.invalidManifest
                        }
                        let url = try safeResourceURL(
                            root: root, path: path, resourceID: resource.id,
                            manager: manager
                        )
                        let actual = try hashFile(at: url)
                        guard actual.bytes == count,
                              actual.sha256 == hash.lowercased(),
                              verifiedBytes <= Int64.max - count else {
                            throw ImageAllMigrationArchiveError.resourceChanged
                        }
                        verifiedBytes += count
                        resourceCount += 1
                    } else {
                        guard resource.relativePath == nil,
                              resource.byteCount == nil,
                              resource.sha256 == nil else {
                            throw ImageAllMigrationArchiveError.invalidManifest
                        }
                        if resource.required { itemComplete = false }
                    }
                }
                if !itemComplete { incomplete.append(item.mediaID) }
                itemCount += 1
                if buffer.count > maximumLineBytes {
                    throw ImageAllMigrationArchiveError.invalidManifest
                }
            }
            guard buffer.count <= maximumLineBytes else {
                throw ImageAllMigrationArchiveError.invalidManifest
            }
        }
        guard buffer.isEmpty, let header,
              header.declaredItemCount == itemCount else {
            throw ImageAllMigrationArchiveError.invalidManifest
        }
        let rootEntries = Set(try manager.contentsOfDirectory(atPath: root.path))
        let expectedRootEntries: Set<String> = paths.isEmpty
            ? [manifestFilename] : [manifestFilename, "resources"]
        guard rootEntries == expectedRootEntries else {
            throw ImageAllMigrationArchiveError.invalidManifest
        }
        if !paths.isEmpty {
            let resourceNames = Set(try manager.contentsOfDirectory(
                atPath: root.appendingPathComponent("resources").path
            ).map { "resources/\($0)".lowercased() })
            guard resourceNames == paths else {
                throw ImageAllMigrationArchiveError.invalidManifest
            }
        }
        return ImageAllMigrationVerification(
            migrationID: header.migrationID,
            manifestSHA256: hex(Data(manifestHash.finalize())),
            itemCount: itemCount, resourceCount: resourceCount,
            verifiedBytes: verifiedBytes, incompleteMediaIDs: incomplete
        )
    }

    /// Publishes only a byte-verified independent copy. Catalog identity and
    /// human facts must be committed separately before archive completion.
    public static func publishVerifiedCopy(
        from archiveRoot: URL, to targetParent: URL
    ) throws -> URL {
        let source = archiveRoot.standardizedFileURL.resolvingSymlinksInPath()
        let target = targetParent.standardizedFileURL.resolvingSymlinksInPath()
        guard source.path != target.path,
              !source.path.hasPrefix(target.path + "/"),
              !target.path.hasPrefix(source.path + "/") else {
            throw ImageAllMigrationArchiveError.destinationOverlap
        }
        let targetValues = try targetParent.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard targetValues.isDirectory == true,
              targetValues.isSymbolicLink != true else {
            throw ImageAllMigrationArchiveError.unsafeResourcePath
        }
        let first = try verify(at: archiveRoot)
        guard first.isComplete else {
            throw ImageAllMigrationArchiveError.invalidManifest
        }
        let manager = FileManager.default
        let final = targetParent.appendingPathComponent(
            "ImageAll-Archive-\(first.migrationID.uuidString.lowercased())",
            isDirectory: true
        )
        let staging = targetParent.appendingPathComponent(
            ".imageall-archive-staging-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        guard !manager.fileExists(atPath: final.path),
              !manager.fileExists(atPath: staging.path) else {
            throw ImageAllMigrationArchiveError.destinationCollision
        }
        do {
            try manager.copyItem(at: archiveRoot, to: staging)
            let copied = try verify(at: staging)
            guard copied == first else {
                throw ImageAllMigrationArchiveError.resourceChanged
            }
            try manager.moveItem(at: staging, to: final)
            return final
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }

    private static func safeResourceURL(
        root: URL, path: String, resourceID: UUID, manager: FileManager
    ) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        let filename = parts.last.map(String.init) ?? ""
        let expectedPrefix = resourceID.uuidString.lowercased() + "."
        let fileExtension = String(filename.dropFirst(expectedPrefix.count))
        guard parts.count == 2, parts[0] == "resources",
              filename.hasPrefix(expectedPrefix),
              !fileExtension.isEmpty, fileExtension.count <= 12,
              fileExtension.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw ImageAllMigrationArchiveError.unsafeResourcePath
        }
        let directory = root.appendingPathComponent("resources", isDirectory: true)
        let directoryValues = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard directoryValues.isDirectory == true,
              directoryValues.isSymbolicLink != true else {
            throw ImageAllMigrationArchiveError.unsafeResourcePath
        }
        let url = directory.appendingPathComponent(String(parts[1]))
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              manager.fileExists(atPath: url.path) else {
            throw ImageAllMigrationArchiveError.resourceMissing
        }
        return url
    }

    private static func hashFile(at url: URL) throws -> (bytes: Int64, sha256: String) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var count: Int64 = 0
        while let block = try handle.read(upToCount: readBlockBytes), !block.isEmpty {
            guard Int64(block.count) <= Int64.max - count else {
                throw ImageAllMigrationArchiveError.resourceChanged
            }
            count += Int64(block.count)
            hasher.update(data: block)
        }
        return (count, hex(Data(hasher.finalize())))
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
