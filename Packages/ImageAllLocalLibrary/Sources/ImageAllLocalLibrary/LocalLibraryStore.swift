import Foundation
import SQLite3

public enum LocalLibraryError: Error, Equatable {
    case database(String)
    case invalidName
    case unknownAsset
    case unknownTag
    case unknownCollection
}

public enum LocalDecision: String, Codable, Sendable {
    case accepted, rejected, cleared
}

public enum LocalFavoriteWritebackState: String, Codable, Sendable {
    case notRequested, pending, matched, failed
}

public struct LocalObservedAsset: Sendable {
    public let localIdentifier: String
    public let kind: String
    public let creationDate: Date?
    public let isFavorite: Bool

    public init(localIdentifier: String, kind: String, creationDate: Date?, isFavorite: Bool) {
        self.localIdentifier = localIdentifier
        self.kind = kind
        self.creationDate = creationDate
        self.isFavorite = isFavorite
    }
}

public struct LocalAsset: Identifiable, Sendable {
    public let id: UUID
    public let localIdentifier: String
    public let kind: String
    public let creationDate: Date?
    public let observedFavorite: Bool
    public let favoriteTarget: Bool?
    public let favoriteWritebackState: LocalFavoriteWritebackState
}

public struct LocalTag: Identifiable, Sendable {
    public let id: UUID
    public let name: String
}

public struct LocalCollection: Identifiable, Sendable {
    public let id: UUID
    public let name: String
}

public struct LocalPendingOperation: Identifiable, Sendable {
    public let id: UUID
    public let sequence: Int64
    public let entityID: UUID
    public let field: String
    public let value: String
}

/// A directory and human-fact projection for assets the owner explicitly selected.
/// It contains no media bytes, thumbnail, GPS, or unreferenced tag/collection names.
public struct LocalSharedSnapshot: Sendable {
    public let installID: UUID
    public let sourceEpoch: UUID
    public let scopeRevision: Int64
    public let assets: [LocalSharedAsset]
}

public struct LocalSharedAsset: Identifiable, Sendable {
    public let id: UUID
    public let localIdentifier: String
    public let kind: String
    public let creationDate: Date?
    public let observedFavorite: Bool
    public let favoriteTarget: Bool?
    public let tagDecisions: [LocalSharedTagDecision]
    public let collections: [LocalSharedCollectionMembership]
}

public struct LocalSharedTagDecision: Sendable {
    public let tagID: UUID
    public let tagName: String
    public let decision: LocalDecision
}

public struct LocalSharedCollectionMembership: Sendable {
    public let collectionID: UUID
    public let collectionName: String
}

