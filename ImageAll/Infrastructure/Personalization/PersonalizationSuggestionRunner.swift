import Foundation

enum PersonalizationSuggestionRunner {
    static let claimOwner = "imageall-personalization-runner"
    static let refreshIntervalNs: UInt64 = 300_000_000

    private final class InFlightGate: @unchecked Sendable {
        private let lock = NSLock()
        private var inFlight = false

        var isInFlight: Bool {
            lock.lock()
            defer { lock.unlock() }
            return inFlight
        }

        func tryEnter() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !inFlight else { return false }
            inFlight = true
            return true
        }

        func leave() {
            lock.lock()
            defer { lock.unlock() }
            inFlight = false
        }
    }

    private static let inFlightGate = InFlightGate()

    private enum StepResult {
        case busy
        case completed(Bool)
    }

    static var isWorkerInFlight: Bool {
        inFlightGate.isInFlight
    }

    @MainActor
    static func startLoop(
        review: any PersonalizationReviewPort,
        refresh: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                switch await runOneStepResult(review: review, refresh: refresh) {
                case .busy:
                    try? await Task.sleep(nanoseconds: refreshIntervalNs)
                case let .completed(didWork):
                    if didWork {
                        await refresh()
                        try? await Task.sleep(nanoseconds: refreshIntervalNs)
                        continue
                    }
                    let retryDelay = await Task.detached {
                        try? review.nextSuggestionRetryDelayNanoseconds()
                    }.value
                    guard let retryDelay else { return }
                    await refresh()
                    try? await Task.sleep(nanoseconds: max(1_000_000, retryDelay))
                }
            }
        }
    }

    static func runOneStep(
        review: any PersonalizationReviewPort,
        refresh: (@MainActor () async -> Void)? = nil
    ) async -> Bool {
        switch await runOneStepResult(review: review, refresh: refresh) {
        case .busy:
            return false
        case let .completed(didWork):
            return didWork
        }
    }

    private static func runOneStepResult(
        review: any PersonalizationReviewPort,
        refresh: (@MainActor () async -> Void)?
    ) async -> StepResult {
        guard inFlightGate.tryEnter() else { return .busy }
        defer { inFlightGate.leave() }

        let refreshTicker: Task<Void, Never>?
        if let refresh {
            refreshTicker = Task { @MainActor in
                await refresh()
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: refreshIntervalNs)
                    guard !Task.isCancelled else { break }
                    await refresh()
                }
            }
        } else {
            refreshTicker = nil
        }
        defer { refreshTicker?.cancel() }

        return .completed(
            (try? await review.runPendingSuggestionJobsAsync(maxSteps: 1)) ?? false
        )
    }
}
