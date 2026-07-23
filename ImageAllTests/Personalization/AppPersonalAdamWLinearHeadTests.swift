import XCTest
@testable import ImageAll

final class AppPersonalAdamWLinearHeadTests: XCTestCase {
    func testAdamWTrainsReloadAndRanksKnownTagAboveOther() throws {
        let firstTagID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let secondTagID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let encoderIdentity = makeEncoderIdentity()
        let snapshot = makeSnapshot(
            firstTagID: firstTagID,
            secondTagID: secondTagID,
            encoderIdentity: encoderIdentity
        )

        var config = AppPersonalAdamWTrainingConfig.default
        config.maxEpochs = 80
        config.patience = 30
        config.seed = 42

        let (artifact, report) = try AppPersonalAdamWLinearHeadTrainer.train(
            snapshot: snapshot,
            encoderIdentity: encoderIdentity,
            config: config
        )
        let model = try AppPersonalLinearHeadModel(artifact: artifact)
        let suggestions = try model.suggestions(
            for: AppCoreMLEmbedding(
                identity: encoderIdentity,
                values: embedding(first: 1.5, second: 0)
            ),
            maximumCount: 2
        )

        XCTAssertEqual(model.algorithmRevision, AppPersonalAdamWLinearHeadTrainer.algorithmRevision)
        XCTAssertEqual(model.identity.personalTagIDs, [firstTagID, secondTagID])
        XCTAssertGreaterThan(report.epochsRun, 1)
        XCTAssertEqual(report.epochMetrics.count, report.epochsRun)
        XCTAssertEqual(report.epochMetrics.map(\.epoch), Array(1...report.epochsRun))
        XCTAssertTrue(report.epochMetrics.allSatisfy { $0.evaluationLoss.isFinite })
        XCTAssertEqual(report.evaluationSplit, .trainFallback)
        XCTAssertEqual(report.trainSampleCount, 4)
        XCTAssertEqual(report.validationSampleCount, 0)
        XCTAssertEqual(suggestions.first?.tagID, firstTagID)
        XCTAssertTrue(suggestions.allSatisfy { $0.score.isFinite && $0.score > 0 })
    }

    func testAdamWReportIdentifiesValidationEvaluationSplit() throws {
        let firstTagID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let secondTagID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let encoderIdentity = makeEncoderIdentity()
        let base = makeSnapshot(
            firstTagID: firstTagID,
            secondTagID: secondTagID,
            encoderIdentity: encoderIdentity
        )
        let extraAssetIDs = [
            UUID(uuidString: "70000000-0000-0000-0000-000000000007")!,
            UUID(uuidString: "80000000-0000-0000-0000-000000000008")!,
        ]
        let snapshot = PersonalModelRebuildSnapshot(
            catalogScopeID: base.catalogScopeID,
            decisionSnapshotRevision: base.decisionSnapshotRevision,
            encoder: base.encoder,
            personalTagIDs: base.personalTagIDs,
            labelVocabularyRevision: base.labelVocabularyRevision,
            embeddings: base.embeddings + [
                PersonalTrainingEmbeddingRow(
                    assetID: extraAssetIDs[0],
                    contentRevision: 1,
                    values: embedding(first: 1.2, second: 0)
                ),
                PersonalTrainingEmbeddingRow(
                    assetID: extraAssetIDs[1],
                    contentRevision: 1,
                    values: embedding(first: 0, second: 1.2)
                ),
            ],
            decisions: base.decisions + [
                PersonalTrainingDecision(
                    assetID: extraAssetIDs[0],
                    contentRevision: 1,
                    tagID: firstTagID,
                    state: .manualAccepted
                ),
                PersonalTrainingDecision(
                    assetID: extraAssetIDs[1],
                    contentRevision: 1,
                    tagID: secondTagID,
                    state: .manualAccepted
                ),
            ]
        )

        let report = try AppPersonalAdamWLinearHeadTrainer.train(
            snapshot: snapshot,
            encoderIdentity: encoderIdentity
        ).1

        XCTAssertEqual(report.evaluationSplit, .validation)
        XCTAssertEqual(report.trainSampleCount, 5)
        XCTAssertEqual(report.validationSampleCount, 1)
        XCTAssertTrue(report.epochMetrics.allSatisfy { $0.evaluationLoss.isFinite })
    }

