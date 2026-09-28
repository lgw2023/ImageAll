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
    /// Nil on archives created before Photos album capture existed.
    public let appleAlbumCoverage: ImageAllMigrationAppleAlbumCoverage?

    public init(
        migrationID: UUID, sourceDeviceID: UUID, sourceEpoch: UUID,
        scopeRevision: Int64, inventoryWatermark: Int64, declaredItemCount: Int,
        appleAlbumCoverage: ImageAllMigrationAppleAlbumCoverage? = nil
    ) {
        recordType = "header"
        formatVersion = 1
        self.migrationID = migrationID
        self.sourceDeviceID = sourceDeviceID
        self.sourceEpoch = sourceEpoch
        self.scopeRevision = scopeRevision
        self.inventoryWatermark = inventoryWatermark
        self.declaredItemCount = declaredItemCount
        self.appleAlbumCoverage = appleAlbumCoverage
    }
}

public enum ImageAllMigrationAppleAlbumCoverage: String, Codable, Sendable {
    /// User-created albums/folders observed by PhotoKit, retaining only
    /// members in the explicit migration scope.
    case selectedAssetsOnly
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

/// A user-created Photos album as observed within the explicitly selected
/// migration scope. The ordinal is its position in PhotoKit's album result,
/// including assets outside that scope; gaps are therefore expected.
public struct ImageAllMigrationAppleAlbumMembership: Codable, Sendable, Equatable {
    public struct Folder: Codable, Sendable, Equatable {
        public let localIdentifier: String
        public let title: String?

        public init(localIdentifier: String, title: String?) {
            self.localIdentifier = localIdentifier
            self.title = title
        }
    }

    public let albumLocalIdentifier: String
    public let albumTitle: String?
    public let folderPath: [Folder]
    public let sourceOrdinal: Int64

    public init(
        albumLocalIdentifier: String, albumTitle: String?,
        folderPath: [Folder], sourceOrdinal: Int64
    ) {
        self.albumLocalIdentifier = albumLocalIdentifier
        self.albumTitle = albumTitle
        self.folderPath = folderPath
        self.sourceOrdinal = sourceOrdinal
    }
}

/// Public source observations, distinct from filesystem timestamps or inferred EXIF.
/// Nil on older archives means not declared; absent location means not provided.
public struct ImageAllMigrationSourceMetadata: Codable, Sendable, Equatable {
    public struct Location: Codable, Sendable, Equatable {
        public let latitude: Double
        public let longitude: Double
        public let horizontalAccuracyMeters: Double
        public let altitudeMeters: Double?
        public let verticalAccuracyMeters: Double?
        public let observedAtMs: Int64?

        public init(latitude: Double, longitude: Double, horizontalAccuracyMeters: Double,
                    altitudeMeters: Double? = nil, verticalAccuracyMeters: Double? = nil,
                    observedAtMs: Int64? = nil) {
            self.latitude = latitude; self.longitude = longitude
            self.horizontalAccuracyMeters = horizontalAccuracyMeters
            self.altitudeMeters = altitudeMeters; self.verticalAccuracyMeters = verticalAccuracyMeters
            self.observedAtMs = observedAtMs
        }
    }
    public let pixelWidth: Int?
    public let pixelHeight: Int?
    public let durationSeconds: Double?
    public let modifiedAtMs: Int64?
    public let location: Location?

    public init(pixelWidth: Int? = nil, pixelHeight: Int? = nil, durationSeconds: Double? = nil,
                modifiedAtMs: Int64? = nil, location: Location? = nil) {
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        self.durationSeconds = durationSeconds; self.modifiedAtMs = modifiedAtMs; self.location = location
    }

