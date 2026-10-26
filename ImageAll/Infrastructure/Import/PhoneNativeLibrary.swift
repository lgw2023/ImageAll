import CryptoKit
import Foundation
import GRDB
import ImageAllRemoteProtocol

/// A projection over verified Mac copies, never a folder enumeration.
enum V064PhoneNativeLibrary {
    static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(CatalogMigrationID.v064PhoneNativeLibrary) { db in
            try db.execute(sql: """
                CREATE TABLE phone_library_source (
                    source_id TEXT PRIMARY KEY NOT NULL REFERENCES source(id) ON DELETE RESTRICT,
                    install_id TEXT NOT NULL, epoch TEXT NOT NULL, parent_path TEXT NOT NULL,
                    UNIQUE(install_id, epoch, parent_path)
                ) STRICT;
                CREATE TABLE phone_library_publication (
                    migration_id TEXT PRIMARY KEY NOT NULL REFERENCES migration_import(id) ON DELETE RESTRICT,
                    source_id TEXT NOT NULL REFERENCES phone_library_source(source_id) ON DELETE RESTRICT,
                    manifest_sha256 TEXT NOT NULL, fact_sequence INTEGER NOT NULL,
                    fact_sha256 TEXT, item_count INTEGER NOT NULL, published_at_ms INTEGER NOT NULL
                ) STRICT;
                CREATE TABLE phone_library_asset (
                    asset_id TEXT PRIMARY KEY NOT NULL REFERENCES asset(id) ON DELETE RESTRICT,
                    migration_id TEXT NOT NULL REFERENCES migration_import(id) ON DELETE RESTRICT,
                    media_id TEXT NOT NULL REFERENCES media_item(id) ON DELETE RESTRICT,
                    UNIQUE(migration_id, media_id)
                ) STRICT;
                CREATE TABLE phone_library_member (
                    source_id TEXT NOT NULL, relative_path TEXT NOT NULL,
                    asset_id TEXT NOT NULL REFERENCES asset(id) ON DELETE RESTRICT,
                    source_ordinal INTEGER NOT NULL,
                    PRIMARY KEY(source_id, relative_path, asset_id),
                    FOREIGN KEY(source_id, relative_path) REFERENCES source_folder(source_id, relative_path) ON DELETE RESTRICT
                ) STRICT;
                CREATE INDEX phone_library_member_asset ON phone_library_member(asset_id, relative_path);
                CREATE TABLE phone_library_tag (
                    install_id TEXT NOT NULL, epoch TEXT NOT NULL, phone_tag_id TEXT NOT NULL,
                    tag_id TEXT NOT NULL UNIQUE REFERENCES tag(id) ON DELETE RESTRICT,
                    PRIMARY KEY(install_id, epoch, phone_tag_id)
                ) STRICT;
                ALTER TABLE source_folder ADD COLUMN source_ordinal INTEGER NOT NULL DEFAULT 0;
                CREATE TRIGGER phone_library_no_mutation_insert BEFORE INSERT ON source_mutation_authorization
                WHEN EXISTS(SELECT 1 FROM phone_library_source WHERE source_id = NEW.source_id)
                BEGIN SELECT RAISE(ABORT, 'managed phone originals are read only'); END;
                CREATE TRIGGER phone_library_no_mutation_update BEFORE UPDATE ON source_mutation_authorization
                WHEN EXISTS(SELECT 1 FROM phone_library_source WHERE source_id = NEW.source_id)
                BEGIN SELECT RAISE(ABORT, 'managed phone originals are read only'); END;
                """)
        }
    }
}

extension Notification.Name {
    static let phoneNativeLibraryChanged = Notification.Name("ImageAll.phoneNativeLibraryChanged")
    static let phoneNativeLibraryOpen = Notification.Name("ImageAll.phoneNativeLibraryOpen")
}

struct PhoneNativeLibraryPublisher: Sendable {
    let database: CatalogDatabase
    private static let publicationLock = NSLock()

