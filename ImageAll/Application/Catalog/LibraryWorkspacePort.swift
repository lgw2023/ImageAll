import Foundation

struct LibrarySourceSummary: Identifiable, Equatable, Sendable {
    let id: UUID
    let displayName: String
    let state: SourceState
}

enum LibraryWorkspacePhase: Equatable, Sendable {
    case loading
    case empty
    case scanning
    case content
    case failed(LibraryWorkspaceSafeError)
}

enum LibraryWorkspaceSafeError: String, Equatable, Sendable {
    case connectionFailed
    case scanFailed
    case catalogFailed
}

protocol LibraryWorkspacePort: Sendable {
    func fetchSources() throws -> [LibrarySourceSummary]
    func connectFolder() async throws -> ConnectFolderOutcome
    func enqueueReconcile(sourceIDs: [UUID]) throws
    func runPendingReconcileJobs() throws
    func fetchAssetPage(sourceID: UUID?, cursor: AssetPageCursor?) throws -> AssetPageResult
    func loadThumbnail(assetID: UUID) async throws -> Data
}
