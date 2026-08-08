import Foundation
import GRDB
import OSLog

private let librarySlimmingRecyclePerformanceLogger = Logger(
    subsystem: "com.gwlee.ImageAll",
    category: "RecyclePerformance"
)

private final class RecycleMoveProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private let totalAssetCount: Int
    private let totalFileBytes: Int64
    private let handler: LibrarySlimmingRecycleMoveProgressHandler
    private var completedAssetCount = 0
    private var copiedBytes: Int64 = 0

    init(
        totalAssetCount: Int,
        totalFileBytes: Int64,
        handler: @escaping LibrarySlimmingRecycleMoveProgressHandler
    ) {
        self.totalAssetCount = max(0, totalAssetCount)
        self.totalFileBytes = max(0, totalFileBytes)
        self.handler = handler
    }

    func report(_ phase: LibrarySlimmingRecycleMovePhase) {
        handler(snapshot(phase: phase))
    }

    func recordCopiedBytes(_ byteCount: Int64) {
        lock.lock()
        copiedBytes = min(totalFileBytes, copiedBytes + max(0, byteCount))
        let progress = snapshotLocked(phase: .copying)
        lock.unlock()
        handler(progress)
    }

    func recordCompletedAsset() {
        lock.lock()
        completedAssetCount = min(totalAssetCount, completedAssetCount + 1)
        let progress = snapshotLocked(phase: .completedAsset)
        lock.unlock()
        handler(progress)
    }

    private func snapshot(phase: LibrarySlimmingRecycleMovePhase)
        -> LibrarySlimmingRecycleMoveProgress
    {
        lock.lock()
        let progress = snapshotLocked(phase: phase)
        lock.unlock()
        return progress
    }

    private func snapshotLocked(phase: LibrarySlimmingRecycleMovePhase)
        -> LibrarySlimmingRecycleMoveProgress
    {
        LibrarySlimmingRecycleMoveProgress(
            phase: phase,
            completedAssetCount: completedAssetCount,
            totalAssetCount: totalAssetCount,
            copiedBytes: copiedBytes,
            totalFileBytes: totalFileBytes
        )
    }
}

private struct PhotosMutationAttemptFailure: Error {
    let diagnostic: PhotosLibraryMutationFailureDiagnostic
}

struct AppOwnedAssetPixelCachePurger: Sendable {
    let database: CatalogDatabase
    let derivedCachesDirectory: URL
    let photosOriginalCache: PhotosOriginalCacheService

