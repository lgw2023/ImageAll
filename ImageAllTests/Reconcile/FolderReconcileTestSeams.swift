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
        try inner.beginGeneration(input)
    }

    func commitAssetBatch(_ input: FolderAssetBatchInput) throws -> FolderBatchCommitResult {
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

struct ReconcileDatabaseFacts: Equatable {
    let scanGeneration: Int
    let dirtyEpoch: Int
    let assetCount: Int
    let fingerprintCount: Int
    let jobState: String
    let jobCheckpoint: Data?
    let progressCompleted: Int
    let leaseExpiresAtMs: Int64?
    let pendingSuccessorCount: Int
}

enum ReconcileDatabaseFactCapture {
    static func capture(database: CatalogDatabase, jobID: UUID, sourceID: UUID) throws -> ReconcileDatabaseFacts {
        try database.pool.read { db in
            let scanGeneration = try Int.fetchOne(
                db,
                sql: "SELECT scan_generation FROM source WHERE id = ?",
                arguments: [sourceID.uuidString.lowercased()]
            ) ?? 0
            let dirtyEpoch = try Int.fetchOne(
                db,
                sql: "SELECT dirty_epoch FROM source WHERE id = ?",
                arguments: [sourceID.uuidString.lowercased()]
            ) ?? 0
            let assetCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset") ?? 0
            let fingerprintCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM file_fingerprint") ?? 0
            let row = try Row.fetchOne(db, sql: "SELECT state, checkpoint, progress_completed, lease_expires_at_ms FROM job WHERE id = ?", arguments: [jobID.uuidString.lowercased()])
            let pendingSuccessorCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM job WHERE source_id = ? AND state = 'pending'",
                arguments: [sourceID.uuidString.lowercased()]
            ) ?? 0
            return ReconcileDatabaseFacts(
                scanGeneration: scanGeneration,
                dirtyEpoch: dirtyEpoch,
                assetCount: assetCount,
                fingerprintCount: fingerprintCount,
                jobState: row?["state"] ?? "",
                jobCheckpoint: row?["checkpoint"],
                progressCompleted: row?["progress_completed"] ?? 0,
                leaseExpiresAtMs: row?["lease_expires_at_ms"],
                pendingSuccessorCount: pendingSuccessorCount
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
