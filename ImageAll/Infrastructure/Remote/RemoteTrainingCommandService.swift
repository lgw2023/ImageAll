import Foundation
import os

/// Durable, privacy-bounded history for user-submitted personal-training batches.
/// Individual model runs remain authoritative for artifacts; this ledger preserves
/// batch-level progress (including tags skipped before a run could be created).
final class RemoteTrainingActivityStore: @unchecked Sendable {
    private struct PersistedState: Codable {
        var activities: [TrainingCommandActivitySnapshot]
    }

    private let storageURL: URL
    private let logger = Logger(
        subsystem: "com.gwlee.ImageAll",
        category: "RemoteTrainingActivityStore"
    )
    private let lock = NSLock()
    private var activitiesByID: [UUID: TrainingCommandActivitySnapshot]

    init(storageURL: URL) {
        self.storageURL = storageURL
        if let data = try? Data(contentsOf: storageURL),
           let state = try? JSONDecoder().decode(PersistedState.self, from: data) {
            activitiesByID = state.activities.reduce(into: [:]) {
                $0[$1.operationID] = $1
            }
        } else {
            activitiesByID = [:]
            if FileManager.default.fileExists(atPath: storageURL.path) {
                logger.error("Training activity history is unreadable; starting empty")
            }
        }
    }

    func restoreAndReconcile(nowMs: Int64) -> [TrainingCommandActivitySnapshot] {
        lock.lock()
        defer { lock.unlock() }
        var changed = false
        for (operationID, activity) in activitiesByID where Self.isActive(activity.phase) {
            changed = true
            activitiesByID[operationID] = TrainingCommandActivitySnapshot(
                operationID: activity.operationID,
                mediaKind: activity.mediaKind,
                method: activity.method,
                phase: .failed,
                completedUnitCount: activity.completedUnitCount,
                totalUnitCount: activity.totalUnitCount,
                sampleCount: activity.sampleCount,
                errorCode: "hostRestartInterrupted",
                tagActivities: activity.tagActivities.map { tag in
                    guard Self.isActive(tag.phase) else { return tag }
                    return TrainingCommandTagActivitySnapshot(
                        tagID: tag.tagID,
                        displayName: tag.displayName,
                        phase: .failed,
                        sampleCount: tag.sampleCount,
                        errorCode: "hostRestartInterrupted"
                    )
                },
                acceptedAtMs: activity.acceptedAtMs,
                updatedAtMs: nowMs
            )
        }
        trimLocked()
        if changed { saveLocked() }
        return sortedLocked()
    }

    func upsert(_ activity: TrainingCommandActivitySnapshot) {
        lock.lock()
        defer { lock.unlock() }
        activitiesByID[activity.operationID] = activity
        trimLocked()
        saveLocked()
    }

    private func sortedLocked() -> [TrainingCommandActivitySnapshot] {
        activitiesByID.values.sorted {
            if $0.updatedAtMs == $1.updatedAtMs {
                return $0.operationID.uuidString < $1.operationID.uuidString
            }
            return $0.updatedAtMs > $1.updatedAtMs
        }
    }

    private func trimLocked() {
        let retained = sortedLocked().prefix(50)
        activitiesByID = Dictionary(
            uniqueKeysWithValues: retained.map { ($0.operationID, $0) }
        )
    }

    private func saveLocked() {
        do {
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let state = PersistedState(activities: sortedLocked())
            let data = try JSONEncoder().encode(state)
            try data.write(to: storageURL, options: [.atomic, .completeFileProtection])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: storageURL.path
            )
        } catch {
            // Training runs remain authoritative even if the auxiliary history cannot save.
            logger.error("Training activity history save failed")
        }
    }

    private static func isActive(_ phase: TrainingCommandActivityPhase) -> Bool {
        [.preparingSamples, .preparingEmbeddings, .trainingAndPublishing].contains(phase)
    }

    private static func isActive(_ phase: TrainingCommandTagActivityPhase) -> Bool {
        [.pending, .preparingSamples, .preparingEmbeddings, .trainingAndPublishing]
            .contains(phase)
    }
}

