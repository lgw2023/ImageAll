import Foundation

/// Personal suggestion activation slot (`personal_suggestion_model.method`).
enum PersonalSuggestionMethod: String, Equatable, Sendable, CaseIterable {
    case personalCentroid
    case personalAdamW

    static let linearHeadBundleID = "app.personal.linear-head.v1"
    static let adamWHeadBundleID = "app.personal.adamw-head.v1"

    init?(bundleID: String) {
        switch bundleID {
        case Self.linearHeadBundleID:
            self = .personalCentroid
        case Self.adamWHeadBundleID:
            self = .personalAdamW
        default:
            return nil
        }
    }
}

enum TrainingRunMethod: String, Equatable, Sendable, CaseIterable {
    case featureKnn
    case personalCentroid
    case personalAdamW
}

enum TrainingRunState: String, Equatable, Sendable, CaseIterable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled:
            return true
        case .queued, .running:
            return false
        }
    }
}

struct TrainingRunRecord: Equatable, Sendable, Identifiable {
    let id: UUID
    let method: TrainingRunMethod
    let state: TrainingRunState
    let createdAtMs: Int64
    let startedAtMs: Int64?
    let finishedAtMs: Int64?
    let catalogScopeID: String
    let jobID: UUID?
    let sampleSummaryJSON: String
    let sampleManifestSHA256: String?
    let configJSON: String
    let metricsJSON: String
    let artifactKind: String?
    let artifactRef: String?
    let artifactSHA256: String?
    let resultSummaryJSON: String
    let errorCode: String?
}

struct TrainingWorkspaceSlot: Equatable, Sendable, Identifiable {
    let method: TrainingRunMethod
    let isPublished: Bool
    let publishedRunID: UUID?
    let artifactRef: String?

    var id: TrainingRunMethod { method }
}

struct TrainingWorkspaceSnapshot: Equatable, Sendable {
    let runs: [TrainingRunRecord]
    let slots: [TrainingWorkspaceSlot]
}

protocol TrainingWorkspacePort: Sendable {
    func snapshot(
        method: TrainingRunMethod?,
        limit: Int
    ) throws -> TrainingWorkspaceSnapshot
}
