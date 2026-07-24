import Foundation

struct AppStorageLocationStatus: Equatable, Sendable {
    let applicationSupportDirectoryURL: URL
    let cachesDirectoryURL: URL
    let preferredExternalRootURL: URL?
    let usesExternalStorage: Bool
    let requiresRestart: Bool
}

enum ExternalAppStorageMigrationPhase: String, Equatable, Sendable {
    case preparing
    case copyingApplicationSupport
    case convergingSQLite
    case mergingCaches
    case writingCompletionMarker
    case completed
    case cancelled
    case failed
}

struct ExternalAppStorageMigrationProgress: Equatable, Sendable {
    var phase: ExternalAppStorageMigrationPhase
    var bytesCopied: Int64
    var totalBytes: Int64
    var filesCopied: Int
    var totalFiles: Int

    static let zero = ExternalAppStorageMigrationProgress(
        phase: .preparing,
        bytesCopied: 0,
        totalBytes: 0,
        filesCopied: 0,
        totalFiles: 0
    )

    var fractionCompleted: Double {
        if totalBytes > 0 {
            return min(1, Double(bytesCopied) / Double(totalBytes))
        }
        if totalFiles > 0 {
            return min(1, Double(filesCopied) / Double(totalFiles))
        }
        switch phase {
        case .completed:
            return 1
        case .preparing, .cancelled, .failed:
            return 0
        default:
            return 0
        }
    }

    var statusText: String {
        switch phase {
        case .preparing:
            return "正在准备迁移…"
        case .copyingApplicationSupport:
            return "正在复制应用资料…"
        case .convergingSQLite:
            return "正在收敛目录库…"
        case .mergingCaches:
            return "正在合并缓存…"
        case .writingCompletionMarker:
            return "正在写入完成标记…"
        case .completed:
            return "迁移已完成"
        case .cancelled:
            return "迁移已取消"
        case .failed:
            return "迁移失败"
        }
    }
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
