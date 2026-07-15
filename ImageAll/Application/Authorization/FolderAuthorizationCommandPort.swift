import Foundation

protocol FolderAuthorizationCommandPort: Sendable {
    func connectFolder() async throws -> ConnectFolderOutcome
    func reauthorizeFolder(sourceID: UUID) async throws -> ReauthorizeFolderOutcome
    func disableFolderSource(sourceID: UUID) async throws -> DisableFolderOutcome
}
