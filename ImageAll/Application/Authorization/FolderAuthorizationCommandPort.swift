import Foundation

protocol FolderAuthorizationCommandPort: Sendable {
    func connectFolder() async throws -> ConnectFolderOutcome
    func reauthorizeFolder(sourceID: UUID) async throws -> ReauthorizeFolderOutcome
    func disableFolderSource(sourceID: UUID) async throws -> DisableFolderOutcome
    /// Silently probes an existing bookmark; returns true when access is restored to active.
    /// Does not present a directory picker.
    func attemptRestoreFolderAuthorization(sourceID: UUID) throws -> Bool
}
