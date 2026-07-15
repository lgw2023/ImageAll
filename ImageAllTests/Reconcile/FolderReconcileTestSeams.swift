import Foundation
import GRDB
import XCTest
@testable import ImageAll

// MARK: - Infrastructure protocol fakes (tests only)

final class ProbeFailingFileResourceReader: FolderFileResourceReading, @unchecked Sendable {
    private let inner = FoundationFolderFileResourceReader()
    private let failResourceIDURL: URL

    init(failResourceIDFor url: URL) {
        failResourceIDURL = url
    }

    func fileSizeBytes(for url: URL) -> Int64? {
        inner.fileSizeBytes(for: url)
    }

    func modifiedAtNs(for url: URL) -> Int64? {
        inner.modifiedAtNs(for: url)
    }

    func resourceIdentifier(for url: URL) -> Data? {
        if url == failResourceIDURL { return nil }
        return inner.resourceIdentifier(for: url)
    }
}

final class NilResourceIDFileResourceReader: FolderFileResourceReading, @unchecked Sendable {
    private let inner = FoundationFolderFileResourceReader()

    func fileSizeBytes(for url: URL) -> Int64? {
        inner.fileSizeBytes(for: url)
    }

    func modifiedAtNs(for url: URL) -> Int64? {
        inner.modifiedAtNs(for: url)
    }

    func resourceIdentifier(for url: URL) -> Data? {
        nil
    }
}

final class FailingFileResourceReader: FolderFileResourceReading, @unchecked Sendable {
    private let inner = FoundationFolderFileResourceReader()
    private let failSizeURL: URL?

    init(failSizeFor url: URL) {
        failSizeURL = url
    }

    func fileSizeBytes(for url: URL) -> Int64? {
        if url == failSizeURL { return nil }
        return inner.fileSizeBytes(for: url)
    }

    func modifiedAtNs(for url: URL) -> Int64? {
        inner.modifiedAtNs(for: url)
    }

    func resourceIdentifier(for url: URL) -> Data? {
        inner.resourceIdentifier(for: url)
    }
}

final class FailingEnumerationResourceReader: FolderEnumerationResourceReading, @unchecked Sendable {
    private let inner = FoundationEnumerationResourceReader()
    private let failURL: URL?

    init(failFor url: URL) {
        failURL = url
    }

    func resourceValues(for url: URL, keys: Set<URLResourceKey>) throws -> URLResourceValues {
        if url == failURL {
            throw NSError(domain: "FailingEnumerationResourceReader", code: 1)
        }
        return try inner.resourceValues(for: url, keys: keys)
    }
}

final class AliasMarkingEnumerationResourceReader: FolderEnumerationResourceReading, @unchecked Sendable {
    private let inner = FoundationEnumerationResourceReader()
    private let aliasURL: URL

    init(aliasURL: URL) {
        self.aliasURL = aliasURL.standardizedFileURL
    }

    func resourceValues(for url: URL, keys: Set<URLResourceKey>) throws -> URLResourceValues {
        try inner.resourceValues(for: url, keys: keys)
    }

    func isAliasFile(for url: URL) -> Bool? {
        url.standardizedFileURL == aliasURL ? true : nil
    }
}

final class FlippingFolderRootResourceReader: FolderRootResourceValueReading, @unchecked Sendable {
    private let inner = FoundationFolderRootResourceReader()
    private let failAfterCall: Int
    private var callCount = 0

    init(failAfterCall: Int) {
        self.failAfterCall = failAfterCall
    }

    func resourceValues(for url: URL) throws -> FolderRootResourceSnapshot {
        callCount += 1
        if callCount > failAfterCall {
            throw NSError(domain: "FlippingFolderRootResourceReader", code: 1)
        }
        return try inner.resourceValues(for: url)
    }
}

// MARK: - Batch port spy

final class RecordingReconcileBatchPort: FolderReconcileBatchPort, @unchecked Sendable {
    private let inner: GRDBFolderReconcileRepository
    private(set) var committedBatchSizes: [Int] = []
    private(set) var beginEnumeratedEntries: Int?
    private(set) var committedEnumeratedEntries: [Int] = []
    var afterCommit: ((Int) throws -> Void)?

    init(queue: GRDBJobQueue) {
        inner = GRDBFolderReconcileRepository(queue: queue)
    }

    func fetchJobContext(jobID: UUID) throws -> FolderReconcileJobContext {
        try inner.fetchJobContext(jobID: jobID)
    }

    func lookupMoveCandidates(
        sourceID: UUID,
        resourceID: Data,
        excludingGeneration: Int
    ) throws -> [FolderMoveCandidate] {
        try inner.lookupMoveCandidates(
            sourceID: sourceID,
            resourceID: resourceID,
            excludingGeneration: excludingGeneration
        )
    }