    public func validate() throws {
        guard pixelWidth.map({ $0 > 0 }) ?? true, pixelHeight.map({ $0 > 0 }) ?? true,
              durationSeconds.map({ $0.isFinite && $0 >= 0 }) ?? true else {
            throw ImageAllMigrationArchiveError.invalidManifest
        }
        if let location {
            guard location.latitude.isFinite, (-90...90).contains(location.latitude),
                  location.longitude.isFinite, (-180...180).contains(location.longitude),
                  location.horizontalAccuracyMeters.isFinite, location.horizontalAccuracyMeters >= 0,
                  location.altitudeMeters.map(\.isFinite) ?? true,
                  location.verticalAccuracyMeters.map({ $0.isFinite && $0 >= 0 }) ?? true,
                  (location.altitudeMeters == nil) == (location.verticalAccuracyMeters == nil) else {
                throw ImageAllMigrationArchiveError.invalidManifest
            }
        }
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
    /// Nil on older archives. Only memberships of selected assets are recorded.
    public let appleAlbums: [ImageAllMigrationAppleAlbumMembership]?
    public let resources: [ImageAllMigrationResource]
    public let sourceMetadata: ImageAllMigrationSourceMetadata?

    public init(
        mediaID: UUID, sourceLocalIdentifier: String,
        mediaKind: RemoteAssetMediaKind, createdAtMs: Int64?,
        favoriteTarget: Bool?, observedFavorite: Bool, factRevision: Int64,
        tagDecisions: [ImageAllMigrationTagDecision],
        collections: [ImageAllMigrationCollectionMembership],
        resources: [ImageAllMigrationResource],
        appleAlbums: [ImageAllMigrationAppleAlbumMembership] = [],
        sourceMetadata: ImageAllMigrationSourceMetadata? = nil
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
        self.appleAlbums = appleAlbums.isEmpty ? nil : appleAlbums
        self.resources = resources
        self.sourceMetadata = sourceMetadata
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
    /// All declared resources that could not be copied. The media list above
    /// includes only assets with a missing required resource.
    public let unavailableResources: [ImageAllMigrationUnavailableResource]
    public let factsSHA256: String?

    /// Current Mac import persists every declared resource. Until partial
    /// resource imports have an explicit catalog contract, any unavailable
    /// resource keeps the package out of the migration path.
    public var isComplete: Bool { unavailableResources.isEmpty }

    public func hasSameMedia(as other: Self) -> Bool {
        migrationID == other.migrationID && manifestSHA256 == other.manifestSHA256
            && itemCount == other.itemCount && resourceCount == other.resourceCount
            && verifiedBytes == other.verifiedBytes && incompleteMediaIDs == other.incompleteMediaIDs
            && unavailableResources == other.unavailableResources
    }
}

public struct ImageAllMigrationUnavailableResource: Sendable, Equatable {
    public let mediaID: UUID
    public let resourceID: UUID
    public let role: String
    public let status: ImageAllMigrationResourceStatus
    public let required: Bool
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
        var highestFactRevision: Int64 = 0
        var incomplete: [UUID] = []
        var unavailableResources: [ImageAllMigrationUnavailableResource] = []
        var mediaIDs: Set<UUID> = []
        var sourceLocators: Set<String> = []
        var resourceIDs: Set<UUID> = []
        var paths: Set<String> = []
        var albumMetadata: [String: (String?, [ImageAllMigrationAppleAlbumMembership.Folder])] = [:]
        var albumOrdinals: [String: Set<Int64>] = [:]
        var folderMetadata: [String: (String?, String?)] = [:]
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
                try item.sourceMetadata?.validate()
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
                let albums = item.appleAlbums ?? []
                guard albums.isEmpty || header?.appleAlbumCoverage == .selectedAssetsOnly else {
                    throw ImageAllMigrationArchiveError.invalidManifest
                }
                guard Set(albums.map(\.albumLocalIdentifier)).count == albums.count else {
                    throw ImageAllMigrationArchiveError.duplicateIdentity
                }
                for album in albums {
                    guard !album.albumLocalIdentifier.isEmpty, album.sourceOrdinal >= 0,
                          album.folderPath.allSatisfy({ !$0.localIdentifier.isEmpty }),
                          Set(album.folderPath.map(\.localIdentifier)).count == album.folderPath.count,
                          !album.folderPath.contains(where: {
                              $0.localIdentifier == album.albumLocalIdentifier
                          }) else {
                        throw ImageAllMigrationArchiveError.invalidManifest
                    }
                    if let previous = albumMetadata[album.albumLocalIdentifier] {
                        guard previous.0 == album.albumTitle,
                              previous.1 == album.folderPath else {
                            throw ImageAllMigrationArchiveError.invalidManifest
                        }
                    } else {
                        albumMetadata[album.albumLocalIdentifier] =
                            (album.albumTitle, album.folderPath)
                    }
                    for (index, folder) in album.folderPath.enumerated() {
                        let parentID = index == 0
                            ? nil : album.folderPath[index - 1].localIdentifier
                        if let previous = folderMetadata[folder.localIdentifier] {
                            guard previous.0 == folder.title, previous.1 == parentID else {
                                throw ImageAllMigrationArchiveError.invalidManifest
                            }
                        } else {
                            folderMetadata[folder.localIdentifier] = (folder.title, parentID)
                        }
                    }
                    guard albumOrdinals[album.albumLocalIdentifier, default: []]
                        .insert(album.sourceOrdinal).inserted else {
                        throw ImageAllMigrationArchiveError.duplicateIdentity
                    }
                }
                highestFactRevision = max(highestFactRevision, item.factRevision)
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
                        unavailableResources.append(ImageAllMigrationUnavailableResource(
                            mediaID: item.mediaID, resourceID: resource.id,
                            role: resource.role, status: resource.status,
                            required: resource.required
                        ))
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
        var expectedRootEntries: Set<String> = paths.isEmpty
            ? [manifestFilename] : [manifestFilename, "resources"]
        if rootEntries.contains(ImageAllMigrationFacts.sidecarDirectoryName) {
            expectedRootEntries.insert(ImageAllMigrationFacts.sidecarDirectoryName)
        }
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
        let publishedFacts = try ImageAllMigrationFacts.inspectPublished(
            at: root, sourceDeviceID: header.sourceDeviceID,
            sourceEpoch: header.sourceEpoch, scopeRevision: header.scopeRevision,
            inventoryWatermark: header.inventoryWatermark,
            minimumFactWatermark: highestFactRevision, mediaIDs: mediaIDs
        )
        return ImageAllMigrationVerification(
            migrationID: header.migrationID,
            manifestSHA256: hex(Data(manifestHash.finalize())),
            itemCount: itemCount, resourceCount: resourceCount,
            verifiedBytes: verifiedBytes, incompleteMediaIDs: incomplete,
            unavailableResources: unavailableResources,
            factsSHA256: publishedFacts.sha256
        )
    }

    /// Streams a verified package into a caller-owned transaction. The second
    /// verification must succeed before that transaction is committed; it
    /// catches a package changing while records are being consumed.
    public static func visitVerifiedRecords(
        at archiveRoot: URL,
        onHeader: (ImageAllMigrationHeader) throws -> Void,
        onItem: (ImageAllMigrationItem) throws -> Void
    ) throws -> ImageAllMigrationVerification {
        let before = try verify(at: archiveRoot)
        let handle = try FileHandle(forReadingFrom: archiveRoot.appendingPathComponent(manifestFilename))
        defer { try? handle.close() }
        let decoder = JSONDecoder()
        var buffer = Data()
        var sawHeader = false
        var itemCount = 0
        while let block = try handle.read(upToCount: readBlockBytes), !block.isEmpty {
            buffer.append(block)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                guard !line.isEmpty, line.count < maximumLineBytes else {
                    throw ImageAllMigrationArchiveError.invalidManifest
                }
                if !sawHeader {
                    let header = try decoder.decode(ImageAllMigrationHeader.self, from: line)
                    guard header.recordType == "header", header.migrationID == before.migrationID else {
                        throw ImageAllMigrationArchiveError.invalidManifest
                    }
                    try onHeader(header)
                    sawHeader = true
                } else {
                    let item = try decoder.decode(ImageAllMigrationItem.self, from: line)
                    guard item.recordType == "item" else {
                        throw ImageAllMigrationArchiveError.invalidManifest
                    }
                    try onItem(item)
                    itemCount += 1
                }
            }
            guard buffer.count <= maximumLineBytes else {
                throw ImageAllMigrationArchiveError.invalidManifest
            }
        }
        guard sawHeader, buffer.isEmpty, itemCount == before.itemCount,
              try verify(at: archiveRoot) == before else {
            throw ImageAllMigrationArchiveError.resourceChanged
        }
        return before
    }

