import Foundation

actor AppPersonalTagLibrarySuggestionRuntime: AppPersonalTagLibrarySuggesting {
    private let expectedCatalogScopeID: String
    private let activationCoordinator: AppModelActivationCoordinator
    private let applicationSupportDirectory: URL
    private let family: AppPersonalLinearHeadFamily
    private let database: CatalogDatabase?
    private var isRunning = false

    init(
        expectedCatalogScopeID: String,
        activationCoordinator: AppModelActivationCoordinator,
        applicationSupportDirectory: URL,
        family: AppPersonalLinearHeadFamily = .centroid,
        database: CatalogDatabase? = nil
    ) {
        self.expectedCatalogScopeID = expectedCatalogScopeID
        self.activationCoordinator = activationCoordinator
        self.applicationSupportDirectory = applicationSupportDirectory
        self.family = family
        self.database = database
    }

    func capability(
        mediaKind: MediaKind,
        tagID: UUID
    ) async throws -> PersonalModelSuggestionCapability {
        let (_, capability) = try await preparedStore(
            mediaKind: mediaKind,
            tagID: tagID
        )
        return capability
    }

    func suggest(
        tagID: UUID,
        candidates: [PersonalSuggestionCandidate],
        maximumPendingCount: Int,
        minimumScore: Double,
        embedding: @escaping @Sendable (PersonalSuggestionCandidate) async throws -> AppCoreMLEmbedding,
        progress: (@Sendable (Int, Int, Int) -> Void)?
    ) async throws -> AppPersonalTagLibrarySuggestionBatch {
        try await suggest(
            mediaKind: .image,
            tagID: tagID,
            candidates: candidates,
            maximumPendingCount: maximumPendingCount,
            minimumScore: minimumScore,
            embedding: embedding,
            progress: progress
        )
    }

    func suggest(
        mediaKind: MediaKind,
        tagID: UUID,
        candidates: [PersonalSuggestionCandidate],
        maximumPendingCount: Int,
        minimumScore: Double,
        embedding: @escaping @Sendable (PersonalSuggestionCandidate) async throws -> AppCoreMLEmbedding,
        progress: (@Sendable (Int, Int, Int) -> Void)?
    ) async throws -> AppPersonalTagLibrarySuggestionBatch {
        guard !isRunning else {
            throw AppPersonalTagLibrarySuggestionError.alreadyRunning
        }
        isRunning = true
        defer { isRunning = false }

        guard maximumPendingCount > 0, minimumScore.isFinite else {
            throw AppPersonalTagLibrarySuggestionError.identityMismatch
        }
        let (store, capability) = try await preparedStore(
            mediaKind: mediaKind,
            tagID: tagID
        )

        var hits: [AppPersonalTagLibrarySuggestionHit] = []
        var skippedCount = 0
        let total = candidates.count
        var progressGate = AppPersonalSuggestionProgressGate()
        for (index, candidate) in candidates.enumerated() {
            try Task.checkCancellation()
            guard candidate.contentRevision > 0 else {
                skippedCount += 1
                progressGate.emit(
                    checked: index + 1,
                    suggested: hits.count,
                    skipped: skippedCount,
                    total: total,
                    progress: progress
                )
                continue
            }
            let values: AppCoreMLEmbedding
            do {
                values = try await embedding(candidate)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                skippedCount += 1
                progressGate.emit(
                    checked: index + 1,
                    suggested: hits.count,
                    skipped: skippedCount,
                    total: total,
                    progress: progress
                )
                continue
            }
            let score: Float
            do {
                // Positive-score / configured threshold: do not pad Top-N with
                // low-confidence scores just to fill the quota.
                guard let scored = try await store.score(tagID: tagID, embedding: values),
                      Double(scored).isFinite,
                      Double(scored) > minimumScore
                else {
                    progressGate.emit(
                        checked: index + 1,
                        suggested: hits.count,
                        skipped: skippedCount,
                        total: total,
                        progress: progress
                    )
                    continue
                }
                score = scored
            } catch {
                skippedCount += 1
                progressGate.emit(
                    checked: index + 1,
                    suggested: hits.count,
                    skipped: skippedCount,
                    total: total,
                    progress: progress
                )
                continue
            }
            hits.append(
                AppPersonalTagLibrarySuggestionHit(
                    candidate: candidate,
                    score: Double(score)
                )
            )
            progressGate.emit(
                checked: index + 1,
                suggested: hits.count,
                skipped: skippedCount,
                total: total,
                progress: progress
            )
        }

        let ranked = hits.sorted {
            if $0.score == $1.score {
                return $0.candidate.assetID.uuidString.lowercased()
                    < $1.candidate.assetID.uuidString.lowercased()
            }
            return $0.score > $1.score
        }
        let retained = Array(ranked.prefix(maximumPendingCount))
        _ = total

        return AppPersonalTagLibrarySuggestionBatch(
            tagID: tagID,
            capability: capability,
            hits: retained,
            checkedCount: candidates.count,
            aboveThresholdCount: hits.count,
            skippedCount: skippedCount
        )
    }

    private func preparedStore(
        mediaKind: MediaKind,
        tagID: UUID
    ) async throws -> (AppPersonalLinearHeadStore, PersonalModelSuggestionCapability) {
        guard let service = await activationCoordinator.readyService(),
              case let .ready(encoderIdentity) = service.availability
        else {
            throw AppPersonalTagLibrarySuggestionError.modelUnavailable
        }
        let store = AppPersonalLinearHeadStore(
            applicationSupportDirectory: applicationSupportDirectory,
            expectedCatalogScopeID: expectedCatalogScopeID,
            expectedEncoderIdentity: encoderIdentity,
            mediaKind: mediaKind,
            family: family
        )
        let storeCapability: AppPersonalLinearHeadCapability
        if let database {
            let review = GRDBPersonalizationReviewRepository(database: database)
            let artifactSHA256 = try review.publishedArtifactSHA256(
                mediaKind: mediaKind,
                method: family.personalSuggestionMethod,
                tagID: tagID
            )
            if artifactSHA256 == nil,
               try review.usesLegacyActivePointer(
                   mediaKind: mediaKind,
                   method: family.personalSuggestionMethod,
                   tagID: tagID
               )
            {
                storeCapability = await store.start()
            } else if let artifactSHA256 {
                storeCapability = await store.start(
                    publishedArtifacts: [tagID: artifactSHA256]
                )
            } else {
                throw AppPersonalTagLibrarySuggestionError.tagNotInPersonalModel
            }
        } else {
            storeCapability = await store.start()
        }
        guard case .ready = storeCapability else {
            throw AppPersonalTagLibrarySuggestionError.personalUnavailable
        }
        let identities = await store.identities()
        guard let matchedIdentity = identities.first(where: {
            $0.personalTagIDs == [tagID]
        }) else {
            throw AppPersonalTagLibrarySuggestionError.tagNotInPersonalModel
        }
        return (
            store,
            AppPersonalSuggestionCapabilityMapper.capability(
                from: matchedIdentity,
                mediaKind: mediaKind,
                family: family
            )
        )
    }
}

struct AppPersonalSuggestionProgressGate {
    private var lastEmissionNanoseconds: UInt64 = 0

    mutating func emit(
        checked: Int,
        suggested: Int,
        skipped: Int,
        total: Int,
        progress: (@Sendable (Int, Int, Int) -> Void)?
    ) {
        guard let progress else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let enoughTimePassed = lastEmissionNanoseconds == 0
            || now &- lastEmissionNanoseconds >= 200_000_000
        guard checked == total || checked.isMultiple(of: 32) || enoughTimePassed else {
            return
        }
        lastEmissionNanoseconds = now
        progress(checked, suggested, skipped)
    }
}
