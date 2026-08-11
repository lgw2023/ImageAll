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

enum RecycleFailureCode {
    /// FolderMutationAccessService emits this before it invokes the file-I/O closure.
    static let mutationAuthorizationRequired = "mutationAuthorizationRequired"
    static let mutationAuthorizationInvalid = "mutationAuthorizationInvalid"
    static let sourceChanged = "sourceChanged"
    static let ioFailure = "ioFailure"
    static let photosAuthorizationRequired = "photosAuthorizationRequired"
    static let photosAssetNotFound = "photosAssetNotFound"
    static let photosMutationFailed = "photosMutationFailed"
    static let photosMutationUserCancelledPrefix =
        "photosMutationFailed.userCancelled."
    static let spaceFirstSourceDeletionPending = "spaceFirstSourceDeletionPending"
    static let spaceFirstAppCacheCleanupPending = "spaceFirstAppCacheCleanupPending"
}

enum RecycleEntryProblem: Sendable, Equatable, Hashable {
    case sourceAuthorizationRequired
    case sourceAuthorizationInvalid
    case sourceChanged
    case photosAuthorizationRequired
    case photosAssetNotFound
    case photosUserCancelled
    case photosMutationFailed
    case fileIO
    case locationConflict
    case locationMissing
    case unknown
}

enum RecycleEntryResolution: Sendable, Equatable, Hashable {
    case restoreOrPurge
    case discardPreflightFailure
    case retryInterruptedOperation
    case reinspectFileLocations
    case updateFolderAuthorization
    case refreshSourceBeforeRetry
    case requestPhotosAuthorization
    case retryFromAnalysis
}

enum LibrarySlimmingRemovalMode: Sendable, Equatable {
    /// Keep folder bytes in ImageAll quarantine so the user can restore them.
    case recoverableRecycle
    /// Delete folder bytes from their source volume after identity validation.
    /// Apple Photos assets still use the system Recently Deleted workflow.
    case releaseSourceSpace
}

struct RecycleEntryRecord: Identifiable, Sendable, Equatable {
    let id: UUID
    let assetID: UUID
    let sourceID: UUID
    let sourceKind: RecycleSourceKind
    let mediaKind: MediaKind
    let trashedAtMs: Int64
    let purgeAfterMs: Int64
    let state: RecycleEntryState
    let quarantineRelativePath: String?
    let originalRelativePath: String?
    let photosLocalIdentifier: String?
    let errorCode: String?
    let fileName: String?

    init(
        id: UUID,
        assetID: UUID,
        sourceID: UUID,
        sourceKind: RecycleSourceKind,
        mediaKind: MediaKind = .image,
        trashedAtMs: Int64,
        purgeAfterMs: Int64,
        state: RecycleEntryState,
        quarantineRelativePath: String?,
        originalRelativePath: String?,
        photosLocalIdentifier: String?,
        errorCode: String?,
        fileName: String?
    ) {
        self.id = id
        self.assetID = assetID
        self.sourceID = sourceID
        self.sourceKind = sourceKind
        self.mediaKind = mediaKind
        self.trashedAtMs = trashedAtMs
        self.purgeAfterMs = purgeAfterMs
        self.state = state
        self.quarantineRelativePath = quarantineRelativePath
        self.originalRelativePath = originalRelativePath
        self.photosLocalIdentifier = photosLocalIdentifier
        self.errorCode = errorCode
        self.fileName = fileName
    }

    var isDiscardablePreflightFailure: Bool {
        state == .failed
            && sourceKind == .file
            && errorCode == RecycleFailureCode.mutationAuthorizationRequired
            && originalRelativePath != nil
            && photosLocalIdentifier == nil
    }

