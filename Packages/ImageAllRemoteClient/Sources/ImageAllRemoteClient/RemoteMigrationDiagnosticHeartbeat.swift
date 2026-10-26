import Foundation

/// Keeps long-running verification observable without retaining the UI owner.
/// Stop before writing a terminal outcome so no later tick replaces it.
@MainActor
public final class RemoteMigrationDiagnosticHeartbeat {
    private var task: Task<Void, Never>?
    public var isRunning: Bool { task != nil }
    public init() {}
    deinit { task?.cancel() }

    public func start(interval: Duration = .seconds(5), write: @escaping @MainActor () -> Void) {
        stop()
        precondition(interval > .zero)
        task = Task { @MainActor in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard !Task.isCancelled else { return }
                write()
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }
}
