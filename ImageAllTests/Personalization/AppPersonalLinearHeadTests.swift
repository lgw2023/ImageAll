import XCTest
@testable import ImageAll

final class AppPersonalLinearHeadTests: XCTestCase {
    func testSyntheticDecisionsTrainReloadAndSuggestAStableKnownTag() throws {
        let firstTagID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let secondTagID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let encoderIdentity = makeEncoderIdentity()
        let snapshot = makeSnapshot(
            firstTagID: firstTagID,
            secondTagID: secondTagID,
            encoderIdentity: encoderIdentity
        )

        let artifact = try AppPersonalLinearHeadTrainer.train(
            snapshot: snapshot,
            encoderIdentity: encoderIdentity
        )
        let repeatedArtifact = try AppPersonalLinearHeadTrainer.train(
            snapshot: snapshot,
            encoderIdentity: encoderIdentity
        )
        let model = try AppPersonalLinearHeadModel(artifact: artifact)
        let suggestions = try model.suggestions(
            for: AppCoreMLEmbedding(
                identity: encoderIdentity,
                values: embedding(first: 1.5, second: 0)
            ),
            maximumCount: 2
        )

        XCTAssertEqual(artifact, repeatedArtifact)
        XCTAssertEqual(model.identity.catalogScopeID, snapshot.catalogScopeID)
        XCTAssertEqual(
            model.identity.decisionSnapshotRevision,
            snapshot.decisionSnapshotRevision
        )
        XCTAssertEqual(model.identity.encoderIdentity, encoderIdentity)
        XCTAssertEqual(model.identity.personalTagIDs, [firstTagID, secondTagID])
        XCTAssertEqual(model.identity.weightsSHA256.count, 64)
        XCTAssertEqual(suggestions.map(\.tagID), [firstTagID])
        XCTAssertTrue(suggestions.allSatisfy { $0.score.isFinite && $0.score > 0 })
    }

    func testTrainingRequiresTwoAcceptedAndTwoRejectedDecisionsPerTag() throws {
        let firstTagID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let secondTagID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let encoderIdentity = makeEncoderIdentity()
        let complete = makeSnapshot(
            firstTagID: firstTagID,
            secondTagID: secondTagID,
            encoderIdentity: encoderIdentity
        )
        var removedAccepted = false
        let decisions = complete.decisions.filter { decision in
            if !removedAccepted,
               decision.tagID == firstTagID,
               decision.state == .manualAccepted
            {
                removedAccepted = true
                return false
            }
            return true
        }
        let insufficient = PersonalModelRebuildSnapshot(
            catalogScopeID: complete.catalogScopeID,
            decisionSnapshotRevision: complete.decisionSnapshotRevision,
            encoder: complete.encoder,
            personalTagIDs: complete.personalTagIDs,
            labelVocabularyRevision: complete.labelVocabularyRevision,
            embeddings: complete.embeddings,
            decisions: decisions
        )

        XCTAssertThrowsError(
            try AppPersonalLinearHeadTrainer.train(
                snapshot: insufficient,
                encoderIdentity: encoderIdentity
            )
        ) { error in
            XCTAssertEqual(error as? AppPersonalLinearHeadError, .insufficientDecisions)
        }
    }

    func testReloadRejectsTamperedParameterBytes() throws {
        let firstTagID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let secondTagID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let encoderIdentity = makeEncoderIdentity()
        let snapshot = makeSnapshot(
            firstTagID: firstTagID,
            secondTagID: secondTagID,
            encoderIdentity: encoderIdentity
        )
        let artifact = try AppPersonalLinearHeadTrainer.train(
            snapshot: snapshot,
            encoderIdentity: encoderIdentity
        )
        var record = try XCTUnwrap(
            JSONSerialization.jsonObject(with: artifact.encodedData) as? [String: Any]
        )
        var parameters = try XCTUnwrap(
            Data(base64Encoded: try XCTUnwrap(record["parameters"] as? String))
        )
        parameters[parameters.startIndex] ^= 0x01
        record["parameters"] = parameters.base64EncodedString()
        let tampered = AppPersonalLinearHeadArtifact(
            encodedData: try JSONSerialization.data(withJSONObject: record)
        )

        XCTAssertThrowsError(try AppPersonalLinearHeadModel(artifact: tampered)) { error in
            XCTAssertEqual(error as? AppPersonalLinearHeadError, .invalidArtifact)
        }
    }