    var problem: RecycleEntryProblem? {
        guard state == .failed else { return nil }
        switch errorCode {
        case RecycleFailureCode.mutationAuthorizationRequired:
            return .sourceAuthorizationRequired
        case RecycleFailureCode.mutationAuthorizationInvalid:
            return .sourceAuthorizationInvalid
        case RecycleFailureCode.sourceChanged:
            return .sourceChanged
        case RecycleFailureCode.photosAuthorizationRequired:
            return .photosAuthorizationRequired
        case RecycleFailureCode.photosAssetNotFound:
            return .photosAssetNotFound
        case let code? where code.hasPrefix(
            RecycleFailureCode.photosMutationUserCancelledPrefix
        ):
            return .photosUserCancelled
        case let code? where code == RecycleFailureCode.photosMutationFailed
            || code.hasPrefix("\(RecycleFailureCode.photosMutationFailed)."):
            return .photosMutationFailed
        case RecycleFailureCode.ioFailure,
             "restoreIOFailure",
             "purgeIOFailure":
            return .fileIO
        case "interruptedConflict", "restoreConflict":
            return .locationConflict
        case "interruptedBeforeMove",
             "interruptedMissingBoth",
             "interruptedRestoreMissingPath",
             "interruptedBeforeRestore":
            return .locationMissing
        default:
            return .unknown
        }
    }

    var resolution: RecycleEntryResolution {
        if state == .recycled {
            return .restoreOrPurge
        }
        if isDiscardablePreflightFailure {
            return .discardPreflightFailure
        }
        if state == .pending || state == .restoring || state == .purging {
            return .retryInterruptedOperation
        }
        switch problem {
        case .sourceAuthorizationInvalid:
            return .updateFolderAuthorization
        case .sourceChanged, .photosAssetNotFound:
            return .refreshSourceBeforeRetry
        case .photosAuthorizationRequired:
            return .requestPhotosAuthorization
        default:
            if state == .failed,
               sourceKind == .file,
               quarantineRelativePath != nil,
               originalRelativePath != nil
            {
                return .reinspectFileLocations
            }
            return .retryFromAnalysis
        }
    }
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
    case durabilityPending
    case invalidState
    case cleanupPlanningUnavailable
    case cleanupPlanChanged
}

enum LibrarySlimmingMoveConfirmationPolicy {
    static let maximumPersistentlySkippableAssetCount = 5

    static func canPersistentlySkip(assetCount: Int) -> Bool {
        (1 ... maximumPersistentlySkippableAssetCount).contains(assetCount)
    }

    static func requiresConfirmation(
        assetCount: Int,
        skipsSmallMoveConfirmation: Bool,
        isIdenticalCleanup: Bool
    ) -> Bool {
        if isIdenticalCleanup {
            return true
        }
        return !(skipsSmallMoveConfirmation && canPersistentlySkip(assetCount: assetCount))
    }
}

struct LibrarySlimmingIdenticalCleanupCandidate: Sendable, Equatable {
    let assetID: UUID
    let sourceID: UUID
    let sourceKind: RecycleSourceKind
    let sourceDisplayName: String
    var isFavoriteProtected: Bool = false
}

struct LibrarySlimmingIdenticalCleanupAssetProof: Sendable, Equatable {
    let assetID: UUID
    let sourceID: UUID
    let sourceKind: RecycleSourceKind
    let locatorIdentity: String
    let contentRevision: Int
    let verifiedOriginalSHA256: Data
}

struct LibrarySlimmingIdenticalCleanupDecision: Sendable, Equatable {
    let clusterID: UUID
    let survivorAssetID: UUID
    let assetIDsToRecycle: [UUID]
    var additionalRetainedAssetIDs: [UUID] = []
    var favoriteRetainedAssetIDs: [UUID] = []

    var retainedAssetIDs: [UUID] {
        [survivorAssetID] + additionalRetainedAssetIDs
    }
}

struct LibrarySlimmingIdenticalCleanupPlan: Sendable, Equatable {
    let decisions: [LibrarySlimmingIdenticalCleanupDecision]
    let skippedGroupCount: Int
    let photosAssetCount: Int
    let fileAssetCount: Int
    let assetProofs: [LibrarySlimmingIdenticalCleanupAssetProof]
    let protectedSkippedAssetCount: Int

