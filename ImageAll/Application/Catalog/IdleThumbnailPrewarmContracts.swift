import Foundation

protocol IdleThumbnailPrewarmPreferenceStore: AnyObject {
    var isEnabled: Bool { get set }
}

protocol IdlePrewarmClock: Sendable {
    var now: TimeInterval { get }
}

struct SystemIdlePrewarmClock: IdlePrewarmClock {
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

enum IdleThumbnailPrewarmDefaults {
    static let idleThresholdSeconds: TimeInterval = 180
    static let monitorTickSeconds: TimeInterval = 1
    static let prewarmConcurrencyLimit = 1
}
