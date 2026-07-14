import Foundation

enum SourceKind: String, Equatable, Sendable {
    case folder
    case photos
}

enum SourceState: String, Equatable, Sendable {
    case active
    case disabled
    case unavailable
    case authorizationRequired
}

enum AssetLocatorKind: String, Equatable, Sendable {
    case file
    case photos
}

enum AssetLocatorState: String, Equatable, Sendable {
    case current
    case historical
}

enum AssetAvailability: String, Equatable, Sendable {
    case available
    case missing
    case unreadable
    case unsupported
}

enum TagState: String, Equatable, Sendable {
    case active
    case archived
}

enum PersistableTagDecision: String, Equatable, Sendable {
    case accepted
    case rejected
}

enum TagDecisionQueryState: Equatable, Sendable {
    case unknown
    case accepted
    case rejected
}

enum ResourceIdentityJudgment: Equatable, Sendable {
    case same
    case different
    case indeterminate
}

enum ScanGenerationCompletion: Equatable, Sendable {
    case incomplete
    case complete
}