    /// Catalog-only observation. Survives removal of receiver staging and does
    /// not reapply phone facts or read original media.
    func importTaskStatus(_ query: RemoteImportTaskQuery) throws -> RemoteImportTaskStatus? {
        try database.pool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT m.source_device_id, m.source_epoch, m.manifest_sha256, m.state,
                    m.item_count, p.source_id,
                    p.manifest_sha256 = m.manifest_sha256
                    AND p.fact_sequence = m.fact_snapshot_sequence
                    AND p.fact_sha256 IS m.fact_snapshot_sha256
                    AND p.item_count = m.item_count
                    AND p.item_count = (SELECT COUNT(*) FROM phone_library_asset a WHERE a.migration_id = m.id)
                    AS current
                FROM migration_import m LEFT JOIN phone_library_publication p ON p.migration_id = m.id
                WHERE m.id = ?
                """, arguments: [query.migrationID.uuidString.lowercased()]) else { return nil }
            guard UUID(uuidString: row["source_device_id"]) == query.sourceInstallID,
                  UUID(uuidString: row["source_epoch"]) == query.sourceEpoch,
                  (row["manifest_sha256"] as String) == query.manifestSHA256 else {
                throw RemoteAPIError(code: .conflict, message: "导入批次来源或清单不一致")
            }
            let source: String? = row["source_id"]
            let current: Bool? = row["current"]
            let committed = (row["state"] as String) == "catalogCommitted"
            return .init(query: query,
                phase: committed && current == true ? .browsable : .needsAttention,
                sourceID: committed && current == true ? source.flatMap(UUID.init(uuidString:)) : nil,
                itemCount: row["item_count"])
        }
    }

    func sourceID(migrationID: UUID) throws -> UUID? {
        try database.pool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT p.source_id, m.state = 'catalogCommitted' AND p.manifest_sha256 = m.manifest_sha256
                  AND p.fact_sequence = m.fact_snapshot_sequence
                  AND p.fact_sha256 IS m.fact_snapshot_sha256
                  AND p.item_count = m.item_count
                  AND p.item_count = (SELECT COUNT(*) FROM phone_library_asset a WHERE a.migration_id = p.migration_id)
                  AS current
                FROM phone_library_publication p JOIN migration_import m ON m.id = p.migration_id
                WHERE p.migration_id = ?
                """, arguments: [migrationID.uuidString.lowercased()]) else { return nil }
            guard row["current"] as Bool else { throw PhoneArchiveImportError.validationStale }
            return UUID(uuidString: row["source_id"])
        }
    }

    /// Fast restart path is DB-only. No original reads, no metadata reapplication.
    func unpublishedBatches() throws -> [PhoneArchiveImportedBatch] {
        try VerifiedPhoneArchiveImporter(database: database).importedBatches(includePrepared: true).filter {
            // Keep stale candidates for per-batch error reporting; one bad receipt
            // must not prevent other interrupted batches from being discovered.
            (try? sourceID(migrationID: $0.id)) == nil
        }
    }

    /// Explicit maintenance only. A cleanup failure never changes publication,
    /// favorites, metadata or final media. Legacy staging is not auto-enrolled.
    func releaseStagingPayload(migrationID: UUID, receiverRoot: URL,
                               priorVerification: ImageAllMigrationVerification? = nil,
                               sourceVerification: ImageAllMigrationVerification? = nil,
                               reuseVerifiedContents: Bool = false) throws -> ImageAllMigrationCleanupResult {
        try Self.publicationLock.withLock {
            let importer = VerifiedPhoneArchiveImporter(database: database)
            guard let batch = try importer.importedBatches().first(where: { $0.id == migrationID }) else {
                throw ImageAllMigrationCleanupError.incompleteReferences
            }
            let archive = URL(fileURLWithPath: batch.archivePath)
            return try ImageAllMigrationStagingCleanup.release(root: receiverRoot, migrationID: migrationID,
                finalArchive: archive, publicationVerification: {
                    var verified: ImageAllMigrationVerification?
                    _ = try importer.auditImportedArchive(migrationID: migrationID, archiveRoot: archive,
                        priorVerification: priorVerification, reuseVerifiedContents: reuseVerifiedContents,
                        onVerifiedArchive: { verified = $0 })
                    guard let verified else { throw ImageAllMigrationCleanupError.incompleteReferences }
                    return verified
                }, sourceVerification: sourceVerification, reuseVerifiedContents: reuseVerifiedContents,
                validatePublication: {
                    guard let sourceID = try sourceID(migrationID: migrationID) else {
                        throw ImageAllMigrationCleanupError.incompleteReferences
                    }
                    try validatePublicationReferences(migrationID: migrationID, sourceID: sourceID, archive: archive, itemCount: batch.itemCount)
                })
        }
    }

    private func validatePublicationReferences(migrationID: UUID, sourceID: UUID, archive: URL, itemCount: Int) throws {
        // Require actual projection and resource coverage, not just
        // an equal-count publication receipt or unrelated source.
        try database.pool.read { db in
            let key = migrationID.uuidString.lowercased(), source = sourceID.uuidString.lowercased()
            let count = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM migration_import_item i
                JOIN migration_import m ON m.id = i.migration_id
                JOIN phone_library_asset p ON p.migration_id = i.migration_id AND p.media_id = i.media_id
                JOIN asset a ON a.id = p.asset_id AND a.source_id = ? AND a.locator_kind = 'file'
                JOIN source visible ON visible.id = a.source_id AND visible.state = 'active'
                JOIN media_asset_binding b ON b.media_id = p.media_id AND b.asset_id = p.asset_id
                JOIN phone_library_source s ON s.source_id = a.source_id
                  AND s.install_id = m.source_device_id AND s.epoch = m.source_epoch
                  AND s.parent_path = m.target_parent_path
                WHERE i.migration_id = ? AND EXISTS (
                    SELECT 1 FROM migration_import_resource r
                    WHERE r.source_device_id = i.source_device_id AND r.source_epoch = i.source_epoch
                      AND r.media_id = i.media_id AND r.role = 'original'
                      AND a.relative_path = ? || '/' || r.relative_path)
                """, arguments: [source, key, archive.lastPathComponent])
            guard count == itemCount else { throw ImageAllMigrationCleanupError.incompleteReferences }
        }
    }

    func exportCleanupReceipt(_ query: RemoteImportTaskQuery, nonce: UUID, hostID: UUID,
                              deviceID: UUID) throws -> RemoteExportCleanupReceipt {
        try Self.publicationLock.withLock {
            guard let status = try importTaskStatus(query), status.phase == .browsable,
                  let source = status.sourceID else { throw ImageAllMigrationCleanupError.incompleteReferences }
            let importer = VerifiedPhoneArchiveImporter(database: database)
            guard let batch = try importer.importedBatches().first(where: { $0.id == query.migrationID }) else {
                throw ImageAllMigrationCleanupError.incompleteReferences
            }
            let archive = URL(fileURLWithPath: batch.archivePath)
            var verification: ImageAllMigrationVerification?
            let report = try importer.auditImportedArchive(migrationID: query.migrationID, archiveRoot: archive,
                onVerifiedArchive: { verification = $0 })
            try validatePublicationReferences(migrationID: query.migrationID, sourceID: source,
                archive: archive, itemCount: batch.itemCount)
            guard let verification, try importTaskStatus(query)?.sourceID == source else { throw ImageAllMigrationCleanupError.changed }
            try verification.validateStorageIdentity(at: archive)
            return .init(query: query, nonce: nonce, hostID: hostID, deviceID: deviceID, sourceID: source,
                itemCount: report.itemCount, resourceCount: report.resourceCount, verifiedBytes: report.verifiedBytes)
        }
    }

    @discardableResult
    func publish(importReceipt: PhoneArchiveImportReceipt,
                 reuseVerifiedContents: Bool = false,
                 onVerifiedArchive: ((ImageAllMigrationVerification) -> Void)? = nil,
                 beforeCommit: (@Sendable () throws -> Void)? = nil) throws -> UUID {
        try publish(migrationID: importReceipt.migrationID, archiveRoot: importReceipt.archiveURL,
                    priorVerification: importReceipt.publicationVerification,
                    reuseVerifiedContents: reuseVerifiedContents, onVerifiedArchive: onVerifiedArchive, beforeCommit: beforeCommit)
    }

    @discardableResult
    func publish(migrationID: UUID, archiveRoot: URL,
                 priorVerification: ImageAllMigrationVerification? = nil,
                 reuseVerifiedContents: Bool = false,
                 onVerifiedArchive: ((ImageAllMigrationVerification) -> Void)? = nil,
                 beforeCommit: (@Sendable () throws -> Void)? = nil) throws -> UUID {
        try Self.publicationLock.withLock {
            try publishLocked(migrationID: migrationID, archiveRoot: archiveRoot,
                              priorVerification: priorVerification, reuseVerifiedContents: reuseVerifiedContents, onVerifiedArchive: onVerifiedArchive, beforeCommit: beforeCommit)
        }
    }

    private func publishLocked(migrationID: UUID, archiveRoot: URL,
                               priorVerification: ImageAllMigrationVerification?,
                               reuseVerifiedContents: Bool,
                               onVerifiedArchive: ((ImageAllMigrationVerification) -> Void)?,
                               beforeCommit: (@Sendable () throws -> Void)?) throws -> UUID {
        if let existing = try sourceID(migrationID: migrationID) { return existing }
        // Only small manifest metadata is retained, never resource bytes/thumbnails.
        var items: [ImageAllMigrationItem] = []
        let importer = VerifiedPhoneArchiveImporter(database: database)
        var archiveVerification: ImageAllMigrationVerification?
        let recovered = try importer.recoverPreparedArchive(migrationID: migrationID, archiveRoot: archiveRoot,
            reuseVerifiedContents: reuseVerifiedContents)
        if priorVerification == nil && recovered == nil {
            try importer.recoverUnpublishedFacts(migrationID: migrationID, archiveRoot: archiveRoot)
        }
        let report = try importer.auditImportedArchive(migrationID: migrationID, archiveRoot: archiveRoot,
            priorVerification: priorVerification ?? recovered?.publicationVerification,
            reuseVerifiedContents: reuseVerifiedContents, onVerifiedArchive: { archiveVerification = $0 }) {
            items.append($0)
        }
        guard let archiveVerification else { throw PhoneArchiveImportError.catalogDiverged }
        let batch = try importer.importedBatches().first { $0.id == migrationID }
        guard let batch else { throw PhoneArchiveImportError.missingImportJournal }
        let parent = archiveRoot.deletingLastPathComponent()
        let bookmark = try parent.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                               includingResourceValuesForKeys: nil, relativeTo: nil)
        let key = migrationID.uuidString.lowercased()
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let published = try database.pool.write { db in
            if let existing = try String.fetchOne(db, sql: "SELECT source_id FROM phone_library_publication WHERE migration_id = ?", arguments: [key]),
               let id = UUID(uuidString: existing) { return id }
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM migration_import WHERE id = ? AND state = 'catalogCommitted'", arguments: [key]),
                  (row["manifest_sha256"] as String) == report.manifestSHA256,
                  (row["fact_snapshot_sequence"] as Int64) == report.factSnapshotSequence,
                  (row["archive_path"] as String) == archiveRoot.path,
                  (row["item_count"] as Int) == items.count else { throw PhoneArchiveImportError.catalogDiverged }
            let install: String = row["source_device_id"], epoch: String = row["source_epoch"]
            let source = try String.fetchOne(db, sql: "SELECT source_id FROM phone_library_source WHERE install_id = ? AND epoch = ? AND parent_path = ?",
                                            arguments: [install, epoch, parent.path]) ?? UUID().uuidString.lowercased()
            try db.execute(sql: """
                INSERT OR IGNORE INTO source(id, kind, display_name, bookmark, state, created_at_ms, updated_at_ms)
                VALUES (?, 'folder', 'iPhone', ?, 'active', ?, ?)
                """, arguments: [source, bookmark, timestamp, timestamp])
            try db.execute(sql: "INSERT OR IGNORE INTO phone_library_source VALUES (?, ?, ?, ?)", arguments: [source, install, epoch, parent.path])
            for node in batch.appleAlbumCatalog ?? [] {
                let catalog = batch.appleAlbumCatalog ?? []
                func path(_ node: ImageAllMigrationAppleCollection) -> String {
                    if let parentID = node.parentLocalIdentifier, let ancestor = catalog.first(where: { $0.id == parentID }) {
                        return path(ancestor) + "/" + Self.component(node.id)
                    }
                    return "albums/" + Self.component(node.id)
                }
                try group(db, source: source, path: "albums", title: "相簿", ordinal: 0)
                try group(db, source: source, path: path(node), title: node.title ?? "未命名相簿", ordinal: node.sourceOrdinal)
            }
            for item in items {
                let media = item.mediaID.uuidString.lowercased()
                guard let original = item.resources.first(where: { $0.role == "original" }),
                      let relative = original.relativePath, let size = original.byteCount else { throw PhoneArchiveImportError.incompleteArchive }
                let resourcePath = archiveRoot.lastPathComponent + "/" + relative
                guard case .success = RelativePathRules.validate(resourcePath) else { throw PhoneArchiveImportError.catalogDiverged }
                let asset = UUID().uuidString.lowercased()
                let metadata = item.sourceMetadata
                let duration = metadata?.durationSeconds.flatMap { $0 > 0 ? Int64($0 * 1000) : nil }
                try db.execute(sql: """
                    INSERT INTO asset(id, source_id, locator_kind, relative_path, media_type, media_kind,
                        file_name, width, height, duration_ms, media_created_at_ms, media_modified_at_ms,
                        record_created_at_ms, record_updated_at_ms)
                    VALUES (?, ?, 'file', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [asset, source, resourcePath, original.uniformTypeIdentifier, item.mediaKind.rawValue,
                        original.originalFilename ?? URL(fileURLWithPath: relative).lastPathComponent,
                        metadata?.pixelWidth, metadata?.pixelHeight, duration, item.createdAtMs, metadata?.modifiedAtMs, timestamp, timestamp])
                if let location = metadata?.location {
                    try db.execute(sql: "INSERT INTO asset_location(asset_id, latitude, longitude, altitude_m, source_kind, updated_at_ms) VALUES (?, ?, ?, ?, 'photosGPS', ?)",
                                   arguments: [asset, location.latitude, location.longitude, location.altitudeMeters, timestamp])
                }
                let values = try archiveRoot.appendingPathComponent(relative).resourceValues(forKeys: [.contentModificationDateKey])
                let modifiedNs = Int64((values.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1_000_000_000)
                try db.execute(sql: "INSERT INTO file_fingerprint(asset_id, size_bytes, modified_at_ns) VALUES (?, ?, ?)", arguments: [asset, size, modifiedNs])
                try db.execute(sql: "INSERT INTO phone_library_asset VALUES (?, ?, ?)", arguments: [asset, key, media])
                try db.execute(sql: "INSERT INTO media_asset_binding VALUES (?, ?, 'migrationManifest', ?)", arguments: [media, asset, timestamp])
                try db.execute(sql: "INSERT INTO media_asset_binding_event(id, media_id, asset_id, event_kind, created_at_ms) VALUES (?, ?, ?, 'confirmed', ?)", arguments: [UUID().uuidString.lowercased(), media, asset, timestamp])
                try db.execute(sql: """
                    INSERT INTO asset_favorite_state(asset_id, desired_value, sync_status, requested_at_ms, updated_at_ms)
                    SELECT ?, COALESCE(favorite_target, observed_favorite), 'localOnly', ?, ?
                    FROM migration_import_item WHERE migration_id = ? AND media_id = ?
                    """, arguments: [asset, timestamp, timestamp, key, media])
                let tags = try Row.fetchAll(db, sql: "SELECT * FROM migration_import_tag_decision WHERE source_device_id = ? AND source_epoch = ? AND media_id = ?", arguments: [install, epoch, media])
                for tag in tags {
                    let phoneID: String = tag["tag_id"], name: String = tag["tag_name"], decision: String = tag["decision"]
                    let native = try String.fetchOne(db, sql: "SELECT tag_id FROM phone_library_tag WHERE install_id = ? AND epoch = ? AND phone_tag_id = ?", arguments: [install, epoch, phoneID]) ?? UUID().uuidString.lowercased()
                    // Preserve phone identity, while retaining normal name search/sort semantics.
                    var displayName = name
                    var normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if case let .success(parts) = TagNameNormalizer.validateAndNormalize(name) {
                        displayName = parts.displayName; normalized = parts.normalizedName
                    }
                    if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM tag WHERE normalized_name = ? AND id != ?)", arguments: [normalized, native]) == true {
                        displayName += " · iPhone " + String(native.prefix(6))
                        normalized += " · iphone " + String(native.prefix(6))
                    }
                    try db.execute(sql: "INSERT OR IGNORE INTO tag(id, name, normalized_name, created_at_ms, updated_at_ms) VALUES (?, ?, ?, ?, ?)", arguments: [native, displayName, normalized, timestamp, timestamp])
                    try db.execute(sql: "INSERT OR IGNORE INTO phone_library_tag VALUES (?, ?, ?, ?)", arguments: [install, epoch, phoneID, native])
                    if decision != "cleared" {
                        try db.execute(sql: "INSERT INTO asset_tag_decision VALUES (?, ?, ?, ?)", arguments: [asset, native, decision, timestamp])
                    }
                }
                for album in item.appleAlbums ?? [] {
                    try group(db, source: source, path: "albums", title: "相簿", ordinal: 0)
                    var path = "albums"
                    for folder in album.folderPath {
                        path += "/" + Self.component(folder.localIdentifier)
                        try group(db, source: source, path: path, title: folder.title ?? "未命名文件夹", ordinal: 0)
                    }
                    path += "/" + Self.component(album.albumLocalIdentifier)
                    try group(db, source: source, path: path, title: album.albumTitle ?? "未命名相簿", ordinal: 0)
                    try member(db, source: source, path: path, asset: asset, ordinal: album.sourceOrdinal)
                }
                for collection in try Row.fetchAll(db, sql: "SELECT * FROM migration_import_collection WHERE source_device_id = ? AND source_epoch = ? AND media_id = ? AND included = 1", arguments: [install, epoch, media]) {
                    let id: String = collection["collection_id"], name: String = collection["collection_name"]
                    try group(db, source: source, path: "collections", title: "集合", ordinal: 1)
                    let path = "collections/" + Self.component(id)
                    try group(db, source: source, path: path, title: name, ordinal: 0)
                    try member(db, source: source, path: path, asset: asset, ordinal: 0)
                }
            }
            // Keep the last full-byte audit bound to these objects while the
            // native projection is built. A change rolls back the entire write.
            try beforeCommit?()
            try archiveVerification.validateStorageIdentity(at: archiveRoot)
            let factDigest: String? = row["fact_snapshot_sha256"]
            try db.execute(sql: "INSERT INTO phone_library_publication VALUES (?, ?, ?, ?, ?, ?, ?)", arguments: [key, source, report.manifestSHA256, report.factSnapshotSequence, factDigest, items.count, timestamp])
            return UUID(uuidString: source)!
        }
        onVerifiedArchive?(archiveVerification)
        return published
    }

    private static func component(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func group(_ db: Database, source: String, path: String, title: String, ordinal: Int64) throws {
        let components = path.split(separator: "/")
        let parent = components.count > 1 ? components.dropLast().joined(separator: "/") : nil
        try db.execute(sql: "INSERT OR IGNORE INTO source_folder(source_id, relative_path, parent_relative_path, name, source_ordinal) VALUES (?, ?, ?, ?, ?)", arguments: [source, path, parent, title, ordinal])
    }
    private func member(_ db: Database, source: String, path: String, asset: String, ordinal: Int64) throws {
        try db.execute(sql: "INSERT INTO phone_library_member VALUES (?, ?, ?, ?)", arguments: [source, path, asset, ordinal])
    }
}