    func testAdamWTrainingIsDeterministicForFixedSeed() throws {
        let firstTagID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let secondTagID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let encoderIdentity = makeEncoderIdentity()
        let snapshot = makeSnapshot(
            firstTagID: firstTagID,
            secondTagID: secondTagID,
            encoderIdentity: encoderIdentity
        )
        var config = AppPersonalAdamWTrainingConfig.default
        config.maxEpochs = 40
        config.patience = 40
        config.seed = 7

        let first = try AppPersonalAdamWLinearHeadTrainer.train(
            snapshot: snapshot,
            encoderIdentity: encoderIdentity,
            config: config
        )
        let second = try AppPersonalAdamWLinearHeadTrainer.train(
            snapshot: snapshot,
            encoderIdentity: encoderIdentity,
            config: config
        )
        XCTAssertEqual(first.0, second.0)
        XCTAssertEqual(first.1, second.1)
    }

    func testAdamWRequiresTwoAcceptedDecisionsPerTag() throws {
        let firstTagID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let secondTagID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let encoderIdentity = makeEncoderIdentity()
        let complete = makeSnapshot(
            firstTagID: firstTagID,
            secondTagID: secondTagID,
            encoderIdentity: encoderIdentity
        )
        var removed = false
        let decisions = complete.decisions.filter { decision in
            if !removed, decision.tagID == firstTagID {
                removed = true
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
            try AppPersonalAdamWLinearHeadTrainer.train(
                snapshot: insufficient,
                encoderIdentity: encoderIdentity
            )
        ) { error in
            XCTAssertEqual(error as? AppPersonalLinearHeadError, .insufficientDecisions)
        }
    }

    func testCentroidAndAdamWStoresDoNotShareActivePointer() async throws {
        let firstTagID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let secondTagID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let encoderIdentity = makeEncoderIdentity()
        let snapshot = makeSnapshot(
            firstTagID: firstTagID,
            secondTagID: secondTagID,
            encoderIdentity: encoderIdentity
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let centroidArtifact = try AppPersonalLinearHeadTrainer.train(
            snapshot: snapshot,
            encoderIdentity: encoderIdentity
        )
        let adamWArtifact = try AppPersonalAdamWLinearHeadTrainer.train(
            snapshot: snapshot,
            encoderIdentity: encoderIdentity
        ).0

        let centroidStore = AppPersonalLinearHeadStore(
            applicationSupportDirectory: root,
            expectedCatalogScopeID: snapshot.catalogScopeID,
            expectedEncoderIdentity: encoderIdentity,
            family: .centroid
        )
        let adamWStore = AppPersonalLinearHeadStore(
            applicationSupportDirectory: root,
            expectedCatalogScopeID: snapshot.catalogScopeID,
            expectedEncoderIdentity: encoderIdentity,
            family: .adamW
        )
        let centroidCapability = try await centroidStore.publish(centroidArtifact)
        let adamWCapability = try await adamWStore.publish(adamWArtifact)
        guard case let .ready(centroidIdentity) = centroidCapability,
              case let .ready(adamWIdentity) = adamWCapability
        else {
            return XCTFail("both stores should become ready")
        }
        XCTAssertNotEqual(centroidIdentity.weightsSHA256, adamWIdentity.weightsSHA256)

        _ = await centroidStore.start()
        _ = await adamWStore.start()
        let reloadedCentroid = await centroidStore.capability()
        let reloadedAdamW = await adamWStore.capability()
        XCTAssertEqual(reloadedCentroid, .ready(centroidIdentity))
        XCTAssertEqual(reloadedAdamW, .ready(adamWIdentity))
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
        let decisions = [
            PersonalTrainingDecision(
                assetID: assetIDs[0],
                contentRevision: 1,
                tagID: firstTagID,
                state: .manualAccepted
            ),
            PersonalTrainingDecision(
                assetID: assetIDs[1],
                contentRevision: 1,
                tagID: firstTagID,
                state: .manualAccepted
            ),
            PersonalTrainingDecision(
                assetID: assetIDs[2],
                contentRevision: 1,
                tagID: secondTagID,
                state: .manualAccepted
            ),
            PersonalTrainingDecision(
                assetID: assetIDs[3],
                contentRevision: 1,
                tagID: secondTagID,
                state: .manualAccepted
            ),
        ]
        return PersonalModelRebuildSnapshot(
            catalogScopeID: "11111111-1111-1111-1111-111111111111",
            decisionSnapshotRevision: String(repeating: "a", count: 64),
            encoder: PersonalTrainingEncoderIdentity(encoderIdentity),
            personalTagIDs: [firstTagID, secondTagID],
            labelVocabularyRevision: String(repeating: "b", count: 64),
            embeddings: rows,
            decisions: decisions
        )
    }

    private func embedding(first: Float, second: Float) -> [Float] {
        var values = [Float](repeating: 0, count: 384)
        values[0] = first
        values[1] = second
        return values
    }
}
