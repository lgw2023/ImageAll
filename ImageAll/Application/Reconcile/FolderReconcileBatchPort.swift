import Foundation

/// Gives user-initiated filesystem mutations priority over background work.
///
/// Background readers cooperate at safe item boundaries. An interactive
/// recycle request first prevents new background items from starting, waits
/// for the current guarded item to finish, and only then begins source I/O.
/// This gives the mutation an acknowledged quiet window instead of merely
/// hoping that an already-running HDD read reaches its next checkpoint soon.
final class InteractiveIOPriorityGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var interactiveWorkCount = 0
    private var interactiveWaiterCount = 0
    private var backgroundWorkCount = 0

    func withInteractiveWork<T>(
        onWaitingForBackground: () -> Void = {},
        onReady: () -> Void = {},
        _ operation: () throws -> T
    ) rethrows -> T {
        let waitsForBackground = beginInteractiveWorkRequest()
        if waitsForBackground {
            onWaitingForBackground()
        }
        acquireInteractiveWork()
        onReady()
        defer { endInteractiveWork() }
        return try operation()
    }

    /// Async variant used by lifecycle commands that must keep the same
    /// exclusive mutation window across awaited catalog coordination.
    func withInteractiveWork<T>(
        onWaitingForBackground: () -> Void = {},
        onReady: () -> Void = {},
        _ operation: () async throws -> T
    ) async rethrows -> T {
        let waitsForBackground = beginInteractiveWorkRequest()
        if waitsForBackground {
            onWaitingForBackground()
        }
        acquireInteractiveWork()
        onReady()
        defer { endInteractiveWork() }
        return try await operation()
    }

    /// Marks one bounded background I/O item. Multiple background items may
    /// overlap, but writer preference prevents new ones from entering once a
    /// recycle request is waiting.
    func withBackgroundWork<T>(_ operation: () throws -> T) rethrows -> T {
        beginBackgroundWork()
        defer { endBackgroundWork() }
        return try operation()
    }

    func waitForInteractiveWorkToFinish() {
        condition.lock()
        while interactiveWorkCount > 0 || interactiveWaiterCount > 0 {
            condition.wait()
        }
        condition.unlock()
    }

    var hasInteractiveWork: Bool {
        condition.withLock {
            interactiveWorkCount > 0 || interactiveWaiterCount > 0
        }
    }

    var hasBackgroundWork: Bool {
        condition.withLock { backgroundWorkCount > 0 }
    }

    /// Returns whether the caller will have to wait for an already-running
    /// background item. The waiter is registered before returning so no later
    /// background work can jump ahead of the interactive request.
    private func beginInteractiveWorkRequest() -> Bool {
        condition.withLock {
            interactiveWaiterCount += 1
            return backgroundWorkCount > 0 || interactiveWorkCount > 0
        }
    }

    private func acquireInteractiveWork() {
        condition.lock()
        while backgroundWorkCount > 0 || interactiveWorkCount > 0 {
            condition.wait()
        }
        interactiveWaiterCount = max(0, interactiveWaiterCount - 1)
        interactiveWorkCount += 1
        condition.unlock()
    }

    private func endInteractiveWork() {
        condition.lock()
        interactiveWorkCount = max(0, interactiveWorkCount - 1)
        if interactiveWorkCount == 0 {
            condition.broadcast()
        }
        condition.unlock()
    }

    private func beginBackgroundWork() {
        condition.lock()
        while interactiveWorkCount > 0 || interactiveWaiterCount > 0 {
            condition.wait()
        }
        backgroundWorkCount += 1
        condition.unlock()
    }

    private func endBackgroundWork() {
        condition.lock()
        backgroundWorkCount = max(0, backgroundWorkCount - 1)
        if backgroundWorkCount == 0 {
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