/// Only live operations use transient phases. After restart the durable catalog
/// is authoritative; no remembered "verifying" operation is auto-resumed here.
@MainActor
enum PhoneImportTaskActivity {
    private static var phases: [UUID: RemoteImportTaskStatus.Phase] = [:]
    static func set(_ phase: RemoteImportTaskStatus.Phase?, for id: UUID) { phases[id] = phase }
    static func automaticCleanup(_ query: RemoteImportTaskQuery, nonce: UUID, hostID: UUID,
                                 deviceID: UUID, receiver: ImageAllMigrationTransferStore) async throws -> RemoteExportCleanupReceipt {
        guard phases[query.migrationID] == nil, let importer = PhoneArchiveImportProcessHolder.importer() else {
            throw ImageAllMigrationCleanupError.busy
        }
        let publisher = PhoneNativeLibraryPublisher(database: importer.database)
        return try await receiver.performAutomaticCleanup(query: query, authenticatedDeviceID: deviceID) { root in
            // Check the full task binding before releasing any bytes. Publication
            // remains untouched on every failure, including a lost HTTP response.
            guard try publisher.importTaskStatus(query)?.phase == .browsable else {
                throw ImageAllMigrationCleanupError.incompleteReferences
            }
            _ = try publisher.releaseStagingPayload(migrationID: query.migrationID, receiverRoot: root)
            return try publisher.exportCleanupReceipt(query, nonce: nonce, hostID: hostID, deviceID: deviceID)
        }
    }
    static func exportCleanupReceipt(_ query: RemoteImportTaskQuery, nonce: UUID, hostID: UUID,
                                     deviceID: UUID) async throws -> RemoteExportCleanupReceipt {
        guard phases[query.migrationID] == nil, let importer = PhoneArchiveImportProcessHolder.importer() else {
            throw ImageAllMigrationCleanupError.busy
        }
        return try await CatalogBlockingExecutor.shared.run(priority: .utility) {
            try PhoneNativeLibraryPublisher(database: importer.database).exportCleanupReceipt(
                query, nonce: nonce, hostID: hostID, deviceID: deviceID)
        }
    }
    static func status(_ query: RemoteImportTaskQuery) async throws -> RemoteImportTaskStatus? {
        // Do not queue the live phase query behind the long-running import on
        // CatalogBlockingExecutor. The HTTP route separately checks its owner.
        if let phase = phases[query.migrationID], phase == .verifying || phase == .publishing {
            return .init(query: query, phase: phase)
        }
        guard let importer = PhoneArchiveImportProcessHolder.importer() else {
            throw RemoteAPIError(code: .internalError, message: "Mac 图库尚未就绪")
        }
        let result = try await CatalogBlockingExecutor.shared.run(priority: .utility) {
            try PhoneNativeLibraryPublisher(database: importer.database).importTaskStatus(query)
        }
        if result?.phase == .browsable { return result }
        if let phase = phases[query.migrationID] { return .init(query: query, phase: phase) }
        return result
    }
}