    public static func readVerifiedHeader(
        at archiveRoot: URL
    ) throws -> (ImageAllMigrationHeader, ImageAllMigrationVerification) {
        let verification = try verify(at: archiveRoot)
        let handle = try FileHandle(forReadingFrom: archiveRoot.appendingPathComponent(manifestFilename))
        defer { try? handle.close() }
        var line = Data()
        while let byte = try handle.read(upToCount: 1), !byte.isEmpty {
            if byte[0] == 0x0A { break }
            line.append(byte)
            guard line.count < maximumLineBytes else {
                throw ImageAllMigrationArchiveError.invalidManifest
            }
        }
        let header = try JSONDecoder().decode(ImageAllMigrationHeader.self, from: line)
        guard header.recordType == "header", header.migrationID == verification.migrationID else {
            throw ImageAllMigrationArchiveError.invalidManifest
        }
        return (header, verification)
    }

    /// Publishes only a byte-verified independent copy. Catalog identity and
    /// human facts must be committed separately before archive completion.
    public static func publishVerifiedCopy(
        from archiveRoot: URL, to targetParent: URL
    ) throws -> URL {
        let source = archiveRoot.standardizedFileURL.resolvingSymlinksInPath()
        let target = targetParent.standardizedFileURL.resolvingSymlinksInPath()
        let first = try verify(at: archiveRoot)
        let receiverOwnedStage = source.lastPathComponent == "package"
            && source.deletingLastPathComponent().lastPathComponent
                == ".imageall-transfer-\(first.migrationID.uuidString.lowercased())"
            && source.deletingLastPathComponent().deletingLastPathComponent() == target
        guard source.path != target.path,
              (!source.path.hasPrefix(target.path + "/") || receiverOwnedStage),
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