    func purge(assetID: UUID) throws {
        let entries: [(id: UUID, format: DerivedImageStorageFormat)] = try database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT id, storage_format
                FROM derived_image_cache_entry
                WHERE asset_id = ?
                ORDER BY id
                """,
                arguments: [assetID.uuidString.lowercased()]
            ).compactMap { row in
                guard let id = UUID(uuidString: row["id"]),
                      let format = DerivedImageStorageFormat(rawValue: row["storage_format"])
                else { return nil }
                return (id, format)
            }
        }

        if !entries.isEmpty {
            let store = DerivedImageCacheStore(cachesDirectory: derivedCachesDirectory)
            let session = try store.ensureLayout()
            for entry in entries {
                try store.deleteObject(
                    entryID: entry.id,
                    format: entry.format,
                    session: session
                )
                try database.pool.write { db in
                    try db.execute(
                        sql: """
                        DELETE FROM derived_image_cache_entry
                        WHERE id = ? AND asset_id = ?
                        """,
                        arguments: [
                            entry.id.uuidString.lowercased(),
                            assetID.uuidString.lowercased(),
                        ]
                    )
                }
            }
        }

        try photosOriginalCache.removePixelObject(assetID: assetID)
    }
}

struct LibrarySlimmingRecycleService: LibrarySlimmingRecyclePort {
    let database: CatalogDatabase
    let mutationAccess: any FolderMutationAccessing
    let photosMutation: (any PhotosLibraryMutationPort)?
    let quarantineRootURL: URL
    let clock: any JobClock
    let jobQueue: (any JobQueue)?
    let pixelCachePurger: AppOwnedAssetPixelCachePurger?
    let interactiveIOGate: InteractiveIOPriorityGate?
    var quarantineIO: FolderQuarantineIO
    var idGenerator: @Sendable () -> UUID

    init(
        database: CatalogDatabase,
        mutationAccess: any FolderMutationAccessing,
        quarantineRootURL: URL,
        clock: any JobClock,
        jobQueue: (any JobQueue)? = nil,
        photosMutation: (any PhotosLibraryMutationPort)? = nil,
        pixelCachePurger: AppOwnedAssetPixelCachePurger? = nil,
        interactiveIOGate: InteractiveIOPriorityGate? = nil,
        quarantineIO: FolderQuarantineIO = FolderQuarantineIO(),
        idGenerator: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.database = database
        self.mutationAccess = mutationAccess
        self.photosMutation = photosMutation
        self.quarantineRootURL = quarantineRootURL
        self.clock = clock
        self.jobQueue = jobQueue
        self.pixelCachePurger = pixelCachePurger
        self.interactiveIOGate = interactiveIOGate
        self.quarantineIO = quarantineIO
        self.idGenerator = idGenerator
    }

    func makeIdenticalCleanupPlan(
        clusters: [SlimmingCluster]
    ) throws -> LibrarySlimmingIdenticalCleanupPlan {
        let assetIDs = Array(
            Set(
                clusters
                    .filter { $0.kind == .byteIdentical }
                    .flatMap(\.memberAssetIDs)
            )
        )
        guard !assetIDs.isEmpty else {
            return LibrarySlimmingIdenticalCleanupPlanner.makePlan(
                clusters: clusters,
                candidates: []
            )
        }

        let facts = try loadIdenticalCleanupFacts(assetIDs: assetIDs)
        let factsByAssetID = Dictionary(
            facts.map { ($0.proof.assetID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var validatedClusters: [SlimmingCluster] = []
        var invalidGroupCount = 0
        for cluster in clusters where cluster.kind == .byteIdentical {
            let memberIDs = Array(Set(cluster.memberAssetIDs))
            let memberFacts = memberIDs.compactMap { factsByAssetID[$0] }
            guard memberIDs.count >= 2,
                  memberFacts.count == memberIDs.count,
                  Set(memberFacts.map(\.proof.verifiedOriginalSHA256)).count == 1
            else {
                invalidGroupCount += 1
                continue
            }
            validatedClusters.append(cluster)
        }

        let basePlan = LibrarySlimmingIdenticalCleanupPlanner.makePlan(
            clusters: validatedClusters,
            candidates: facts.map(\.candidate)
        )
        let plannedAssetIDs = Set(basePlan.survivorAssetIDs + basePlan.assetIDsToRecycle)
        let proofs = plannedAssetIDs.compactMap { factsByAssetID[$0]?.proof }.sorted {
            $0.assetID.uuidString.lowercased() < $1.assetID.uuidString.lowercased()
        }
        return LibrarySlimmingIdenticalCleanupPlan(
            decisions: basePlan.decisions,
            skippedGroupCount: basePlan.skippedGroupCount + invalidGroupCount,
            photosAssetCount: basePlan.photosAssetCount,
            fileAssetCount: basePlan.fileAssetCount,
            assetProofs: proofs,
            protectedSkippedAssetCount: basePlan.protectedSkippedAssetCount
        )
    }

    private struct IdenticalCleanupFact {
        let candidate: LibrarySlimmingIdenticalCleanupCandidate
        let proof: LibrarySlimmingIdenticalCleanupAssetProof
    }

    private func loadIdenticalCleanupFacts(
        assetIDs: [UUID]
    ) throws -> [IdenticalCleanupFact] {
        try database.pool.read { db in
            var loaded: [IdenticalCleanupFact] = []
            loaded.reserveCapacity(assetIDs.count)
            let idStrings = assetIDs.map { $0.uuidString.lowercased() }
            let chunkSize = 400
            for start in stride(from: 0, to: idStrings.count, by: chunkSize) {
                let end = min(start + chunkSize, idStrings.count)
                let chunk = Array(idStrings[start ..< end])
                let placeholders = Array(repeating: "?", count: chunk.count)
                    .joined(separator: ",")
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT
                        a.id AS asset_id,
                        a.source_id AS source_id,
                        a.locator_kind AS locator_kind,
                        COALESCE(a.relative_path, a.photos_local_identifier) AS locator_identity,
                        a.content_revision AS content_revision,
                        s.display_name AS source_display_name,
                        sf.content_sha256 AS content_sha256,
                        CASE WHEN favorite.desired_value = 1
                                   OR favorite.photos_observed_value = 1
                             THEN 1 ELSE 0 END AS is_favorite_protected
                    FROM asset a
                    JOIN source s ON s.id = a.source_id
                    JOIN asset_similarity_fingerprint sf
                      ON sf.asset_id = a.id
                     AND sf.content_revision = a.content_revision
                    LEFT JOIN asset_favorite_state favorite
                      ON favorite.asset_id = a.id
                    WHERE a.id IN (\(placeholders))
                      AND a.locator_state = 'current'
                      AND a.availability = 'available'
                      AND a.media_kind = 'image'
                      AND s.state = 'active'
                      AND (
                        (a.locator_kind = 'file' AND s.kind = 'folder')
                        OR (a.locator_kind = 'photos' AND s.kind = 'photos')
                      )
                      AND sf.content_digest_origin = 'verifiedOriginalBytes'
                      AND sf.content_sha256 IS NOT NULL
                    """,
                    arguments: StatementArguments(chunk)
                )
                for row in rows {
                    guard let assetID = UUID(uuidString: row["asset_id"]),
                          let sourceID = UUID(uuidString: row["source_id"])
                    else { continue }
                    guard let locatorIdentity: String = row["locator_identity"],
                          !locatorIdentity.isEmpty,
                          let sha256: Data = row["content_sha256"],
                          sha256.count == 32
                    else { continue }
                    let sourceKind: RecycleSourceKind
                    switch row["locator_kind"] as String {
                    case AssetLocatorKind.photos.rawValue:
                        sourceKind = .photos
                    case AssetLocatorKind.file.rawValue:
                        sourceKind = .file
                    default:
                        continue
                    }
                    loaded.append(
                        IdenticalCleanupFact(
                            candidate: LibrarySlimmingIdenticalCleanupCandidate(
                                assetID: assetID,
                                sourceID: sourceID,
                                sourceKind: sourceKind,
                                sourceDisplayName: row["source_display_name"],
                                isFavoriteProtected: (row["is_favorite_protected"] as Int) == 1
                            ),
                            proof: LibrarySlimmingIdenticalCleanupAssetProof(
                                assetID: assetID,
                                sourceID: sourceID,
                                sourceKind: sourceKind,
                                locatorIdentity: locatorIdentity,
                                contentRevision: row["content_revision"],
                                verifiedOriginalSHA256: sha256
                            )
                        )
                    )
                }
            }
            return loaded
        }
    }

    func verifyIdenticalCleanup(
        plan: LibrarySlimmingIdenticalCleanupPlan
    ) throws -> LibrarySlimmingIdenticalCleanupVerification {
        enum ObservedState: Equatable {
            case currentAvailable
            case recycled
            case unresolved
        }

        let plannedAssetIDs = Set(plan.survivorAssetIDs + plan.assetIDsToRecycle)
        var statesByAssetID: [UUID: ObservedState] = [:]
        let normalized = plannedAssetIDs
            .map { $0.uuidString.lowercased() }
            .sorted()

        for start in stride(from: 0, to: normalized.count, by: 400) {
            let chunk = Array(normalized[start ..< min(start + 400, normalized.count)])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let rows = try database.pool.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                    SELECT
                        a.id,
                        CASE
                            WHEN a.locator_state = 'current'
                             AND a.availability = 'available'
                             AND s.state = 'active'
                            THEN 1 ELSE 0
                        END AS is_current_available,
                        CASE
                            WHEN a.availability = 'recycled'
                             AND EXISTS (
                                SELECT 1
                                FROM recycle_entry r
                                WHERE r.asset_id = a.id
                                  AND r.state IN ('recycled', 'purging', 'purged')
                             )
                            THEN 1 ELSE 0
                        END AS is_recycled
                    FROM asset a
                    JOIN source s ON s.id = a.source_id
                    WHERE a.id IN (\(placeholders))
                    """,
                    arguments: StatementArguments(chunk)
                )
            }
            for row in rows {
                guard let assetID = UUID(uuidString: row["id"]) else { continue }
                let isCurrentAvailable: Int = row["is_current_available"]
                let isRecycled: Int = row["is_recycled"]
                if isCurrentAvailable == 1 {
                    statesByAssetID[assetID] = .currentAvailable
                } else if isRecycled == 1 {
                    statesByAssetID[assetID] = .recycled
                } else {
                    statesByAssetID[assetID] = .unresolved
                }
            }
        }

        let currentAvailable = Set(
            statesByAssetID.compactMap { assetID, state in
                state == .currentAvailable ? assetID : nil
            }
        )
        var retainedNonredundant = Set<UUID>()
        var recycledRedundant = Set<UUID>()
        var remainingRedundant = Set<UUID>()
        var unresolved = plannedAssetIDs.subtracting(statesByAssetID.keys)
        var verifiedGroups = Set<UUID>()
        var unresolvedGroups = Set<UUID>()

        for decision in plan.decisions {
            let redundantIDs = Set(decision.assetIDsToRecycle)
            let retainedIDs = Set(decision.retainedAssetIDs)
            let groupIDs = redundantIDs.union(retainedIDs)
            let availableInGroup = groupIDs.intersection(currentAvailable)
            let recycledInGroup = Set(redundantIDs.filter {
                statesByAssetID[$0] == .recycled
            })
            let remainingInGroup = redundantIDs.intersection(currentAvailable)
            let unresolvedInGroup = Set(groupIDs.filter {
                guard let state = statesByAssetID[$0] else { return true }
                return state == .unresolved
            })

            recycledRedundant.formUnion(recycledInGroup)
            remainingRedundant.formUnion(remainingInGroup)
            unresolved.formUnion(unresolvedInGroup)

            let groupIsVerified =
                availableInGroup == retainedIDs
                && recycledInGroup == redundantIDs
                && unresolvedInGroup.isEmpty
            if groupIsVerified {
                verifiedGroups.insert(decision.clusterID)
                retainedNonredundant.formUnion(retainedIDs)
            } else {
                unresolvedGroups.insert(decision.clusterID)
            }
        }

        func sorted(_ ids: Set<UUID>) -> [UUID] {
            ids.sorted {
                $0.uuidString.lowercased() < $1.uuidString.lowercased()
            }
        }

        return LibrarySlimmingIdenticalCleanupVerification(
            observedAssetIDs: sorted(Set(statesByAssetID.keys)),
            currentAvailableAssetIDs: sorted(currentAvailable),
            retainedNonredundantAssetIDs: sorted(retainedNonredundant),
            recycledRedundantAssetIDs: sorted(recycledRedundant),
            remainingRedundantAssetIDs: sorted(remainingRedundant),
            unresolvedAssetIDs: sorted(unresolved),
            verifiedGroupIDs: sorted(verifiedGroups),
            unresolvedGroupIDs: sorted(unresolvedGroups)
        )
    }

    func moveAssetsToRecycle(assetIDs: [UUID]) throws -> LibrarySlimmingRecycleMoveOutcome {
        try moveAssetsToRecycle(assetIDs: assetIDs, onProgress: { _ in })
    }

    func moveAssetsToRecycle(
        assetIDs: [UUID],
        onProgress: @escaping LibrarySlimmingRecycleMoveProgressHandler
    ) throws -> LibrarySlimmingRecycleMoveOutcome {
        let reporter = RecycleMoveProgressReporter(
            totalAssetCount: assetIDs.count,
            totalFileBytes: (try? estimatedTotalFileBytes(assetIDs: assetIDs)) ?? 0,
            handler: onProgress
        )
        let startedAt = DispatchTime.now().uptimeNanoseconds
        defer {
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
            librarySlimmingRecyclePerformanceLogger.notice(
                "batch_completed assets=\(assetIDs.count, privacy: .public) elapsed_ms=\(elapsedMs, privacy: .public)"
            )
        }
        if let interactiveIOGate {
            return try interactiveIOGate.withInteractiveWork(
                onWaitingForBackground: {
                    reporter.report(.waitingForBackgroundIO)
                },
                onReady: {
                    reporter.report(.preparing)
                }
            ) {
                try moveAssetsToRecycleWithInteractivePriority(
                    assetIDs: assetIDs,
                    reporter: reporter,
                    mode: .recoverableRecycle
                )
            }
        }
        reporter.report(.preparing)
        return try moveAssetsToRecycleWithInteractivePriority(
            assetIDs: assetIDs,
            reporter: reporter,
            mode: .recoverableRecycle
        )
    }

    func deleteAssetsImmediately(
        assetIDs: [UUID],
        onProgress: @escaping LibrarySlimmingRecycleMoveProgressHandler
    ) throws -> LibrarySlimmingRecycleMoveOutcome {
        let reporter = RecycleMoveProgressReporter(
            totalAssetCount: assetIDs.count,
            totalFileBytes: 0,
            handler: onProgress
        )
        let startedAt = DispatchTime.now().uptimeNanoseconds
        defer {
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
            librarySlimmingRecyclePerformanceLogger.notice(
                "space_first_batch_completed assets=\(assetIDs.count, privacy: .public) elapsed_ms=\(elapsedMs, privacy: .public)"
            )
        }
        if let interactiveIOGate {
            return try interactiveIOGate.withInteractiveWork(
                onWaitingForBackground: {
                    reporter.report(.waitingForBackgroundIO)
                },
                onReady: {
                    reporter.report(.preparing)
                }
            ) {
                try moveAssetsToRecycleWithInteractivePriority(
                    assetIDs: assetIDs,
                    reporter: reporter,
                    mode: .releaseSourceSpace
                )
            }
        }
        reporter.report(.preparing)
        return try moveAssetsToRecycleWithInteractivePriority(
            assetIDs: assetIDs,
            reporter: reporter,
            mode: .releaseSourceSpace
        )
    }

    private func moveAssetsToRecycleWithInteractivePriority(
        assetIDs: [UUID],
        reporter: RecycleMoveProgressReporter,
        mode: LibrarySlimmingRemovalMode
    ) throws -> LibrarySlimmingRecycleMoveOutcome {
        var outcome = LibrarySlimmingRecycleMoveOutcome(
            recycledEntryIDs: [],
            skippedPhotosAssetIDs: [],
            failedAssetIDs: [],
            authorizationRequiredSourceIDs: [],
            authorizationRequiredAssetIDs: [],
            authorizationDeniedPhotosAssetIDs: [],
            mutationAuthorizationInvalidAssetIDs: [],
            photosMutationFailedAssetIDs: [],
            sourceChangedAssetIDs: []
        )
        if mode == .recoverableRecycle {
            try quarantineIO.ensureQuarantineRoot(at: quarantineRootURL)
        }

        var photosAssets: [AssetSnapshot] = []
        for assetID in assetIDs {
            var reachedTerminalOutcome = true
            do {
                let asset = try loadAssetForRecycle(assetID: assetID)
                guard asset.availability == AssetAvailability.available.rawValue else {
                    throw asset.availability == AssetAvailability.recycled.rawValue
                        ? LibrarySlimmingRecycleError.alreadyRecycled
                        : LibrarySlimmingRecycleError.invalidState
                }
                switch asset.locatorKind {
                case AssetLocatorKind.file.rawValue:
                    switch mode {
                    case .recoverableRecycle:
                        outcome.recycledEntryIDs.append(
                            try recycleFileAsset(asset, reporter: reporter)
                        )
                    case .releaseSourceSpace:
                        _ = try deleteFileAssetImmediately(asset, reporter: reporter)
                        outcome.permanentlyDeletedAssetIDs.append(asset.assetID)
                    }
                case AssetLocatorKind.photos.rawValue:
                    guard let localIdentifier = asset.photosLocalIdentifier,
                          !localIdentifier.isEmpty
                    else {
                        throw LibrarySlimmingRecycleError.invalidState
                    }
                    photosAssets.append(asset)
                    reachedTerminalOutcome = false
                default:
                    throw LibrarySlimmingRecycleError.invalidState
                }
            } catch LibrarySlimmingRecycleError.mutationAuthorizationRequired {
                reachedTerminalOutcome = false
                if let sourceID = try? loadSourceID(assetID: assetID) {
                    if !outcome.authorizationRequiredSourceIDs.contains(sourceID) {
                        outcome.authorizationRequiredSourceIDs.append(sourceID)
                    }
                }
                outcome.failedAssetIDs.append(assetID)
                outcome.authorizationRequiredAssetIDs.append(assetID)
            } catch LibrarySlimmingRecycleError.mutationAuthorizationInvalid {
                outcome.failedAssetIDs.append(assetID)
                outcome.mutationAuthorizationInvalidAssetIDs.append(assetID)
            } catch LibrarySlimmingRecycleError.photosAuthorizationRequired {
                reachedTerminalOutcome = false
                outcome.failedAssetIDs.append(assetID)
                outcome.authorizationDeniedPhotosAssetIDs.append(assetID)
            } catch LibrarySlimmingRecycleError.photosMutationFailed {
                outcome.failedAssetIDs.append(assetID)
                outcome.photosMutationFailedAssetIDs.append(assetID)
            } catch LibrarySlimmingRecycleError.sourceChanged {
                outcome.failedAssetIDs.append(assetID)
                outcome.sourceChangedAssetIDs.append(assetID)
            } catch LibrarySlimmingRecycleError.durabilityPending {
                outcome.durabilityPendingAssetIDs.append(assetID)
            } catch {
                outcome.failedAssetIDs.append(assetID)
            }
            if reachedTerminalOutcome {
                reporter.recordCompletedAsset()
            }
        }
        if !photosAssets.isEmpty {
            let photosAssetIDs = photosAssets.map(\.assetID)
            var reachedTerminalOutcome = true
            do {
                reporter.report(.photosSystemMutation)
                outcome.recycledEntryIDs.append(
                    contentsOf: try recyclePhotosAssets(photosAssets)
                )
            } catch LibrarySlimmingRecycleError.photosAuthorizationRequired {
                reachedTerminalOutcome = false
                outcome.failedAssetIDs.append(contentsOf: photosAssetIDs)
                outcome.authorizationDeniedPhotosAssetIDs.append(contentsOf: photosAssetIDs)
            } catch LibrarySlimmingRecycleError.photosMutationFailed {
                outcome.failedAssetIDs.append(contentsOf: photosAssetIDs)
                outcome.photosMutationFailedAssetIDs.append(contentsOf: photosAssetIDs)
            } catch LibrarySlimmingRecycleError.sourceChanged {
                outcome.failedAssetIDs.append(contentsOf: photosAssetIDs)
                outcome.sourceChangedAssetIDs.append(contentsOf: photosAssetIDs)
            } catch let failure as PhotosMutationAttemptFailure {
                outcome.failedAssetIDs.append(contentsOf: photosAssetIDs)
                outcome.photosMutationFailedAssetIDs.append(contentsOf: photosAssetIDs)
                outcome.photosMutationFailureCategories.append(
                    failure.diagnostic.category
                )
                outcome.photosMutationFailureCodes.append(
                    failure.diagnostic.displayCode
                )
            } catch {
                outcome.failedAssetIDs.append(contentsOf: photosAssetIDs)
            }
            if reachedTerminalOutcome {
                for _ in photosAssetIDs {
                    reporter.recordCompletedAsset()
                }
            }
        }
        return outcome
    }

    func moveIdenticalCleanupAssetsToRecycle(
        plan: LibrarySlimmingIdenticalCleanupPlan,
        onProgress: @escaping LibrarySlimmingRecycleMoveProgressHandler
    ) throws -> LibrarySlimmingRecycleMoveOutcome {
        try validateIdenticalCleanupProofs(plan)
        if let blocked = preflightIdenticalCleanupMutationAuthorization(plan) {
            return blocked
        }
        return try moveAssetsToRecycle(
            assetIDs: plan.assetIDsToRecycle,
            onProgress: onProgress
        )
    }

    func deleteIdenticalCleanupAssetsImmediately(
        plan: LibrarySlimmingIdenticalCleanupPlan,
        onProgress: @escaping LibrarySlimmingRecycleMoveProgressHandler
    ) throws -> LibrarySlimmingRecycleMoveOutcome {
        try validateIdenticalCleanupProofs(plan)
        if let blocked = preflightIdenticalCleanupMutationAuthorization(plan) {
            return blocked
        }
        return try deleteAssetsImmediately(
            assetIDs: plan.assetIDsToRecycle,
            onProgress: onProgress
        )
    }

    private func preflightIdenticalCleanupMutationAuthorization(
        _ plan: LibrarySlimmingIdenticalCleanupPlan
    ) -> LibrarySlimmingRecycleMoveOutcome? {
        let deletionIDs = Set(plan.assetIDsToRecycle)
        let deletionProofs = plan.assetProofs.filter {
            deletionIDs.contains($0.assetID)
        }
        var failedAssetIDs = Set<UUID>()
        var authorizationRequiredSourceIDs = Set<UUID>()
        var authorizationRequiredAssetIDs = Set<UUID>()
        var authorizationDeniedPhotosAssetIDs = Set<UUID>()
        var mutationAuthorizationInvalidAssetIDs = Set<UUID>()

        let fileProofsBySource = Dictionary(grouping: deletionProofs.filter {
            $0.sourceKind == .file
        }, by: \.sourceID)
        for (sourceID, proofs) in fileProofsBySource {
            do {
                try mutationAccess.withWritableSourceRoot(sourceID: sourceID) { _ in () }
            } catch LibrarySlimmingRecycleError.mutationAuthorizationRequired {
                authorizationRequiredSourceIDs.insert(sourceID)
                authorizationRequiredAssetIDs.formUnion(proofs.map(\.assetID))
                failedAssetIDs.formUnion(proofs.map(\.assetID))
            } catch LibrarySlimmingRecycleError.mutationAuthorizationInvalid {
                mutationAuthorizationInvalidAssetIDs.formUnion(proofs.map(\.assetID))
                failedAssetIDs.formUnion(proofs.map(\.assetID))
            } catch {
                failedAssetIDs.formUnion(proofs.map(\.assetID))
            }
        }

        let photosAssetIDs = Set(
            deletionProofs
                .filter { $0.sourceKind == .photos }
                .map(\.assetID)
        )
        if !photosAssetIDs.isEmpty {
            let isAuthorized = photosMutation?.authorizationState() == .authorized
            if !isAuthorized {
                authorizationDeniedPhotosAssetIDs.formUnion(photosAssetIDs)
                failedAssetIDs.formUnion(photosAssetIDs)
            }
        }

        guard !failedAssetIDs.isEmpty else {
            return nil
        }
        // One-click cleanup is all-or-nothing at the authorization gate: do
        // not start any file or PhotoKit mutation while another member still
        // needs authorization or has an invalid writable source.
        failedAssetIDs.formUnion(deletionIDs)
        func sorted(_ ids: Set<UUID>) -> [UUID] {
            ids.sorted {
                $0.uuidString.lowercased() < $1.uuidString.lowercased()
            }
        }
        return LibrarySlimmingRecycleMoveOutcome(
            recycledEntryIDs: [],
            skippedPhotosAssetIDs: [],
            failedAssetIDs: sorted(failedAssetIDs),
            authorizationRequiredSourceIDs: sorted(authorizationRequiredSourceIDs),
            authorizationRequiredAssetIDs: sorted(authorizationRequiredAssetIDs),
            authorizationDeniedPhotosAssetIDs: sorted(authorizationDeniedPhotosAssetIDs),
            mutationAuthorizationInvalidAssetIDs: sorted(mutationAuthorizationInvalidAssetIDs),
            photosMutationFailedAssetIDs: [],
            sourceChangedAssetIDs: []
        )
    }

    private func validateIdenticalCleanupProofs(
        _ plan: LibrarySlimmingIdenticalCleanupPlan
    ) throws {
        let plannedAssetIDs = Set(plan.survivorAssetIDs + plan.assetIDsToRecycle)
        guard !plannedAssetIDs.isEmpty,
              plan.assetProofs.count == plannedAssetIDs.count,
              Set(plan.assetProofs.map(\.assetID)) == plannedAssetIDs
        else {
            throw LibrarySlimmingRecycleError.cleanupPlanChanged
        }
        let current = try loadIdenticalCleanupFacts(assetIDs: Array(plannedAssetIDs))
        let currentProofs = Dictionary(
            current.map { ($0.proof.assetID, $0.proof) },
            uniquingKeysWith: { first, _ in first }
        )
        let previewedProofs = Dictionary(
            plan.assetProofs.map { ($0.assetID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        guard currentProofs == previewedProofs else {
            throw LibrarySlimmingRecycleError.cleanupPlanChanged
        }
        var assignedAssetIDs = Set<UUID>()
        for decision in plan.decisions {
            let groupIDs = Set(decision.assetIDsToRecycle + decision.retainedAssetIDs)
            let hashes = Set(groupIDs.compactMap {
                currentProofs[$0]?.verifiedOriginalSHA256
            })
            guard Set(decision.assetIDsToRecycle).isDisjoint(with: decision.retainedAssetIDs),
                  Set(decision.assetIDsToRecycle).count == decision.assetIDsToRecycle.count,
                  hashes.count == 1,
                  groupIDs.count >= 2,
                  assignedAssetIDs.isDisjoint(with: groupIDs)
            else {
                throw LibrarySlimmingRecycleError.cleanupPlanChanged
            }
            assignedAssetIDs.formUnion(groupIDs)
        }
        guard assignedAssetIDs == plannedAssetIDs else {
            throw LibrarySlimmingRecycleError.cleanupPlanChanged
        }
    }

    func listRecycleBinEntries() throws -> [RecycleEntryRecord] {
        try database.pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                WITH latest_attempt AS (
                    SELECT
                        r.*,
                        r.rowid AS recycle_rowid,
                        ROW_NUMBER() OVER (
                            PARTITION BY r.asset_id
                            ORDER BY r.created_at_ms DESC, r.rowid DESC
                        ) AS lifecycle_rank
                    FROM recycle_entry AS r
                    WHERE r.asset_id IS NOT NULL
                )
                SELECT
                    r.id, r.asset_id, a.source_id, r.source_kind, r.trashed_at_ms, r.purge_after_ms,
                    r.state, r.quarantine_relative_path, r.original_relative_path,
                    r.photos_local_identifier, r.error_code, a.file_name, a.media_kind
                FROM latest_attempt AS r
                JOIN asset a ON a.id = r.asset_id
                WHERE r.lifecycle_rank = 1
                  AND r.state NOT IN ('restored', 'purged')
                  AND (
                      r.source_kind <> 'file'
                      OR r.error_code IS NULL
                      OR r.error_code NOT IN (?, ?)
                  )
                ORDER BY r.created_at_ms DESC, r.recycle_rowid DESC
                """,
                arguments: [
                    RecycleFailureCode.spaceFirstSourceDeletionPending,
                    RecycleFailureCode.spaceFirstAppCacheCleanupPending,
                ]
            )
            return rows.compactMap(Self.mapRecycleEntryRecord)
        }
    }

    func listRecycledEntries() throws -> [RecycleEntryRecord] {
        try listRecycleBinEntries().filter { $0.state == .recycled }
    }

    func discardFailedPreflightEntry(entryID: UUID) throws {
        try database.pool.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT
                    r.source_kind, r.state, r.original_relative_path,
                    r.photos_local_identifier, r.error_code
                FROM recycle_entry AS r
                JOIN asset AS a ON a.id = r.asset_id
                WHERE r.id = ?
                """,
                arguments: [entryID.uuidString.lowercased()]
            ) else {
                throw LibrarySlimmingRecycleError.notFound
            }
            let sourceKind: String = row["source_kind"]
            let state: String = row["state"]
            let originalRelativePath: String? = row["original_relative_path"]
            let photosLocalIdentifier: String? = row["photos_local_identifier"]
            let errorCode: String? = row["error_code"]
            guard sourceKind == RecycleSourceKind.file.rawValue,
                  state == RecycleEntryState.failed.rawValue,
                  originalRelativePath != nil,
                  photosLocalIdentifier == nil,
                  errorCode == RecycleFailureCode.mutationAuthorizationRequired
            else {
                throw LibrarySlimmingRecycleError.invalidState
            }
            try db.execute(
                sql: """
                DELETE FROM recycle_entry
                WHERE id = ?
                  AND state = 'failed'
                  AND source_kind = 'file'
                  AND error_code = ?
                """,
                arguments: [
                    entryID.uuidString.lowercased(),
                    RecycleFailureCode.mutationAuthorizationRequired,
                ]
            )
            guard db.changesCount == 1 else {
                throw LibrarySlimmingRecycleError.invalidState
            }
        }
    }

    func retryInterruptedEntry(entryID: UUID) throws {
        let snapshot = try loadActiveEntry(entryID: entryID)
        switch snapshot.state {
        case .pending:
            _ = try recoverPending(snapshot)
        case .restoring:
            try recoverRestoring(snapshot)
        case .purging:
            try recoverPurging(snapshot)
        case .failed:
            try reinspectFailedEntry(snapshot)
        case .recycled, .restored, .purged:
            throw LibrarySlimmingRecycleError.invalidState
        }
    }

    func restore(entryID: UUID) throws {
        let snapshot = try loadActiveEntry(entryID: entryID)
        guard snapshot.state == .recycled else {
            throw LibrarySlimmingRecycleError.invalidState
        }
        switch snapshot.sourceKind {
        case .file:
            try restoreFileEntry(snapshot)
        case .photos:
            try restorePhotosEntry(snapshot)
        }
    }

    func purgeNow(entryID: UUID) throws {
        let snapshot = try loadActiveEntry(entryID: entryID)
        guard snapshot.state == .recycled else {
            throw LibrarySlimmingRecycleError.invalidState
        }
        switch snapshot.sourceKind {
        case .file:
            try purgeFileEntry(snapshot)
        case .photos:
            try purgePhotosEntry(snapshot)
        }
    }

    func purgeExpired(nowMs: Int64) throws -> Int {
        _ = try? reconcilePhotosRecycleEntries()
        let interruptedPurges = try loadInterruptedEntries().filter {
            $0.state == .purging
        }
        var purged = 0
        for entry in interruptedPurges {
            do {
                try recoverPurging(entry)
                purged += 1
            } catch {
                continue
            }
        }
        let dueIDs: [UUID] = try database.pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id FROM recycle_entry
                WHERE state = 'recycled' AND purge_after_ms <= ?
                  AND NOT EXISTS (
                      SELECT 1 FROM asset_favorite_state favorite
                      WHERE favorite.asset_id = recycle_entry.asset_id
                        AND (
                            favorite.desired_value = 1
                            OR favorite.photos_observed_value = 1
                        )
                  )
                ORDER BY purge_after_ms ASC, id ASC
                """,
                arguments: [nowMs]
            )
            return rows.compactMap { UUID(uuidString: $0["id"]) }
        }
        for id in dueIDs {
            do {
                try purgeNow(entryID: id)
                purged += 1
            } catch {
                continue
            }
        }
        return purged
    }

    func enqueuePurgeExpired() throws {
        guard let jobQueue else { return }
        guard let earliestPurgeAfterMs = try database.pool.read({ db in
            try Int64.fetchOne(
                db,
                sql: """
                SELECT MIN(
                    CASE WHEN state = 'purging' THEN updated_at_ms ELSE purge_after_ms END
                )
                FROM recycle_entry
                WHERE state = 'purging'
                   OR (
                        state = 'recycled'
                        AND NOT EXISTS (
                            SELECT 1 FROM asset_favorite_state favorite
                            WHERE favorite.asset_id = recycle_entry.asset_id
                              AND (
                                  favorite.desired_value = 1
                                  OR favorite.photos_observed_value = 1
                              )
                        )
                   )
                """
            )
        }) else {
            return
        }
        let command = try LibrarySlimmingPurgeJobFactory.makeEnqueueCommand(
            jobID: idGenerator(),
            notBeforeMs: earliestPurgeAfterMs
        )
        do {
            _ = try jobQueue.enqueue(command)
        } catch JobQueueError.activeCoalescingConflict {
            // Existing singleton already covers the earliest outstanding deadline.
        }
    }

    @discardableResult
    func recoverInterruptedOperations() throws -> Int {
        try quarantineIO.ensureQuarantineRoot(at: quarantineRootURL)
        let entries = try loadInterruptedEntries()
        var recovered = 0
        for entry in entries {
            do {
                switch entry.state {
                case .pending:
                    if try recoverPending(entry) {
                        recovered += 1
                    }
                case .restoring:
                    try recoverRestoring(entry)
                    recovered += 1
                case .purging:
                    try recoverPurging(entry)
                    recovered += 1
                case .recycled, .restored, .purged, .failed:
                    continue
                }
            } catch {
                continue
            }
        }
        recovered += try reconcilePhotosRecycleEntries()
        return recovered
    }

    @discardableResult
    func reconcilePhotosRecycleEntries() throws -> Int {
        guard let photosMutation else { return 0 }
        let entries = try loadPhotosRecycledEntries()
        let indexedEntries = entries.compactMap { entry -> (EntrySnapshot, String)? in
            guard let rawIdentifier = entry.photosLocalIdentifier else { return nil }
            let identifier = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            return identifier.isEmpty ? nil : (entry, identifier)
        }
        guard !indexedEntries.isEmpty else { return 0 }
        let presenceByIdentifier: [String: PhotosAssetPresence]
        do {
            presenceByIdentifier = try photosMutation.presences(
                localIdentifiers: indexedEntries.map(\.1)
            )
        } catch PhotosLibraryMutationError.authorizationDenied,
                PhotosLibraryMutationError.authorizationRestricted,
                PhotosLibraryMutationError.notDetermined
        {
            return 0
        } catch {
            return 0
        }
        var converged = 0
        for (entry, localIdentifier) in indexedEntries {
            guard let presence = presenceByIdentifier[localIdentifier] else { continue }
            switch presence {
            case .available:
                if clock.nowMs - entry.trashedAtMs
                    < LibrarySlimmingRecyclePolicy.photosDeleteConvergenceGraceMs
                {
                    continue
                }
                try markPhotosRestored(entry)
                converged += 1
            case .missing:
                if entry.purgeAfterMs <= clock.nowMs {
                    try transitionEntry(
                        entryID: entry.id,
                        from: .recycled,
                        to: .purging,
                        errorCode: nil
                    )
                    try pixelCachePurger?.purge(assetID: entry.assetID)
                    try finalizePurged(entry)
                    converged += 1
                }
            case .recentlyDeleted:
                if entry.purgeAfterMs <= clock.nowMs {
                    try transitionEntry(
                        entryID: entry.id,
                        from: .recycled,
                        to: .purging,
                        errorCode: nil
                    )
                    try pixelCachePurger?.purge(assetID: entry.assetID)
                    try finalizePurged(entry)
                    converged += 1
                }
            }
        }
        return converged
    }

    func slimmingHiddenAssetIDs(from assetIDs: [UUID]) throws -> Set<UUID> {
        guard !assetIDs.isEmpty else { return [] }
        let normalized = assetIDs.map { $0.uuidString.lowercased() }
        let placeholders = Array(repeating: "?", count: normalized.count).joined(separator: ", ")
        return try database.pool.read { db in
            var hidden = Set<UUID>()
            let recycledRows = try Row.fetchAll(
                db,
                sql: """
                SELECT id FROM asset
                WHERE id IN (\(placeholders)) AND availability = 'recycled'
                """,
                arguments: StatementArguments(normalized)
            )
            for row in recycledRows {
                if let id = UUID(uuidString: row["id"]) {
                    hidden.insert(id)
                }
            }
            let pendingRows = try Row.fetchAll(
                db,
                sql: """
                SELECT asset_id FROM recycle_entry
                WHERE asset_id IN (\(placeholders))
                  AND state IN ('recycled', 'pending')
                """,
                arguments: StatementArguments(normalized)
            )
            for row in pendingRows {
                if let id = UUID(uuidString: row["asset_id"]) {
                    hidden.insert(id)
                }
            }
            return hidden
        }
    }

    func restoredAssetReplacements(from assetIDs: [UUID]) throws -> [UUID: UUID] {
        guard !assetIDs.isEmpty else { return [:] }
        var replacements: [UUID: UUID] = [:]
        let normalized = Array(Set(assetIDs)).map { $0.uuidString.lowercased() }
        for start in stride(from: 0, to: normalized.count, by: 400) {
            let chunk = Array(normalized[start ..< min(start + 400, normalized.count)])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            let rows = try database.pool.write { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT historical.id AS historical_id, current.id AS current_id
                    FROM asset AS historical
                    JOIN recycle_entry AS recycle
                      ON recycle.asset_id = historical.id
                     AND recycle.source_kind = 'file'
                     AND recycle.state = 'restored'
                    JOIN asset AS current
                      ON current.source_id = historical.source_id
                     AND current.relative_path = historical.relative_path
                     AND current.locator_kind = 'file'
                     AND current.locator_state = 'current'
                     AND current.availability = 'available'
                     AND current.id != historical.id
                    JOIN file_fingerprint AS historical_file
                      ON historical_file.asset_id = historical.id
                    JOIN file_fingerprint AS current_file
                      ON current_file.asset_id = current.id
                    LEFT JOIN asset_similarity_fingerprint AS historical_similarity
                      ON historical_similarity.asset_id = historical.id
                     AND historical_similarity.content_revision = historical.content_revision
                    LEFT JOIN asset_similarity_fingerprint AS current_similarity
                      ON current_similarity.asset_id = current.id
                     AND current_similarity.content_revision = current.content_revision
                    WHERE historical.id IN (\(placeholders))
                      AND historical.locator_state = 'historical'
                      AND historical.availability = 'missing'
                      AND historical_file.size_bytes = current_file.size_bytes
                      AND historical_file.modified_at_ns = current_file.modified_at_ns
                      AND COALESCE(
                            historical_file.sha256,
                            historical_similarity.content_sha256
                          ) IS NOT NULL
                      AND COALESCE(
                            historical_file.sha256,
                            historical_similarity.content_sha256
                          ) = COALESCE(
                            current_file.sha256,
                            current_similarity.content_sha256
                          )
                    """,
                    arguments: StatementArguments(chunk)
                )
                for row in rows {
                    let historicalID: String = row["historical_id"]
                    let currentID: String = row["current_id"]
                    try db.execute(
                        sql: """
                        INSERT INTO asset_favorite_state (
                            asset_id, desired_value, photos_observed_value,
                            sync_status, intent_revision, requested_at_ms,
                            photos_observed_modified_at_ms,
                            photos_write_modified_at_ms, last_error_code, updated_at_ms
                        )
                        SELECT ?, desired_value, photos_observed_value,
                               sync_status, intent_revision, requested_at_ms,
                               photos_observed_modified_at_ms,
                               photos_write_modified_at_ms, last_error_code, updated_at_ms
                        FROM asset_favorite_state WHERE asset_id = ?
                        ON CONFLICT(asset_id) DO UPDATE SET
                            desired_value = excluded.desired_value,
                            photos_observed_value = excluded.photos_observed_value,
                            sync_status = excluded.sync_status,
                            intent_revision = MAX(
                                asset_favorite_state.intent_revision,
                                excluded.intent_revision
                            ),
                            requested_at_ms = excluded.requested_at_ms,
                            photos_observed_modified_at_ms = excluded.photos_observed_modified_at_ms,
                            photos_write_modified_at_ms = excluded.photos_write_modified_at_ms,
                            last_error_code = excluded.last_error_code,
                            updated_at_ms = MAX(
                                asset_favorite_state.updated_at_ms,
                                excluded.updated_at_ms
                            )
                        """,
                        arguments: [currentID, historicalID]
                    )
                    try db.execute(
                        sql: "DELETE FROM asset_favorite_state WHERE asset_id = ?",
                        arguments: [historicalID]
                    )
                }
                return rows
            }
            for row in rows {
                guard let historical = UUID(uuidString: row["historical_id"]),
                      let current = UUID(uuidString: row["current_id"])
                else { continue }
                replacements[historical] = current
            }
        }
        return replacements
    }

    // MARK: - Private

    private struct AssetSnapshot {
        let assetID: UUID
        let sourceID: UUID
        let locatorKind: String
        let relativePath: String?
        let photosLocalIdentifier: String?
        let fileName: String?
        let availability: String
        let sizeBytes: Int64?
        let modifiedAtNs: Int64?
        let resourceID: Data?
        let sha256: Data?
    }

    private struct EntrySnapshot {
        let id: UUID
        let assetID: UUID
        let sourceKind: RecycleSourceKind
        let state: RecycleEntryState
        let quarantineRelativePath: String?
        let originalRelativePath: String?
        let photosLocalIdentifier: String?
        let errorCode: String?
        let trashedAtMs: Int64
        let purgeAfterMs: Int64
    }

    private func recycleFileAsset(
        _ asset: AssetSnapshot,
        reporter: RecycleMoveProgressReporter
    ) throws -> UUID {
        guard let relativePath = asset.relativePath else {
            throw LibrarySlimmingRecycleError.invalidState
        }
        let fileName = asset.fileName
            ?? RelativePathRules.fileName(from: relativePath)
            ?? "asset"
        let quarantineRelative = QuarantinePathLayout.relativePath(
            sourceID: asset.sourceID,
            assetID: asset.assetID,
            fileName: fileName
        )
        let entryID = idGenerator()
        let now = clock.nowMs
        let purgeAfter = LibrarySlimmingRecyclePolicy.purgeAfterMs(trashedAtMs: now)
        guard let sizeBytes = asset.sizeBytes,
              let modifiedAtNs = asset.modifiedAtNs,
              asset.sha256 == nil || asset.sha256?.count == 32
        else {
            throw LibrarySlimmingRecycleError.sourceChanged
        }
        let expectedIdentity = FolderQuarantineExpectedIdentity(
            sizeBytes: sizeBytes,
            modifiedAtNs: modifiedAtNs,
            resourceID: asset.resourceID,
            sha256: asset.sha256
        )

        try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO recycle_entry (
                    id, asset_id, source_kind, trashed_at_ms, purge_after_ms, state,
                    quarantine_relative_path, original_relative_path, photos_local_identifier,
                    error_code, created_at_ms, updated_at_ms
                )
                SELECT ?, asset.id, 'file', ?, ?, 'pending', ?, ?, NULL, NULL, ?, ?
                FROM asset
                JOIN source ON source.id = asset.source_id
                WHERE asset.id = ?
                  AND asset.source_id = ?
                  AND asset.locator_state = 'current'
                  AND asset.availability = 'available'
                  AND source.kind = 'folder'
                  AND source.state = 'active'
                """,
                arguments: [
                    entryID.uuidString.lowercased(),
                    now,
                    purgeAfter,
                    quarantineRelative,
                    relativePath,
                    now,
                    now,
                    asset.assetID.uuidString.lowercased(),
                    asset.sourceID.uuidString.lowercased(),
                ]
            )
            guard db.changesCount == 1 else {
                throw LibrarySlimmingRecycleError.invalidState
            }
        }

        do {
            try mutationAccess.withWritableSourceRoot(sourceID: asset.sourceID) { sourceRoot in
                var instrumentedIO = quarantineIO
                let existingStarted = instrumentedIO.onPhaseStarted
                let existingCompleted = instrumentedIO.onPhaseCompleted
                let existingBytesCopied = instrumentedIO.onBytesCopied
                instrumentedIO.onPhaseStarted = { phase in
                    existingStarted(phase)
                    reporter.report(Self.recycleMovePhase(for: phase))
                }
                instrumentedIO.onPhaseCompleted = { phase, elapsedMs in
                    existingCompleted(phase, elapsedMs)
                }
                instrumentedIO.onBytesCopied = { copiedBytes in
                    existingBytesCopied(copiedBytes)
                    reporter.recordCopiedBytes(copiedBytes)
                }
                try instrumentedIO.moveIntoQuarantine(
                    sourceRootURL: sourceRoot,
                    sourceRelativePath: relativePath,
                    quarantineRootURL: quarantineRootURL,
                    quarantineRelativePath: quarantineRelative,
                    expectedIdentity: expectedIdentity
                )
            }
        } catch LibrarySlimmingRecycleError.mutationAuthorizationRequired {
            try markFailed(
                entryID: entryID,
                code: RecycleFailureCode.mutationAuthorizationRequired
            )
            throw LibrarySlimmingRecycleError.mutationAuthorizationRequired
        } catch LibrarySlimmingRecycleError.mutationAuthorizationInvalid {
            try markFailed(
                entryID: entryID,
                code: RecycleFailureCode.mutationAuthorizationInvalid
            )
            throw LibrarySlimmingRecycleError.mutationAuthorizationInvalid
        } catch FolderQuarantineIOError.verificationFailed {
            try markFailed(entryID: entryID, code: RecycleFailureCode.sourceChanged)
            throw LibrarySlimmingRecycleError.sourceChanged
        } catch FolderQuarantineIOError.durabilityUncertain {
            // Keep `pending`: recovery compares both namespace locations and
            // converges to recycled without risking a second destructive move.
            throw LibrarySlimmingRecycleError.ioFailure
        } catch {
            try markFailed(entryID: entryID, code: RecycleFailureCode.ioFailure)
            throw LibrarySlimmingRecycleError.ioFailure
        }

        try database.pool.write { db in
            try db.execute(
                sql: """
                UPDATE recycle_entry
                SET state = 'recycled',
                    quarantine_relative_path = ?,
                    error_code = NULL,
                    updated_at_ms = ?
                WHERE id = ?
                """,
                arguments: [
                    quarantineRelative,
                    clock.nowMs,
                    entryID.uuidString.lowercased(),
                ]
            )
            try db.execute(
                sql: """
                UPDATE asset
                SET availability = 'recycled', record_updated_at_ms = ?
                WHERE id = ?
                """,
                arguments: [
                    clock.nowMs,
                    asset.assetID.uuidString.lowercased(),
                ]
            )
        }
        return entryID
    }

    private func deleteFileAssetImmediately(
        _ asset: AssetSnapshot,
        reporter: RecycleMoveProgressReporter
    ) throws -> UUID {
        guard let relativePath = asset.relativePath,
              let sizeBytes = asset.sizeBytes,
              let modifiedAtNs = asset.modifiedAtNs,
              asset.resourceID != nil || asset.sha256 != nil,
              asset.sha256 == nil || asset.sha256?.count == 32
        else {
            throw LibrarySlimmingRecycleError.sourceChanged
        }
        let entryID = idGenerator()
        let now = clock.nowMs
        let expectedIdentity = FolderQuarantineExpectedIdentity(
            sizeBytes: sizeBytes,
            modifiedAtNs: modifiedAtNs,
            resourceID: asset.resourceID,
            sha256: asset.sha256
        )

        try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO recycle_entry (
                    id, asset_id, source_kind, trashed_at_ms, purge_after_ms, state,
                    quarantine_relative_path, original_relative_path, photos_local_identifier,
                    error_code, created_at_ms, updated_at_ms
                )
                SELECT ?, asset.id, 'file', ?, ?, 'pending', NULL, ?, NULL, ?, ?, ?
                FROM asset
                JOIN source ON source.id = asset.source_id
                WHERE asset.id = ?
                  AND asset.source_id = ?
                  AND asset.locator_state = 'current'
                  AND asset.availability = 'available'
                  AND source.kind = 'folder'
                  AND source.state = 'active'
                """,
                arguments: [
                    entryID.uuidString.lowercased(),
                    now,
                    now,
                    relativePath,
                    RecycleFailureCode.spaceFirstSourceDeletionPending,
                    now,
                    now,
                    asset.assetID.uuidString.lowercased(),
                    asset.sourceID.uuidString.lowercased(),
                ]
            )
            guard db.changesCount == 1 else {
                throw LibrarySlimmingRecycleError.invalidState
            }
        }

        do {
            try mutationAccess.withWritableSourceRoot(sourceID: asset.sourceID) { sourceRoot in
                var instrumentedIO = quarantineIO
                let existingStarted = instrumentedIO.onPhaseStarted
                let existingCompleted = instrumentedIO.onPhaseCompleted
                instrumentedIO.onPhaseStarted = { phase in
                    existingStarted(phase)
                    reporter.report(Self.recycleMovePhase(for: phase))
                }
                instrumentedIO.onPhaseCompleted = { phase, elapsedMs in
                    existingCompleted(phase, elapsedMs)
                }
                try instrumentedIO.deleteSourceImmediately(
                    sourceRootURL: sourceRoot,
                    sourceRelativePath: relativePath,
                    expectedIdentity: expectedIdentity
                )
            }
        } catch LibrarySlimmingRecycleError.mutationAuthorizationRequired {
            try markFailed(
                entryID: entryID,
                code: RecycleFailureCode.mutationAuthorizationRequired
            )
            throw LibrarySlimmingRecycleError.mutationAuthorizationRequired
        } catch LibrarySlimmingRecycleError.mutationAuthorizationInvalid {
            try markFailed(
                entryID: entryID,
                code: RecycleFailureCode.mutationAuthorizationInvalid
            )
            throw LibrarySlimmingRecycleError.mutationAuthorizationInvalid
        } catch FolderQuarantineIOError.verificationFailed {
            try markFailed(entryID: entryID, code: RecycleFailureCode.sourceChanged)
            throw LibrarySlimmingRecycleError.sourceChanged
        } catch FolderQuarantineIOError.durabilityUncertain {
            // The unlink committed in the current namespace. Keep the pending
            // intent so recovery can observe whether the source path exists.
            throw LibrarySlimmingRecycleError.durabilityPending
        } catch {
            try markFailed(entryID: entryID, code: RecycleFailureCode.ioFailure)
            throw LibrarySlimmingRecycleError.ioFailure
        }

        do {
            try markSpaceFirstSourceDeleted(
                entryID: entryID,
                assetID: asset.assetID
            )
        } catch {
            // The source unlink already committed in the live namespace. Do not
            // report a normal failure and make the optimistic card reappear;
            // the durable pending intent lets startup/background recovery
            // converge the catalog transaction without deleting source bytes a
            // second time.
            throw LibrarySlimmingRecycleError.durabilityPending
        }
        return entryID
    }

    private func markSpaceFirstSourceDeleted(
        entryID: UUID,
        assetID: UUID
    ) throws {
        try database.pool.write { db in
            try db.execute(
                sql: """
                UPDATE recycle_entry
                SET state = 'purging',
                    original_relative_path = NULL,
                    error_code = ?,
                    updated_at_ms = ?
                WHERE id = ?
                  AND asset_id = ?
                  AND state = 'pending'
                  AND error_code = ?
                """,
                arguments: [
                    RecycleFailureCode.spaceFirstAppCacheCleanupPending,
                    clock.nowMs,
                    entryID.uuidString.lowercased(),
                    assetID.uuidString.lowercased(),
                    RecycleFailureCode.spaceFirstSourceDeletionPending,
                ]
            )
            guard db.changesCount == 1 else {
                throw LibrarySlimmingRecycleError.invalidState
            }
            try db.execute(
                sql: """
                UPDATE asset
                SET availability = 'recycled', record_updated_at_ms = ?
                WHERE id = ?
                """,
                arguments: [
                    clock.nowMs,
                    assetID.uuidString.lowercased(),
                ]
            )
            guard db.changesCount == 1 else {
                throw LibrarySlimmingRecycleError.notFound
            }
        }
    }

    private static func recycleMovePhase(
        for phase: FolderQuarantineIOPhase
    ) -> LibrarySlimmingRecycleMovePhase {
        switch phase {
        case .sourceInitialHash, .sourceFinalVerification:
            .verifyingSource
        case .copy:
            .copying
        case .destinationSync, .destinationDirectorySync:
            .syncingDestination
        case .destinationHash:
            .verifyingDestination
        case .unlinkSource:
            .deletingSource
        case .sourceDirectorySync:
            .syncingSourceDirectory
        }
    }

    private func estimatedTotalFileBytes(assetIDs: [UUID]) throws -> Int64 {
        let keys = assetIDs.map { $0.uuidString.lowercased() }
        guard !keys.isEmpty else { return 0 }
        return try database.pool.read { db in
            var total: Int64 = 0
            for chunkStart in stride(from: 0, to: keys.count, by: 500) {
                let chunkEnd = min(chunkStart + 500, keys.count)
                let chunk = Array(keys[chunkStart ..< chunkEnd])
                let placeholders = Array(repeating: "?", count: chunk.count)
                    .joined(separator: ", ")
                let subtotal = try Int64.fetchOne(
                    db,
                    sql: """
                    SELECT COALESCE(SUM(f.size_bytes), 0)
                    FROM asset AS a
                    JOIN file_fingerprint AS f ON f.asset_id = a.id
                    WHERE a.id IN (\(placeholders))
                      AND a.locator_kind = 'file'
                    """,
                    arguments: StatementArguments(chunk)
                ) ?? 0
                let addition = total.addingReportingOverflow(max(0, subtotal))
                total = addition.overflow ? Int64.max : addition.partialValue
            }
            return total
        }
    }

    private func recyclePhotosAssets(_ assets: [AssetSnapshot]) throws -> [UUID] {
        guard !assets.isEmpty else { return [] }
        guard let photosMutation else {
            throw LibrarySlimmingRecycleError.photosAuthorizationRequired
        }
        switch photosMutation.authorizationState() {
        case .authorized:
            break
        case .denied, .restricted, .notDetermined:
            throw LibrarySlimmingRecycleError.photosAuthorizationRequired
        }

        let now = clock.nowMs
        let purgeAfter = LibrarySlimmingRecyclePolicy.purgeAfterMs(trashedAtMs: now)
        let pendingEntries: [(asset: AssetSnapshot, entryID: UUID, localIdentifier: String)] =
            try assets.map { asset in
                guard let localIdentifier = asset.photosLocalIdentifier,
                      !localIdentifier.isEmpty
                else {
                    throw LibrarySlimmingRecycleError.invalidState
                }
                return (asset, idGenerator(), localIdentifier)
            }

        try database.pool.write { db in
            for pending in pendingEntries {
                let displayPath = pending.asset.fileName ?? pending.localIdentifier
                try db.execute(
                    sql: """
                    INSERT INTO recycle_entry (
                        id, asset_id, source_kind, trashed_at_ms, purge_after_ms, state,
                        quarantine_relative_path, original_relative_path, photos_local_identifier,
                        error_code, created_at_ms, updated_at_ms
                    )
                    SELECT ?, asset.id, 'photos', ?, ?, 'pending', NULL, ?, ?, NULL, ?, ?
                    FROM asset
                    JOIN source ON source.id = asset.source_id
                    WHERE asset.id = ?
                      AND asset.source_id = ?
                      AND asset.locator_state = 'current'
                      AND asset.availability = 'available'
                      AND source.kind = 'photos'
                      AND source.state = 'active'
                    """,
                    arguments: [
                        pending.entryID.uuidString.lowercased(),
                        now,
                        purgeAfter,
                        displayPath,
                        pending.localIdentifier,
                        now,
                        now,
                        pending.asset.assetID.uuidString.lowercased(),
                        pending.asset.sourceID.uuidString.lowercased(),
                    ]
                )
                guard db.changesCount == 1 else {
                    throw LibrarySlimmingRecycleError.invalidState
                }
            }
        }

        do {
            let movedIdentifiers = try photosMutation.moveToRecentlyDeleted(
                localIdentifiers: pendingEntries.map(\.localIdentifier)
            )
            guard Set(movedIdentifiers) == Set(pendingEntries.map(\.localIdentifier)),
                  movedIdentifiers.count == Set(movedIdentifiers).count
            else {
                throw PhotosLibraryMutationError.changeFailed
            }
        } catch PhotosLibraryMutationError.authorizationDenied,
                PhotosLibraryMutationError.authorizationRestricted,
                PhotosLibraryMutationError.notDetermined
        {
            for pending in pendingEntries {
                try markFailed(
                    entryID: pending.entryID,
                    code: RecycleFailureCode.photosAuthorizationRequired
                )
            }
            throw LibrarySlimmingRecycleError.photosAuthorizationRequired
        } catch PhotosLibraryMutationError.assetNotFound {
            for pending in pendingEntries {
                try markFailed(
                    entryID: pending.entryID,
                    code: RecycleFailureCode.photosAssetNotFound
                )
            }
            throw LibrarySlimmingRecycleError.sourceChanged
        } catch let PhotosLibraryMutationError.systemChangeFailed(diagnostic) {
            for pending in pendingEntries {
                try markFailed(
                    entryID: pending.entryID,
                    code: diagnostic.persistenceCode
                )
            }
            throw PhotosMutationAttemptFailure(diagnostic: diagnostic)
        } catch PhotosLibraryMutationError.changeFailed {
            let diagnostic = PhotosLibraryMutationFailureDiagnostic(
                category: .system,
                domain: "ImageAll.PhotosMutation",
                code: 1
            )
            for pending in pendingEntries {
                try markFailed(
                    entryID: pending.entryID,
                    code: diagnostic.persistenceCode
                )
            }
            throw PhotosMutationAttemptFailure(diagnostic: diagnostic)
        } catch {
            let systemError = error as NSError
            let diagnostic = PhotosLibraryMutationFailureDiagnostic(
                category: .system,
                domain: systemError.domain,
                code: systemError.code
            )
            for pending in pendingEntries {
                try markFailed(
                    entryID: pending.entryID,
                    code: diagnostic.persistenceCode
                )
            }
            throw PhotosMutationAttemptFailure(diagnostic: diagnostic)
        }

        try database.pool.write { db in
            for pending in pendingEntries {
                try db.execute(
                    sql: """
                    UPDATE recycle_entry
                    SET state = 'recycled', error_code = NULL, updated_at_ms = ?
                    WHERE id = ?
                    """,
                    arguments: [clock.nowMs, pending.entryID.uuidString.lowercased()]
                )
                try db.execute(
                    sql: """
                    UPDATE asset
                    SET availability = 'recycled', record_updated_at_ms = ?
                    WHERE id = ?
                    """,
                    arguments: [
                        clock.nowMs,
                        pending.asset.assetID.uuidString.lowercased(),
                    ]
                )
            }
        }
        return pendingEntries.map(\.entryID)
    }

    private func restoreFileEntry(_ snapshot: EntrySnapshot) throws {
        guard let quarantinePath = snapshot.quarantineRelativePath,
              let originalRelativePath = snapshot.originalRelativePath
        else {
            throw LibrarySlimmingRecycleError.invalidState
        }
        let asset = try loadAsset(assetID: snapshot.assetID)
        guard let sizeBytes = asset.sizeBytes,
              let modifiedAtNs = asset.modifiedAtNs,
              asset.sha256 == nil || asset.sha256?.count == 32
        else {
            throw LibrarySlimmingRecycleError.sourceChanged
        }
        let expectedIdentity = FolderQuarantineExpectedIdentity(
            sizeBytes: sizeBytes,
            modifiedAtNs: modifiedAtNs,
            resourceID: nil,
            sha256: asset.sha256
        )
        try transitionEntry(
            entryID: snapshot.id,
            from: .recycled,
            to: .restoring,
            errorCode: nil
        )

        do {
            try mutationAccess.withWritableSourceRoot(sourceID: asset.sourceID) { sourceRoot in
                try quarantineIO.moveOutOfQuarantine(
                    quarantineRootURL: quarantineRootURL,
                    quarantineRelativePath: quarantinePath,
                    sourceRootURL: sourceRoot,
                    originalRelativePath: originalRelativePath,
                    expectedIdentity: expectedIdentity
                )
            }
        } catch FolderQuarantineIOError.targetExists {
            try? transitionEntry(
                entryID: snapshot.id,
                from: .restoring,
                to: .recycled,
                errorCode: "restoreConflict"
            )
            throw LibrarySlimmingRecycleError.restoreConflict
        } catch LibrarySlimmingRecycleError.mutationAuthorizationRequired {
            try? transitionEntry(
                entryID: snapshot.id,
                from: .restoring,
                to: .recycled,
                errorCode: "mutationAuthorizationRequired"
            )
            throw LibrarySlimmingRecycleError.mutationAuthorizationRequired
        } catch LibrarySlimmingRecycleError.mutationAuthorizationInvalid {
            try? transitionEntry(
                entryID: snapshot.id,
                from: .restoring,
                to: .recycled,
                errorCode: RecycleFailureCode.mutationAuthorizationInvalid
            )
            throw LibrarySlimmingRecycleError.mutationAuthorizationInvalid
        } catch FolderQuarantineIOError.durabilityUncertain {
            // Keep `restoring`: recovery determines which side contains the
            // committed object and finalizes the matching catalog state.
            throw LibrarySlimmingRecycleError.ioFailure
        } catch {
            try? transitionEntry(
                entryID: snapshot.id,
                from: .restoring,
                to: .recycled,
                errorCode: "restoreIOFailure"
            )
            throw LibrarySlimmingRecycleError.ioFailure
        }

        try finalizeRestored(snapshot)
    }

    private func restorePhotosEntry(_ snapshot: EntrySnapshot) throws {
        guard let localIdentifier = snapshot.photosLocalIdentifier,
              let photosMutation
        else {
            throw LibrarySlimmingRecycleError.invalidState
        }
        let presence: PhotosAssetPresence
        do {
            presence = try photosMutation.presence(localIdentifier: localIdentifier)
        } catch PhotosLibraryMutationError.authorizationDenied,
                PhotosLibraryMutationError.authorizationRestricted,
                PhotosLibraryMutationError.notDetermined
        {
            throw LibrarySlimmingRecycleError.photosAuthorizationRequired
        } catch {
            throw LibrarySlimmingRecycleError.photosMutationFailed
        }
        switch presence {
        case .available:
            try transitionEntry(
                entryID: snapshot.id,
                from: .recycled,
                to: .restoring,
                errorCode: nil
            )
            try finalizeRestored(snapshot)
        case .recentlyDeleted, .missing:
            throw LibrarySlimmingRecycleError.photosRestoreRequiresPhotosApp
        }
    }

    private func purgeFileEntry(_ snapshot: EntrySnapshot) throws {
        guard let quarantinePath = snapshot.quarantineRelativePath else {
            throw LibrarySlimmingRecycleError.invalidState
        }
        try transitionEntry(
            entryID: snapshot.id,
            from: .recycled,
            to: .purging,
            errorCode: nil
        )
        do {
            try pixelCachePurger?.purge(assetID: snapshot.assetID)
            try quarantineIO.deleteQuarantineObject(
                quarantineRootURL: quarantineRootURL,
                quarantineRelativePath: quarantinePath
            )
        } catch FolderQuarantineIOError.durabilityUncertain {
            // Keep `purging`: recovery finalizes the tombstone if the object is
            // gone, or retries safely if it still exists.
            throw LibrarySlimmingRecycleError.ioFailure
        } catch {
            try? transitionEntry(
                entryID: snapshot.id,
                from: .purging,
                to: .recycled,
                errorCode: "purgeIOFailure"
            )
            throw LibrarySlimmingRecycleError.ioFailure
        }
        try finalizePurged(snapshot)
    }

    private func purgePhotosEntry(_ snapshot: EntrySnapshot) throws {
        throw LibrarySlimmingRecycleError.photosManagedBySystem
    }

    private func markFailed(entryID: UUID, code: String) throws {
        try database.pool.write { db in
            try db.execute(
                sql: """
                UPDATE recycle_entry
                SET state = 'failed', error_code = ?, updated_at_ms = ?
                WHERE id = ?
                """,
                arguments: [code, clock.nowMs, entryID.uuidString.lowercased()]
            )
        }
    }

    private func recoverPending(_ entry: EntrySnapshot) throws -> Bool {
        if entry.sourceKind == .photos {
            guard let localIdentifier = entry.photosLocalIdentifier,
                  let photosMutation
            else {
                try markFailed(entryID: entry.id, code: "interruptedPhotosPending")
                return true
            }
            let presence: PhotosAssetPresence
            do {
                presence = try photosMutation.presence(localIdentifier: localIdentifier)
            } catch PhotosLibraryMutationError.authorizationDenied,
                    PhotosLibraryMutationError.authorizationRestricted,
                    PhotosLibraryMutationError.notDetermined
            {
                throw LibrarySlimmingRecycleError.photosAuthorizationRequired
            } catch {
                throw LibrarySlimmingRecycleError.photosMutationFailed
            }
            switch presence {
            case .available:
                if clock.nowMs - entry.trashedAtMs
                    < LibrarySlimmingRecyclePolicy.photosDeleteConvergenceGraceMs
                {
                    return false
                }
                try markFailed(entryID: entry.id, code: "interruptedBeforePhotosMove")
            case .recentlyDeleted, .missing:
                try finalizeRecycled(entry)
            }
            return true
        }
        if entry.errorCode == RecycleFailureCode.spaceFirstSourceDeletionPending {
            guard let originalRelativePath = entry.originalRelativePath else {
                try markFailed(entryID: entry.id, code: "interruptedFastDeleteMissingPath")
                return true
            }
            let sourceID = try loadSourceID(assetID: entry.assetID)
            let sourceExists = try mutationAccess.withWritableSourceRoot(
                sourceID: sourceID
            ) { root in
                try quarantineIO.objectExists(
                    rootURL: root,
                    relativePath: originalRelativePath
                )
            }
            if sourceExists {
                try markFailed(entryID: entry.id, code: "interruptedBeforeFastDelete")
            } else {
                try markSpaceFirstSourceDeleted(
                    entryID: entry.id,
                    assetID: entry.assetID
                )
                try recoverPurging(
                    EntrySnapshot(
                        id: entry.id,
                        assetID: entry.assetID,
                        sourceKind: entry.sourceKind,
                        state: .purging,
                        quarantineRelativePath: nil,
                        originalRelativePath: nil,
                        photosLocalIdentifier: nil,
                        errorCode: RecycleFailureCode.spaceFirstAppCacheCleanupPending,
                        trashedAtMs: entry.trashedAtMs,
                        purgeAfterMs: entry.purgeAfterMs
                    )
                )
            }
            return true
        }
        guard let quarantinePath = entry.quarantineRelativePath,
              let originalRelativePath = entry.originalRelativePath
        else {
            try markFailed(entryID: entry.id, code: "interruptedBeforeMove")
            return true
        }
        let quarantineExists = try quarantineIO.objectExists(
            rootURL: quarantineRootURL,
            relativePath: quarantinePath
        )
        let sourceID = try loadSourceID(assetID: entry.assetID)
        let sourceExists = try mutationAccess.withWritableSourceRoot(sourceID: sourceID) { root in
            try quarantineIO.objectExists(
                rootURL: root,
                relativePath: originalRelativePath
            )
        }

        switch (sourceExists, quarantineExists) {
        case (false, true):
            try finalizeRecycled(entry)
        case (true, false):
            try markFailed(entryID: entry.id, code: "interruptedBeforeMove")
        case (true, true):
            // The original path may have been recreated after the move completed.
            // Keep both objects: deleting either side would make an ambiguous crash
            // recovery destructive. The user can resolve the retained conflict.
            try markFailed(entryID: entry.id, code: "interruptedConflict")
        case (false, false):
            try markFailed(entryID: entry.id, code: "interruptedMissingBoth")
        }
        return true
    }

    private func reinspectFailedEntry(_ entry: EntrySnapshot) throws {
        guard entry.sourceKind == .file,
              let quarantinePath = entry.quarantineRelativePath,
              let originalRelativePath = entry.originalRelativePath
        else {
            throw LibrarySlimmingRecycleError.durabilityPending
        }
        let quarantineExists = try quarantineIO.objectExists(
            rootURL: quarantineRootURL,
            relativePath: quarantinePath
        )
        let sourceID = try loadSourceID(assetID: entry.assetID)
        let sourceExists = try mutationAccess.withWritableSourceRoot(
            sourceID: sourceID
        ) { root in
            try quarantineIO.objectExists(
                rootURL: root,
                relativePath: originalRelativePath
            )
        }

        switch (sourceExists, quarantineExists) {
        case (true, false):
            try resolveFailedEntry(
                entry,
                as: .restored,
                availability: .available
            )
        case (false, true):
            try resolveFailedEntry(
                entry,
                as: .recycled,
                availability: .recycled
            )
        case (true, true):
            try transitionEntry(
                entryID: entry.id,
                from: .failed,
                to: .failed,
                errorCode: "interruptedConflict"
            )
            throw LibrarySlimmingRecycleError.durabilityPending
        case (false, false):
            try transitionEntry(
                entryID: entry.id,
                from: .failed,
                to: .failed,
                errorCode: "interruptedMissingBoth"
            )
            throw LibrarySlimmingRecycleError.durabilityPending
        }
    }

    private func resolveFailedEntry(
        _ entry: EntrySnapshot,
        as state: RecycleEntryState,
        availability: AssetAvailability
    ) throws {
        guard state == .restored || state == .recycled else {
            throw LibrarySlimmingRecycleError.invalidState
        }
        try database.pool.write { db in
            try db.execute(
                sql: """
                UPDATE recycle_entry
                SET state = ?, error_code = NULL, updated_at_ms = ?
                WHERE id = ? AND asset_id = ? AND state = 'failed'
                """,
                arguments: [
                    state.rawValue,
                    clock.nowMs,
                    entry.id.uuidString.lowercased(),
                    entry.assetID.uuidString.lowercased(),
                ]
            )
            guard db.changesCount == 1 else {
                throw LibrarySlimmingRecycleError.invalidState
            }
            try db.execute(
                sql: """
                UPDATE asset
                SET availability = ?, record_updated_at_ms = ?
                WHERE id = ?
                """,
                arguments: [
                    availability.rawValue,
                    clock.nowMs,
                    entry.assetID.uuidString.lowercased(),
                ]
            )
            guard db.changesCount == 1 else {
                throw LibrarySlimmingRecycleError.notFound
            }
        }
    }

    private func finalizeRecycled(_ entry: EntrySnapshot) throws {
        try database.pool.write { db in
            try db.execute(
                sql: """
                UPDATE recycle_entry
                SET state = 'recycled', error_code = NULL, updated_at_ms = ?
                WHERE id = ? AND state = 'pending'
                """,
                arguments: [clock.nowMs, entry.id.uuidString.lowercased()]
            )
            guard db.changesCount == 1 else {
                throw LibrarySlimmingRecycleError.invalidState
            }
            try db.execute(
                sql: """
                UPDATE asset
                SET availability = 'recycled', record_updated_at_ms = ?
                WHERE id = ?
                """,
                arguments: [clock.nowMs, entry.assetID.uuidString.lowercased()]
            )
            guard db.changesCount == 1 else {
                throw LibrarySlimmingRecycleError.notFound
            }
        }
    }

    private func recoverRestoring(_ entry: EntrySnapshot) throws {
        if entry.sourceKind == .photos {
            guard let localIdentifier = entry.photosLocalIdentifier,
                  let photosMutation
            else {
                try markFailed(entryID: entry.id, code: "interruptedPhotosRestore")
                return
            }
            let presence = (try? photosMutation.presence(localIdentifier: localIdentifier)) ?? .missing
            switch presence {
            case .available:
                try finalizeRestored(entry)
            case .recentlyDeleted, .missing:
                try transitionEntry(
                    entryID: entry.id,
                    from: .restoring,
                    to: .recycled,
                    errorCode: "photosRestoreRequiresPhotosApp"
                )
            }
            return
        }
        guard let quarantinePath = entry.quarantineRelativePath,
              let originalRelativePath = entry.originalRelativePath
        else {
            try markFailed(entryID: entry.id, code: "interruptedRestoreMissingPath")
            return
        }
        let quarantineExists = try quarantineIO.objectExists(
            rootURL: quarantineRootURL,
            relativePath: quarantinePath
        )
        let sourceID = try loadSourceID(assetID: entry.assetID)
        let sourceExists = try mutationAccess.withWritableSourceRoot(sourceID: sourceID) { root in
            try quarantineIO.objectExists(
                rootURL: root,
                relativePath: originalRelativePath
            )
        }

        switch (sourceExists, quarantineExists) {
        case (true, false):
            try finalizeRestored(entry)
        case (false, true):
            try transitionEntry(
                entryID: entry.id,
                from: .restoring,
                to: .recycled,
                errorCode: "interruptedBeforeRestore"
            )
        case (true, true):
            try transitionEntry(
                entryID: entry.id,
                from: .restoring,
                to: .recycled,
                errorCode: "restoreConflict"
            )
        case (false, false):
            try markFailed(entryID: entry.id, code: "interruptedRestoreMissingBoth")
        }
    }

    private func finalizeRestored(_ entry: EntrySnapshot) throws {
        try database.pool.write { db in
            try db.execute(
                sql: """
                UPDATE recycle_entry
                SET state = 'restored', updated_at_ms = ?, error_code = NULL
                WHERE id = ? AND state = 'restoring'
                """,
                arguments: [clock.nowMs, entry.id.uuidString.lowercased()]
            )
            guard db.changesCount == 1 else {
                throw LibrarySlimmingRecycleError.invalidState
            }
            try db.execute(
                sql: """
                UPDATE asset
                SET availability = 'available', record_updated_at_ms = ?
                WHERE id = ?
                """,
                arguments: [clock.nowMs, entry.assetID.uuidString.lowercased()]
            )
            guard db.changesCount == 1 else {
                throw LibrarySlimmingRecycleError.notFound
            }
        }
    }

    private func markPhotosRestored(_ entry: EntrySnapshot) throws {
        try database.pool.write { db in
            try db.execute(
                sql: """
                UPDATE recycle_entry
                SET state = 'restored', updated_at_ms = ?, error_code = NULL
                WHERE id = ? AND state = 'recycled'
                """,
                arguments: [clock.nowMs, entry.id.uuidString.lowercased()]
            )
            guard db.changesCount == 1 else {
                throw LibrarySlimmingRecycleError.invalidState
            }
            try db.execute(
                sql: """
                UPDATE asset
                SET availability = 'available', record_updated_at_ms = ?
                WHERE id = ?
                """,
                arguments: [clock.nowMs, entry.assetID.uuidString.lowercased()]
            )
            guard db.changesCount == 1 else {
                throw LibrarySlimmingRecycleError.notFound
            }
        }
    }

    private func recoverPurging(_ entry: EntrySnapshot) throws {
        if entry.sourceKind == .photos {
            try transitionEntry(
                entryID: entry.id,
                from: .purging,
                to: .recycled,
                errorCode: "photosManagedBySystem"
            )
            return
        }
        try pixelCachePurger?.purge(assetID: entry.assetID)
        if let quarantinePath = entry.quarantineRelativePath {
            let quarantineExists = try quarantineIO.objectExists(
                rootURL: quarantineRootURL,
                relativePath: quarantinePath
            )
            if quarantineExists {
                do {
                    try quarantineIO.deleteQuarantineObject(
                        quarantineRootURL: quarantineRootURL,
                        quarantineRelativePath: quarantinePath
                    )
                } catch FolderQuarantineIOError.durabilityUncertain {
                    // The unlink committed; keep `purging` so a later recovery
                    // can observe the missing object and finalize the tombstone.
                    throw LibrarySlimmingRecycleError.ioFailure
                } catch {
                    try? transitionEntry(
                        entryID: entry.id,
                        from: .purging,
                        to: .recycled,
                        errorCode: "purgeIOFailure"
                    )
                    throw LibrarySlimmingRecycleError.ioFailure
                }
            }
        }
        try finalizePurged(entry)
    }

    private func finalizePurged(_ entry: EntrySnapshot) throws {
        try database.pool.write { db in
            let assetID = entry.assetID.uuidString.lowercased()
            try db.execute(
                sql: """
                UPDATE recycle_entry
                SET quarantine_relative_path = NULL,
                    original_relative_path = NULL,
                    photos_local_identifier = NULL,
                    error_code = NULL,
                    state = 'purged',
                    updated_at_ms = ?
                WHERE id = ? AND asset_id = ? AND state = 'purging'
                """,
                arguments: [
                    clock.nowMs,
                    entry.id.uuidString.lowercased(),
                    assetID,
                ]
            )
            guard db.changesCount == 1 else {
                throw LibrarySlimmingRecycleError.invalidState
            }
            // Keep the recycled catalog row as a non-browseable tombstone. Its
            // tag decisions, fingerprints/features, training samples, and model
            // provenance remain useful knowledge after the original bytes are gone.
        }
    }

    private func transitionEntry(
        entryID: UUID,
        from: RecycleEntryState,
        to: RecycleEntryState,
        errorCode: String?
    ) throws {
        try database.pool.write { db in
            try db.execute(
                sql: """
                UPDATE recycle_entry
                SET state = ?, error_code = ?, updated_at_ms = ?
                WHERE id = ? AND state = ?
                """,
                arguments: [
                    to.rawValue,
                    errorCode,
                    clock.nowMs,
                    entryID.uuidString.lowercased(),
                    from.rawValue,
                ]
            )
            guard db.changesCount == 1 else {
                throw LibrarySlimmingRecycleError.invalidState
            }
        }
    }

    private func loadInterruptedEntries() throws -> [EntrySnapshot] {
        try database.pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT
                    id, asset_id, source_kind, state, quarantine_relative_path,
                    original_relative_path, photos_local_identifier, error_code,
                    trashed_at_ms, purge_after_ms
                FROM recycle_entry
                WHERE state IN ('pending', 'restoring', 'purging')
                ORDER BY updated_at_ms ASC, id ASC
                """
            )
            return rows.compactMap(Self.mapEntrySnapshot)
        }
    }

    private func loadPhotosRecycledEntries() throws -> [EntrySnapshot] {
        try database.pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT
                    id, asset_id, source_kind, state, quarantine_relative_path,
                    original_relative_path, photos_local_identifier, error_code,
                    trashed_at_ms, purge_after_ms
                FROM recycle_entry
                WHERE state = 'recycled' AND source_kind = 'photos'
                ORDER BY updated_at_ms ASC, id ASC
                """
            )
            return rows.compactMap(Self.mapEntrySnapshot)
        }
    }

    private static func mapRecycleEntryRecord(_ row: Row) -> RecycleEntryRecord? {
        guard let id = UUID(uuidString: row["id"]),
              let assetID = UUID(uuidString: row["asset_id"]),
              let sourceID = UUID(uuidString: row["source_id"]),
              let sourceKind = RecycleSourceKind(rawValue: row["source_kind"]),
              let mediaKind = MediaKind(rawValue: row["media_kind"]),
              let state = RecycleEntryState(rawValue: row["state"])
        else {
            return nil
        }
        return RecycleEntryRecord(
            id: id,
            assetID: assetID,
            sourceID: sourceID,
            sourceKind: sourceKind,
            mediaKind: mediaKind,
            trashedAtMs: row["trashed_at_ms"],
            purgeAfterMs: row["purge_after_ms"],
            state: state,
            quarantineRelativePath: row["quarantine_relative_path"],
            originalRelativePath: row["original_relative_path"],
            photosLocalIdentifier: row["photos_local_identifier"],
            errorCode: row["error_code"],
            fileName: row["file_name"]
        )
    }

    private static func mapEntrySnapshot(_ row: Row) -> EntrySnapshot? {
        guard let id = UUID(uuidString: row["id"]),
              let assetID = UUID(uuidString: row["asset_id"]),
              let sourceKind = RecycleSourceKind(rawValue: row["source_kind"]),
              let state = RecycleEntryState(rawValue: row["state"])
        else {
            return nil
        }
        return EntrySnapshot(
            id: id,
            assetID: assetID,
            sourceKind: sourceKind,
            state: state,
            quarantineRelativePath: row["quarantine_relative_path"],
            originalRelativePath: row["original_relative_path"],
            photosLocalIdentifier: row["photos_local_identifier"],
            errorCode: row["error_code"],
            trashedAtMs: row["trashed_at_ms"],
            purgeAfterMs: row["purge_after_ms"]
        )
    }

    private func loadAsset(assetID: UUID) throws -> AssetSnapshot {
        try database.pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT
                    a.id, a.source_id, a.locator_kind, a.relative_path,
                    a.photos_local_identifier, a.file_name, a.availability,
                    f.size_bytes, f.modified_at_ns, f.resource_id,
                    CASE a.media_kind
                        WHEN 'video' THEN f.sha256
                        ELSE COALESCE(
                            f.sha256,
                            CASE
                                WHEN sf.content_digest_origin = 'verifiedOriginalBytes'
                                THEN sf.content_sha256
                            END
                        )
                    END AS sha256
                FROM asset a
                LEFT JOIN file_fingerprint f ON f.asset_id = a.id
                LEFT JOIN asset_similarity_fingerprint sf
                    ON sf.asset_id = a.id
                   AND sf.content_revision = a.content_revision
                WHERE a.id = ?
                """,
                arguments: [assetID.uuidString.lowercased()]
            ),
                let id = UUID(uuidString: row["id"]),
                let sourceID = UUID(uuidString: row["source_id"])
            else {
                throw LibrarySlimmingRecycleError.notFound
            }
            return AssetSnapshot(
                assetID: id,
                sourceID: sourceID,
                locatorKind: row["locator_kind"],
                relativePath: row["relative_path"],
                photosLocalIdentifier: row["photos_local_identifier"],
                fileName: row["file_name"],
                availability: row["availability"],
                sizeBytes: row["size_bytes"],
                modifiedAtNs: row["modified_at_ns"],
                resourceID: row["resource_id"],
                sha256: row["sha256"]
            )
        }
    }

    private func loadAssetForRecycle(assetID: UUID) throws -> AssetSnapshot {
        let eligible = try database.pool.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                SELECT EXISTS(
                    SELECT 1
                    FROM asset a
                    JOIN source s ON s.id = a.source_id
                    WHERE a.id = ?
                      AND a.locator_state = 'current'
                      AND a.availability = 'available'
                      AND s.state = 'active'
                      AND (
                        (a.locator_kind = 'file' AND s.kind = 'folder')
                        OR (a.locator_kind = 'photos' AND s.kind = 'photos')
                      )
                )
                """,
                arguments: [assetID.uuidString.lowercased()]
            ) ?? false
        }
        guard eligible else {
            throw LibrarySlimmingRecycleError.invalidState
        }
        return try loadAsset(assetID: assetID)
    }

    private func loadSourceID(assetID: UUID) throws -> UUID {
        try loadAsset(assetID: assetID).sourceID
    }

    private func loadActiveEntry(entryID: UUID) throws -> EntrySnapshot {
        try database.pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT
                    id, asset_id, source_kind, state, quarantine_relative_path,
                    original_relative_path, photos_local_identifier, error_code,
                    trashed_at_ms, purge_after_ms
                FROM recycle_entry WHERE id = ?
                """,
                arguments: [entryID.uuidString.lowercased()]
            ),
                let snapshot = Self.mapEntrySnapshot(row)
            else {
                throw LibrarySlimmingRecycleError.notFound
            }
            return snapshot
        }
    }
}

final class UserDefaultsLibrarySlimmingRecycleConfirmationPreferenceStore:
    LibrarySlimmingRecycleConfirmationPreferenceStore,
    @unchecked Sendable
{
    private static let skipsMoveConfirmationKey =
        "library.slimming.recycle.skip-move-confirmation"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var skipsMoveConfirmation: Bool {
        get { defaults.bool(forKey: Self.skipsMoveConfirmationKey) }
        set { defaults.set(newValue, forKey: Self.skipsMoveConfirmationKey) }
    }
}
