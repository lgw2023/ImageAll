import Foundation

enum CatalogSnapshotError: Error, Equatable, Sendable {
    case invalidManifest
    case unsupportedManifestFormat(version: Int)
    case invalidSnapshotID
    case snapshotIDMismatch
    case invalidDatabaseFilename
    case invalidCreatedAt
    case invalidAppVersion
    case invalidMigrationHistory
    case migrationHistoryMismatch
    case futureMigrationHistory(applied: [String], unknown: [String])
    case invalidDatabaseBytes
    case invalidDatabaseChecksum
    case databaseChecksumMismatch
    case databaseSizeMismatch
    case snapshotCollision
    case backupFailed
    case backupAborted
    case integrityCheckFailed
    case closeFailed
    case sidecarConvergenceFailed
    case manifestWriteFailed
    case publicationFailed
    case checkpointFailed
    case candidatePreparationFailed
    case differentVolume
    case replacementPreconditionNotMet
    case initialReplacementFailed
    case postReplaceValidationFailed
    case postReplaceValidationFailedWithSuccessfulRollback
    case rollbackReplacementFailed
    case manualInterventionRequired
}
