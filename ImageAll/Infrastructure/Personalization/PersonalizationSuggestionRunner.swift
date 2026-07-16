import Foundation

enum PersonalizationSuggestionRunner {
    static let claimOwner = "imageall-personalization-runner"

    @MainActor
    static func startLoop(
        review: any PersonalizationReviewPort,
        refresh: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                let didWork = await runOneStep(review: review)
                if didWork {
                    await refresh()
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
    }

    static func runOneStep(review: any PersonalizationReviewPort) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let didWork = (try? review.runPendingSuggestionJobs(maxSteps: 1)) ?? false
                continuation.resume(returning: didWork)
            }
        }
    }
}
