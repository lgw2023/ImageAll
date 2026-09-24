import CryptoKit
import Foundation

/// A user-exported, fact-only checkpoint for the exact media IDs in one archive.
/// It carries no source locator, media bytes, bookmark, or Photos credential.
public struct ImageAllMigrationFactSnapshot: Codable, Sendable, Equatable {
    public let formatVersion: Int
    public let sourceDeviceID: UUID
    public let sourceEpoch: UUID
    public let scopeRevision: Int64
    public let snapshotSequence: Int64
    public let factWatermark: Int64
    public let items: [ImageAllMigrationFactItem]
    /// Phone-local delivery checkpoint. Mac must compare these cursors with
    /// its change-log heads before any completion decision.
    public let syncCheckpoint: ImageAllMigrationSyncCheckpoint?

    public init(
        sourceDeviceID: UUID, sourceEpoch: UUID, scopeRevision: Int64,
        snapshotSequence: Int64, factWatermark: Int64,
        items: [ImageAllMigrationFactItem],
        syncCheckpoint: ImageAllMigrationSyncCheckpoint? = nil
    ) {
        formatVersion = 1
        self.sourceDeviceID = sourceDeviceID
        self.sourceEpoch = sourceEpoch
        self.scopeRevision = scopeRevision
        self.snapshotSequence = snapshotSequence
        self.factWatermark = factWatermark
        self.items = items
        self.syncCheckpoint = syncCheckpoint
    }
}

public struct ImageAllMigrationSyncCheckpoint: Codable, Sendable, Equatable {
    public let hostID: UUID
    public let deviceID: UUID
    public let acknowledgedScopeRevision: Int64
    public let acknowledgedSnapshotSequence: Int64
    public let tagChangeCursor: Int64
    public let collectionChangeCursor: Int64
    public let favoriteChangeCursor: Int64
    /// Present in new checkpoints. Missing in older files means no aliases.
    public let tagAliases: [ImageAllMigrationTagAlias]?
    /// Present in new checkpoints. Missing in older files means no aliases.
    public let collectionAliases: [ImageAllMigrationCollectionAlias]?
    /// Digest of the immutable media manifest whose source resources were
    /// reread locally before this checkpoint was exported. Older candidates
    /// without this proof remain readable but cannot pass completion checks.
    public let archiveManifestSHA256: String?
    public let sourceVerifiedAtMs: Int64?

    public init(
        hostID: UUID, deviceID: UUID,
        acknowledgedScopeRevision: Int64,
        acknowledgedSnapshotSequence: Int64,
        tagChangeCursor: Int64,
        collectionChangeCursor: Int64,
        favoriteChangeCursor: Int64,
        tagAliases: [ImageAllMigrationTagAlias]? = nil,
        collectionAliases: [ImageAllMigrationCollectionAlias]? = nil,
        archiveManifestSHA256: String? = nil,
        sourceVerifiedAtMs: Int64? = nil
    ) {
        self.hostID = hostID
        self.deviceID = deviceID
        self.acknowledgedScopeRevision = acknowledgedScopeRevision
        self.acknowledgedSnapshotSequence = acknowledgedSnapshotSequence
        self.tagChangeCursor = tagChangeCursor
        self.collectionChangeCursor = collectionChangeCursor
        self.favoriteChangeCursor = favoriteChangeCursor
        self.tagAliases = tagAliases
        self.collectionAliases = collectionAliases
        self.archiveManifestSHA256 = archiveManifestSHA256
        self.sourceVerifiedAtMs = sourceVerifiedAtMs
    }
}

/// The phone retains its local tag identity in the archive; this explicit
/// mapping identifies the same tag in the Mac shared ledger for one checkpoint.
public struct ImageAllMigrationTagAlias: Codable, Sendable, Equatable {
    public let localTagID: UUID
    public let localTagName: String
    public let remoteTagID: UUID
    public let remoteTagName: String

    public init(
        localTagID: UUID, localTagName: String,
        remoteTagID: UUID, remoteTagName: String
    ) {
        self.localTagID = localTagID
        self.localTagName = localTagName
        self.remoteTagID = remoteTagID
        self.remoteTagName = remoteTagName
    }
}

/// The phone retains its local collection identity in the archive while
/// shared synchronization addresses the confirmed Mac collection identity.
public struct ImageAllMigrationCollectionAlias: Codable, Sendable, Equatable {
    public let localCollectionID: UUID
    public let localCollectionName: String
    public let remoteCollectionID: UUID
    public let remoteCollectionName: String

