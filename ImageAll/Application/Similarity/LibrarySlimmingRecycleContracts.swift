import Foundation

enum RecycleEntryState: String, Sendable, Equatable {
    case pending
    case recycled
    case restoring
    case purging
    case restored
    case purged
    case failed
}

enum RecycleSourceKind: String, Sendable, Equatable {
    case file
    case photos
}

struct RecycleEntryRecord: Identifiable, Sendable, Equatable {
    let id: UUID
    let assetID: UUID
    let sourceID: UUID
    let sourceKind: RecycleSourceKind
    let trashedAtMs: Int64
    let purgeAfterMs: Int64
    let state: RecycleEntryState
    let quarantineRelativePath: String?
    let originalRelativePath: String?
    let photosLocalIdentifier: String?
    let errorCode: String?
    let fileName: String?
}

enum LibrarySlimmingRecyclePolicy {
    static let retentionDays: Int = 30
    static let dayMs: Int64 = 24 * 60 * 60 * 1_000

    static func purgeAfterMs(trashedAtMs: Int64) -> Int64 {
        trashedAtMs + Int64(retentionDays) * dayMs
    }
}

enum RecycleCountdownFormatter {
    static func text(purgeAfterMs: Int64, nowMs: Int64) -> String {
        let remaining = purgeAfterMs - nowMs
        if remaining <= 0 {
            return "即将永久删除"
        }
        let hourMs: Int64 = 60 * 60 * 1_000
        if remaining < LibrarySlimmingRecyclePolicy.dayMs {
            let hours = max(1, (remaining + hourMs - 1) / hourMs)
            return "\(hours) 小时后永久删除"
        }
        let days = max(1, (remaining + LibrarySlimmingRecyclePolicy.dayMs - 1) / LibrarySlimmingRecyclePolicy.dayMs)
        return "\(days) 天后永久删除"
    }

    static func recordCleanupText(cleanupAfterMs: Int64, nowMs: Int64) -> String {
        let remaining = cleanupAfterMs - nowMs
        if remaining <= 0 {
            return "ImageAll 即将清理此记录"
        }
        let hourMs: Int64 = 60 * 60 * 1_000
        if remaining < LibrarySlimmingRecyclePolicy.dayMs {
            let hours = max(1, (remaining + hourMs - 1) / hourMs)
            return "ImageAll 将在 \(hours) 小时后清理此记录"
        }
        let days = max(
            1,
            (remaining + LibrarySlimmingRecyclePolicy.dayMs - 1)
                / LibrarySlimmingRecyclePolicy.dayMs
        )
        return "ImageAll 将在 \(days) 天后清理此记录"
    }
}

enum LibrarySlimmingRecycleError: Error, Equatable, Sendable {
    case notFound
    case ineligiblePhotos
    case alreadyRecycled
    case mutationAuthorizationRequired
    case photosAuthorizationRequired
    case photosRestoreRequiresPhotosApp
    case photosManagedBySystem
    case photosMutationFailed
    case restoreConflict
    case ioFailure
    case sourceChanged
    case invalidState
}

struct LibrarySlimmingRecycleMoveOutcome: Sendable, Equatable {
    var recycledEntryIDs: [UUID]
    /// Retained for compatibility; S5 no longer skips Photos on the success path.
    var skippedPhotosAssetIDs: [UUID]
    var failedAssetIDs: [UUID]
    var authorizationRequiredSourceIDs: [UUID]
    var authorizationRequiredAssetIDs: [UUID]
    var authorizationDeniedPhotosAssetIDs: [UUID]
}

protocol LibrarySlimmingRecyclePort: Sendable {
    func moveAssetsToRecycle(assetIDs: [UUID]) throws -> LibrarySlimmingRecycleMoveOutcome
    func listRecycledEntries() throws -> [RecycleEntryRecord]
    func restore(entryID: UUID) throws
    func purgeNow(entryID: UUID) throws
    func purgeExpired(nowMs: Int64) throws -> Int
    func enqueuePurgeExpired() throws
    @discardableResult
    func recoverInterruptedOperations() throws -> Int
    @discardableResult
    func reconcilePhotosRecycleEntries() throws -> Int
}

extension LibrarySlimmingRecyclePort {
    /// Compatibility alias used by older call sites / stubs.
    func moveFolderAssetsToRecycle(assetIDs: [UUID]) throws -> LibrarySlimmingRecycleMoveOutcome {
        try moveAssetsToRecycle(assetIDs: assetIDs)
    }
}
