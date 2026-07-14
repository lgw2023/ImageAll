import Foundation

struct AppPaths: Equatable, Sendable {
    let applicationSupportDirectory: URL
    let catalogDirectory: URL
    let catalogDatabaseURL: URL
    let backupsDirectory: URL
    let runtimeDirectory: URL
    let catalogLockFileURL: URL
    let cachesDirectory: URL
}

enum AppPathsError: Error, Equatable, Sendable {
    case resolutionFailed
    case pathNotDirectory
    case directoryCreationFailed
    case crossVolumeLayoutRejected
}

protocol AppPathsResolving: Sendable {
    func resolve() throws -> AppPaths
    func ensureRequiredDirectories(for paths: AppPaths) throws
}