    public init(
        localCollectionID: UUID, localCollectionName: String,
        remoteCollectionID: UUID, remoteCollectionName: String
    ) {
        self.localCollectionID = localCollectionID
        self.localCollectionName = localCollectionName
        self.remoteCollectionID = remoteCollectionID
        self.remoteCollectionName = remoteCollectionName
    }
}

public struct ImageAllMigrationFactItem: Codable, Sendable, Equatable {
    public let mediaID: UUID
    public let observedFavorite: Bool
    public let favoriteTarget: Bool?
    public let tagDecisions: [ImageAllMigrationTagDecision]
    public let collections: [ImageAllMigrationCollectionMembership]

    public init(
        mediaID: UUID, observedFavorite: Bool, favoriteTarget: Bool?,
        tagDecisions: [ImageAllMigrationTagDecision],
        collections: [ImageAllMigrationCollectionMembership]
    ) {
        self.mediaID = mediaID
        self.observedFavorite = observedFavorite
        self.favoriteTarget = favoriteTarget
        self.tagDecisions = tagDecisions
        self.collections = collections
    }
}

public enum ImageAllMigrationFactsError: Error, Equatable, Sendable {
    case invalidSnapshot
    case unsupportedVersion
    case unsafeFile
    case publishedFactsChanged
}

public enum ImageAllMigrationFacts {
    public static let sidecarDirectoryName = "facts"

    public static func write(_ snapshot: ImageAllMigrationFactSnapshot, to url: URL) throws {
        try validate(snapshot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }

    public static func read(at url: URL) throws -> ImageAllMigrationFactSnapshot {
        try readWithDigest(at: url).snapshot
    }

    public static func readWithDigest(
        at url: URL
    ) throws -> (snapshot: ImageAllMigrationFactSnapshot, sha256: String) {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ImageAllMigrationFactsError.unsafeFile
        }
        let data = try Data(contentsOf: url)
        let snapshot = try JSONDecoder().decode(ImageAllMigrationFactSnapshot.self, from: data)
        try validate(snapshot)
        return (snapshot, hexDigest(Data(SHA256.hash(data: data))))
    }