@MainActor
enum PhoneNativeLibraryProcess {
    private static var recovery: Task<Void, Never>?
    private(set) static var lastError: String?

    static func waitForRecovery() async { await recovery?.value }

    static func recover(database: CatalogDatabase) {
        guard recovery == nil else { return }
        recovery = Task {
            defer { recovery = nil }
            do {
                let publisher = PhoneNativeLibraryPublisher(database: database)
                let batches = try await CatalogBlockingExecutor.shared.run(priority: .userInitiated) {
                    try publisher.unpublishedBatches()
                }
                for batch in batches {
                    do {
                        try await CatalogBlockingExecutor.shared.run(priority: .userInitiated) {
                            var stale = false
                            let parent: URL
                            if let bookmark = batch.targetBookmark {
                                parent = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope],
                                    relativeTo: nil, bookmarkDataIsStale: &stale)
                            } else {
                                parent = URL(fileURLWithPath: batch.targetParentPath)
                            }
                            let access = parent.startAccessingSecurityScopedResource()
                            defer { if access { parent.stopAccessingSecurityScopedResource() } }
                            _ = try publisher.publish(migrationID: batch.id, archiveRoot: parent.appendingPathComponent(
                                "ImageAll-Archive-\(batch.id.uuidString.lowercased())", isDirectory: true), reuseVerifiedContents: true)
                        }
                        lastError = nil
                        NotificationCenter.default.post(name: .phoneNativeLibraryChanged, object: nil)
                    } catch {
                        lastError = "手机归档暂未加入图库：\(error.localizedDescription)"
                        NotificationCenter.default.post(name: .phoneNativeLibraryChanged, object: nil)
                    }
                }
            } catch {
                lastError = "手机来源检查失败：\(error.localizedDescription)"
                NotificationCenter.default.post(name: .phoneNativeLibraryChanged, object: nil)
            }
        }
    }
}

