import Foundation

/// User-controlled suggestion enqueue thresholds (ADR-040).
/// Method keys match `TrainingRunMethod` / ST-P2.
typealias SuggestionScoreThresholdMethod = TrainingRunMethod

enum SuggestionThresholdError: Error, Equatable, Sendable {
    case invalidScore
    case tagNotFound
    case persistenceFailure
}

struct SuggestionThresholdDefaults: Equatable, Sendable {
    var featureKnn: Double
    var personalCentroid: Double
    var personalAdamW: Double

    static let factory = SuggestionThresholdDefaults(
        featureKnn: 0,
        personalCentroid: 0,
        personalAdamW: 0
    )

    subscript(method: SuggestionScoreThresholdMethod) -> Double {
        get {
            switch method {
            case .featureKnn: featureKnn
            case .personalCentroid: personalCentroid
            case .personalAdamW: personalAdamW
            }
        }
        set {
            switch method {
            case .featureKnn: featureKnn = newValue
            case .personalCentroid: personalCentroid = newValue
            case .personalAdamW: personalAdamW = newValue
            }
        }
    }
}

struct SuggestionTagThresholdOverrideRow: Equatable, Sendable, Identifiable {
    let tagID: UUID
    let displayName: String
    /// Only methods that have an override row.
    let overrides: [SuggestionScoreThresholdMethod: Double]

    var id: UUID { tagID }
}

struct SuggestionThresholdReference: Equatable, Sendable {
    let minScore: Double
    /// Traceable accepted scores used when the separator is based on both classes.
    let acceptedSampleCount: Int
    let rejectedSampleCount: Int

    init(
        minScore: Double,
        acceptedSampleCount: Int = 0,
        rejectedSampleCount: Int
    ) {
        self.minScore = minScore
        self.acceptedSampleCount = acceptedSampleCount
        self.rejectedSampleCount = rejectedSampleCount
    }
}

protocol SuggestionThresholdPort: Sendable {
    func defaults() throws -> SuggestionThresholdDefaults
    func setDefault(
        method: SuggestionScoreThresholdMethod,
        minScore: Double,
        updatedAtMs: Int64
    ) throws
    func overrideMinScore(
        tagID: UUID,
        method: SuggestionScoreThresholdMethod
    ) throws -> Double?
    func setOverride(
        tagID: UUID,
        method: SuggestionScoreThresholdMethod,
        minScore: Double,
        updatedAtMs: Int64
    ) throws
    func clearOverride(
        tagID: UUID,
        method: SuggestionScoreThresholdMethod
    ) throws
    func effectiveMinScore(
        tagID: UUID,
        method: SuggestionScoreThresholdMethod
    ) throws -> Double
    /// Read-only sample-based reference for the same tag and method.
    /// Prefers the midpoint between median accepted and median rejected scores when both
    /// classes have at least five traceable scores; otherwise falls back to the 90th
    /// percentile of recent rejected scores. Returns nil until enough scores exist.
    func referenceSuggestion(
        tagID: UUID,
        method: SuggestionScoreThresholdMethod
    ) throws -> SuggestionThresholdReference?
    func listTagOverrides() throws -> [SuggestionTagThresholdOverrideRow]
    /// Deletes pending suggestions with `score <= minScore` for one tag + method.
    /// Does not rescan the library. Returns deleted row count.
    func prunePendingBelowThreshold(
        tagID: UUID,
        method: SuggestionScoreThresholdMethod,
        minScore: Double
    ) throws -> Int
}

extension SuggestionGenerationMethod {
    var thresholdMethod: SuggestionScoreThresholdMethod {
        switch self {
        case .featureKnn:
            return .featureKnn
        case .personalModel:
            return .personalCentroid
        case .personalAdamW:
            return .personalAdamW
        }
    }
}

enum SuggestionScoreThresholdMethodPresentation {
    static func displayName(_ method: SuggestionScoreThresholdMethod) -> String {
        switch method {
        case .featureKnn: "特征向量"
        case .personalCentroid: "个人模型"
        case .personalAdamW: "超级个人模型"
        }
    }
}