    /// Fact checkpoints are immutable siblings inside the published media
    /// package. Staging stays outside the package so an interrupted copy does
    /// not make the last complete package invalid.
    public static func publish(from source: URL, into archiveRoot: URL) throws -> URL {
        let expected = try readWithDigest(at: source)
        let name = filename(sequence: expected.snapshot.snapshotSequence, sha256: expected.sha256)
        let manager = FileManager.default
        let rootValues = try archiveRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw ImageAllMigrationFactsError.unsafeFile
        }
        let facts = archiveRoot.appendingPathComponent(sidecarDirectoryName, isDirectory: true)
        let final = facts.appendingPathComponent(name)
        let staging = archiveRoot.deletingLastPathComponent().appendingPathComponent(
            ".imageall-facts-staging-\(UUID().uuidString.lowercased())"
        )
        try manager.copyItem(at: source, to: staging)
        defer { try? manager.removeItem(at: staging) }
        guard try readWithDigest(at: staging).sha256 == expected.sha256 else {
            throw ImageAllMigrationFactsError.publishedFactsChanged
        }
        if manager.fileExists(atPath: facts.path) {
            let values = try facts.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw ImageAllMigrationFactsError.unsafeFile
            }
        } else {
            try manager.createDirectory(at: facts, withIntermediateDirectories: false)
        }
        if manager.fileExists(atPath: final.path) {
            guard try readWithDigest(at: final).sha256 == expected.sha256 else {
                throw ImageAllMigrationFactsError.publishedFactsChanged
            }
            return final
        }
        try manager.moveItem(at: staging, to: final)
        return final
    }

    public static func inspectPublished(
        at archiveRoot: URL, sourceDeviceID: UUID, sourceEpoch: UUID,
        scopeRevision: Int64, inventoryWatermark: Int64,
        minimumFactWatermark: Int64, mediaIDs: Set<UUID>
    ) throws -> (sha256: String?, latestURL: URL?) {
        let facts = archiveRoot.appendingPathComponent(sidecarDirectoryName, isDirectory: true)
        guard try FileManager.default.contentsOfDirectory(atPath: archiveRoot.path)
            .contains(sidecarDirectoryName) else { return (nil, nil) }
        let values = try facts.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ImageAllMigrationFactsError.unsafeFile
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: facts.path).sorted()
        var digest = SHA256()
        var lastSequence: Int64 = -1
        var lastWatermark = minimumFactWatermark
        var latest: URL?
        for name in names {
            let url = facts.appendingPathComponent(name)
            let read = try readWithDigest(at: url)
            let snapshot = read.snapshot
            guard name == filename(sequence: snapshot.snapshotSequence, sha256: read.sha256),
                  snapshot.sourceDeviceID == sourceDeviceID,
                  snapshot.sourceEpoch == sourceEpoch,
                  snapshot.scopeRevision == scopeRevision,
                  snapshot.snapshotSequence >= inventoryWatermark,
                  snapshot.snapshotSequence > lastSequence,
                  snapshot.factWatermark >= lastWatermark,
                  Set(snapshot.items.map(\.mediaID)) == mediaIDs else {
                throw ImageAllMigrationFactsError.publishedFactsChanged
            }
            digest.update(data: Data("\(name)\n".utf8))
            lastSequence = snapshot.snapshotSequence
            lastWatermark = snapshot.factWatermark
            latest = url
        }
        return (names.isEmpty ? nil : hexDigest(Data(digest.finalize())), latest)
    }

    /// Call after the enclosing media package has passed `verify(at:)`.
    public static func latestPublishedURL(in archiveRoot: URL) throws -> URL? {
        let facts = archiveRoot.appendingPathComponent(sidecarDirectoryName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: facts.path) else { return nil }
        guard let last = try FileManager.default.contentsOfDirectory(atPath: facts.path).sorted().last
        else { return nil }
        return facts.appendingPathComponent(last)
    }

    private static func filename(sequence: Int64, sha256: String) -> String {
        String(format: "%020lld-%@.imageallfacts", sequence, sha256)
    }

    private static func hexDigest(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    public static func validate(_ snapshot: ImageAllMigrationFactSnapshot) throws {
        guard snapshot.formatVersion == 1 else {
            throw ImageAllMigrationFactsError.unsupportedVersion
        }
        guard snapshot.scopeRevision >= 0, snapshot.snapshotSequence >= 0,
              snapshot.factWatermark >= 0, !snapshot.items.isEmpty,
              Set(snapshot.items.map(\.mediaID)).count == snapshot.items.count else {
            throw ImageAllMigrationFactsError.invalidSnapshot
        }
        for item in snapshot.items {
            guard Set(item.tagDecisions.map(\.tagID)).count == item.tagDecisions.count,
                  Set(item.collections.map(\.collectionID)).count == item.collections.count,
                  item.tagDecisions.allSatisfy({ !$0.tagName.isEmpty }),
                  item.collections.allSatisfy({ !$0.collectionName.isEmpty }) else {
                throw ImageAllMigrationFactsError.invalidSnapshot
            }
        }
        if let checkpoint = snapshot.syncCheckpoint {
            let aliases = checkpoint.tagAliases ?? []
            let collectionAliases = checkpoint.collectionAliases ?? []
            guard checkpoint.acknowledgedScopeRevision == snapshot.scopeRevision,
                  checkpoint.acknowledgedSnapshotSequence > 0,
                  checkpoint.acknowledgedSnapshotSequence <= snapshot.snapshotSequence,
                  checkpoint.tagChangeCursor >= 0,
                  checkpoint.collectionChangeCursor >= 0,
                  checkpoint.favoriteChangeCursor >= 0,
                  (checkpoint.archiveManifestSHA256 == nil) ==
                    (checkpoint.sourceVerifiedAtMs == nil),
                  (checkpoint.archiveManifestSHA256 == nil ||
                   (checkpoint.archiveManifestSHA256?.count == 64 &&
                    checkpoint.archiveManifestSHA256?.allSatisfy({ $0.isHexDigit }) == true)),
                  checkpoint.sourceVerifiedAtMs.map({ $0 > 0 }) ?? true,
                  Set(aliases.map(\.localTagID)).count == aliases.count,
                  Set(aliases.map(\.remoteTagID)).count == aliases.count,
                  aliases.allSatisfy({
                      $0.localTagID != $0.remoteTagID &&
                      !$0.localTagName.isEmpty && !$0.remoteTagName.isEmpty
                  }),
                  Set(collectionAliases.map(\.localCollectionID)).count == collectionAliases.count,
                  Set(collectionAliases.map(\.remoteCollectionID)).count == collectionAliases.count,
                  collectionAliases.allSatisfy({
                      $0.localCollectionID != $0.remoteCollectionID &&
                      !$0.localCollectionName.isEmpty && !$0.remoteCollectionName.isEmpty
                  }) else {
                throw ImageAllMigrationFactsError.invalidSnapshot
            }
        }
    }
}
