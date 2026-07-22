import Foundation

actor AppPersonalTagLibrarySuggestionRuntime: AppPersonalTagLibrarySuggesting {
    private let expectedCatalogScopeID: String
    private let activationCoordinator: AppModelActivationCoordinator
    private let applicationSupportDirectory: URL
    private var isRunning = false

    init(
        expectedCatalogScopeID: String,
        activationCoordinator: AppModelActivationCoordinator,
        applicationSupportDirectory: URL
    ) {
        self.expectedCatalogScopeID = expectedCatalogScopeID
        self.activationCoordinator = activationCoordinator
        self.applicationSupportDirectory = applicationSupportDirectory
    }

    func suggest(
        tagID: UUID,
        candidates: [PersonalSuggestionCandidate],
        maximumPendingCount: Int,
        embedding: @escaping @Sendable (PersonalSuggestionCandidate) async throws -> AppCoreMLEmbedding,
        progress: (@Sendable (Int, Int, Int) -> Void)?
    ) async throws -> AppPersonalTagLibrarySuggestionBatch {
        guard !isRunning else {
            throw AppPersonalTagLibrarySuggestionError.alreadyRunning
        }
        isRunning = true
        defer { isRunning = false }

        guard maximumPendingCount > 0 else {
            throw AppPersonalTagLibrarySuggestionError.identityMismatch
        }
        guard let service = await activationCoordinator.readyService(),
              case let .ready(encoderIdentity) = service.availability
        else {
            throw AppPersonalTagLibrarySuggestionError.modelUnavailable
        }

        let store = AppPersonalLinearHeadStore(
            applicationSupportDirectory: applicationSupportDirectory,
            expectedCatalogScopeID: expectedCatalogScopeID,
            expectedEncoderIdentity: encoderIdentity
        )
        guard case let .ready(identity) = await store.start() else {
            throw AppPersonalTagLibrarySuggestionError.personalUnavailable
        }
        guard identity.personalTagIDs.contains(tagID) else {
            throw AppPersonalTagLibrarySuggestionError.tagNotInPersonalModel
        }
        let capability = AppPersonalSuggestionCapabilityMapper.capability(from: identity)

        var hits: [AppPersonalTagLibrarySuggestionHit] = []
        var skippedCount = 0
        let total = candidates.count
        for (index, candidate) in candidates.enumerated() {
            try Task.checkCancellation()
            guard candidate.contentRevision > 0 else {
                skippedCount += 1
                progress?(index + 1, hits.count, skippedCount)
                continue
            }
            let values: AppCoreMLEmbedding
            do {
                values = try await embedding(candidate)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                skippedCount += 1
                progress?(index + 1, hits.count, skippedCount)
                continue
            }
            let score: Float
            do {
                guard let scored = try await store.score(tagID: tagID, embedding: values),
                      scored > 0
                else {
                    progress?(index + 1, hits.count, skippedCount)
                    continue
                }
                score = scored
            } catch {
                skippedCount += 1
                progress?(index + 1, hits.count, skippedCount)
                continue
            }
            hits.append(
                AppPersonalTagLibrarySuggestionHit(
                    candidate: candidate,
                    score: Double(score)
                )
            )
            progress?(index + 1, hits.count, skippedCount)
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
            skippedCount: skippedCount
        )
    }
}