    func testInferenceRejectsACompleteEncoderIdentityMismatch() throws {
        let firstTagID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let secondTagID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let encoderIdentity = makeEncoderIdentity()
        let model = try AppPersonalLinearHeadModel(
            artifact: AppPersonalLinearHeadTrainer.train(
                snapshot: makeSnapshot(
                    firstTagID: firstTagID,
                    secondTagID: secondTagID,
                    encoderIdentity: encoderIdentity
                ),
                encoderIdentity: encoderIdentity
            )
        )
        let mismatchedIdentity = AppCoreMLModelIdentity(
            provider: encoderIdentity.provider,
            modelID: encoderIdentity.modelID,
            modelRevision: encoderIdentity.modelRevision,
            preprocessingRevision: encoderIdentity.preprocessingRevision,
            embeddingSemantics: encoderIdentity.embeddingSemantics,
            postprocessingRevision: encoderIdentity.postprocessingRevision,
            elementType: encoderIdentity.elementType,
            elementCount: encoderIdentity.elementCount,
            sourceModelSHA256: encoderIdentity.sourceModelSHA256,
            artifactSHA256: String(repeating: "9", count: 64),
            manifestSHA256: encoderIdentity.manifestSHA256,
            licenseID: encoderIdentity.licenseID,
            licenseSHA256: encoderIdentity.licenseSHA256
        )

        XCTAssertThrowsError(
            try model.suggestions(
                for: AppCoreMLEmbedding(
                    identity: mismatchedIdentity,
                    values: embedding(first: 1.5, second: 0)
                ),
                maximumCount: 2
            )
        ) { error in
            XCTAssertEqual(error as? AppPersonalLinearHeadError, .identityMismatch)
        }
    }

    func testTrainingRejectsDuplicateAssetRevisionTagDecisions() throws {
        let firstTagID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let secondTagID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let encoderIdentity = makeEncoderIdentity()
        let complete = makeSnapshot(
            firstTagID: firstTagID,
            secondTagID: secondTagID,
            encoderIdentity: encoderIdentity
        )
        let duplicated = PersonalModelRebuildSnapshot(
            catalogScopeID: complete.catalogScopeID,
            decisionSnapshotRevision: complete.decisionSnapshotRevision,
            encoder: complete.encoder,
            personalTagIDs: complete.personalTagIDs,
            labelVocabularyRevision: complete.labelVocabularyRevision,
            embeddings: complete.embeddings,
            decisions: complete.decisions + [try XCTUnwrap(complete.decisions.first)]
        )

        XCTAssertThrowsError(
            try AppPersonalLinearHeadTrainer.train(
                snapshot: duplicated,
                encoderIdentity: encoderIdentity
            )
        ) { error in
            XCTAssertEqual(error as? AppPersonalLinearHeadError, .invalidSnapshot)
        }
    }

    private func makeEncoderIdentity() -> AppCoreMLModelIdentity {
        AppCoreMLModelIdentity(
            provider: "facebook",
            modelID: "dinov2-small",
            modelRevision: "pinned-revision",
            preprocessingRevision: "resize256-center224-imagenet-v1",
            embeddingSemantics: "dinov2-cls-token",
            postprocessingRevision: "raw-float32-v1",
            elementType: "float32",
            elementCount: 384,
            sourceModelSHA256: String(repeating: "1", count: 64),
            artifactSHA256: String(repeating: "2", count: 64),
            manifestSHA256: String(repeating: "3", count: 64),
            licenseID: "Apache-2.0",
            licenseSHA256: String(repeating: "4", count: 64)
        )
    }

    private func makeSnapshot(
        firstTagID: UUID,
        secondTagID: UUID,
        encoderIdentity: AppCoreMLModelIdentity
    ) -> PersonalModelRebuildSnapshot {
        let assetIDs = [
            UUID(uuidString: "30000000-0000-0000-0000-000000000003")!,
            UUID(uuidString: "40000000-0000-0000-0000-000000000004")!,
            UUID(uuidString: "50000000-0000-0000-0000-000000000005")!,
            UUID(uuidString: "60000000-0000-0000-0000-000000000006")!,
        ]
        let values = [
            embedding(first: 2, second: 0),
            embedding(first: 1, second: 0),
            embedding(first: 0, second: 2),
            embedding(first: 0, second: 1),
        ]
        let rows = zip(assetIDs, values).map { assetID, embedding in
            PersonalTrainingEmbeddingRow(
                assetID: assetID,
                contentRevision: 1,
                values: embedding
            )
        }
        let decisions = assetIDs.enumerated().flatMap { index, assetID in
            let firstState: PersonalTrainingDecisionState = index < 2
                ? .manualAccepted
                : .manualRejected
            let secondState: PersonalTrainingDecisionState = index < 2
                ? .manualRejected
                : .manualAccepted
            return [
                PersonalTrainingDecision(
                    assetID: assetID,
                    contentRevision: 1,
                    tagID: firstTagID,
                    state: firstState
                ),
                PersonalTrainingDecision(
                    assetID: assetID,
                    contentRevision: 1,
                    tagID: secondTagID,
                    state: secondState
                ),
            ]
        }
        return PersonalModelRebuildSnapshot(
            catalogScopeID: "70000000-0000-0000-0000-000000000007",
            decisionSnapshotRevision: String(repeating: "a", count: 64),
            encoder: PersonalTrainingEncoderIdentity(
                provider: encoderIdentity.provider,
                modelID: encoderIdentity.modelID,
                modelRevision: encoderIdentity.modelRevision,
                preprocessingRevision: encoderIdentity.preprocessingRevision,
                elementCount: encoderIdentity.elementCount
            ),
            personalTagIDs: [firstTagID, secondTagID],
            labelVocabularyRevision: String(repeating: "b", count: 64),
            embeddings: rows,
            decisions: decisions
        )
    }

    private func embedding(first: Float, second: Float) -> [Float] {
        [first, second] + [Float](repeating: 0, count: 382)
    }
}
