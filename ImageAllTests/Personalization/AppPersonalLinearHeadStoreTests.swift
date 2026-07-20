import CryptoKit
import XCTest
@testable import ImageAll

final class AppPersonalLinearHeadStoreTests: XCTestCase {
    func testValidCandidateBecomesReadyAndRestartsFromTheActiveArtifact() async throws {
        let applicationSupportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: applicationSupportDirectory) }
        let encoderIdentity = makeEncoderIdentity()
        let snapshot = makeSnapshot(encoderIdentity: encoderIdentity)
        let artifact = try AppPersonalLinearHeadTrainer.train(
            snapshot: snapshot,
            encoderIdentity: encoderIdentity
        )
        let identity = try AppPersonalLinearHeadModel(artifact: artifact).identity
        let store = AppPersonalLinearHeadStore(
            applicationSupportDirectory: applicationSupportDirectory,
            expectedCatalogScopeID: snapshot.catalogScopeID,
            expectedEncoderIdentity: encoderIdentity
        )

        let initialCapability = await store.start()
        let publishedCapability = try await store.publish(artifact)
        XCTAssertEqual(initialCapability, .unavailable(.artifactMissing))
        XCTAssertEqual(publishedCapability, .ready(identity))

        let restarted = AppPersonalLinearHeadStore(
            applicationSupportDirectory: applicationSupportDirectory,
            expectedCatalogScopeID: snapshot.catalogScopeID,
            expectedEncoderIdentity: encoderIdentity
        )
        let restartedCapability = await restarted.start()
        XCTAssertEqual(restartedCapability, .ready(identity))
    }

    func testPublicationFailureKeepsThePreviousActiveCapability() async throws {
        let applicationSupportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: applicationSupportDirectory) }
        let encoderIdentity = makeEncoderIdentity()
        let firstSnapshot = makeSnapshot(encoderIdentity: encoderIdentity)
        let secondSnapshot = makeSnapshot(
            encoderIdentity: encoderIdentity,
            decisionSnapshotRevision: String(repeating: "c", count: 64)
        )
        let firstArtifact = try AppPersonalLinearHeadTrainer.train(
            snapshot: firstSnapshot,
            encoderIdentity: encoderIdentity
        )
        let secondArtifact = try AppPersonalLinearHeadTrainer.train(
            snapshot: secondSnapshot,
            encoderIdentity: encoderIdentity
        )
        let firstIdentity = try AppPersonalLinearHeadModel(artifact: firstArtifact).identity
        let store = AppPersonalLinearHeadStore(
            applicationSupportDirectory: applicationSupportDirectory,
            expectedCatalogScopeID: firstSnapshot.catalogScopeID,
            expectedEncoderIdentity: encoderIdentity
        )
        _ = try await store.publish(firstArtifact)
        let storeRoot = applicationSupportDirectory.appendingPathComponent(
            "PersonalModels/LinearHead/v1",
            isDirectory: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: storeRoot.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: storeRoot.path
            )
        }

        do {
            _ = try await store.publish(secondArtifact)
            XCTFail("expected publication to fail")
        } catch {
            XCTAssertEqual(error as? AppPersonalLinearHeadStoreError, .persistenceFailed)
        }
        let capability = await store.capability()
        XCTAssertEqual(capability, .ready(firstIdentity))
    }

    func testCorruptActivePointerDegradesAndCannotInfer() async throws {
        let applicationSupportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: applicationSupportDirectory) }
        let encoderIdentity = makeEncoderIdentity()
        let snapshot = makeSnapshot(encoderIdentity: encoderIdentity)
        let artifact = try AppPersonalLinearHeadTrainer.train(
            snapshot: snapshot,
            encoderIdentity: encoderIdentity
        )
        let store = AppPersonalLinearHeadStore(
            applicationSupportDirectory: applicationSupportDirectory,
            expectedCatalogScopeID: snapshot.catalogScopeID,
            expectedEncoderIdentity: encoderIdentity
        )
        _ = try await store.publish(artifact)
        let activePointer = applicationSupportDirectory.appendingPathComponent(
            "PersonalModels/LinearHead/v1/active.json"
        )
        try Data("{}".utf8).write(to: activePointer, options: .atomic)

        let restarted = AppPersonalLinearHeadStore(
            applicationSupportDirectory: applicationSupportDirectory,
            expectedCatalogScopeID: snapshot.catalogScopeID,
            expectedEncoderIdentity: encoderIdentity
        )
        let capability = await restarted.start()
        XCTAssertEqual(capability, .unavailable(.artifactInvalid))
        do {
            _ = try await restarted.suggestions(
                for: AppCoreMLEmbedding(
                    identity: encoderIdentity,
                    values: embedding(first: 3)
                ),
                maximumCount: 1
            )
            XCTFail("expected inference to remain unavailable")
        } catch {
            XCTAssertEqual(error as? AppPersonalLinearHeadStoreError, .unavailable)
        }
    }

    func testUnsafeCandidateObjectDoesNotReplaceThePreviousActiveArtifact() async throws {
        let applicationSupportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: applicationSupportDirectory) }
        let encoderIdentity = makeEncoderIdentity()
        let firstSnapshot = makeSnapshot(encoderIdentity: encoderIdentity)
        let secondSnapshot = makeSnapshot(
            encoderIdentity: encoderIdentity,
            decisionSnapshotRevision: String(repeating: "c", count: 64)
        )
        let firstArtifact = try AppPersonalLinearHeadTrainer.train(
            snapshot: firstSnapshot,
            encoderIdentity: encoderIdentity
        )
        let secondArtifact = try AppPersonalLinearHeadTrainer.train(
            snapshot: secondSnapshot,
            encoderIdentity: encoderIdentity
        )
        let firstIdentity = try AppPersonalLinearHeadModel(artifact: firstArtifact).identity
        let store = AppPersonalLinearHeadStore(
            applicationSupportDirectory: applicationSupportDirectory,
            expectedCatalogScopeID: firstSnapshot.catalogScopeID,
            expectedEncoderIdentity: encoderIdentity
        )
        _ = try await store.publish(firstArtifact)
        let sentinel = applicationSupportDirectory.appendingPathComponent("sentinel.txt")
        let sentinelBytes = Data("unchanged".utf8)
        try sentinelBytes.write(to: sentinel)
        let artifactSHA256 = SHA256.hash(data: secondArtifact.encodedData)
            .map { String(format: "%02x", $0) }
            .joined()
        let candidateObject = applicationSupportDirectory.appendingPathComponent(
            "PersonalModels/LinearHead/v1/objects/\(artifactSHA256).personal-head"
        )
        try FileManager.default.createSymbolicLink(
            at: candidateObject,
            withDestinationURL: sentinel
        )

        do {
            _ = try await store.publish(secondArtifact)
            XCTFail("expected unsafe candidate object to be rejected")
        } catch {
            XCTAssertEqual(error as? AppPersonalLinearHeadStoreError, .persistenceFailed)
        }
        let capability = await store.capability()
        XCTAssertEqual(capability, .ready(firstIdentity))
        XCTAssertEqual(try Data(contentsOf: sentinel), sentinelBytes)
        XCTAssertTrue(DerivedImageSecureIO.isSymlink(at: candidateObject))
    }

    func testCatalogAndEncoderIdentityMismatchesPreserveTheActiveCapability() async throws {
        let applicationSupportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: applicationSupportDirectory) }
        let encoderIdentity = makeEncoderIdentity()
        let matchingSnapshot = makeSnapshot(encoderIdentity: encoderIdentity)
        let matchingArtifact = try AppPersonalLinearHeadTrainer.train(
            snapshot: matchingSnapshot,
            encoderIdentity: encoderIdentity
        )
        let matchingIdentity = try AppPersonalLinearHeadModel(
            artifact: matchingArtifact
        ).identity
        let store = AppPersonalLinearHeadStore(
            applicationSupportDirectory: applicationSupportDirectory,
            expectedCatalogScopeID: matchingSnapshot.catalogScopeID,
            expectedEncoderIdentity: encoderIdentity
        )
        _ = try await store.publish(matchingArtifact)

        let otherCatalogSnapshot = makeSnapshot(
            encoderIdentity: encoderIdentity,
            catalogScopeID: "70000000-0000-0000-0000-000000000007"
        )
        let otherCatalogArtifact = try AppPersonalLinearHeadTrainer.train(
            snapshot: otherCatalogSnapshot,
            encoderIdentity: encoderIdentity
        )
        do {
            _ = try await store.publish(otherCatalogArtifact)
            XCTFail("expected catalog mismatch")
        } catch {
            XCTAssertEqual(error as? AppPersonalLinearHeadStoreError, .identityMismatch)
        }

        let otherEncoder = AppCoreMLModelIdentity(
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
        let otherEncoderSnapshot = makeSnapshot(encoderIdentity: otherEncoder)
        let otherEncoderArtifact = try AppPersonalLinearHeadTrainer.train(
            snapshot: otherEncoderSnapshot,
            encoderIdentity: otherEncoder
        )
        do {
            _ = try await store.publish(otherEncoderArtifact)
            XCTFail("expected encoder mismatch")
        } catch {
            XCTAssertEqual(error as? AppPersonalLinearHeadStoreError, .identityMismatch)
        }
        let retainedCapability = await store.capability()
        XCTAssertEqual(retainedCapability, .ready(matchingIdentity))

        let mismatchedRestart = AppPersonalLinearHeadStore(
            applicationSupportDirectory: applicationSupportDirectory,
            expectedCatalogScopeID: matchingSnapshot.catalogScopeID,
            expectedEncoderIdentity: otherEncoder
        )
        let restartCapability = await mismatchedRestart.start()
        XCTAssertEqual(restartCapability, .unavailable(.identityMismatch))
    }

    func testSymlinkedStoreParentCannotExposeAnExternalActiveArtifact() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let externalSupport = temporaryRoot.appendingPathComponent(
            "external",
            isDirectory: true
        )
        let attackedSupport = temporaryRoot.appendingPathComponent(
            "attacked",
            isDirectory: true
        )
        let encoderIdentity = makeEncoderIdentity()
        let snapshot = makeSnapshot(encoderIdentity: encoderIdentity)
        let artifact = try AppPersonalLinearHeadTrainer.train(
            snapshot: snapshot,
            encoderIdentity: encoderIdentity
        )
        let externalStore = AppPersonalLinearHeadStore(
            applicationSupportDirectory: externalSupport,
            expectedCatalogScopeID: snapshot.catalogScopeID,
            expectedEncoderIdentity: encoderIdentity
        )
        _ = try await externalStore.publish(artifact)
        try FileManager.default.createDirectory(
            at: attackedSupport,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: attackedSupport.appendingPathComponent("PersonalModels"),
            withDestinationURL: externalSupport.appendingPathComponent("PersonalModels")
        )

        let attackedStore = AppPersonalLinearHeadStore(
            applicationSupportDirectory: attackedSupport,
            expectedCatalogScopeID: snapshot.catalogScopeID,
            expectedEncoderIdentity: encoderIdentity
        )
        let capability = await attackedStore.start()
        XCTAssertEqual(capability, .unavailable(.artifactInvalid))
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
        encoderIdentity: AppCoreMLModelIdentity,
        decisionSnapshotRevision: String = String(repeating: "a", count: 64),
        catalogScopeID: String = "60000000-0000-0000-0000-000000000006"
    ) -> PersonalModelRebuildSnapshot {
        let tagID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let assetIDs = [
            UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            UUID(uuidString: "30000000-0000-0000-0000-000000000003")!,
            UUID(uuidString: "40000000-0000-0000-0000-000000000004")!,
            UUID(uuidString: "50000000-0000-0000-0000-000000000005")!,
        ]
        let values = [
            embedding(first: 2),
            embedding(first: 1),
            embedding(first: -1),
            embedding(first: -2),
        ]
        return PersonalModelRebuildSnapshot(
            catalogScopeID: catalogScopeID,
            decisionSnapshotRevision: decisionSnapshotRevision,
            encoder: PersonalTrainingEncoderIdentity(
                provider: encoderIdentity.provider,
                modelID: encoderIdentity.modelID,
                modelRevision: encoderIdentity.modelRevision,
                preprocessingRevision: encoderIdentity.preprocessingRevision,
                elementCount: encoderIdentity.elementCount
            ),
            personalTagIDs: [tagID],
            labelVocabularyRevision: String(repeating: "b", count: 64),
            embeddings: zip(assetIDs, values).map { assetID, values in
                PersonalTrainingEmbeddingRow(
                    assetID: assetID,
                    contentRevision: 1,
                    values: values
                )
            },
            decisions: assetIDs.enumerated().map { index, assetID in
                PersonalTrainingDecision(
                    assetID: assetID,
                    contentRevision: 1,
                    tagID: tagID,
                    state: index < 2 ? .manualAccepted : .manualRejected
                )
            }
        )
    }

    private func embedding(first: Float) -> [Float] {
        [first] + [Float](repeating: 0, count: 383)
    }
}