actor RemoteTrainingCommandService: RemoteTrainingCommandPort {
    private struct SampleRevision: Hashable, Sendable {
        let assetID: UUID
        let contentRevision: Int
    }

    private struct AcceptedOperation: Sendable {
        let command: TrainingLaunchCommand
        let receipt: TrainingLaunchReceipt
    }

    private struct EmbeddingRevision: Sendable {
        let assetID: UUID
        let contentRevision: Int
    }

    private let catalog: any RemoteCatalogServing
    private let review: any PersonalizationReviewPort
    private let centroidRebuilder: (any AppPersonalModelRebuilding)?
    private let adamWRebuilder: (any AppPersonalModelRebuilding)?
    private let embeddingCache: (any AppSelectedAssetEmbeddingCaching)?
    private let sampleSuggester: (any AppPersonalSampleSuggesting)?
    private let centroidTagSuggester: (any AppPersonalTagLibrarySuggesting)?
    private let adamWTagSuggester: (any AppPersonalTagLibrarySuggesting)?
    private let localModelSuggestions: LocalModelSuggestionRuntime?
    private let sampleSuggestionLimit: @Sendable () -> Int
    private let tagSuggestionMinimumScore:
        @Sendable (UUID, TagLibrarySuggestionMethod) throws -> Double
    private let clock: any JobClock
    private let trainingActivityStore: RemoteTrainingActivityStore?

    private var acceptedOperations: [UUID: AcceptedOperation] = [:]
    private var activitiesByOperationID: [UUID: TrainingCommandActivitySnapshot] = [:]
    private var personalTasks: [UUID: Task<Void, Never>] = [:]
    private var activePersonalMethods: Set<TrainingRunMethod> = []
    private var suggestionRunnerTask: Task<Void, Never>?
    private var acceptedEmbeddingCommands: [UUID: EmbeddingPreparationCommand] = [:]
    private var embeddingActivities: [UUID: EmbeddingPreparationActivitySnapshot] = [:]
    private var embeddingTasks: [UUID: Task<Void, Never>] = [:]
    private var activeEmbeddingOperationID: UUID?
    private var acceptedSampleSuggestionCommands: [UUID: SampleSuggestionCommand] = [:]
    private var sampleSuggestionActivitiesByID: [UUID: SampleSuggestionActivitySnapshot] = [:]
    private var sampleSuggestionTasks: [UUID: Task<Void, Never>] = [:]
    private var activeSampleSuggestionOperationID: UUID?
    private var acceptedTagSuggestionCommands: [UUID: TagLibrarySuggestionCommand] = [:]
    private var tagSuggestionActivitiesByID: [UUID: TagLibrarySuggestionActivitySnapshot] = [:]
    private var tagSuggestionTasks: [UUID: Task<Void, Never>] = [:]
    private var activeTagSuggestionOperationID: UUID?
    private var acceptedLibrarySuggestionCommands: [UUID: LibrarySuggestionCommand] = [:]
    private var librarySuggestionReceipts: [UUID: LibrarySuggestionReceipt] = [:]
    private var librarySuggestionService = LibrarySuggestionServiceSnapshot(
        state: .unchecked,
        serviceVersion: nil,
        provider: nil,
        modelID: nil
    )

    init(
        catalog: any RemoteCatalogServing,
        review: any PersonalizationReviewPort,
        centroidRebuilder: (any AppPersonalModelRebuilding)?,
        adamWRebuilder: (any AppPersonalModelRebuilding)?,
        embeddingCache: (any AppSelectedAssetEmbeddingCaching)?,
        sampleSuggester: (any AppPersonalSampleSuggesting)? = nil,
        centroidTagSuggester: (any AppPersonalTagLibrarySuggesting)? = nil,
        adamWTagSuggester: (any AppPersonalTagLibrarySuggesting)? = nil,
        localModelSuggestions: LocalModelSuggestionRuntime? = nil,
        sampleSuggestionLimit: @escaping @Sendable () -> Int = {
            AppPersonalSampleSuggestionLimits.defaultSampleCount
        },
        tagSuggestionMinimumScore:
            @escaping @Sendable (UUID, TagLibrarySuggestionMethod) throws -> Double = { _, _ in 0 },
        trainingActivityStore: RemoteTrainingActivityStore? = nil,
        clock: any JobClock = SystemJobClock()
    ) {
        self.catalog = catalog
        self.review = review
        self.centroidRebuilder = centroidRebuilder
        self.adamWRebuilder = adamWRebuilder
        self.embeddingCache = embeddingCache
        self.sampleSuggester = sampleSuggester
        self.centroidTagSuggester = centroidTagSuggester
        self.adamWTagSuggester = adamWTagSuggester
        self.localModelSuggestions = localModelSuggestions
        self.sampleSuggestionLimit = sampleSuggestionLimit
        self.tagSuggestionMinimumScore = tagSuggestionMinimumScore
        self.trainingActivityStore = trainingActivityStore
        self.clock = clock
        let restoredActivities = trainingActivityStore?.restoreAndReconcile(
            nowMs: clock.nowMs
        ) ?? []
        activitiesByOperationID = restoredActivities.reduce(into: [:]) {
            $0[$1.operationID] = $1
        }
    }

    func librarySuggestions(
        mediaKind: MediaKind,
        refreshServiceHealth: Bool
    ) async throws -> LibrarySuggestionWorkspaceSnapshot {
        if refreshServiceHealth || librarySuggestionService.state == .unchecked {
            librarySuggestionService = await refreshLibrarySuggestionServiceHealth()
        }
        let activities = try catalog.fetchJobActivity()
        let activitiesByID = Dictionary(uniqueKeysWithValues: activities.map { ($0.id, $0) })
        let standardProjection = try review.standardLibrarySuggestionJob(mediaKind: mediaKind)
        let personalProjection = try review.personalLibrarySuggestionJob(mediaKind: mediaKind)
        return LibrarySuggestionWorkspaceSnapshot(
            mediaKind: mediaKind,
            service: librarySuggestionService,
            standardAvailable: mediaKind == .image && localModelSuggestions != nil,
            personalMode: {
                if mediaKind != .image { return .unavailable }
                if localModelSuggestions != nil { return .fullLibrary }
                if sampleSuggester != nil, embeddingCache != nil { return .sample }
                return .unavailable
            }(),
            standardJob: standardProjection.map {
                Self.mapLibrarySuggestionJob($0, activity: activitiesByID[$0.id])
            },
            personalJob: personalProjection.map {
                Self.mapLibrarySuggestionJob($0, activity: activitiesByID[$0.id])
            }
        )
    }

    func generateLibrarySuggestions(
        _ command: LibrarySuggestionCommand
    ) async throws -> LibrarySuggestionReceipt {
        if let accepted = acceptedLibrarySuggestionCommands[command.operationID] {
            guard accepted == command,
                  let receipt = librarySuggestionReceipts[command.operationID]
            else {
                throw TrainingCommandError.activeConflict
            }
            return LibrarySuggestionReceipt(
                operationID: receipt.operationID,
                track: receipt.track,
                jobID: receipt.jobID,
                replayed: true
            )
        }
        guard command.mediaKind == .image, let runtime = localModelSuggestions else {
            throw TrainingCommandError.unavailable
        }
        let sourceIDs = try validatedLibrarySuggestionSourceIDs(command.sourceIDs)
        let existingStandard = try review.standardLibrarySuggestionJob(mediaKind: command.mediaKind)
        let existingPersonal = try review.personalLibrarySuggestionJob(mediaKind: command.mediaKind)
        guard !Self.isActiveLibrarySuggestionJob(existingStandard?.state),
              !Self.isActiveLibrarySuggestionJob(existingPersonal?.state),
              activeSampleSuggestionOperationID == nil,
              activeTagSuggestionOperationID == nil,
              activePersonalMethods.isEmpty
        else {
            throw TrainingCommandError.activeConflict
        }

        let jobID: UUID
        do {
            switch command.track {
            case .standard:
                let availability = try await runtime.client.standardCapability()
                guard case let .available(capability) = availability else {
                    throw TrainingCommandError.unavailable
                }
                let package = try Self.approvedStandardPackage(for: capability)
                try catalog.installStandardOntologyPackage(package)
                jobID = try review.enqueueStandardLibrarySuggestions(
                    mediaKind: command.mediaKind,
                    target: capability.target,
                    sourceIDs: sourceIDs
                )
            case .personal:
                let availability = try await runtime.client.personalCapability()
                guard case let .available(capability) = availability else {
                    throw TrainingCommandError.unavailable
                }
                try Self.validatePersonalCapability(
                    capability,
                    catalogScopeID: runtime.catalogScopeID,
                    mediaKind: command.mediaKind,
                    activeTagIDs: Set(
                        try catalog.listTags().filter { $0.state == .active }.map(\.id)
                    )
                )
                jobID = try review.enqueuePersonalLibrarySuggestions(
                    capability: capability,
                    sourceIDs: sourceIDs
                )
            }
        } catch PersonalizationReviewError.activeJobConflict {
            throw TrainingCommandError.activeConflict
        } catch LocalModelSuggestionClientError.serviceUnavailable {
            throw TrainingCommandError.unavailable
        } catch LocalModelSuggestionClientError.identityMismatch {
            throw TrainingCommandError.invalidSelection
        } catch let LocalModelSuggestionClientError.rejected(statusCode, _)
            where statusCode == 503
        {
            throw TrainingCommandError.unavailable
        }

        let receipt = LibrarySuggestionReceipt(
            operationID: command.operationID,
            track: command.track,
            jobID: jobID,
            replayed: false
        )
        acceptedLibrarySuggestionCommands[command.operationID] = command
        librarySuggestionReceipts[command.operationID] = receipt
        await ensureSuggestionRunnerRunning()
        return receipt
    }

    private func refreshLibrarySuggestionServiceHealth() async -> LibrarySuggestionServiceSnapshot {
        guard let client = localModelSuggestions?.client else {
            return LibrarySuggestionServiceSnapshot(
                state: .unavailable,
                serviceVersion: nil,
                provider: nil,
                modelID: nil
            )
        }
        do {
            switch try await client.serviceHealth() {
            case let .ready(serviceVersion, provider):
                return LibrarySuggestionServiceSnapshot(
                    state: .ready,
                    serviceVersion: serviceVersion,
                    provider: provider.provider,
                    modelID: provider.modelID
                )
            case let .degraded(serviceVersion):
                return LibrarySuggestionServiceSnapshot(
                    state: .degraded,
                    serviceVersion: serviceVersion,
                    provider: nil,
                    modelID: nil
                )
            }
        } catch {
            return LibrarySuggestionServiceSnapshot(
                state: .unavailable,
                serviceVersion: nil,
                provider: nil,
                modelID: nil
            )
        }
    }

    private func validatedLibrarySuggestionSourceIDs(_ requested: [UUID]?) throws -> [UUID]? {
        guard let requested else { return nil }
        guard !requested.isEmpty, Set(requested).count == requested.count else {
            throw TrainingCommandError.invalidSelection
        }
        let activeSourceIDs = Set(try setup(mediaKind: .image).sources.map(\.id))
        guard Set(requested).isSubset(of: activeSourceIDs) else {
            throw TrainingCommandError.invalidSelection
        }
        return requested.sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
    }

    private static func isActiveLibrarySuggestionJob(_ state: JobState?) -> Bool {
        guard let state else { return false }
        return [.pending, .running, .paused, .retryableFailed].contains(state)
    }

    private static func mapLibrarySuggestionJob(
        _ projection: StandardLibrarySuggestionJobProjection,
        activity: JobActivityItem?
    ) -> LibrarySuggestionJobSnapshot {
        LibrarySuggestionJobSnapshot(
            jobID: projection.id,
            state: projection.state,
            checkedCount: projection.checkedCount,
            totalCount: projection.totalCount,
            suggestedCount: projection.suggestedCount,
            skippedCount: projection.skippedCount,
            lastErrorCode: projection.lastErrorCode,
            availableActions: activity?.availableActions ?? []
        )
    }

    private static func mapLibrarySuggestionJob(
        _ projection: PersonalLibrarySuggestionJobProjection,
        activity: JobActivityItem?
    ) -> LibrarySuggestionJobSnapshot {
        LibrarySuggestionJobSnapshot(
            jobID: projection.id,
            state: projection.state,
            checkedCount: projection.checkedCount,
            totalCount: projection.totalCount,
            suggestedCount: projection.suggestedCount,
            skippedCount: projection.skippedCount,
            lastErrorCode: projection.lastErrorCode,
            availableActions: activity?.availableActions ?? []
        )
    }

    private static func validatePersonalCapability(
        _ capability: PersonalModelSuggestionCapability,
        catalogScopeID: String,
        mediaKind: MediaKind,
        activeTagIDs: Set<UUID>
    ) throws {
        let target = capability.target
        guard target.catalogScopeID == catalogScopeID,
              target.mediaKind == mediaKind,
              !target.bundleID.isEmpty,
              !target.bundleRevision.isEmpty,
              !target.provider.isEmpty,
              !target.modelID.isEmpty,
              !target.modelRevision.isEmpty,
              !target.preprocessingRevision.isEmpty,
              target.elementCount > 0,
              isLowercaseSHA256(target.labelVocabularyRevision),
              isLowercaseSHA256(target.weightsSHA256),
              !target.policyRevision.isEmpty,
              capability.tagIDs.count == 1,
              Set(capability.tagIDs).isSubset(of: activeTagIDs)
        else {
            throw LocalModelSuggestionClientError.identityMismatch
        }
    }

    private static func approvedStandardPackage(
        for capability: StandardModelSuggestionCapability
    ) throws -> StandardOntologyPackageInput {
        let package = StandardOntologyCatalog.bundledSceneFixture
        guard capability.target.standardPackID == package.standardPackID,
              capability.target.standardPackRevision == package.standardPackRevision,
              capability.manifestSHA256 == package.manifestSHA256,
              capability.ontologyID == package.ontologyID,
              capability.ontologyRevision == package.ontologyRevision,
              capability.provider == package.provider,
              capability.modelID == package.modelID,
              capability.modelRevision == package.modelRevision,
              capability.preprocessingRevision == package.preprocessingRevision,
              capability.mappingRevision == package.mappingRevision,
              capability.policyRevision == package.policyRevision,
              capability.weightsSHA256 == package.weightsSHA256
        else {
            throw LocalModelSuggestionClientError.identityMismatch
        }
        return package
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy {
            ("0" ... "9").contains(String($0)) || ("a" ... "f").contains(String($0))
        }
    }

    func setup(mediaKind: MediaKind) throws -> TrainingCommandSetupSnapshot {
        let overviews = try review.tagOverviews(mediaKind: mediaKind, sourceIDs: nil)
        let tags = overviews.map { overview in
            TrainingCommandTagOption(
                id: overview.id,
                displayName: overview.displayName,
                acceptedSampleCount: overview.acceptedSampleCount,
                rejectedSampleCount: overview.rejectedSampleCount,
                featureMode: overview.canUpdate
                    ? .update
                    : (overview.canGenerate ? .generate : nil),
                personalEligible: overview.canGeneratePersonalModel
            )
        }
        let sources = try catalog.fetchSources()
            .filter { $0.state == .active }
            .map { TrainingCommandSourceOption(id: $0.id, displayName: $0.displayName) }
        return TrainingCommandSetupSnapshot(
            mediaKind: mediaKind,
            tags: tags,
            sources: sources,
            supportsPersonalCentroid: centroidRebuilder != nil && embeddingCache != nil,
            supportsPersonalAdamW: adamWRebuilder != nil && embeddingCache != nil
        )
    }

    func launch(_ command: TrainingLaunchCommand) async throws -> TrainingLaunchReceipt {
        if let accepted = acceptedOperations[command.operationID] {
            guard accepted.command == command else {
                throw TrainingCommandError.activeConflict
            }
            return accepted.receipt
        }

        let setup = try setup(mediaKind: command.mediaKind)
        let receipt: TrainingLaunchReceipt
        switch command.method {
        case .featureKnn:
            receipt = try launchFeature(command, setup: setup)
        case .personalCentroid, .personalAdamW:
            receipt = try launchPersonal(command, setup: setup)
        }
        acceptedOperations[command.operationID] = AcceptedOperation(
            command: command,
            receipt: receipt
        )
        return receipt
    }

    func activities(mediaKind: MediaKind) -> [TrainingCommandActivitySnapshot] {
        activitiesByOperationID.values
            .filter { $0.mediaKind == mediaKind }
            .sorted {
                if $0.updatedAtMs == $1.updatedAtMs {
                    return $0.operationID.uuidString < $1.operationID.uuidString
                }
                return $0.updatedAtMs > $1.updatedAtMs
            }
    }

    func cancelActivity(
        operationID: UUID
    ) async throws -> TrainingCommandActivitySnapshot {
        guard let activity = activitiesByOperationID[operationID] else {
            throw TrainingCommandError.activityNotFound
        }
        guard activity.availableActions.contains(.cancel) else {
            return activity
        }
        personalTasks[operationID]?.cancel()
        let cancelled = TrainingCommandActivitySnapshot(
            operationID: activity.operationID,
            mediaKind: activity.mediaKind,
            method: activity.method,
            phase: .cancelled,
            completedUnitCount: activity.completedUnitCount,
            totalUnitCount: activity.totalUnitCount,
            sampleCount: activity.sampleCount,
            errorCode: nil,
            tagActivities: activity.tagActivities.map { tag in
                guard [.preparingSamples, .preparingEmbeddings, .trainingAndPublishing]
                    .contains(tag.phase)
                else { return tag }
                return TrainingCommandTagActivitySnapshot(
                    tagID: tag.tagID,
                    displayName: tag.displayName,
                    phase: .cancelled,
                    sampleCount: tag.sampleCount,
                    errorCode: nil
                )
            },
            acceptedAtMs: activity.acceptedAtMs,
            updatedAtMs: clock.nowMs
        )
        activitiesByOperationID[operationID] = cancelled
        trainingActivityStore?.upsert(cancelled)
        switch activity.method {
        case .personalCentroid:
            await centroidRebuilder?.cancel()
        case .personalAdamW:
            await adamWRebuilder?.cancel()
        case .featureKnn:
            throw TrainingCommandError.invalidSelection
        }
        return cancelled
    }

    func ensureSuggestionRunnerRunning() {
        startSuggestionRunnerIfNeeded()
    }

    func embeddingPreparationAvailable() async -> Bool {
        embeddingCache != nil
    }

    func prepareEmbeddings(
        _ command: EmbeddingPreparationCommand
    ) async throws -> EmbeddingPreparationReceipt {
        if let accepted = acceptedEmbeddingCommands[command.operationID] {
            guard accepted == command else {
                throw TrainingCommandError.activeConflict
            }
            guard let activity = embeddingActivities[command.operationID] else {
                throw TrainingCommandError.activityNotFound
            }
            return EmbeddingPreparationReceipt(activity: activity, replayed: true)
        }
        guard embeddingCache != nil else {
            throw TrainingCommandError.unavailable
        }
        guard !command.assetIDs.isEmpty, command.assetIDs.count <= 5_000 else {
            throw TrainingCommandError.invalidSelection
        }
        guard activeEmbeddingOperationID == nil else {
            throw TrainingCommandError.activeConflict
        }

        let revisions = try command.assetIDs.map { assetID -> EmbeddingRevision in
            let detail = try catalog.fetchInspectorDetail(assetID: assetID)
            guard detail.assetID == assetID,
                  detail.mediaKind == command.mediaKind,
                  detail.contentRevision > 0
            else {
                throw TrainingCommandError.invalidSelection
            }
            return EmbeddingRevision(
                assetID: assetID,
                contentRevision: detail.contentRevision
            )
        }.sorted {
            $0.assetID.uuidString.lowercased() < $1.assetID.uuidString.lowercased()
        }

        let activity = EmbeddingPreparationActivitySnapshot(
            operationID: command.operationID,
            mediaKind: command.mediaKind,
            phase: .running,
            completedUnitCount: 0,
            totalUnitCount: revisions.count,
            preparedCount: 0,
            cachedCount: 0,
            cloudOnlyCount: 0,
            failedCount: 0,
            errorCode: nil
        )
        acceptedEmbeddingCommands[command.operationID] = command
        embeddingActivities[command.operationID] = activity
        activeEmbeddingOperationID = command.operationID
        embeddingTasks[command.operationID] = Task { [weak self] in
            await self?.executeEmbeddingPreparation(
                operationID: command.operationID,
                mediaKind: command.mediaKind,
                revisions: revisions
            )
        }
        return EmbeddingPreparationReceipt(activity: activity, replayed: false)
    }

    func embeddingPreparationActivities(
        mediaKind: MediaKind
    ) async -> [EmbeddingPreparationActivitySnapshot] {
        embeddingActivities.values
            .filter { $0.mediaKind == mediaKind }
            .sorted { $0.operationID.uuidString < $1.operationID.uuidString }
    }

    func cancelEmbeddingPreparation(
        operationID: UUID
    ) async throws -> EmbeddingPreparationActivitySnapshot {
        guard let activity = embeddingActivities[operationID] else {
            throw TrainingCommandError.activityNotFound
        }
        guard activity.phase == .running else { return activity }
        embeddingTasks[operationID]?.cancel()
        let cancelled = EmbeddingPreparationActivitySnapshot(
            operationID: activity.operationID,
            mediaKind: activity.mediaKind,
            phase: .cancelled,
            completedUnitCount: activity.completedUnitCount,
            totalUnitCount: activity.totalUnitCount,
            preparedCount: activity.preparedCount,
            cachedCount: activity.cachedCount,
            cloudOnlyCount: activity.cloudOnlyCount,
            failedCount: activity.failedCount,
            errorCode: nil
        )
        embeddingActivities[operationID] = cancelled
        activeEmbeddingOperationID = nil
        return cancelled
    }

    func sampleSuggestionsAvailable(mediaKind: MediaKind) async -> Bool {
        mediaKind == .image && sampleSuggester != nil && embeddingCache != nil
    }

    func sampleSuggestionMaximumCount() async -> Int {
        min(
            max(sampleSuggestionLimit(), PendingSuggestionGenerationLimits.minCount),
            PendingSuggestionGenerationLimits.maxCount
        )
    }

    func generateSampleSuggestions(
        _ command: SampleSuggestionCommand
    ) async throws -> SampleSuggestionReceipt {
        if let accepted = acceptedSampleSuggestionCommands[command.operationID] {
            guard accepted == command else {
                throw TrainingCommandError.activeConflict
            }
            guard let activity = sampleSuggestionActivitiesByID[command.operationID] else {
                throw TrainingCommandError.activityNotFound
            }
            return SampleSuggestionReceipt(activity: activity, replayed: true)
        }
        guard sampleSuggester != nil, embeddingCache != nil else {
            throw TrainingCommandError.unavailable
        }
        guard command.mediaKind == .image else {
            throw TrainingCommandError.unavailable
        }
        guard activeSampleSuggestionOperationID == nil,
              activeTagSuggestionOperationID == nil,
              activePersonalMethods.isEmpty
        else {
            throw TrainingCommandError.activeConflict
        }
        let limit = min(
            max(sampleSuggestionLimit(), PendingSuggestionGenerationLimits.minCount),
            PendingSuggestionGenerationLimits.maxCount
        )
        guard command.assetIDs.count <= limit,
              Set(command.assetIDs).count == command.assetIDs.count
        else {
            throw TrainingCommandError.invalidSelection
        }
        if let sourceIDs = command.sourceIDs {
            guard command.assetIDs.isEmpty,
                  !sourceIDs.isEmpty,
                  Set(sourceIDs).count == sourceIDs.count
            else {
                throw TrainingCommandError.invalidSelection
            }
            let availableSourceIDs = Set(
                try setup(mediaKind: command.mediaKind).sources.map(\.id)
            )
            guard Set(sourceIDs).isSubset(of: availableSourceIDs) else {
                throw TrainingCommandError.invalidSelection
            }
        }

        let candidates: [PersonalSuggestionCandidate]
        if command.assetIDs.isEmpty {
            candidates = try review.personalSuggestionCandidates(
                mediaKind: command.mediaKind,
                afterAssetID: nil,
                limit: limit,
                sourceIDs: command.sourceIDs,
                excludingDecisionsForTagID: nil
            )
        } else {
            candidates = try command.assetIDs.map { assetID in
                let detail = try catalog.fetchInspectorDetail(assetID: assetID)
                guard detail.assetID == assetID,
                      detail.mediaKind == command.mediaKind,
                      detail.contentRevision > 0
                else {
                    throw TrainingCommandError.invalidSelection
                }
                return PersonalSuggestionCandidate(
                    assetID: assetID,
                    contentRevision: detail.contentRevision
                )
            }
        }
        guard !candidates.isEmpty else {
            throw TrainingCommandError.invalidSelection
        }

        let activity = SampleSuggestionActivitySnapshot(
            operationID: command.operationID,
            mediaKind: command.mediaKind,
            phase: .running,
            completedUnitCount: 0,
            totalUnitCount: candidates.count,
            suggestedCount: 0,
            skippedCount: 0,
            errorCode: nil
        )
        acceptedSampleSuggestionCommands[command.operationID] = command
        sampleSuggestionActivitiesByID[command.operationID] = activity
        activeSampleSuggestionOperationID = command.operationID
        sampleSuggestionTasks[command.operationID] = Task { [weak self] in
            await self?.executeSampleSuggestions(
                operationID: command.operationID,
                mediaKind: command.mediaKind,
                candidates: candidates
            )
        }
        return SampleSuggestionReceipt(activity: activity, replayed: false)
    }

    func sampleSuggestionActivities(
        mediaKind: MediaKind
    ) async -> [SampleSuggestionActivitySnapshot] {
        sampleSuggestionActivitiesByID.values
            .filter { $0.mediaKind == mediaKind }
            .sorted { $0.operationID.uuidString < $1.operationID.uuidString }
    }

    func cancelSampleSuggestions(
        operationID: UUID
    ) async throws -> SampleSuggestionActivitySnapshot {
        guard let activity = sampleSuggestionActivitiesByID[operationID] else {
            throw TrainingCommandError.activityNotFound
        }
        guard activity.phase == .running else { return activity }
        sampleSuggestionTasks[operationID]?.cancel()
        let cancelled = SampleSuggestionActivitySnapshot(
            operationID: activity.operationID,
            mediaKind: activity.mediaKind,
            phase: .cancelled,
            completedUnitCount: activity.completedUnitCount,
            totalUnitCount: activity.totalUnitCount,
            suggestedCount: activity.suggestedCount,
            skippedCount: activity.skippedCount,
            errorCode: nil
        )
        sampleSuggestionActivitiesByID[operationID] = cancelled
        activeSampleSuggestionOperationID = nil
        return cancelled
    }

    private func executeSampleSuggestions(
        operationID: UUID,
        mediaKind: MediaKind,
        candidates: [PersonalSuggestionCandidate]
    ) async {
        guard let sampleSuggester, let embeddingCache else { return }
        var suggested = 0
        var skipped = 0
        var phase: SampleSuggestionPhase = .completed
        var errorCode: String?
        do {
            try Task.checkCancellation()
            let batch = try await sampleSuggester.suggest(
                mediaKind: mediaKind,
                candidates: candidates,
                maximumSuggestionsPerAsset:
                    AppPersonalSampleSuggestionLimits.defaultMaximumSuggestionsPerAsset,
                embedding: { [catalog] candidate in
                    let result = try await embeddingCache.cacheSelectedAsset(
                        assetID: candidate.assetID,
                        contentRevision: candidate.contentRevision,
                        imageData: {
                            try await catalog.loadPreview(assetID: candidate.assetID)
                        }
                    )
                    try Task.checkCancellation()
                    return AppCoreMLEmbedding(identity: result.identity, values: result.values)
                }
            )
            try Task.checkCancellation()
            for capability in batch.capabilities {
                try review.activatePersonalSuggestionBundle(capability)
            }
            for result in batch.results {
                try Task.checkCancellation()
                let predictionsByTag = Dictionary(grouping: result.predictions, by: \.tagID)
                for capability in batch.capabilities {
                    guard let tagID = capability.tagIDs.first,
                          let predictions = predictionsByTag[tagID],
                          !predictions.isEmpty
                    else { continue }
                    suggested += try review.replacePersonalSuggestions(
                        candidate: result.candidate,
                        predictions: predictions,
                        expectedCapability: capability
                    )
                }
            }
            skipped = batch.skippedCount
        } catch is CancellationError {
            phase = .cancelled
        } catch AppPersonalSampleSuggestionError.personalUnavailable {
            phase = .failed
            errorCode = "personalUnavailable"
        } catch AppPersonalSampleSuggestionError.modelUnavailable {
            phase = .failed
            errorCode = "modelUnavailable"
        } catch {
            phase = .failed
            errorCode = Self.safeSampleSuggestionErrorCode(error)
        }

        if sampleSuggestionActivitiesByID[operationID]?.phase == .cancelled {
            phase = .cancelled
        }
        sampleSuggestionActivitiesByID[operationID] = SampleSuggestionActivitySnapshot(
            operationID: operationID,
            mediaKind: mediaKind,
            phase: phase,
            completedUnitCount: phase == .completed ? candidates.count : 0,
            totalUnitCount: candidates.count,
            suggestedCount: suggested,
            skippedCount: skipped,
            errorCode: errorCode
        )
        sampleSuggestionTasks[operationID] = nil
        if activeSampleSuggestionOperationID == operationID {
            activeSampleSuggestionOperationID = nil
        }
    }

    func tagLibrarySuggestionsAvailable(
        mediaKind: MediaKind,
        method: TagLibrarySuggestionMethod
    ) async -> Bool {
        guard mediaKind == .image, embeddingCache != nil else { return false }
        return switch method {
        case .personalCentroid: centroidTagSuggester != nil
        case .personalAdamW: adamWTagSuggester != nil
        }
    }

    func tagLibrarySuggestionTagOptions(
        mediaKind: MediaKind
    ) async throws -> [TagLibrarySuggestionTagOption] {
        let setup = try setup(mediaKind: mediaKind)
        return try setup.tags.map { tag in
            TagLibrarySuggestionTagOption(
                tagID: tag.id,
                personalEligible: tag.personalEligible,
                personalCentroidMinScore: try tagSuggestionMinimumScore(
                    tag.id,
                    .personalCentroid
                ),
                personalAdamWMinScore: try tagSuggestionMinimumScore(
                    tag.id,
                    .personalAdamW
                )
            )
        }
    }

    func generateTagLibrarySuggestions(
        _ command: TagLibrarySuggestionCommand
    ) async throws -> TagLibrarySuggestionReceipt {
        if let accepted = acceptedTagSuggestionCommands[command.operationID] {
            guard accepted == command else {
                throw TrainingCommandError.activeConflict
            }
            guard let activity = tagSuggestionActivitiesByID[command.operationID] else {
                throw TrainingCommandError.activityNotFound
            }
            return TagLibrarySuggestionReceipt(activity: activity, replayed: true)
        }
        guard command.mediaKind == .image, embeddingCache != nil else {
            throw TrainingCommandError.unavailable
        }
        let suggester: any AppPersonalTagLibrarySuggesting
        switch command.method {
        case .personalCentroid:
            guard let centroidTagSuggester else { throw TrainingCommandError.unavailable }
            suggester = centroidTagSuggester
        case .personalAdamW:
            guard let adamWTagSuggester else { throw TrainingCommandError.unavailable }
            suggester = adamWTagSuggester
        }
        guard activeTagSuggestionOperationID == nil,
              activeSampleSuggestionOperationID == nil,
              activePersonalMethods.isEmpty
        else {
            throw TrainingCommandError.activeConflict
        }
        let setup = try setup(mediaKind: command.mediaKind)
        let availableSourceIDs = Set(setup.sources.map(\.id))
        guard !command.sourceIDs.isEmpty,
              command.sourceIDs.isSubset(of: availableSourceIDs),
              setup.tags.contains(where: {
                  $0.id == command.tagID && $0.personalEligible
              })
        else {
            throw TrainingCommandError.invalidSelection
        }
        let minimumScore = try tagSuggestionMinimumScore(command.tagID, command.method)
        guard minimumScore.isFinite else {
            throw TrainingCommandError.invalidSelection
        }

        let activity = TagLibrarySuggestionActivitySnapshot(
            operationID: command.operationID,
            mediaKind: command.mediaKind,
            method: command.method,
            tagID: command.tagID,
            phase: .preparingCandidates,
            completedUnitCount: 0,
            totalUnitCount: 0,
            aboveThresholdCount: 0,
            insertedCount: 0,
            skippedCount: 0,
            errorCode: nil
        )
        acceptedTagSuggestionCommands[command.operationID] = command
        tagSuggestionActivitiesByID[command.operationID] = activity
        activeTagSuggestionOperationID = command.operationID
        tagSuggestionTasks[command.operationID] = Task { [weak self] in
            await self?.executeTagLibrarySuggestions(
                command,
                suggester: suggester,
                minimumScore: minimumScore
            )
        }
        return TagLibrarySuggestionReceipt(activity: activity, replayed: false)
    }

    func tagLibrarySuggestionActivities(
        mediaKind: MediaKind
    ) async -> [TagLibrarySuggestionActivitySnapshot] {
        tagSuggestionActivitiesByID.values
            .filter { $0.mediaKind == mediaKind }
            .sorted { $0.operationID.uuidString < $1.operationID.uuidString }
    }

    func cancelTagLibrarySuggestions(
        operationID: UUID
    ) async throws -> TagLibrarySuggestionActivitySnapshot {
        guard let activity = tagSuggestionActivitiesByID[operationID] else {
            throw TrainingCommandError.activityNotFound
        }
        guard activity.availableActions.contains(.cancel) else { return activity }
        tagSuggestionTasks[operationID]?.cancel()
        let cancelled = TagLibrarySuggestionActivitySnapshot(
            operationID: activity.operationID,
            mediaKind: activity.mediaKind,
            method: activity.method,
            tagID: activity.tagID,
            phase: .cancelled,
            completedUnitCount: activity.completedUnitCount,
            totalUnitCount: activity.totalUnitCount,
            aboveThresholdCount: activity.aboveThresholdCount,
            insertedCount: activity.insertedCount,
            skippedCount: activity.skippedCount,
            errorCode: nil
        )
        tagSuggestionActivitiesByID[operationID] = cancelled
        activeTagSuggestionOperationID = nil
        return cancelled
    }

    private func executeTagLibrarySuggestions(
        _ command: TagLibrarySuggestionCommand,
        suggester: any AppPersonalTagLibrarySuggesting,
        minimumScore: Double
    ) async {
        guard let embeddingCache else { return }
        var checked = 0
        var total = 0
        var aboveThreshold = 0
        var inserted = 0
        var skipped = 0
        var phase: TagLibrarySuggestionPhase = .completed
        var errorCode: String?
        do {
            let candidates = try await resolveTagSuggestionCandidates(command)
            try Task.checkCancellation()
            total = candidates.count
            guard total > 0 else { throw TrainingCommandError.invalidSelection }
            tagSuggestionActivitiesByID[command.operationID] =
                TagLibrarySuggestionActivitySnapshot(
                    operationID: command.operationID,
                    mediaKind: command.mediaKind,
                    method: command.method,
                    tagID: command.tagID,
                    phase: .scoring,
                    completedUnitCount: 0,
                    totalUnitCount: total,
                    aboveThresholdCount: 0,
                    insertedCount: 0,
                    skippedCount: 0,
                    errorCode: nil
                )
            let operationID = command.operationID
            let batch = try await suggester.suggest(
                mediaKind: command.mediaKind,
                tagID: command.tagID,
                candidates: candidates,
                maximumPendingCount: sampleSuggestionMaximumCountValue(),
                minimumScore: minimumScore,
                embedding: { [catalog] candidate in
                    let result = try await embeddingCache.cacheSelectedAsset(
                        assetID: candidate.assetID,
                        contentRevision: candidate.contentRevision,
                        imageData: {
                            try await catalog.loadPreview(assetID: candidate.assetID)
                        }
                    )
                    try Task.checkCancellation()
                    return AppCoreMLEmbedding(identity: result.identity, values: result.values)
                },
                progress: { [weak self] progressChecked, progressSuggested, progressSkipped in
                    Task {
                        await self?.updateTagSuggestionProgress(
                            operationID: operationID,
                            checked: progressChecked,
                            aboveThreshold: progressSuggested,
                            skipped: progressSkipped
                        )
                    }
                }
            )
            try Task.checkCancellation()
            checked = batch.checkedCount
            aboveThreshold = batch.aboveThresholdCount
            skipped = batch.skippedCount
            tagSuggestionActivitiesByID[command.operationID] =
                TagLibrarySuggestionActivitySnapshot(
                    operationID: command.operationID,
                    mediaKind: command.mediaKind,
                    method: command.method,
                    tagID: command.tagID,
                    phase: .publishing,
                    completedUnitCount: checked,
                    totalUnitCount: total,
                    aboveThresholdCount: aboveThreshold,
                    insertedCount: 0,
                    skippedCount: skipped,
                    errorCode: nil
                )
            try review.activatePersonalSuggestionBundle(batch.capability)
            inserted = try review.replacePersonalTagLibrarySuggestions(
                tagID: batch.tagID,
                hits: batch.hits,
                expectedCapability: batch.capability,
                maximumPendingCount: sampleSuggestionMaximumCountValue()
            )
        } catch is CancellationError {
            phase = .cancelled
        } catch TrainingCommandError.invalidSelection {
            phase = .failed
            errorCode = "noCandidates"
        } catch AppPersonalTagLibrarySuggestionError.personalUnavailable {
            phase = .failed
            errorCode = "personalUnavailable"
        } catch AppPersonalTagLibrarySuggestionError.tagNotInPersonalModel {
            phase = .failed
            errorCode = "tagNotInPersonalModel"
        } catch AppPersonalTagLibrarySuggestionError.modelUnavailable {
            phase = .failed
            errorCode = "modelUnavailable"
        } catch AppPersonalTagLibrarySuggestionError.identityMismatch {
            phase = .failed
            errorCode = "identityMismatch"
        } catch AppPersonalTagLibrarySuggestionError.alreadyRunning {
            phase = .failed
            errorCode = "activeConflict"
        } catch {
            phase = .failed
            errorCode = "suggestionFailed"
        }

        if tagSuggestionActivitiesByID[command.operationID]?.phase == .cancelled {
            phase = .cancelled
        }
        tagSuggestionActivitiesByID[command.operationID] =
            TagLibrarySuggestionActivitySnapshot(
                operationID: command.operationID,
                mediaKind: command.mediaKind,
                method: command.method,
                tagID: command.tagID,
                phase: phase,
                completedUnitCount: checked,
                totalUnitCount: total,
                aboveThresholdCount: aboveThreshold,
                insertedCount: inserted,
                skippedCount: skipped,
                errorCode: errorCode
            )
        tagSuggestionTasks[command.operationID] = nil
        if activeTagSuggestionOperationID == command.operationID {
            activeTagSuggestionOperationID = nil
        }
    }

    private func resolveTagSuggestionCandidates(
        _ command: TagLibrarySuggestionCommand
    ) async throws -> [PersonalSuggestionCandidate] {
        var candidates: [PersonalSuggestionCandidate] = []
        var afterAssetID: UUID?
        while true {
            try Task.checkCancellation()
            let page = try review.personalSuggestionCandidates(
                mediaKind: command.mediaKind,
                afterAssetID: afterAssetID,
                limit: AppPersonalTagLibrarySuggestionLimits.candidatePageSize,
                sourceIDs: Array(command.sourceIDs).sorted {
                    $0.uuidString.lowercased() < $1.uuidString.lowercased()
                },
                excludingDecisionsForTagID: command.tagID
            )
            if page.isEmpty { break }
            candidates.append(contentsOf: page)
            afterAssetID = page.last?.assetID
            updatePreparingCandidateCount(
                operationID: command.operationID,
                count: candidates.count
            )
            if page.count < AppPersonalTagLibrarySuggestionLimits.candidatePageSize { break }
            await Task.yield()
        }
        return candidates
    }

    private func updatePreparingCandidateCount(operationID: UUID, count: Int) {
        guard let activity = tagSuggestionActivitiesByID[operationID],
              activity.phase == .preparingCandidates
        else { return }
        tagSuggestionActivitiesByID[operationID] = TagLibrarySuggestionActivitySnapshot(
            operationID: activity.operationID,
            mediaKind: activity.mediaKind,
            method: activity.method,
            tagID: activity.tagID,
            phase: .preparingCandidates,
            completedUnitCount: count,
            totalUnitCount: 0,
            aboveThresholdCount: 0,
            insertedCount: 0,
            skippedCount: 0,
            errorCode: nil
        )
    }

    private func updateTagSuggestionProgress(
        operationID: UUID,
        checked: Int,
        aboveThreshold: Int,
        skipped: Int
    ) {
        guard let activity = tagSuggestionActivitiesByID[operationID],
              activity.phase == .scoring
        else { return }
        tagSuggestionActivitiesByID[operationID] = TagLibrarySuggestionActivitySnapshot(
            operationID: activity.operationID,
            mediaKind: activity.mediaKind,
            method: activity.method,
            tagID: activity.tagID,
            phase: .scoring,
            completedUnitCount: checked,
            totalUnitCount: activity.totalUnitCount,
            aboveThresholdCount: aboveThreshold,
            insertedCount: 0,
            skippedCount: skipped,
            errorCode: nil
        )
    }

    private func sampleSuggestionMaximumCountValue() -> Int {
        min(
            max(sampleSuggestionLimit(), PendingSuggestionGenerationLimits.minCount),
            PendingSuggestionGenerationLimits.maxCount
        )
    }

    private func executeEmbeddingPreparation(
        operationID: UUID,
        mediaKind: MediaKind,
        revisions: [EmbeddingRevision]
    ) async {
        guard let embeddingCache else { return }
        var prepared = 0
        var cached = 0
        var cloudOnly = 0
        var failed = 0
        var completed = 0
        var terminalPhase: EmbeddingPreparationPhase = .completed
        var errorCode: String?

        for revision in revisions {
            do {
                try Task.checkCancellation()
                let result = try await embeddingCache.cacheSelectedAsset(
                    assetID: revision.assetID,
                    contentRevision: revision.contentRevision,
                    imageData: { [catalog] in
                        try await catalog.loadPreview(assetID: revision.assetID)
                    }
                )
                try Task.checkCancellation()
                if result.origin == .cacheHit { cached += 1 } else { prepared += 1 }
            } catch is CancellationError {
                terminalPhase = .cancelled
                break
            } catch AppSelectedAssetEmbeddingCacheError.modelUnavailable {
                terminalPhase = .failed
                errorCode = "modelUnavailable"
                break
            } catch PhotosLibraryError.cloudOnly {
                cloudOnly += 1
            } catch {
                failed += 1
            }
            completed += 1
            embeddingActivities[operationID] = EmbeddingPreparationActivitySnapshot(
                operationID: operationID,
                mediaKind: mediaKind,
                phase: .running,
                completedUnitCount: completed,
                totalUnitCount: revisions.count,
                preparedCount: prepared,
                cachedCount: cached,
                cloudOnlyCount: cloudOnly,
                failedCount: failed,
                errorCode: nil
            )
        }

        if embeddingActivities[operationID]?.phase == .cancelled {
            terminalPhase = .cancelled
        }
        embeddingActivities[operationID] = EmbeddingPreparationActivitySnapshot(
            operationID: operationID,
            mediaKind: mediaKind,
            phase: terminalPhase,
            completedUnitCount: completed,
            totalUnitCount: revisions.count,
            preparedCount: prepared,
            cachedCount: cached,
            cloudOnlyCount: cloudOnly,
            failedCount: failed,
            errorCode: errorCode
        )
        embeddingTasks[operationID] = nil
        if activeEmbeddingOperationID == operationID {
            activeEmbeddingOperationID = nil
        }
    }

    private func launchFeature(
        _ command: TrainingLaunchCommand,
        setup: TrainingCommandSetupSnapshot
    ) throws -> TrainingLaunchReceipt {
        guard command.tagIDs.count == 1,
              command.assetIDs.isEmpty,
              !command.sourceIDs.isEmpty,
              let tagID = command.tagIDs.first,
              let tag = setup.tags.first(where: { $0.id == tagID }),
              let featureMode = tag.featureMode
        else {
            throw TrainingCommandError.invalidSelection
        }
        let availableSourceIDs = Set(setup.sources.map(\.id))
        guard command.sourceIDs.isSubset(of: availableSourceIDs) else {
            throw TrainingCommandError.invalidSelection
        }
        let mode: PersonalizationReviewEnqueueMode = featureMode == .update ? .update : .generate
        let jobID: UUID
        do {
            jobID = try review.enqueueFullLibrarySuggestions(
                mediaKind: command.mediaKind,
                tagID: tagID,
                mode: mode,
                sourceIDs: Array(command.sourceIDs).sorted {
                    $0.uuidString.lowercased() < $1.uuidString.lowercased()
                }
            )
        } catch PersonalizationReviewError.insufficientSamples {
            throw TrainingCommandError.insufficientSamples
        } catch PersonalizationReviewError.activeJobConflict {
            throw TrainingCommandError.activeConflict
        }
        startSuggestionRunnerIfNeeded()
        return TrainingLaunchReceipt(
            operationID: command.operationID,
            method: command.method,
            acceptedAtMs: clock.nowMs,
            scheduledTagCount: 1,
            jobID: jobID
        )
    }

    private func launchPersonal(
        _ command: TrainingLaunchCommand,
        setup: TrainingCommandSetupSnapshot
    ) throws -> TrainingLaunchReceipt {
        let rebuilder: any AppPersonalModelRebuilding
        switch command.method {
        case .personalCentroid:
            guard setup.supportsPersonalCentroid, let centroidRebuilder else {
                throw TrainingCommandError.unavailable
            }
            rebuilder = centroidRebuilder
        case .personalAdamW:
            guard setup.supportsPersonalAdamW, let adamWRebuilder else {
                throw TrainingCommandError.unavailable
            }
            rebuilder = adamWRebuilder
        case .featureKnn:
            throw TrainingCommandError.invalidSelection
        }
        guard !activePersonalMethods.contains(command.method),
              activeSampleSuggestionOperationID == nil,
              activeTagSuggestionOperationID == nil,
              !command.tagIDs.isEmpty,
              command.sourceIDs.isEmpty,
              command.tagIDs.allSatisfy({ tagID in
                  setup.tags.contains { $0.id == tagID && $0.personalEligible }
              })
        else {
            throw activePersonalMethods.contains(command.method)
                || activeSampleSuggestionOperationID != nil
                || activeTagSuggestionOperationID != nil
                ? TrainingCommandError.activeConflict
                : TrainingCommandError.invalidSelection
        }

        for tagID in command.tagIDs {
            let snapshot = try review.personalTrainingSnapshot(
                mediaKind: command.mediaKind,
                limitingToTagIDs: [tagID],
                limitingToAssetIDs: command.assetIDs.isEmpty ? nil : command.assetIDs
            )
            guard Self.hasMinimumPersonalSamples(snapshot) else {
                throw TrainingCommandError.insufficientSamples
            }
        }

        let acceptedAtMs = clock.nowMs
        let orderedTagIDs = command.tagIDs.sorted {
            $0.uuidString.lowercased() < $1.uuidString.lowercased()
        }
        let tagActivities = orderedTagIDs.map { tagID in
            TrainingCommandTagActivitySnapshot(
                tagID: tagID,
                displayName: setup.tags.first(where: { $0.id == tagID })?.displayName
                    ?? tagID.uuidString.lowercased(),
                phase: .pending,
                sampleCount: nil,
                errorCode: nil
            )
        }
        let receipt = TrainingLaunchReceipt(
            operationID: command.operationID,
            method: command.method,
            acceptedAtMs: acceptedAtMs,
            scheduledTagCount: command.tagIDs.count,
            jobID: nil
        )
        activePersonalMethods.insert(command.method)
        let initialActivity = TrainingCommandActivitySnapshot(
            operationID: command.operationID,
            mediaKind: command.mediaKind,
            method: command.method,
            phase: .preparingSamples,
            completedUnitCount: 0,
            totalUnitCount: command.tagIDs.count,
            sampleCount: nil,
            errorCode: nil,
            tagActivities: tagActivities,
            acceptedAtMs: acceptedAtMs,
            updatedAtMs: acceptedAtMs
        )
        activitiesByOperationID[command.operationID] = initialActivity
        trainingActivityStore?.upsert(initialActivity)
        personalTasks[command.operationID] = Task { [weak self] in
            await self?.executePersonal(
                command,
                acceptedAtMs: acceptedAtMs,
                rebuilder: rebuilder
            )
        }
        return receipt
    }

    private func executePersonal(
        _ command: TrainingLaunchCommand,
        acceptedAtMs: Int64,
        rebuilder: any AppPersonalModelRebuilding
    ) async {
        defer {
            activePersonalMethods.remove(command.method)
            personalTasks[command.operationID] = nil
        }
        let orderedTagIDs = command.tagIDs.sorted {
            $0.uuidString.lowercased() < $1.uuidString.lowercased()
        }
        var tagActivities = activitiesByOperationID[command.operationID]?.tagActivities ?? []
        var succeededTagCount = 0
        var skippedTagCount = 0
        var failedTagCount = 0
        var cancelled = false
        var lastErrorCode: String?

        func setTag(
            at index: Int,
            phase: TrainingCommandTagActivityPhase,
            sampleCount: Int? = nil,
            errorCode: String? = nil
        ) {
            guard tagActivities.indices.contains(index) else { return }
            let previous = tagActivities[index]
            tagActivities[index] = TrainingCommandTagActivitySnapshot(
                tagID: previous.tagID,
                displayName: previous.displayName,
                phase: phase,
                sampleCount: sampleCount ?? previous.sampleCount,
                errorCode: errorCode
            )
        }

        func publish(
            phase: TrainingCommandActivityPhase,
            currentSampleCount: Int? = nil,
            errorCode: String? = nil
        ) {
            let completed = succeededTagCount + skippedTagCount + failedTagCount
                + (cancelled ? 1 : 0)
            let activity = TrainingCommandActivitySnapshot(
                operationID: command.operationID,
                mediaKind: command.mediaKind,
                method: command.method,
                phase: phase,
                completedUnitCount: min(completed, orderedTagIDs.count),
                totalUnitCount: orderedTagIDs.count,
                sampleCount: currentSampleCount,
                errorCode: errorCode,
                tagActivities: tagActivities,
                acceptedAtMs: acceptedAtMs,
                updatedAtMs: clock.nowMs
            )
            activitiesByOperationID[command.operationID] = activity
            trainingActivityStore?.upsert(activity)
        }

        for (index, tagID) in orderedTagIDs.enumerated() {
            do {
                try Task.checkCancellation()
                setTag(at: index, phase: .preparingSamples)
                publish(phase: .preparingSamples)
                let tagIDs: Set<UUID> = [tagID]
                let batchContext = PersonalTrainingBatchContext(
                    operationID: command.operationID,
                    orderedTagIDs: orderedTagIDs,
                    currentTagIndex: index,
                    acceptedAtMs: acceptedAtMs
                )
                let snapshotSource = AppPersonalTrainingSnapshotPortSource { [review] in
                    let snapshot = try review.personalTrainingSnapshot(
                        mediaKind: command.mediaKind,
                        limitingToTagIDs: tagIDs,
                        limitingToAssetIDs: command.assetIDs.isEmpty ? nil : command.assetIDs
                    )
                    return PersonalTrainingSnapshot(
                        catalogScopeID: snapshot.catalogScopeID,
                        mediaKind: snapshot.mediaKind,
                        personalTagIDs: snapshot.personalTagIDs,
                        decisions: snapshot.decisions,
                        batchContext: batchContext
                    )
                }
                let snapshot = try await snapshotSource.currentSnapshot()
                try Task.checkCancellation()
                guard Self.hasMinimumPersonalSamples(snapshot) else {
                    setTag(
                        at: index,
                        phase: .skipped,
                        errorCode: "insufficientSamples"
                    )
                    skippedTagCount += 1
                    publish(phase: .preparingSamples)
                    continue
                }
                let revisions = Set(snapshot.decisions.map {
                    SampleRevision(assetID: $0.assetID, contentRevision: $0.contentRevision)
                }).sorted { lhs, rhs in
                    let lhsID = lhs.assetID.uuidString.lowercased()
                    let rhsID = rhs.assetID.uuidString.lowercased()
                    return lhsID == rhsID
                        ? lhs.contentRevision < rhs.contentRevision
                        : lhsID < rhsID
                }
                setTag(
                    at: index,
                    phase: .preparingEmbeddings,
                    sampleCount: revisions.count
                )
                publish(
                    phase: .preparingEmbeddings,
                    currentSampleCount: revisions.count
                )
                try await prepareEmbeddings(revisions)
                try Task.checkCancellation()
                setTag(
                    at: index,
                    phase: .trainingAndPublishing,
                    sampleCount: revisions.count
                )
                publish(
                    phase: .trainingAndPublishing,
                    currentSampleCount: revisions.count
                )
                _ = try await rebuilder.rebuild(snapshotSource: snapshotSource)
                setTag(at: index, phase: .succeeded, sampleCount: revisions.count)
                succeededTagCount += 1
                publish(phase: .trainingAndPublishing)
            } catch {
                let wasCancelled = error is CancellationError
                    || (error as? AppPersonalModelRebuildError) == .cancelled
                if wasCancelled {
                    cancelled = true
                    setTag(at: index, phase: .cancelled)
                    break
                }
                let errorCode = Self.safeErrorCode(error)
                if (error as? AppPersonalModelRebuildError) == .invalidSnapshot
                    || errorCode == "insufficientSamples"
                {
                    setTag(at: index, phase: .skipped, errorCode: errorCode)
                    skippedTagCount += 1
                } else {
                    setTag(at: index, phase: .failed, errorCode: errorCode)
                    failedTagCount += 1
                    lastErrorCode = errorCode
                }
                publish(phase: .trainingAndPublishing)
            }
        }
        let finalPhase: TrainingCommandActivityPhase
        let finalErrorCode: String?
        if cancelled {
            finalPhase = .cancelled
            finalErrorCode = nil
        } else if succeededTagCount > 0 {
            finalPhase = .completed
            finalErrorCode = lastErrorCode
        } else {
            finalPhase = .failed
            finalErrorCode = lastErrorCode ?? (skippedTagCount > 0
                ? "insufficientSamples"
                : "trainingFailed")
        }
        publish(phase: finalPhase, errorCode: finalErrorCode)
    }

    private func prepareEmbeddings(_ revisions: [SampleRevision]) async throws {
        guard let embeddingCache else {
            throw TrainingCommandError.unavailable
        }
        for revision in revisions {
            try Task.checkCancellation()
            _ = try await embeddingCache.cacheSelectedAsset(
                assetID: revision.assetID,
                contentRevision: revision.contentRevision,
                imageData: { [catalog] in
                    try await catalog.loadPreview(assetID: revision.assetID)
                }
            )
        }
    }

    private func startSuggestionRunnerIfNeeded() {
        guard suggestionRunnerTask == nil else { return }
        let review = review
        suggestionRunnerTask = Task { @MainActor [weak self] in
            let worker = PersonalizationSuggestionRunner.startLoop(review: review) { }
            await worker.value
            await self?.clearSuggestionRunner()
        }
    }

    private func clearSuggestionRunner() {
        suggestionRunnerTask = nil
    }

    private static func hasMinimumPersonalSamples(_ snapshot: PersonalTrainingSnapshot) -> Bool {
        guard snapshot.personalTagIDs.count == 1,
              let tagID = snapshot.personalTagIDs.first
        else { return false }
        return snapshot.decisions.filter {
            $0.tagID == tagID && $0.state == .manualAccepted
        }.count >= 2
    }

    private static func safeErrorCode(_ error: Error) -> String {
        switch error {
        case TrainingCommandError.insufficientSamples:
            "insufficientSamples"
        case TrainingCommandError.activeConflict,
             AppPersonalModelRebuildError.alreadyRunning:
            "activeConflict"
        case AppPersonalModelRebuildError.modelUnavailable,
             AppSelectedAssetEmbeddingCacheError.modelUnavailable:
            "modelUnavailable"
        case AppPersonalModelRebuildError.embeddingUnavailable,
             AppSelectedAssetEmbeddingCacheError.persistenceFailed:
            "embeddingUnavailable"
        case AppPersonalModelRebuildError.staleSnapshot:
            "staleSnapshot"
        case AppPersonalModelRebuildError.cancelled, is CancellationError:
            "cancelled"
        default:
            "trainingFailed"
        }
    }

    private static func safeSampleSuggestionErrorCode(_ error: Error) -> String {
        switch error {
        case AppPersonalSampleSuggestionError.personalUnavailable:
            "personalUnavailable"
        case AppPersonalSampleSuggestionError.modelUnavailable,
             AppSelectedAssetEmbeddingCacheError.modelUnavailable:
            "modelUnavailable"
        case AppPersonalSampleSuggestionError.alreadyRunning:
            "activeConflict"
        case AppPersonalSampleSuggestionError.identityMismatch:
            "identityMismatch"
        case AppSelectedAssetEmbeddingCacheError.persistenceFailed:
            "embeddingUnavailable"
        default:
            "suggestionFailed"
        }
    }
}
