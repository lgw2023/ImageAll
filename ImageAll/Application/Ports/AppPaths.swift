import Foundation

struct AppStorageLocationStatus: Equatable, Sendable {
    let applicationSupportDirectoryURL: URL
    let cachesDirectoryURL: URL
    let preferredExternalRootURL: URL?
    let usesExternalStorage: Bool
    let requiresRestart: Bool
}

protocol AppStorageAccessLease: AnyObject, Sendable {
    func stop()
}

struct AppPaths: Sendable {
    let applicationSupportDirectory: URL
    let catalogDirectory: URL
    let catalogDatabaseURL: URL
    let backupsDirectory: URL
    let runtimeDirectory: URL
    let catalogLockFileURL: URL
    let cachesDirectory: URL
    let storageLocationStatus: AppStorageLocationStatus
    let storageAccessLease: (any AppStorageAccessLease)?

    init(
        applicationSupportDirectory: URL,
        catalogDirectory: URL,
        catalogDatabaseURL: URL,
        backupsDirectory: URL,
        runtimeDirectory: URL,
        catalogLockFileURL: URL,
        cachesDirectory: URL,
        storageLocationStatus: AppStorageLocationStatus? = nil,
        storageAccessLease: (any AppStorageAccessLease)? = nil
    ) {
        self.applicationSupportDirectory = applicationSupportDirectory
        self.catalogDirectory = catalogDirectory
        self.catalogDatabaseURL = catalogDatabaseURL
        self.backupsDirectory = backupsDirectory
        self.runtimeDirectory = runtimeDirectory
        self.catalogLockFileURL = catalogLockFileURL
        self.cachesDirectory = cachesDirectory
        self.storageLocationStatus = storageLocationStatus ?? AppStorageLocationStatus(
            applicationSupportDirectoryURL: applicationSupportDirectory,
            cachesDirectoryURL: cachesDirectory,
            preferredExternalRootURL: nil,
            usesExternalStorage: false,
            requiresRestart: false
        )
        self.storageAccessLease = storageAccessLease
    }
}

extension AppPaths: Equatable {
    static func == (lhs: AppPaths, rhs: AppPaths) -> Bool {
        lhs.applicationSupportDirectory == rhs.applicationSupportDirectory
            && lhs.catalogDirectory == rhs.catalogDirectory
            && lhs.catalogDatabaseURL == rhs.catalogDatabaseURL
            && lhs.backupsDirectory == rhs.backupsDirectory
            && lhs.runtimeDirectory == rhs.runtimeDirectory
            && lhs.catalogLockFileURL == rhs.catalogLockFileURL
            && lhs.cachesDirectory == rhs.cachesDirectory
            && lhs.storageLocationStatus == rhs.storageLocationStatus
    }
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
