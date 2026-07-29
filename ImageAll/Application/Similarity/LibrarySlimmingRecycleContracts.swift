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
    /// PhotoKit may still return an asset briefly after `deleteAssets`; do not treat as user-restored.
    static let photosDeleteConvergenceGraceMs: Int64 = 2 * 60 * 1_000

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
    case mutationAuthorizationInvalid
    case photosAuthorizationRequired
    case photosRestoreRequiresPhotosApp
    case photosManagedBySystem
    case photosMutationFailed
    case restoreConflict
    case ioFailure
    case sourceChanged
    case invalidState
    case cleanupPlanningUnavailable
}

struct LibrarySlimmingIdenticalCleanupCandidate: Sendable, Equatable {
    let assetID: UUID
    let sourceID: UUID
    let sourceKind: RecycleSourceKind
    let sourceDisplayName: String
}

struct LibrarySlimmingIdenticalCleanupDecision: Sendable, Equatable {
    let clusterID: UUID
    let survivorAssetID: UUID
    let assetIDsToRecycle: [UUID]
}

struct LibrarySlimmingIdenticalCleanupPlan: Sendable, Equatable {
    let decisions: [LibrarySlimmingIdenticalCleanupDecision]
    let skippedGroupCount: Int
    let photosAssetCount: Int
    let fileAssetCount: Int

    var groupCount: Int {
        decisions.count
    }

    var assetIDsToRecycle: [UUID] {
        decisions.flatMap(\.assetIDsToRecycle)
    }

    var survivorAssetIDs: [UUID] {
        decisions.map(\.survivorAssetID)
    }

    /// Exact count of distinct survivor asset IDs selected by the runtime plan.
    var retainedAssetCount: Int {
        Set(survivorAssetIDs).count
    }

    /// Exact count of distinct assets covered by executable cleanup decisions.
    var verifiedAssetCount: Int {
        Set(survivorAssetIDs).union(assetIDsToRecycle).count
    }

    /// Runtime distribution of executable groups by their actual member count.
    var groupSizeHistogram: [Int: Int] {
        decisions.reduce(into: [:]) { histogram, decision in
            let memberCount = Set(
                decision.assetIDsToRecycle + [decision.survivorAssetID]
            ).count
            histogram[memberCount, default: 0] += 1
        }
    }

    var isEmpty: Bool {
        decisions.isEmpty || assetIDsToRecycle.isEmpty
    }
}

enum LibrarySlimmingIdenticalCleanupPlanner {
    static func makePlan(
        clusters: [SlimmingCluster],
        candidates: [LibrarySlimmingIdenticalCleanupCandidate]
    ) -> LibrarySlimmingIdenticalCleanupPlan {
        let candidatesByAssetID = Dictionary(
            candidates.map { ($0.assetID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var decisions: [LibrarySlimmingIdenticalCleanupDecision] = []
        var skippedGroupCount = 0
        var photosAssetCount = 0
        var fileAssetCount = 0

        for cluster in clusters where cluster.kind == .byteIdentical {
            var seen = Set<UUID>()
            let memberIDs = cluster.memberAssetIDs.filter { seen.insert($0).inserted }
            guard memberIDs.count >= 2 else { continue }
            let resolved = memberIDs.compactMap { candidatesByAssetID[$0] }
            guard resolved.count == memberIDs.count else {
                skippedGroupCount += 1
                continue
            }

            let deletionOrder = resolved.sorted(by: shouldDeleteBefore)
            guard let survivor = deletionOrder.last else {
                skippedGroupCount += 1
                continue
            }
            let redundant = deletionOrder.dropLast()
            photosAssetCount += redundant.filter { $0.sourceKind == .photos }.count
            fileAssetCount += redundant.filter { $0.sourceKind == .file }.count
            decisions.append(
                LibrarySlimmingIdenticalCleanupDecision(
                    clusterID: cluster.id,
                    survivorAssetID: survivor.assetID,
                    assetIDsToRecycle: redundant.map(\.assetID)
                )
            )
        }

        return LibrarySlimmingIdenticalCleanupPlan(
            decisions: decisions,
            skippedGroupCount: skippedGroupCount,
            photosAssetCount: photosAssetCount,
            fileAssetCount: fileAssetCount
        )
    }

    /// Earlier entries are removed first; the final entry is the single survivor.
    private static func shouldDeleteBefore(
        _ lhs: LibrarySlimmingIdenticalCleanupCandidate,
        _ rhs: LibrarySlimmingIdenticalCleanupCandidate
    ) -> Bool {
        if lhs.sourceKind != rhs.sourceKind {
            return lhs.sourceKind == .photos
        }
        if lhs.sourceDisplayName.count != rhs.sourceDisplayName.count {
            return lhs.sourceDisplayName.count > rhs.sourceDisplayName.count
        }
        if lhs.sourceDisplayName != rhs.sourceDisplayName {
            return lhs.sourceDisplayName > rhs.sourceDisplayName
        }
        let lhsSourceID = lhs.sourceID.uuidString.lowercased()
        let rhsSourceID = rhs.sourceID.uuidString.lowercased()
        if lhsSourceID != rhsSourceID {
            return lhsSourceID > rhsSourceID
        }
        return lhs.assetID.uuidString.lowercased() > rhs.assetID.uuidString.lowercased()
    }
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
    func makeIdenticalCleanupPlan(
        clusters: [SlimmingCluster]
    ) throws -> LibrarySlimmingIdenticalCleanupPlan
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
    /// Asset IDs that should be hidden from slimming cluster presentation.
    func slimmingHiddenAssetIDs(from assetIDs: [UUID]) throws -> Set<UUID>
    /// Maps a restored historical file identity to the verified current identity
    /// created by a folder reconcile race at the same path.
    func restoredAssetReplacements(from assetIDs: [UUID]) throws -> [UUID: UUID]
}

extension LibrarySlimmingRecyclePort {
    func makeIdenticalCleanupPlan(
        clusters _: [SlimmingCluster]
    ) throws -> LibrarySlimmingIdenticalCleanupPlan {
        throw LibrarySlimmingRecycleError.cleanupPlanningUnavailable
    }

    /// Compatibility alias used by older call sites / stubs.
    func moveFolderAssetsToRecycle(assetIDs: [UUID]) throws -> LibrarySlimmingRecycleMoveOutcome {
        try moveAssetsToRecycle(assetIDs: assetIDs)
    }

    func restoredAssetReplacements(from _: [UUID]) throws -> [UUID: UUID] {
        [:]
    }
}

protocol LibrarySlimmingRecycleConfirmationPreferenceStore: Sendable {
    var skipsMoveConfirmation: Bool { get nonmutating set }
}