    init(
        decisions: [LibrarySlimmingIdenticalCleanupDecision],
        skippedGroupCount: Int,
        photosAssetCount: Int,
        fileAssetCount: Int,
        assetProofs: [LibrarySlimmingIdenticalCleanupAssetProof] = [],
        protectedSkippedAssetCount: Int = 0
    ) {
        self.decisions = decisions
        self.skippedGroupCount = skippedGroupCount
        self.photosAssetCount = photosAssetCount
        self.fileAssetCount = fileAssetCount
        self.assetProofs = assetProofs
        self.protectedSkippedAssetCount = protectedSkippedAssetCount
    }

    var groupCount: Int {
        decisions.count
    }

    var assetIDsToRecycle: [UUID] {
        decisions.flatMap(\.assetIDsToRecycle)
    }

    var survivorAssetIDs: [UUID] {
        decisions.flatMap(\.retainedAssetIDs)
    }

    var favoriteRetainedAssetIDs: [UUID] {
        decisions.flatMap(\.favoriteRetainedAssetIDs)
    }

    var favoriteRetainedAssetCount: Int {
        Set(favoriteRetainedAssetIDs).count
    }

    var ordinaryRetainedAssetCount: Int {
        max(0, retainedAssetCount - favoriteRetainedAssetCount)
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
                decision.assetIDsToRecycle + decision.retainedAssetIDs
            ).count
            histogram[memberCount, default: 0] += 1
        }
    }

    var isEmpty: Bool {
        decisions.isEmpty || assetIDsToRecycle.isEmpty
    }
}

struct LibrarySlimmingIdenticalCleanupVerification: Sendable, Equatable {
    /// Every planned asset ID that was found in the catalog during the post-delete read.
    let observedAssetIDs: [UUID]
    /// Assets that are still current and available after the cleanup attempt.
    let currentAvailableAssetIDs: [UUID]
    /// Survivors from groups that now contain exactly one available asset and whose
    /// redundant members all have completed recycle records.
    let retainedNonredundantAssetIDs: [UUID]
    /// Planned redundant assets confirmed in the recycle state after execution.
    let recycledRedundantAssetIDs: [UUID]
    /// Planned redundant assets that are still current and available.
    let remainingRedundantAssetIDs: [UUID]
    /// Planned assets that could not be classified as current/available or recycled.
    let unresolvedAssetIDs: [UUID]
    let verifiedGroupIDs: [UUID]
    let unresolvedGroupIDs: [UUID]

    var observedAssetCount: Int {
        Set(observedAssetIDs).count
    }

    var currentAvailableAssetCount: Int {
        Set(currentAvailableAssetIDs).count
    }

    var retainedNonredundantAssetCount: Int {
        Set(retainedNonredundantAssetIDs).count
    }

    var recycledRedundantAssetCount: Int {
        Set(recycledRedundantAssetIDs).count
    }

    var remainingRedundantAssetCount: Int {
        Set(remainingRedundantAssetIDs).count
    }

    var unresolvedAssetCount: Int {
        Set(unresolvedAssetIDs).count
    }

    var verifiedGroupCount: Int {
        Set(verifiedGroupIDs).count
    }

    var unresolvedGroupCount: Int {
        Set(unresolvedGroupIDs).count
    }

    /// Every runtime cleanup group represented by the post-delete verification.
    var targetGroupCount: Int {
        Set(verifiedGroupIDs).union(unresolvedGroupIDs).count
    }

    var targetRetainedAssetCount: Int {
        retainedNonredundantAssetCount + unresolvedGroupIDs.count
    }

    var isComplete: Bool {
        !verifiedGroupIDs.isEmpty
            && unresolvedGroupIDs.isEmpty
            && remainingRedundantAssetIDs.isEmpty
            && unresolvedAssetIDs.isEmpty
    }
}

