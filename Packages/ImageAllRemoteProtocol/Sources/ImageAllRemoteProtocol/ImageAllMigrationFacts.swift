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

    public init(
        sourceDeviceID: UUID, sourceEpoch: UUID, scopeRevision: Int64,
        snapshotSequence: Int64, factWatermark: Int64,
        items: [ImageAllMigrationFactItem]
    ) {
        formatVersion = 1
        self.sourceDeviceID = sourceDeviceID
        self.sourceEpoch = sourceEpoch
        self.scopeRevision = scopeRevision
        self.snapshotSequence = snapshotSequence
        self.factWatermark = factWatermark
        self.items = items
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
}

public enum ImageAllMigrationFacts {
    public static func write(_ snapshot: ImageAllMigrationFactSnapshot, to url: URL) throws {
        try validate(snapshot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }

    public static func read(at url: URL) throws -> ImageAllMigrationFactSnapshot {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ImageAllMigrationFactsError.unsafeFile
        }
        let snapshot = try JSONDecoder().decode(
            ImageAllMigrationFactSnapshot.self, from: Data(contentsOf: url)
        )
        try validate(snapshot)
        return snapshot
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
    }
}
