import Foundation
import GRDB

enum PhotosReconcileJobFactory {
    static let kind = "photos.reconcile.v1"
    static let payloadVersion = 1
    static let maxAttempts = 5
    static let priority = 10

    static func coalescingKey(sourceID: UUID) -> String {
        "\(kind):\(sourceID.uuidString.lowercased())"
    }

    static func makePayload(sourceID: UUID) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "contract_version": 1,
                "source_id": sourceID.uuidString.lowercased(),
            ]
        )
    }

    static func makeEnqueueCommand(
        jobID: UUID,
        sourceID: UUID,
        notBeforeMs: Int64
    ) throws -> EnqueueJobCommand {
        EnqueueJobCommand(
            id: jobID,
            kind: kind,
            payloadVersion: payloadVersion,
            payload: try makePayload(sourceID: sourceID),
            sourceID: sourceID,
            coalescingKey: coalescingKey(sourceID: sourceID),
            priority: priority,
            maxAttempts: maxAttempts,
            notBeforeMs: notBeforeMs
        )
    }
}

struct PhotosLibraryConnectionService: Sendable {
    let database: CatalogDatabase
    let access: any PhotosLibraryAccessPort
    let clock: any JobClock
    let idGenerator: @Sendable () -> UUID

    init(
        database: CatalogDatabase,
        access: any PhotosLibraryAccessPort,
        clock: any JobClock = SystemJobClock(),
        idGenerator: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.database = database
        self.access = access
        self.clock = clock
        self.idGenerator = idGenerator
    }

    func connect() async throws -> ConnectPhotosOutcome {
        let status: PhotosAuthorizationState
        switch access.authorizationState() {
        case .notDetermined:
            status = await access.requestAuthorization()
        case let current:
            status = current
        }

        switch status {
        case .authorized:
            break
        case .denied, .notDetermined:
            throw PhotosLibraryError.authorizationDenied
        case .restricted:
            throw PhotosLibraryError.authorizationRestricted
        }

        do {
            return try await database.pool.write { db in
                let existingIDString = try String.fetchOne(
                    db,
                    sql: "SELECT id FROM source WHERE kind = 'photos' ORDER BY created_at_ms, id LIMIT 1"
                )
                let sourceID: UUID
                let outcome: ConnectPhotosOutcome
                if let existingIDString, let existingID = UUID(uuidString: existingIDString) {
                    sourceID = existingID
                    outcome = .alreadyConnected(sourceID: existingID)
                    try db.execute(
                        sql: "UPDATE source SET state = 'active', updated_at_ms = ? WHERE id = ?",
                        arguments: [clock.nowMs, existingIDString]
                    )
                } else {
                    sourceID = idGenerator()
                    let sourceIDString = sourceID.uuidString.lowercased()
                    try db.execute(
                        sql: """
                        INSERT INTO source (
                            id, kind, display_name, bookmark, state,
                            created_at_ms, updated_at_ms
                        ) VALUES (?, 'photos', 'Apple Photos', NULL, 'active', ?, ?)
                        """,
                        arguments: [sourceIDString, clock.nowMs, clock.nowMs]
                    )
                    outcome = .connected(sourceID: sourceID)
                }

                try enqueueIfNeeded(sourceID: sourceID, db: db)
                return outcome
            }
        } catch let error as PhotosLibraryError {
            throw error
        } catch {
            throw PhotosLibraryError.persistenceFailure
        }
    }

    func enqueueReconcile(sourceID: UUID) throws {
        try database.pool.write { db in
            let isActivePhotosSource = try Bool.fetchOne(
                db,
                sql: """
                SELECT EXISTS(
                    SELECT 1 FROM source WHERE id = ? AND kind = 'photos' AND state = 'active'
                )
                """,
                arguments: [sourceID.uuidString.lowercased()]
            ) ?? false
            guard isActivePhotosSource else { throw PhotosLibraryError.libraryUnavailable }
            try enqueueIfNeeded(sourceID: sourceID, db: db)
        }
    }

    func disable(sourceID: UUID) throws -> DisableFolderOutcome {
        try database.pool.write { db in
            try db.execute(
                sql: """
                UPDATE source SET state = 'disabled', updated_at_ms = ?
                WHERE id = ? AND kind = 'photos'
                """,
                arguments: [clock.nowMs, sourceID.uuidString.lowercased()]
            )
            guard db.changesCount == 1 else { throw PhotosLibraryError.libraryUnavailable }
            try db.execute(
                sql: """
                UPDATE job SET
                    state = 'cancelled', control_request = 'none',
                    lease_owner = NULL, lease_expires_at_ms = NULL, updated_at_ms = ?
                WHERE source_id = ? AND kind = ?
                    AND state IN ('pending', 'paused', 'retryableFailed')
                """,
                arguments: [clock.nowMs, sourceID.uuidString.lowercased(), PhotosReconcileJobFactory.kind]
            )
            try db.execute(
                sql: """
                UPDATE job SET control_request = 'cancel', updated_at_ms = ?
                WHERE source_id = ? AND kind = ? AND state = 'running'
                """,
                arguments: [clock.nowMs, sourceID.uuidString.lowercased(), PhotosReconcileJobFactory.kind]
            )
            return .disabled(sourceID: sourceID)
        }
    }

    func fetchSources() throws -> [LibrarySourceSummary] {
        try database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT id, kind, display_name, state FROM source ORDER BY created_at_ms, id"
            ).compactMap { row in
                guard let id = UUID(uuidString: row["id"]),
                      let kind = SourceKind(rawValue: row["kind"]),
                      let state = SourceState(rawValue: row["state"])
                else { return nil }
                return LibrarySourceSummary(
                    id: id,
                    kind: kind,
                    displayName: row["display_name"],
                    state: state
                )
            }
        }
    }

    private func enqueueIfNeeded(sourceID: UUID, db: Database) throws {
        let activeJobExists = try Bool.fetchOne(
            db,
            sql: """
            SELECT EXISTS(
                SELECT 1 FROM job
                WHERE coalescing_key = ?
                    AND state IN ('pending', 'running', 'paused', 'retryableFailed')
            )
            """,
            arguments: [PhotosReconcileJobFactory.coalescingKey(sourceID: sourceID)]
        ) ?? false
        guard !activeJobExists else { return }
        let command = try PhotosReconcileJobFactory.makeEnqueueCommand(
            jobID: idGenerator(),
            sourceID: sourceID,
            notBeforeMs: clock.nowMs
        )
        try JobInsertInTransaction.insertPendingJob(db, command: command, nowMs: clock.nowMs)
    }
}