/// Owns only ImageAll's local index and human facts. PhotoKit remains the source of media bytes.
/// Every fact change and its future sync operation are committed in the same SQLite transaction.
public actor LocalLibraryStore {
    nonisolated(unsafe) private let db: OpaquePointer

    public init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var connection: OpaquePointer?
        let status = sqlite3_open_v2(
            url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil
        )
        guard status == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let connection { sqlite3_close(connection) }
            throw LocalLibraryError.database(message)
        }
        db = connection
        sqlite3_busy_timeout(db, 5_000)
        do {
            let schema = """
                PRAGMA journal_mode=WAL;
                PRAGMA foreign_keys=ON;
                CREATE TABLE IF NOT EXISTS identity (
                  key TEXT PRIMARY KEY, value TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS assets (
                  id TEXT PRIMARY KEY, source_epoch TEXT NOT NULL,
                  local_identifier TEXT NOT NULL, kind TEXT NOT NULL,
                  creation_time REAL, observed_favorite INTEGER NOT NULL,
                  favorite_target INTEGER,
                  UNIQUE(source_epoch, local_identifier)
                );
                CREATE TABLE IF NOT EXISTS tags (
                  id TEXT PRIMARY KEY, name TEXT NOT NULL COLLATE NOCASE UNIQUE
                );
                CREATE TABLE IF NOT EXISTS tag_decisions (
                  asset_id TEXT NOT NULL REFERENCES assets(id),
                  tag_id TEXT NOT NULL REFERENCES tags(id),
                  decision TEXT NOT NULL, revision INTEGER NOT NULL,
                  PRIMARY KEY(asset_id, tag_id)
                );
                CREATE TABLE IF NOT EXISTS collections (
                  id TEXT PRIMARY KEY, name TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS memberships (
                  collection_id TEXT NOT NULL REFERENCES collections(id),
                  asset_id TEXT NOT NULL REFERENCES assets(id),
                  included INTEGER NOT NULL, revision INTEGER NOT NULL,
                  PRIMARY KEY(collection_id, asset_id)
                );
                CREATE TABLE IF NOT EXISTS outbox (
                  sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                  operation_id TEXT NOT NULL UNIQUE, entity_id TEXT NOT NULL,
                  field TEXT NOT NULL, value TEXT NOT NULL,
                  created_time REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS favorite_writebacks (
                  asset_id TEXT PRIMARY KEY REFERENCES assets(id),
                  target INTEGER NOT NULL, state TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS shared_assets (
                  asset_id TEXT PRIMARY KEY REFERENCES assets(id)
                );
                """
            let setup = schema + """
                INSERT OR IGNORE INTO identity(key,value) VALUES('install_id','\(UUID().uuidString)');
                INSERT OR IGNORE INTO identity(key,value) VALUES('source_epoch','\(UUID().uuidString)');
                INSERT OR IGNORE INTO identity(key,value) VALUES('share_scope_revision','0');
                """
            guard sqlite3_exec(db, setup, nil, nil, nil) == SQLITE_OK else {
                throw LocalLibraryError.database(String(cString: sqlite3_errmsg(db)))
            }
        } catch {
            sqlite3_close(db)
            throw error
        }
    }

    deinit { sqlite3_close(db) }

    public func installID() throws -> UUID {
        UUID(uuidString: try requiredIdentity("install_id"))!
    }

    public func sourceEpoch() throws -> UUID {
        UUID(uuidString: try requiredIdentity("source_epoch"))!
    }

    /// Selection is local and persistent. It never starts a network transfer.
    public func setShared(assetID: UUID, shared: Bool) throws {
        guard try exists("assets", id: assetID) else { throw LocalLibraryError.unknownAsset }
        let selected = try scalar("SELECT asset_id FROM shared_assets WHERE asset_id=?", [assetID.uuidString]) != nil
        guard selected != shared else { return }
        try transaction {
            if shared {
                try execute("INSERT INTO shared_assets(asset_id) VALUES(?)", [assetID.uuidString])
            } else {
                try execute("DELETE FROM shared_assets WHERE asset_id=?", [assetID.uuidString])
            }
            try execute("""
                UPDATE identity SET value=CAST(value AS INTEGER)+1 WHERE key='share_scope_revision'
                """)
        }
    }

    public func isShared(assetID: UUID) throws -> Bool {
        try scalar("SELECT asset_id FROM shared_assets WHERE asset_id=?", [assetID.uuidString]) != nil
    }

    /// The caller supplies the identifiers currently returned by PhotoKit. Missing permission
    /// only hides the projection; it does not revoke sharing or generate deletion records.
    public func sharedSnapshot(visibleIdentifiers: Set<String>) throws -> LocalSharedSnapshot {
        let epoch = try requiredIdentity("source_epoch")
        let revision = Int64(try requiredIdentity("share_scope_revision")) ?? 0
        let selected = try rows("""
            SELECT a.id,a.local_identifier,a.kind,a.creation_time,a.observed_favorite,a.favorite_target
            FROM shared_assets s JOIN assets a ON a.id=s.asset_id
            WHERE a.source_epoch=? ORDER BY a.id
            """, [epoch])
        let assets: [LocalSharedAsset] = try selected.compactMap { row in
            guard let id = UUID(uuidString: row[0] ?? ""),
                  let identifier = row[1], visibleIdentifiers.contains(identifier) else { return nil }
            let tagDecisions = try rows("""
                SELECT t.id,t.name,d.decision FROM tag_decisions d
                JOIN tags t ON t.id=d.tag_id WHERE d.asset_id=? ORDER BY t.id
                """, [id.uuidString]).compactMap { item -> LocalSharedTagDecision? in
                    guard let tagID = UUID(uuidString: item[0] ?? ""),
                          let decision = LocalDecision(rawValue: item[2] ?? "") else { return nil }
                    return LocalSharedTagDecision(
                        tagID: tagID, tagName: item[1] ?? "", decision: decision
                    )
                }
            let collections = try rows("""
                SELECT c.id,c.name FROM memberships m
                JOIN collections c ON c.id=m.collection_id
                WHERE m.asset_id=? AND m.included=1 ORDER BY c.id
                """, [id.uuidString]).compactMap { item -> LocalSharedCollectionMembership? in
                    guard let collectionID = UUID(uuidString: item[0] ?? "") else { return nil }
                    return LocalSharedCollectionMembership(
                        collectionID: collectionID, collectionName: item[1] ?? ""
                    )
                }
            return LocalSharedAsset(
                id: id, localIdentifier: identifier, kind: row[2] ?? "image",
                creationDate: row[3].flatMap(Double.init).map(Date.init(timeIntervalSince1970:)),
                observedFavorite: row[4] == "1", favoriteTarget: row[5].map { $0 == "1" },
                tagDecisions: tagDecisions, collections: collections
            )
        }
        return LocalSharedSnapshot(
            installID: try installID(), sourceEpoch: try sourceEpoch(),
            scopeRevision: revision, assets: assets
        )
    }

    /// Upserts only items PhotoKit returned. Permission contraction never creates tombstones.
    public func observe(_ assets: [LocalObservedAsset]) throws {
        let epoch = try requiredIdentity("source_epoch")
        try transaction {
            for asset in assets {
                guard !asset.localIdentifier.isEmpty else { continue }
                try execute("""
                    INSERT INTO assets(id,source_epoch,local_identifier,kind,creation_time,observed_favorite)
                    VALUES(?,?,?,?,?,?)
                    ON CONFLICT(source_epoch,local_identifier) DO UPDATE SET
                      kind=excluded.kind, creation_time=excluded.creation_time,
                      observed_favorite=excluded.observed_favorite
                    """, [
                        UUID().uuidString, epoch, asset.localIdentifier, asset.kind,
                        asset.creationDate.map { String($0.timeIntervalSince1970) } ?? "",
                        asset.isFavorite ? "1" : "0"
                    ])
                // Source observation resolves an interrupted write and detects later drift.
                try execute("""
                    UPDATE favorite_writebacks SET state=CASE
                      WHEN target=? THEN 'matched'
                      WHEN state='matched' THEN 'failed'
                      ELSE state END
                    WHERE asset_id=(SELECT id FROM assets WHERE source_epoch=? AND local_identifier=?)
                    """, [asset.isFavorite ? "1" : "0", epoch, asset.localIdentifier])
            }
        }
    }

    public func assets(visibleIdentifiers: Set<String>) throws -> [LocalAsset] {
        guard !visibleIdentifiers.isEmpty else { return [] }
        let epoch = try requiredIdentity("source_epoch")
        let placeholders = Array(repeating: "?", count: visibleIdentifiers.count).joined(separator: ",")
        return try rows(
            "SELECT a.id,a.local_identifier,a.kind,a.creation_time,a.observed_favorite,a.favorite_target,w.state FROM assets a LEFT JOIN favorite_writebacks w ON w.asset_id=a.id WHERE a.source_epoch=? AND a.local_identifier IN (\(placeholders))",
            [epoch] + visibleIdentifiers.sorted()
        )
            .compactMap { row in
                guard visibleIdentifiers.contains(row[1] ?? ""),
                      let id = UUID(uuidString: row[0] ?? "") else { return nil }
                return LocalAsset(
                    id: id, localIdentifier: row[1] ?? "", kind: row[2] ?? "image",
                    creationDate: (row[3].flatMap(Double.init)).map(Date.init(timeIntervalSince1970:)),
                    observedFavorite: row[4] == "1",
                    favoriteTarget: row[5].map { $0 == "1" },
                    favoriteWritebackState: LocalFavoriteWritebackState(rawValue: row[6] ?? "")
                        ?? .notRequested
                )
            }
    }

    public func tags() throws -> [LocalTag] {
        try rows("SELECT id,name FROM tags ORDER BY name COLLATE NOCASE").compactMap {
            guard let id = UUID(uuidString: $0[0] ?? "") else { return nil }
            return LocalTag(id: id, name: $0[1] ?? "")
        }
    }

    public func collections() throws -> [LocalCollection] {
        try rows("SELECT id,name FROM collections ORDER BY name COLLATE NOCASE").compactMap {
            guard let id = UUID(uuidString: $0[0] ?? "") else { return nil }
            return LocalCollection(id: id, name: $0[1] ?? "")
        }
    }

    @discardableResult public func createTag(name: String) throws -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LocalLibraryError.invalidName }
        if let existing = try scalar("SELECT id FROM tags WHERE name=? COLLATE NOCASE", [trimmed]),
           let id = UUID(uuidString: existing) { return id }
        let id = UUID()
        try transaction {
            try execute("INSERT INTO tags(id,name) VALUES(?,?)", [id.uuidString, trimmed])
            try enqueue(id, field: "tag.create", value: trimmed)
        }
        return id
    }

    @discardableResult public func createCollection(name: String) throws -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LocalLibraryError.invalidName }
        let id = UUID()
        try transaction {
            try execute("INSERT INTO collections(id,name) VALUES(?,?)", [id.uuidString, trimmed])
            try enqueue(id, field: "collection.create", value: trimmed)
        }
        return id
    }

    public func setDecision(assetID: UUID, tagID: UUID, decision: LocalDecision) throws {
        guard try exists("assets", id: assetID) else { throw LocalLibraryError.unknownAsset }
        guard try exists("tags", id: tagID) else { throw LocalLibraryError.unknownTag }
        let field = "tag.\(tagID.uuidString)"
        try transaction {
            try execute("""
                INSERT INTO tag_decisions(asset_id,tag_id,decision,revision) VALUES(?,?,?,1)
                ON CONFLICT(asset_id,tag_id) DO UPDATE SET
                  decision=excluded.decision, revision=revision+1
                """, [assetID.uuidString, tagID.uuidString, decision.rawValue])
            try enqueue(assetID, field: field, value: decision.rawValue)
        }
    }

    public func decisions(assetID: UUID) throws -> [UUID: LocalDecision] {
        var result: [UUID: LocalDecision] = [:]
        for row in try rows("SELECT tag_id,decision FROM tag_decisions WHERE asset_id=?", [assetID.uuidString]) {
            if let id = UUID(uuidString: row[0] ?? ""),
               let decision = LocalDecision(rawValue: row[1] ?? "") { result[id] = decision }
        }
        return result
    }

    public func setMembership(assetID: UUID, collectionID: UUID, included: Bool) throws {
        guard try exists("assets", id: assetID) else { throw LocalLibraryError.unknownAsset }
        guard try exists("collections", id: collectionID) else { throw LocalLibraryError.unknownCollection }
        try transaction {
            try execute("""
                INSERT INTO memberships(collection_id,asset_id,included,revision) VALUES(?,?,?,1)
                ON CONFLICT(collection_id,asset_id) DO UPDATE SET
                  included=excluded.included, revision=revision+1
                """, [collectionID.uuidString, assetID.uuidString, included ? "1" : "0"])
            try enqueue(assetID, field: "collection.\(collectionID.uuidString)", value: included ? "1" : "0")
        }
    }

    public func memberships(assetID: UUID) throws -> Set<UUID> {
        Set(try rows("SELECT collection_id FROM memberships WHERE asset_id=? AND included=1", [assetID.uuidString])
            .compactMap { UUID(uuidString: $0[0] ?? "") })
    }

    /// Records ImageAll's desired favorite separately from PhotoKit's last observed state.
    /// Pending intent survives a crash between source mutation and readback.
    public func setFavoriteTarget(assetID: UUID, isFavorite: Bool) throws {
        guard try exists("assets", id: assetID) else { throw LocalLibraryError.unknownAsset }
        try transaction {
            try execute("UPDATE assets SET favorite_target=? WHERE id=?", [isFavorite ? "1" : "0", assetID.uuidString])
            try execute("""
                INSERT INTO favorite_writebacks(asset_id,target,state) VALUES(?,?,'pending')
                ON CONFLICT(asset_id) DO UPDATE SET target=excluded.target,state='pending'
                """, [assetID.uuidString, isFavorite ? "1" : "0"])
            try enqueue(assetID, field: "favorite.target", value: isFavorite ? "1" : "0")
        }
    }

    /// A late result for an older target cannot acknowledge or overwrite a newer user intent.
    public func finishFavoriteWriteback(
        assetID: UUID, requestedValue: Bool, observedValue: Bool?
    ) throws {
        let value = requestedValue ? "1" : "0"
        guard try scalar("SELECT favorite_target FROM assets WHERE id=?", [assetID.uuidString]) == value
        else { return }
        try transaction {
            if let observedValue {
                try execute("UPDATE assets SET observed_favorite=? WHERE id=?", [
                    observedValue ? "1" : "0", assetID.uuidString
                ])
            }
            try execute("UPDATE favorite_writebacks SET state=? WHERE asset_id=? AND target=?", [
                observedValue == requestedValue ? "matched" : "failed", assetID.uuidString, value
            ])
        }
    }

    public func pendingOperations() throws -> [LocalPendingOperation] {
        try rows("SELECT sequence,operation_id,entity_id,field,value FROM outbox ORDER BY sequence")
            .compactMap { row in
                guard let sequence = Int64(row[0] ?? ""),
                      let id = UUID(uuidString: row[1] ?? ""),
                      let entityID = UUID(uuidString: row[2] ?? "") else { return nil }
                return LocalPendingOperation(
                    id: id, sequence: sequence, entityID: entityID,
                    field: row[3] ?? "", value: row[4] ?? ""
                )
            }
    }

    private func requiredIdentity(_ key: String) throws -> String {
        guard let value = try scalar("SELECT value FROM identity WHERE key=?", [key]) else {
            throw LocalLibraryError.database("missing identity")
        }
        return value
    }

    private func exists(_ table: String, id: UUID) throws -> Bool {
        try scalar("SELECT id FROM \(table) WHERE id=?", [id.uuidString]) != nil
    }

    private func enqueue(_ entityID: UUID, field: String, value: String) throws {
        try execute("INSERT INTO outbox(operation_id,entity_id,field,value,created_time) VALUES(?,?,?,?,?)", [
            UUID().uuidString, entityID.uuidString, field, value, String(Date().timeIntervalSince1970)
        ])
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func scalar(_ sql: String, _ bindings: [String] = []) throws -> String? {
        try rows(sql, bindings).first?.first ?? nil
    }

    private func execute(_ sql: String, _ bindings: [String] = []) throws {
        try withStatement(sql, bindings) { statement in
            let status = sqlite3_step(statement)
            guard status == SQLITE_DONE || status == SQLITE_ROW else {
                throw LocalLibraryError.database(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    private func rows(_ sql: String, _ bindings: [String] = []) throws -> [[String?]] {
        try withStatement(sql, bindings) { statement in
            var output: [[String?]] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return output }
                guard status == SQLITE_ROW else {
                    throw LocalLibraryError.database(String(cString: sqlite3_errmsg(db)))
                }
                output.append((0..<sqlite3_column_count(statement)).map { index in
                    guard let text = sqlite3_column_text(statement, index) else { return nil }
                    return String(cString: text)
                })
            }
        }
    }

    private func withStatement<T>(
        _ sql: String, _ bindings: [String], _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw LocalLibraryError.database(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() {
            let status = value.withCString { pointer in
                sqlite3_bind_text(statement, Int32(index + 1), pointer, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            guard status == SQLITE_OK else {
                throw LocalLibraryError.database(String(cString: sqlite3_errmsg(db)))
            }
        }
        return try body(statement)
    }
}
