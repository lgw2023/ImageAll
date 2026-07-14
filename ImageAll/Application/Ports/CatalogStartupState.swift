import Foundation

enum CatalogStartupStage: String, Equatable, Sendable {
    case paths
    case lock
    case catalog
    case recovery
}

enum CatalogUnavailableReason: Equatable, Sendable {
    case pathsFailed
    case lockIOFailed
    case schemaUnsupported
    case integrityFailed
    case insufficientSpace(requiredBytes: UInt64)
    case snapshotFailed
    case migrationFailed
    case publicationFailed
    case finalOpenFailed
    case recoveryFailed
}

enum CatalogStartupOutcome: Equatable, Sendable {
    case starting(CatalogStartupStage)
    case catalogReady
    case anotherInstanceRunning
    case catalogUnavailable(CatalogUnavailableReason)
}

struct StartupPresentation: Equatable {
    let productName: String
    let foundationReady: Bool
    let catalogState: CatalogStartupOutcome
}
