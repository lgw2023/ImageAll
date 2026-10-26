#if DEBUG
import Foundation

/// Bounded opt-in measurements for synthetic XCTest hosts. Disabled by default.
public enum ImageAllMigrationArchiveDiagnostics {
    public struct Sample: Codable, Sendable {
        public let stage: String
        public let path: String
        public let startedAtMs: Int64
        public let seconds: Double
        public let resourceReadSeconds: Double
        public let resourceBytes: Int64
    }
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var enabled = false
        var samples: [Sample] = []
    }
    private static let state = State()
    public static func start() {
        state.lock.withLock { state.samples.removeAll(); state.enabled = true }
    }
    public static func snapshot() -> [Sample] { state.lock.withLock { state.samples } }
    /// Same opt-in, bounded recorder for the Mac-owned pipeline. No persistent
    /// logging or media paths are produced when diagnostics are disabled.
    public static func hostStage(_ name: String, root: URL, started: TimeInterval, wall: Int64) {
        record(stage: "host-" + name, root: root, started: started, wall: wall)
    }
    static func record(stage: String, root: URL, started: TimeInterval, wall: Int64,
                       resourceReadSeconds: Double = 0, resourceBytes: Int64 = 0) {
        state.lock.withLock {
            guard state.enabled, state.samples.count < 256 else { return }
            state.samples.append(.init(stage: stage, path: root.path, startedAtMs: wall,
                seconds: ProcessInfo.processInfo.systemUptime - started,
                resourceReadSeconds: resourceReadSeconds, resourceBytes: resourceBytes))
        }
    }
}
#endif