    func beginGeneration(_ input: FolderBeginGenerationInput) throws -> FolderBeginGenerationResult {
        let result = try inner.beginGeneration(input)
        beginEnumeratedEntries = result.checkpoint.enumeratedEntries
        return result
    }

    func commitAssetBatch(_ input: FolderAssetBatchInput) throws -> FolderBatchCommitResult {
        committedEnumeratedEntries.append(input.checkpoint.enumeratedEntries)
        committedBatchSizes.append(input.observations.count)
        let result = try inner.commitAssetBatch(input)
        if let afterCommit {
            try afterCommit(committedBatchSizes.count)
        }
        return result
    }

    func completeGeneration(_ input: FolderCompleteGenerationInput) throws -> FolderCompleteGenerationResult {
        try inner.completeGeneration(input)
    }

    func stopIncomplete(_ input: FolderStopIncompleteInput) throws -> FolderBatchCommitResult {
        try inner.stopIncomplete(input)
    }
}

struct SpyJobLeaseContextProvider: JobLeaseContextProviding {
    let queue: GRDBJobQueue
    let batchPort: any FolderReconcileBatchPort

    func makeLeaseContext(leaseDurationMs: Int64) -> JobLeaseExecutionContext {
        JobLeaseExecutionContext(
            leaseDurationMs: leaseDurationMs,
            reconcileBatch: batchPort,
            jobLookup: batchPort
        )
    }
}

// MARK: - Database fact snapshots for fault rollback

struct SourceFactRow: Equatable {
    let id: String
    let kind: String
    let displayName: String
    let bookmark: Data?
    let syncCursor: Data?
    let scanGeneration: Int
    let dirtyEpoch: Int
    let state: String
    let createdAtMs: Int64
    let updatedAtMs: Int64
}

struct AssetFactRow: Equatable {
    let id: String
    let sourceID: String
    let locatorKind: String
    let relativePath: String?
    let fileName: String?
    let photosLocalIdentifier: String?
    let locatorState: String
    let mediaType: String
    let width: Int?
    let height: Int?
    let mediaCreatedAtMs: Int64?
    let mediaModifiedAtMs: Int64?
    let contentRevision: Int
    let lastSeenGeneration: Int?
    let availability: String
    let recordCreatedAtMs: Int64
    let recordUpdatedAtMs: Int64
}

struct FingerprintFactRow: Equatable {
    let assetID: String
    let sizeBytes: Int64
    let modifiedAtNs: Int64
    let resourceID: Data?
    let sha256: Data?
}

struct JobFactRow: Equatable {
    let id: String
    let kind: String
    let payloadVersion: Int
    let payload: Data
    let sourceID: String?
    let coalescingKey: String?
    let checkpointVersion: Int?
    let checkpoint: Data?
    let scanGeneration: Int?
    let startedDirtyEpoch: Int?
    let state: String
    let controlRequest: String
    let priority: Int
    let attempts: Int
    let maxAttempts: Int
    let notBeforeMs: Int64
    let leaseOwner: String?
    let leaseExpiresAtMs: Int64?
    let progressCompleted: Int
    let progressTotal: Int?
    let lastErrorCode: String?
    let lastErrorMessage: String?
    let createdAtMs: Int64
    let updatedAtMs: Int64
}

struct ReconcileDatabaseFacts: Equatable {
    let source: SourceFactRow
    let assets: [AssetFactRow]
    let fingerprints: [FingerprintFactRow]
    let jobs: [JobFactRow]
}