enum LibrarySlimmingIdenticalCleanupPostDeleteReport: Sendable, Equatable {
    case verified(LibrarySlimmingIdenticalCleanupVerification)
    case unavailable(message: String)
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
        var protectedSkippedAssetCount = 0

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
            let protected = deletionOrder.filter(\.isFavoriteProtected)
            if !protected.isEmpty {
                let redundant = deletionOrder.filter { !$0.isFavoriteProtected }
                guard !redundant.isEmpty, let survivor = protected.last else {
                    skippedGroupCount += 1
                    protectedSkippedAssetCount += protected.count
                    continue
                }
                photosAssetCount += redundant.filter { $0.sourceKind == .photos }.count
                fileAssetCount += redundant.filter { $0.sourceKind == .file }.count
                decisions.append(
                    LibrarySlimmingIdenticalCleanupDecision(
                        clusterID: cluster.id,
                        survivorAssetID: survivor.assetID,
                        assetIDsToRecycle: redundant.map(\.assetID),
                        additionalRetainedAssetIDs: protected.dropLast().map(\.assetID),
                        favoriteRetainedAssetIDs: protected.map(\.assetID)
                    )
                )
                continue
            }
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
            fileAssetCount: fileAssetCount,
            protectedSkippedAssetCount: protectedSkippedAssetCount
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
    /// File assets deleted directly from their source volume. They cannot be
    /// restored by ImageAll and therefore do not appear in the recycle bin.
    var permanentlyDeletedAssetIDs: [UUID] = []
    /// The source unlink committed, but the source-directory durability sync
    /// failed. The item stays hidden while crash recovery confirms the namespace.
    var durabilityPendingAssetIDs: [UUID] = []
    /// Retained for compatibility; S5 no longer skips Photos on the success path.
    var skippedPhotosAssetIDs: [UUID]
    var failedAssetIDs: [UUID]
    var authorizationRequiredSourceIDs: [UUID]
    var authorizationRequiredAssetIDs: [UUID]
    var authorizationDeniedPhotosAssetIDs: [UUID]
    /// Folder mutation bookmark resolve/startAccessing failed; UI should point to「更新回收权限…」.
    var mutationAuthorizationInvalidAssetIDs: [UUID] = []
    /// PhotoKit soft-delete failed after authorization was available (cancel, changeFailed, etc.).
    var photosMutationFailedAssetIDs: [UUID] = []
    /// Safe aggregate PhotoKit failure categories for user-facing recovery guidance.
    var photosMutationFailureCategories: [PhotosLibraryMutationFailureCategory] = []
    /// Safe system domain/code pairs; never contains Photos local identifiers or paths.
    var photosMutationFailureCodes: [String] = []
    /// The source no longer matches the identity captured by the analysis snapshot.
    var sourceChangedAssetIDs: [UUID] = []

    var hasOnlyMutationAuthorizationInvalidFailures: Bool {
        let failures = Set(failedAssetIDs)
        return !failures.isEmpty && failures == Set(mutationAuthorizationInvalidAssetIDs)
    }

    var hasOnlyPhotosMutationFailures: Bool {
        let failures = Set(failedAssetIDs)
        return !failures.isEmpty && failures == Set(photosMutationFailedAssetIDs)
    }

    var hasOnlySourceChangedFailures: Bool {
        let failures = Set(failedAssetIDs)
        return !failures.isEmpty && failures == Set(sourceChangedAssetIDs)
    }
}

enum LibrarySlimmingRemovalAuthorizationGate: Sendable, Equatable {
    case folderMutation
    case photosLibrary
}

