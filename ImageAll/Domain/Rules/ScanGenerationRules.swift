import Foundation

enum ScanGenerationRules {
    static func canMarkUnseenAssetMissing(completion: ScanGenerationCompletion) -> Bool {
        completion == .complete
    }

    static func generationCompletionInferredFromSourceState(_ state: SourceState) -> ScanGenerationCompletion? {
        switch state {
        case .active, .disabled, .unavailable, .authorizationRequired:
            nil
        }
    }

    /// A source is reconcile-clean when its latest completed reconcile job finished
    /// at the current `dirty_epoch`, meaning no filesystem or Photos changes remain
    /// to converge since the last successful scan.
    static func isSourceReconcileClean(
        dirtyEpoch: Int,
        lastCompletedJobStartedDirtyEpoch: Int?
    ) -> Bool {
        guard let lastCompletedJobStartedDirtyEpoch else { return false }
        return dirtyEpoch == lastCompletedJobStartedDirtyEpoch
    }
}
