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
}