/// Shared receiver ownership survives USB/server teardown. It is also used by
/// startup recovery, so cleanup never competes with our own second lease.
final class PhoneHostImportReceivers: @unchecked Sendable {
    static let shared = PhoneHostImportReceivers()
    private let lock = NSLock()
    private final class Entry {
        weak var store: ImageAllMigrationTransferStore?
        init(_ store: ImageAllMigrationTransferStore) { self.store = store }
    }
    private var stores: [String: Entry] = [:]
    private var scopes: [URL] = []
    func receiver(at root: URL, maximumBytes: Int64 = ImageAllMigrationTransferStore.defaultMaximumSessionBytes) throws -> ImageAllMigrationTransferStore {
        try lock.withLock {
            if let existing = stores[root.standardizedFileURL.path]?.store { return existing }
            let access = root.startAccessingSecurityScopedResource()
            do {
                let store = try ImageAllMigrationTransferStore(root: root, maximumSessionBytes: maximumBytes,
                    recoveryPolicy: .receiveProgress)
                stores[root.standardizedFileURL.path] = Entry(store)
                if access { scopes.append(root) }
                return store
            } catch {
                if access { root.stopAccessingSecurityScopedResource() }
                throw error
            }
        }
    }
}

/// Process-owned work, deliberately not a view task or an HTTP request task.
/// Durable enrollment is the receiver's immutable hostHandoff; stage/error are
/// advisory and all writes still pass the importer/publisher/cleanup gates.
@MainActor
enum PhoneHostImportProcess {
    private static var workers: [String: Task<Void, Never>] = [:]
    private static var requested: Set<String> = []
    private static var retries: Set<UUID> = []
    private(set) static var lastError: String?