/// Reconciles a retry with earlier batch results without losing completed work
/// or leaving a stale failure classification attached to a retried asset.
enum LibrarySlimmingRemovalOutcomeMerger {
    static func merge(
        _ retry: LibrarySlimmingRecycleMoveOutcome,
        into accumulated: inout LibrarySlimmingRecycleMoveOutcome,
        replacingFailuresFor retriedAssetIDs: [UUID],
        authorizationGate: LibrarySlimmingRemovalAuthorizationGate
    ) {
        let retried = Set(retriedAssetIDs)

        accumulated.recycledEntryIDs.append(contentsOf: retry.recycledEntryIDs)
        accumulated.permanentlyDeletedAssetIDs.append(
            contentsOf: retry.permanentlyDeletedAssetIDs
        )
        accumulated.durabilityPendingAssetIDs.append(
            contentsOf: retry.durabilityPendingAssetIDs
        )
        accumulated.skippedPhotosAssetIDs.append(contentsOf: retry.skippedPhotosAssetIDs)

        replaceAssets(
            in: &accumulated.failedAssetIDs,
            retried: retried,
            with: retry.failedAssetIDs
        )
        replaceAssets(
            in: &accumulated.authorizationRequiredAssetIDs,
            retried: retried,
            with: retry.authorizationRequiredAssetIDs
        )
        replaceAssets(
            in: &accumulated.authorizationDeniedPhotosAssetIDs,
            retried: retried,
            with: retry.authorizationDeniedPhotosAssetIDs
        )
        replaceAssets(
            in: &accumulated.mutationAuthorizationInvalidAssetIDs,
            retried: retried,
            with: retry.mutationAuthorizationInvalidAssetIDs
        )
        replaceAssets(
            in: &accumulated.photosMutationFailedAssetIDs,
            retried: retried,
            with: retry.photosMutationFailedAssetIDs
        )
        replaceAssets(
            in: &accumulated.sourceChangedAssetIDs,
            retried: retried,
            with: retry.sourceChangedAssetIDs
        )

        switch authorizationGate {
        case .folderMutation:
            accumulated.authorizationRequiredSourceIDs =
                retry.authorizationRequiredSourceIDs
        case .photosLibrary:
            accumulated.authorizationRequiredSourceIDs.append(
                contentsOf: retry.authorizationRequiredSourceIDs
            )
        }

        accumulated.photosMutationFailureCategories.append(
            contentsOf: retry.photosMutationFailureCategories
        )
        accumulated.photosMutationFailureCodes.append(
            contentsOf: retry.photosMutationFailureCodes
        )

        accumulated.recycledEntryIDs = uniqued(accumulated.recycledEntryIDs)
        accumulated.permanentlyDeletedAssetIDs = uniqued(
            accumulated.permanentlyDeletedAssetIDs
        )
        accumulated.durabilityPendingAssetIDs = uniqued(
            accumulated.durabilityPendingAssetIDs
        )
        accumulated.skippedPhotosAssetIDs = uniqued(accumulated.skippedPhotosAssetIDs)
        accumulated.failedAssetIDs = uniqued(accumulated.failedAssetIDs)
        accumulated.authorizationRequiredSourceIDs = uniqued(
            accumulated.authorizationRequiredSourceIDs
        )
        accumulated.authorizationRequiredAssetIDs = uniqued(
            accumulated.authorizationRequiredAssetIDs
        )
        accumulated.authorizationDeniedPhotosAssetIDs = uniqued(
            accumulated.authorizationDeniedPhotosAssetIDs
        )
        accumulated.mutationAuthorizationInvalidAssetIDs = uniqued(
            accumulated.mutationAuthorizationInvalidAssetIDs
        )
        accumulated.photosMutationFailedAssetIDs = uniqued(
            accumulated.photosMutationFailedAssetIDs
        )
        accumulated.photosMutationFailureCategories = uniquedEquatable(
            accumulated.photosMutationFailureCategories
        )
        accumulated.photosMutationFailureCodes = uniqued(
            accumulated.photosMutationFailureCodes
        )
        accumulated.sourceChangedAssetIDs = uniqued(accumulated.sourceChangedAssetIDs)
    }

    private static func replaceAssets(
        in accumulated: inout [UUID],
        retried: Set<UUID>,
        with retry: [UUID]
    ) {
        accumulated.removeAll { retried.contains($0) }
        accumulated.append(contentsOf: retry)
    }

