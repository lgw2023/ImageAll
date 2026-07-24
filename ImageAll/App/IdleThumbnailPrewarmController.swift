import AppKit
import Foundation

/// Watches for user inactivity and runs a low-priority thumbnail prewarm callback.
@MainActor
final class IdleThumbnailPrewarmController {
    private let preferenceStore: any IdleThumbnailPrewarmPreferenceStore
    private let clock: any IdlePrewarmClock
    private let idleThresholdSeconds: TimeInterval
    private let monitorTickSeconds: TimeInterval
    private let installEventMonitor: Bool

    private var lastInteractionAt: TimeInterval
    private var monitorTask: Task<Void, Never>?
    private var prewarmTask: Task<Void, Never>?
    private var eventMonitor: Any?
    private var isStarted = false
    private var prewarmGeneration = 0

    private let onPrewarm: @MainActor (_ generation: Int) async -> Void

    init(
        preferenceStore: any IdleThumbnailPrewarmPreferenceStore,
        clock: any IdlePrewarmClock = SystemIdlePrewarmClock(),
        idleThresholdSeconds: TimeInterval = IdleThumbnailPrewarmDefaults.idleThresholdSeconds,
        monitorTickSeconds: TimeInterval = IdleThumbnailPrewarmDefaults.monitorTickSeconds,
        installEventMonitor: Bool = true,
        onPrewarm: @escaping @MainActor (_ generation: Int) async -> Void
    ) {
        self.preferenceStore = preferenceStore
        self.clock = clock
        self.idleThresholdSeconds = idleThresholdSeconds
        self.monitorTickSeconds = monitorTickSeconds
        self.installEventMonitor = installEventMonitor
        self.onPrewarm = onPrewarm
        lastInteractionAt = clock.now
    }

    var isEnabled: Bool {
        get { preferenceStore.isEnabled }
        set {
            preferenceStore.isEnabled = newValue
            if !newValue {
                cancelPrewarm()
            } else {
                evaluateIdleState()
            }
        }
    }

    var isPrewarming: Bool {
        prewarmTask != nil
    }

    var currentPrewarmGeneration: Int {
        prewarmGeneration
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        lastInteractionAt = clock.now
        if installEventMonitor {
            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [
                    .keyDown,
                    .keyUp,
                    .flagsChanged,
                    .leftMouseDown,
                    .rightMouseDown,
                    .otherMouseDown,
                    .leftMouseDragged,
                    .rightMouseDragged,
                    .otherMouseDragged,
                    .scrollWheel,
                    .magnify,
                    .rotate,
                    .gesture,
                    .mouseMoved,
                ]
            ) { [weak self] event in
                Task { @MainActor in
                    self?.noteUserInteraction()
                }
                return event
            }
        }
        monitorTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                self.evaluateIdleState()
                let tickNanoseconds = UInt64(max(self.monitorTickSeconds, 0.05) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: tickNanoseconds)
            }
        }
    }

    func stop() {
        isStarted = false
        monitorTask?.cancel()
        monitorTask = nil
        cancelPrewarm()
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    func noteUserInteraction() {
        lastInteractionAt = clock.now
        cancelPrewarm()
    }

    /// Test / manual hook to re-evaluate without waiting for the monitor tick.
    func evaluateIdleState() {
        guard isStarted else { return }
        guard preferenceStore.isEnabled else {
            cancelPrewarm()
            return
        }
        let idleFor = clock.now - lastInteractionAt
        guard idleFor >= idleThresholdSeconds else {
            return
        }
        startPrewarmIfNeeded()
    }

    private func startPrewarmIfNeeded() {
        guard prewarmTask == nil else { return }
        prewarmGeneration &+= 1
        let generation = prewarmGeneration
        prewarmTask = Task { [weak self] in
            guard let self else { return }
            await self.onPrewarm(generation)
            await MainActor.run {
                if self.prewarmTask != nil, self.prewarmGeneration == generation {
                    self.prewarmTask = nil
                }
            }
        }
    }

    private func cancelPrewarm() {
        prewarmGeneration &+= 1
        prewarmTask?.cancel()
        prewarmTask = nil
    }
}