    static func resumeConfigured() {
        guard let target = RemoteHostProcessHolder.migrationTransferTargetURL() else { return }
        do {
            let receiver = try PhoneHostImportReceivers.shared.receiver(at: target,
                maximumBytes: RemoteHostProcessHolder.migrationTransferMaximumBytes())
            wake(receiver: receiver, target: target)
        } catch { lastError = "Mac 接收任务恢复失败：\(error.localizedDescription)" }
    }

    static func retry(_ id: UUID) {
        retries.insert(id)
        resumeConfigured()
    }

    static func wake(receiver: ImageAllMigrationTransferStore, target: URL) {
        let key = target.standardizedFileURL.path
        requested.insert(key)
        guard workers[key] == nil else { return }
        workers[key] = Task {
            defer { workers[key] = nil }
            await PhoneNativeLibraryProcess.waitForRecovery()
            guard let importer = PhoneArchiveImportProcessHolder.importer() else { return }
            while requested.remove(key) != nil {
                do {
                    for job in try await receiver.hostJobs() where job.phase != .complete {
                        if job.phase == .needsAttention && !retries.contains(job.id) { continue }
                        retries.remove(job.id)
                        await process(job, receiver: receiver, target: target, importer: importer)
                    }
                    lastError = nil
                } catch { lastError = "Mac 接收任务检查失败：\(error.localizedDescription)" }
                NotificationCenter.default.post(name: .phoneNativeLibraryChanged, object: nil)
            }
        }
    }

