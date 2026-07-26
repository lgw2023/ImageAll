import Foundation

actor AppPersonalSampleSuggestionRuntime: AppPersonalSampleSuggesting {
    private let expectedCatalogScopeID: String
    private let activationCoordinator: AppModelActivationCoordinator
    private let applicationSupportDirectory: URL
    private let database: CatalogDatabase?
    private var isRunning = false

    init(
        expectedCatalogScopeID: String,
        activationCoordinator: AppModelActivationCoordinator,
        applicationSupportDirectory: URL,
        database: CatalogDatabase? = nil
    ) {
        self.expectedCatalogScopeID = expectedCatalogScopeID
        self.activationCoordinator = activationCoordinator
        self.applicationSupportDirectory = applicationSupportDirectory
        self.database = database
    }

    func suggest(
        candidates: [PersonalSuggestionCandidate],
        maximumSuggestionsPerAsset: Int,
        embedding: @escaping @Sendable (PersonalSuggestionCandidate) async throws -> AppCoreMLEmbedding
    ) async throws -> AppPersonalSampleSuggestionBatch {
        guard !isRunning else {
            throw AppPersonalSampleSuggestionError.alreadyRunning
        }
        isRunning = true
        defer { isRunning = false }

        guard maximumSuggestionsPerAsset > 0 else {
            throw AppPersonalSampleSuggestionError.identityMismatch
        }
        guard let service = await activationCoordinator.readyService(),
              case let .ready(encoderIdentity) = service.availability
        else {
            throw AppPersonalSampleSuggestionError.modelUnavailable
        }

        let store = AppPersonalLinearHeadStore(
            applicationSupportDirectory: applicationSupportDirectory,
            expectedCatalogScopeID: expectedCatalogScopeID,
            expectedEncoderIdentity: encoderIdentity
        )
        let storeCapability: AppPersonalLinearHeadCapability
        if let database {
            let review = GRDBPersonalizationReviewRepository(database: database)
            let published = try review.publishedArtifactSHA256s(method: .personalCentroid)
            if published.isEmpty,
               try review.usesLegacyActivePointer(method: .personalCentroid)
            {
                storeCapability = await store.start()
            } else {
                storeCapability = await store.start(publishedArtifacts: published)
            }
        } else {
            storeCapability = await store.start()
        }
        guard case .ready = storeCapability else {
            throw AppPersonalSampleSuggestionError.personalUnavailable
        }
        let identities = await store.identities()
        guard !identities.isEmpty else {
            throw AppPersonalSampleSuggestionError.personalUnavailable
        }
        // Each active model is single-tag; persist/match capability per tag.
        let capabilities = identities.map {
            AppPersonalSuggestionCapabilityMapper.capability(from: $0)
        }

        var results: [AppPersonalSampleSuggestionAssetResult] = []
        var skippedCount = 0
        for candidate in candidates {
            try Task.checkCancellation()
            guard candidate.contentRevision > 0 else {
                skippedCount += 1
                continue
            }
            let values: AppCoreMLEmbedding
            do {
                values = try await embedding(candidate)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                skippedCount += 1
                continue
            }
            // Score each tag model independently, then take the global top-N.
            var perTag: [AppPersonalLinearHeadSuggestion] = []
            for identity in identities {
                guard let tagID = identity.personalTagIDs.first else { continue }
                do {
                    guard let score = try await store.score(tagID: tagID, embedding: values)
                    else { continue }
                    perTag.append(
                        AppPersonalLinearHeadSuggestion(tagID: tagID, score: score)
                    )
                } catch {
                    continue
                }
            }
            let suggestions = Array(
                perTag
                    .sorted {
                        if $0.score == $1.score {
                            return $0.tagID.uuidString.lowercased()
                                < $1.tagID.uuidString.lowercased()
                        }
                        return $0.score > $1.score
                    }
                    .prefix(maximumSuggestionsPerAsset)
            )
            guard !suggestions.isEmpty else {
                skippedCount += 1
                continue
            }
            results.append(
                AppPersonalSampleSuggestionAssetResult(
                    candidate: candidate,
                    predictions: suggestions.map {
                        PersonalSuggestionPrediction(tagID: $0.tagID, score: Double($0.score))
                    }
                )
            )
        }

        return AppPersonalSampleSuggestionBatch(
            capabilities: capabilities,
            results: results,
            skippedCount: skippedCount
        )
    }
}
