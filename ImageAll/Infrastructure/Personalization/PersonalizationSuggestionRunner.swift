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
                let didWork = await runOneStep(review: review, refresh: refresh)
                guard didWork else { return }
                await refresh()
                try? await Task.sleep(nanoseconds: refreshIntervalNs)
            }
        }
    }

    static func runOneStep(
        review: any PersonalizationReviewPort,
        refresh: (@MainActor () async -> Void)? = nil
    ) async -> Bool {
        guard inFlightGate.tryEnter() else { return false }
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

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let didWork = (try? review.runPendingSuggestionJobs(maxSteps: 1)) ?? false
                continuation.resume(returning: didWork)
            }
        }
    }
}