    static func process(_ job: ImageAllMigrationHostJob, receiver: ImageAllMigrationTransferStore,
                        target: URL, importer: VerifiedPhoneArchiveImporter) async {
        let publisher = PhoneNativeLibraryPublisher(database: importer.database)
        var isPublished = false
        #if DEBUG
        var previousStage: ImageAllMigrationHostJob.Phase?
        var stageStart = ProcessInfo.processInfo.systemUptime
        var stageWall = Int64(Date().timeIntervalSince1970 * 1000)
        #endif
        func stage(_ phase: ImageAllMigrationHostJob.Phase) async throws {
            #if DEBUG
            if let previousStage {
                ImageAllMigrationArchiveDiagnostics.hostStage(previousStage.rawValue, root: target,
                    started: stageStart, wall: stageWall)
            }
            previousStage = phase
            stageStart = ProcessInfo.processInfo.systemUptime
            stageWall = Int64(Date().timeIntervalSince1970 * 1000)
            #endif
            try await receiver.recordHostState(.init(migrationID: job.id, phase: phase))
            NotificationCenter.default.post(name: .phoneNativeLibraryChanged, object: nil)
        }
        do {
            let published = try await CatalogBlockingExecutor.shared.run(priority: .userInitiated) {
                try publisher.importTaskStatus(job.query)?.phase == .browsable
            }
            isPublished = published
            let completionVerification: ImageAllMigrationVerification?
            let sourceVerification: ImageAllMigrationVerification?
            if !published {
                try await receiver.validateHostHandoff(job)
                try await stage(.verifying)
                PhoneImportTaskActivity.set(.verifying, for: job.id)
                let receipt = try await CatalogBlockingExecutor.shared.run(priority: .userInitiated) {
                    let package = target.appendingPathComponent(".imageall-transfer-\(job.id.uuidString.lowercased())/package")
                    return try importer.importArchive(from: package, to: target, reuseVerifiedContents: true)
                }
                sourceVerification = receipt.sourceVerification
                try await stage(.publishing)
                PhoneImportTaskActivity.set(.publishing, for: job.id)
                completionVerification = try await CatalogBlockingExecutor.shared.run(priority: .userInitiated) {
                    var verification: ImageAllMigrationVerification?
                    _ = try publisher.publish(importReceipt: receipt, reuseVerifiedContents: true, onVerifiedArchive: { verification = $0 })
                    return verification
                }
                isPublished = true
            } else { completionVerification = nil; sourceVerification = nil }
            PhoneImportTaskActivity.set(nil, for: job.id)
            try await stage(.cleanup)
            _ = try await receiver.performAutomaticCleanup(query: job.query, authenticatedDeviceID: job.deviceID) { root in
                guard try publisher.importTaskStatus(job.query)?.phase == .browsable else {
                    throw ImageAllMigrationCleanupError.incompleteReferences
                }
                return try publisher.releaseStagingPayload(migrationID: job.id, receiverRoot: root,
                    priorVerification: completionVerification, sourceVerification: sourceVerification,
                    reuseVerifiedContents: true)
            }
            try await stage(.complete)
        } catch {
            PhoneImportTaskActivity.set(.needsAttention, for: job.id)
            do {
                try await receiver.recordHostState(.init(migrationID: job.id, phase: .needsAttention,
                    error: (isPublished ? "已发布图库保持可用，暂存收尾未完成：" : "本批次尚未发布：") + failureDescription(error)))
            } catch { lastError = "Mac 任务状态保存失败：\(error.localizedDescription)" }
            NotificationCenter.default.post(name: .phoneNativeLibraryChanged, object: nil)
        }
    }

    private static func failureDescription(_ error: Error) -> String {
        guard let error = error as? ImageAllMigrationArchiveError else { return error.localizedDescription }
        switch error {
        case .resourceChanged: return "文件内容与清单不一致。现有文件已保留，请在 Mac 核查目标磁盘和接收副本。"
        case .resourceMissing: return "接收副本缺少文件。请检查 Mac 目标磁盘是否完整可用。"
        case .unsafeResourcePath: return "文件路径或对象身份发生变化，已停止处理并保留文件。"
        case .destinationOverlap: return "接收目录与目标目录的关系不符合导入要求，已停止处理。"
        case .destinationCollision: return "目标归档已存在且不能确认为本任务产物，未覆盖已有文件。"
        case .invalidManifest, .unsupportedVersion, .duplicateIdentity: return "接收清单格式或身份核对未通过，已保留资料。"
        case .publicationFailed: return "Mac 归档发布未完成，可在检查目标磁盘后重试。"
        }
    }
}
