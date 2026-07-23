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
            let artifactSHA256 = try review.publishedArtifactSHA256(
                method: .personalCentroid
            )
            if artifactSHA256 == nil,
               try review.usesLegacyActivePointer(method: .personalCentroid)
            {
                storeCapability = await store.start()
            } else {
                storeCapability = await store.start(
                    publishedArtifactSHA256: artifactSHA256
                )
            }
        } else {
            storeCapability = await store.start()
        }
        guard case let .ready(identity) = storeCapability else {
            throw AppPersonalSampleSuggestionError.personalUnavailable
        }
        let capability = AppPersonalSuggestionCapabilityMapper.capability(from: identity)

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
            let suggestions: [AppPersonalLinearHeadSuggestion]
            do {
                suggestions = try await store.suggestions(
                    for: values,
                    maximumCount: maximumSuggestionsPerAsset
                )
            } catch {
                skippedCount += 1
                continue
            }
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
            capability: capability,
            results: results,
            skippedCount: skippedCount
        )
    }
}