    private static func uniqued<Element: Hashable>(_ values: [Element]) -> [Element] {
        var seen = Set<Element>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func uniquedEquatable<Element: Equatable>(
        _ values: [Element]
    ) -> [Element] {
        values.reduce(into: []) { result, value in
            if !result.contains(value) {
                result.append(value)
            }
        }
    }
}

enum LibrarySlimmingRecycleMovePhase: String, Sendable, Equatable {
    case waitingForBackgroundIO
    case preparing
    case copying
    case syncingDestination
    case verifyingDestination
    case verifyingSource
    case deletingSource
    case syncingSourceDirectory
    case photosSystemMutation
    case completedAsset
}

struct LibrarySlimmingRecycleMoveProgress: Sendable, Equatable {
    let phase: LibrarySlimmingRecycleMovePhase
    let completedAssetCount: Int
    let totalAssetCount: Int
    /// Bytes belonging to file assets that have completed the copy stage.
    /// PhotoKit-managed assets intentionally do not contribute.
    let copiedBytes: Int64
    let totalFileBytes: Int64

    init(
        phase: LibrarySlimmingRecycleMovePhase = .completedAsset,
        completedAssetCount: Int,
        totalAssetCount: Int,
        copiedBytes: Int64 = 0,
        totalFileBytes: Int64 = 0
    ) {
        self.phase = phase
        self.completedAssetCount = completedAssetCount
        self.totalAssetCount = totalAssetCount
        self.copiedBytes = max(0, copiedBytes)
        self.totalFileBytes = max(0, totalFileBytes)
    }
}

typealias LibrarySlimmingRecycleMoveProgressHandler =
    @Sendable (LibrarySlimmingRecycleMoveProgress) -> Void

protocol LibrarySlimmingRecyclePort: Sendable {
    func makeIdenticalCleanupPlan(
        clusters: [SlimmingCluster]
    ) throws -> LibrarySlimmingIdenticalCleanupPlan
    func verifyIdenticalCleanup(
        plan: LibrarySlimmingIdenticalCleanupPlan
    ) throws -> LibrarySlimmingIdenticalCleanupVerification
    func moveAssetsToRecycle(assetIDs: [UUID]) throws -> LibrarySlimmingRecycleMoveOutcome
    func moveAssetsToRecycle(
        assetIDs: [UUID],
        onProgress: @escaping LibrarySlimmingRecycleMoveProgressHandler
    ) throws -> LibrarySlimmingRecycleMoveOutcome
    func moveIdenticalCleanupAssetsToRecycle(
        plan: LibrarySlimmingIdenticalCleanupPlan,
        onProgress: @escaping LibrarySlimmingRecycleMoveProgressHandler
    ) throws -> LibrarySlimmingRecycleMoveOutcome
    func deleteAssetsImmediately(
        assetIDs: [UUID],
        onProgress: @escaping LibrarySlimmingRecycleMoveProgressHandler
    ) throws -> LibrarySlimmingRecycleMoveOutcome
    func deleteIdenticalCleanupAssetsImmediately(
        plan: LibrarySlimmingIdenticalCleanupPlan,
        onProgress: @escaping LibrarySlimmingRecycleMoveProgressHandler
    ) throws -> LibrarySlimmingRecycleMoveOutcome
    /// All unresolved entries that belong in the user-facing recycle lifecycle,
    /// including failed/interrupted blockers as well as truly recycled items.
    func listRecycleBinEntries() throws -> [RecycleEntryRecord]
    func listRecycledEntries() throws -> [RecycleEntryRecord]
    /// Removes only a proven pre-file-I/O authorization failure intent.
    /// This operation never reads, writes, moves, or deletes source/quarantine files.
    func discardFailedPreflightEntry(entryID: UUID) throws
    /// Re-runs deterministic recovery for an interrupted transitional entry.
    func retryInterruptedEntry(entryID: UUID) throws
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
    func listRecycleBinEntries() throws -> [RecycleEntryRecord] {
        try listRecycledEntries()
    }

    func discardFailedPreflightEntry(entryID _: UUID) throws {
        throw LibrarySlimmingRecycleError.invalidState
    }

    func retryInterruptedEntry(entryID _: UUID) throws {
        throw LibrarySlimmingRecycleError.invalidState
    }

