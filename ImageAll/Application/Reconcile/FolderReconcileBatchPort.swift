import Foundation

/// Gives user-initiated filesystem mutations priority over background work.
///
/// Background scanners wait only at safe item boundaries, so an in-flight
/// database batch is never abandoned. A recycle operation holds an interactive
/// lease while it validates, copies, verifies, and unlinks the source. This
/// avoids competing seeks on mechanical disks without weakening durability.
final class InteractiveIOPriorityGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var interactiveWorkCount = 0

    func withInteractiveWork<T>(_ operation: () throws -> T) rethrows -> T {
        beginInteractiveWork()
        defer { endInteractiveWork() }
        return try operation()
    }

    func waitForInteractiveWorkToFinish() {
        condition.lock()
        while interactiveWorkCount > 0 {
            condition.wait()
        }
        condition.unlock()
    }

    var hasInteractiveWork: Bool {
        condition.withLock { interactiveWorkCount > 0 }
    }

    private func beginInteractiveWork() {
        condition.withLock {
            interactiveWorkCount += 1
        }
    }

    private func endInteractiveWork() {
        condition.lock()
        interactiveWorkCount = max(0, interactiveWorkCount - 1)
        if interactiveWorkCount == 0 {
            condition.broadcast()
        }
        condition.unlock()
    }
}

private extension NSCondition {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}

struct FolderReconcileJobContext: Equatable, Sendable {
    let jobID: UUID
    let kind: String
    let payloadVersion: Int
    let sourceID: UUID?
    let scanGeneration: Int?
    let startedDirtyEpoch: Int?
    let progressCompleted: Int
}

protocol FolderReconcileJobLookupPort: Sendable {
    func fetchJobContext(jobID: UUID) throws -> FolderReconcileJobContext
}

struct FolderMoveCandidate: Equatable, Sendable {
    let assetID: UUID
    let relativePath: String
    let sizeBytes: Int64
    let modifiedAtNs: Int64
    let resourceID: Data?
}

protocol FolderReconcileBatchPort: FolderReconcileJobLookupPort, Sendable {
    func beginGeneration(_ input: FolderBeginGenerationInput) throws -> FolderBeginGenerationResult
    func commitAssetBatch(_ input: FolderAssetBatchInput) throws -> FolderBatchCommitResult
    func completeGeneration(_ input: FolderCompleteGenerationInput) throws -> FolderCompleteGenerationResult
    func stopIncomplete(_ input: FolderStopIncompleteInput) throws -> FolderBatchCommitResult
    func lookupReusableObservation(
        sourceID: UUID,
        relativePath: String,
        fileName: String,
        sizeBytes: Int64,
        modifiedAtNs: Int64,
        resourceID: Data?
    ) throws -> FolderReconcileAssetObservation?
    func lookupMoveCandidates(sourceID: UUID, resourceID: Data, excludingGeneration: Int) throws -> [FolderMoveCandidate]
}

extension FolderReconcileBatchPort {
    func lookupReusableObservation(
        sourceID: UUID,
        relativePath: String,
        fileName: String,
        sizeBytes: Int64,
        modifiedAtNs: Int64,
        resourceID: Data?
    ) throws -> FolderReconcileAssetObservation? {
        nil
    }
}
