import Foundation

enum CatalogProcessLockAcquireResult: Sendable {
    case acquired(CatalogProcessLockToken)
    case alreadyRunning
}

enum CatalogProcessLockError: Error, Equatable, Sendable {
    case ioFailure
}

/// NSLock serializes one-time release; fd ownership lives in releaseHandler only.
final class CatalogProcessLockToken: @unchecked Sendable {
    private let releaseHandler: @Sendable () -> Void
    private let lock = NSLock()
    private var isReleased = false
    private var skipReleaseHandler = false

    init(releaseHandler: @escaping @Sendable () -> Void) {
        self.releaseHandler = releaseHandler
    }

    deinit {
        release()
    }

    /// Marks the token consumed without running the release handler; the OS lock stays held until process exit.
    func abandonKeepingLockHeld() {
        lock.lock()
        defer { lock.unlock() }
        guard !isReleased else { return }
        isReleased = true
        skipReleaseHandler = true
    }

    func release() {
        lock.lock()
        defer { lock.unlock() }
        guard !isReleased else { return }
        isReleased = true
        guard !skipReleaseHandler else { return }
        releaseHandler()
    }
}

protocol CatalogProcessLocking: Sendable {
    func tryAcquire(at lockFileURL: URL) throws -> CatalogProcessLockAcquireResult
}