    func makeIdenticalCleanupPlan(
        clusters _: [SlimmingCluster]
    ) throws -> LibrarySlimmingIdenticalCleanupPlan {
        throw LibrarySlimmingRecycleError.cleanupPlanningUnavailable
    }

    func verifyIdenticalCleanup(
        plan _: LibrarySlimmingIdenticalCleanupPlan
    ) throws -> LibrarySlimmingIdenticalCleanupVerification {
        throw LibrarySlimmingRecycleError.cleanupPlanningUnavailable
    }

    func moveAssetsToRecycle(
        assetIDs: [UUID],
        onProgress: @escaping LibrarySlimmingRecycleMoveProgressHandler
    ) throws -> LibrarySlimmingRecycleMoveOutcome {
        let outcome = try moveAssetsToRecycle(assetIDs: assetIDs)
        onProgress(
            LibrarySlimmingRecycleMoveProgress(
                completedAssetCount: assetIDs.count,
                totalAssetCount: assetIDs.count
            )
        )
        return outcome
    }

    func moveIdenticalCleanupAssetsToRecycle(
        plan: LibrarySlimmingIdenticalCleanupPlan,
        onProgress: @escaping LibrarySlimmingRecycleMoveProgressHandler
    ) throws -> LibrarySlimmingRecycleMoveOutcome {
        try moveAssetsToRecycle(
            assetIDs: plan.assetIDsToRecycle,
            onProgress: onProgress
        )
    }

    func deleteAssetsImmediately(
        assetIDs _: [UUID],
        onProgress _: @escaping LibrarySlimmingRecycleMoveProgressHandler
    ) throws -> LibrarySlimmingRecycleMoveOutcome {
        throw LibrarySlimmingRecycleError.invalidState
    }

    func deleteIdenticalCleanupAssetsImmediately(
        plan: LibrarySlimmingIdenticalCleanupPlan,
        onProgress: @escaping LibrarySlimmingRecycleMoveProgressHandler
    ) throws -> LibrarySlimmingRecycleMoveOutcome {
        try deleteAssetsImmediately(
            assetIDs: plan.assetIDsToRecycle,
            onProgress: onProgress
        )
    }

    /// Compatibility alias used by older call sites / stubs.
    func moveFolderAssetsToRecycle(assetIDs: [UUID]) throws -> LibrarySlimmingRecycleMoveOutcome {
        try moveAssetsToRecycle(assetIDs: assetIDs)
    }

    func restoredAssetReplacements(from _: [UUID]) throws -> [UUID: UUID] {
        [:]
    }
}

/// The single application-level dispatch boundary for destructive slimming work.
/// UI code owns confirmation and authorization prompts; this executor owns the
/// exact recycle/delete operation selected by the reviewed plan and mode.
enum LibrarySlimmingRemovalExecutor {
    static func perform(
        recycle: any LibrarySlimmingRecyclePort,
        assetIDs: [UUID],
        identicalCleanupPlan: LibrarySlimmingIdenticalCleanupPlan?,
        removalMode: LibrarySlimmingRemovalMode,
        onProgress: @escaping LibrarySlimmingRecycleMoveProgressHandler
    ) throws -> LibrarySlimmingRecycleMoveOutcome {
        switch (removalMode, identicalCleanupPlan) {
        case let (.recoverableRecycle, .some(plan)):
            try recycle.moveIdenticalCleanupAssetsToRecycle(
                plan: plan,
                onProgress: onProgress
            )
        case (.recoverableRecycle, .none):
            try recycle.moveAssetsToRecycle(
                assetIDs: assetIDs,
                onProgress: onProgress
            )
        case let (.releaseSourceSpace, .some(plan)):
            try recycle.deleteIdenticalCleanupAssetsImmediately(
                plan: plan,
                onProgress: onProgress
            )
        case (.releaseSourceSpace, .none):
            try recycle.deleteAssetsImmediately(
                assetIDs: assetIDs,
                onProgress: onProgress
            )
        }
    }
}

protocol LibrarySlimmingRecycleConfirmationPreferenceStore: Sendable {
    var skipsMoveConfirmation: Bool { get nonmutating set }
}