enum ReconcileDatabaseFactCapture {
    static func capture(database: CatalogDatabase, jobID: UUID, sourceID: UUID) throws -> ReconcileDatabaseFacts {
        let sourceIDLower = sourceID.uuidString.lowercased()
        _ = jobID
        return try database.pool.read { db in
            let sourceRow = try Row.fetchOne(
                db,
                sql: """
                SELECT id, kind, display_name, bookmark, sync_cursor, scan_generation, dirty_epoch,
                       state, created_at_ms, updated_at_ms
                FROM source WHERE id = ?
                """,
                arguments: [sourceIDLower]
            )
            let source = SourceFactRow(
                id: sourceRow?["id"] ?? "",
                kind: sourceRow?["kind"] ?? "",
                displayName: sourceRow?["display_name"] ?? "",
                bookmark: sourceRow?["bookmark"],
                syncCursor: sourceRow?["sync_cursor"],
                scanGeneration: sourceRow?["scan_generation"] ?? 0,
                dirtyEpoch: sourceRow?["dirty_epoch"] ?? 0,
                state: sourceRow?["state"] ?? "",
                createdAtMs: sourceRow?["created_at_ms"] ?? 0,
                updatedAtMs: sourceRow?["updated_at_ms"] ?? 0
            )

            let assetRows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, source_id, locator_kind, relative_path, file_name, photos_local_identifier,
                       locator_state, media_type, width, height, media_created_at_ms, media_modified_at_ms,
                       content_revision, last_seen_generation, availability,
                       record_created_at_ms, record_updated_at_ms
                FROM asset WHERE source_id = ?
                ORDER BY id
                """,
                arguments: [sourceIDLower]
            )
            let assets = assetRows.map { row in
                AssetFactRow(
                    id: row["id"],
                    sourceID: row["source_id"],
                    locatorKind: row["locator_kind"],
                    relativePath: row["relative_path"],
                    fileName: row["file_name"],
                    photosLocalIdentifier: row["photos_local_identifier"],
                    locatorState: row["locator_state"],
                    mediaType: row["media_type"],
                    width: row["width"],
                    height: row["height"],
                    mediaCreatedAtMs: row["media_created_at_ms"],
                    mediaModifiedAtMs: row["media_modified_at_ms"],
                    contentRevision: row["content_revision"],
                    lastSeenGeneration: row["last_seen_generation"],
                    availability: row["availability"],
                    recordCreatedAtMs: row["record_created_at_ms"],
                    recordUpdatedAtMs: row["record_updated_at_ms"]
                )
            }

            let fingerprintRows = try Row.fetchAll(
                db,
                sql: """
                SELECT f.asset_id, f.size_bytes, f.modified_at_ns, f.resource_id, f.sha256
                FROM file_fingerprint f
                INNER JOIN asset a ON a.id = f.asset_id
                WHERE a.source_id = ?
                ORDER BY f.asset_id
                """,
                arguments: [sourceIDLower]
            )
            let fingerprints = fingerprintRows.map { row in
                FingerprintFactRow(
                    assetID: row["asset_id"],
                    sizeBytes: row["size_bytes"],
                    modifiedAtNs: row["modified_at_ns"],
                    resourceID: row["resource_id"],
                    sha256: row["sha256"]
                )
            }

            let jobRows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, kind, payload_version, payload, source_id, coalescing_key,
                       checkpoint_version, checkpoint, scan_generation, started_dirty_epoch,
                       state, control_request, priority, attempts, max_attempts, not_before_ms,
                       lease_owner, lease_expires_at_ms, progress_completed, progress_total,
                       last_error_code, last_error_message, created_at_ms, updated_at_ms
                FROM job WHERE source_id = ?
                ORDER BY id
                """,
                arguments: [sourceIDLower]
            )
            let jobs = jobRows.map { row in
                JobFactRow(
                    id: row["id"],
                    kind: row["kind"],
                    payloadVersion: row["payload_version"],
                    payload: row["payload"],
                    sourceID: row["source_id"],
                    coalescingKey: row["coalescing_key"],
                    checkpointVersion: row["checkpoint_version"],
                    checkpoint: row["checkpoint"],
                    scanGeneration: row["scan_generation"],
                    startedDirtyEpoch: row["started_dirty_epoch"],
                    state: row["state"],
                    controlRequest: row["control_request"],
                    priority: row["priority"],
                    attempts: row["attempts"],
                    maxAttempts: row["max_attempts"],
                    notBeforeMs: row["not_before_ms"],
                    leaseOwner: row["lease_owner"],
                    leaseExpiresAtMs: row["lease_expires_at_ms"],
                    progressCompleted: row["progress_completed"],
                    progressTotal: row["progress_total"],
                    lastErrorCode: row["last_error_code"],
                    lastErrorMessage: row["last_error_message"],
                    createdAtMs: row["created_at_ms"],
                    updatedAtMs: row["updated_at_ms"]
                )
            }

            return ReconcileDatabaseFacts(
                source: source,
                assets: assets,
                fingerprints: fingerprints,
                jobs: jobs
            )
        }
    }
}

// MARK: - Advancing clock queue for lease renewal tests

final class AdvancingJobClock: JobClock, @unchecked Sendable {
    private(set) var nowMs: Int64

    init(startMs: Int64) {
        nowMs = startMs
    }

    func advance(by ms: Int64) {
        nowMs += ms
    }
}

enum ReconcileStrictJSONMutation {
    static func payloadJSON(sourceID: UUID) -> String {
        #"{"contract_version":1,"source_id":"\#(sourceID.uuidString.lowercased())"}"#
    }

    static let canonicalCheckpointJSON = """
    {"contract_version":1,"generation":1,"started_dirty_epoch":0,"attempt":1,\
    "enumerated_entries":0,"candidate_files":0,"committed_assets":0,"ignored_entries":0,\
    "unsupported_assets":0,"unreadable_assets":0,"identity_conflicts":0}
    """
}
