import CryptoKit
import Foundation

actor AppPersonalModelRebuildCoordinator {
    private let expectedCatalogScopeID: String
    private let encoderIdentity: AppCoreMLModelIdentity
    private let snapshotSource: any AppPersonalTrainingSnapshotSource
    private let embeddingSource: any AppPersonalTrainingEmbeddingSource
    private let store: AppPersonalLinearHeadStore
    private var activeTask: Task<AppPersonalLinearHeadIdentity, Error>?

    init(
        expectedCatalogScopeID: String,
        encoderIdentity: AppCoreMLModelIdentity,
        snapshotSource: any AppPersonalTrainingSnapshotSource,
        embeddingSource: any AppPersonalTrainingEmbeddingSource,
        store: AppPersonalLinearHeadStore
    ) {
        self.expectedCatalogScopeID = expectedCatalogScopeID
        self.encoderIdentity = encoderIdentity
        self.snapshotSource = snapshotSource
        self.embeddingSource = embeddingSource
        self.store = store
    }

    func rebuild() async throws -> AppPersonalLinearHeadIdentity {
        guard activeTask == nil else {
            throw AppPersonalModelRebuildError.alreadyRunning
        }
        let task = Task {
            try await self.performRebuild()
        }
        activeTask = task
        defer { activeTask = nil }
        do {
            return try await task.value
        } catch is CancellationError {
            throw AppPersonalModelRebuildError.cancelled
        }
    }

    func cancel() {
        activeTask?.cancel()
    }

    private func performRebuild() async throws -> AppPersonalLinearHeadIdentity {
        try Task.checkCancellation()
        let source = try await snapshotSource.currentSnapshot()
        try Task.checkCancellation()
        guard source.catalogScopeID == expectedCatalogScopeID else {
            throw AppPersonalModelRebuildError.invalidSnapshot
        }
        let expectedEncoder = PersonalTrainingEncoderIdentity(encoderIdentity)
        let revisions = Set(source.decisions.map {
            AssetRevision(assetID: $0.assetID, contentRevision: $0.contentRevision)
        }).sorted(by: AssetRevision.isOrderedBefore)
        var embeddings: [PersonalTrainingEmbeddingRow] = []
        for revision in revisions {
            let key = PersonalTrainingEmbeddingCacheKey(
                catalogScopeID: source.catalogScopeID,
                assetID: revision.assetID,
                contentRevision: revision.contentRevision
            )
            let cached: PersonalTrainingEmbedding?
            do {
                cached = try await embeddingSource.cachedEmbedding(for: key)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw AppPersonalModelRebuildError.embeddingUnavailable
            }
            guard let embedding = cached,
                  embedding.encoder == expectedEncoder
            else {
                throw AppPersonalModelRebuildError.embeddingUnavailable
            }
            try Task.checkCancellation()
            embeddings.append(
                PersonalTrainingEmbeddingRow(
                    assetID: revision.assetID,
                    contentRevision: revision.contentRevision,
                    values: embedding.values
                )
            )
        }
        let tagIDs = source.personalTagIDs.sorted {
            $0.uuidString.lowercased() < $1.uuidString.lowercased()
        }
        let decisionSnapshotRevision = Self.decisionSnapshotRevision(source)
        let labelVocabularyRevision = Self.labelVocabularyRevision(tagIDs)
        let snapshot = PersonalModelRebuildSnapshot(
            catalogScopeID: source.catalogScopeID,
            decisionSnapshotRevision: decisionSnapshotRevision,
            encoder: expectedEncoder,
            personalTagIDs: tagIDs,
            labelVocabularyRevision: labelVocabularyRevision,
            embeddings: embeddings,
            decisions: source.decisions
        )
        let artifact: AppPersonalLinearHeadArtifact
        do {
            artifact = try AppPersonalLinearHeadTrainer.train(
                snapshot: snapshot,
                encoderIdentity: encoderIdentity
            )
        } catch {
            throw AppPersonalModelRebuildError.invalidSnapshot
        }
        let current = try await snapshotSource.currentSnapshot()
        try Task.checkCancellation()
        let currentTagIDs = current.personalTagIDs.sorted {
            $0.uuidString.lowercased() < $1.uuidString.lowercased()
        }
        guard Self.decisionSnapshotRevision(current) == decisionSnapshotRevision,
              Self.labelVocabularyRevision(currentTagIDs) == labelVocabularyRevision
        else {
            throw AppPersonalModelRebuildError.staleSnapshot
        }
        let capability = try await store.publish(artifact)
        guard case let .ready(identity) = capability else {
            throw AppPersonalModelRebuildError.invalidSnapshot
        }
        return identity
    }

    private static func labelVocabularyRevision(_ tagIDs: [UUID]) -> String {
        sha256(tagIDs.map { $0.uuidString.lowercased() }.joined(separator: "\n"))
    }

    private static func decisionSnapshotRevision(_ snapshot: PersonalTrainingSnapshot) -> String {
        let decisions = snapshot.decisions.sorted { lhs, rhs in
            decisionKey(lhs) < decisionKey(rhs)
        }
        let lines = ["catalog|\(snapshot.catalogScopeID)"]
            + snapshot.personalTagIDs.map { "tag|\($0.uuidString.lowercased())" }.sorted()
            + decisions.map {
                "decision|\($0.assetID.uuidString.lowercased())|\($0.contentRevision)|\($0.tagID.uuidString.lowercased())|\($0.state.rawValue)"
            }
        return sha256(lines.joined(separator: "\n"))
    }

    private static func decisionKey(_ decision: PersonalTrainingDecision) -> String {
        "\(decision.tagID.uuidString.lowercased())|\(decision.assetID.uuidString.lowercased())|\(decision.contentRevision)|\(decision.state.rawValue)"
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private struct AssetRevision: Hashable {
        let assetID: UUID
        let contentRevision: Int

        static func isOrderedBefore(_ lhs: Self, _ rhs: Self) -> Bool {
            let lhsID = lhs.assetID.uuidString.lowercased()
            let rhsID = rhs.assetID.uuidString.lowercased()
            return lhsID == rhsID
                ? lhs.contentRevision < rhs.contentRevision
                : lhsID < rhsID
        }
    }
}

private extension PersonalTrainingEncoderIdentity {
    init(_ identity: AppCoreMLModelIdentity) {
        self.init(
            provider: identity.provider,
            modelID: identity.modelID,
            modelRevision: identity.modelRevision,
            preprocessingRevision: identity.preprocessingRevision,
            elementCount: identity.elementCount
        )
    }
}
