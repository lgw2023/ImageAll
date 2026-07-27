import XCTest
@testable import ImageAll

final class NearDuplicateSceneClusteringTests: XCTestCase {
    private let sceneModelIdentity = SlimmingVectorModelIdentity(
        featurePrintProvider: PersonalizationConstants.provider,
        featurePrintRequestRevision: PersonalizationConstants.requestRevision,
        featurePrintPreprocessingRevision: PersonalizationConstants.preprocessingRevision,
        embeddingProvider: "dinov2",
        embeddingModelID: "facebook/dinov2-small",
        embeddingModelRevision: "model-v1",
        embeddingPreprocessingRevision: "preprocessing-v1",
        perceptualAlgoVersion: nil,
        policyVersion: NearDuplicateScenePolicy.policyVersion
    )

    func testFeaturePrintRecallAndDINORefineFormsSceneCluster() throws {
        let a = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let b = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
        let c = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!

        let featurePrints: [UUID: [Float]] = [
            a: [1, 0, 0, 0],
            b: [0.98, 0.02, 0, 0],
            c: [0, 0, 1, 0],
        ]
        let embeddings: [UUID: [Float]] = [
            a: [1, 0, 0],
            b: [0.99, 0.01, 0],
            c: [0, 1, 0],
        ]

        let clusters = NearDuplicateSceneClusterService().cluster(
            featurePrints: featurePrints,
            embeddings: embeddings,
            modelIdentity: sceneModelIdentity
        )
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].kind, .nearDuplicateScene)
        XCTAssertEqual(Set(clusters[0].memberAssetIDs), Set([a, b]))
        XCTAssertGreaterThanOrEqual(
            clusters[0].score,
            NearDuplicateScenePolicy.dinoCosineMinSimilarity
        )
        XCTAssertTrue(clusters[0].modelIdentity.revisionCaption.contains("fp:vision-feature-print/r2"))
        XCTAssertTrue(clusters[0].modelIdentity.revisionCaption.contains("dino:dinov2/"))
    }

    func testDINOBelowThresholdDoesNotClusterDespiteCloseFeaturePrint() throws {
        let a = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let b = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!

        let featurePrints: [UUID: [Float]] = [
            a: [1, 0],
            b: [0.99, 0.01],
        ]
        let embeddings: [UUID: [Float]] = [
            a: [1, 0],
            b: [0, 1],
        ]

        let clusters = NearDuplicateSceneClusterService().cluster(
            featurePrints: featurePrints,
            embeddings: embeddings,
            modelIdentity: sceneModelIdentity
        )
        XCTAssertTrue(clusters.isEmpty)
    }

    func testBridgePairDoesNotMergeIntoThreeMemberClusterUnderCompleteLinkage() throws {
        let a = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let b = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
        let c = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!

        let featurePrints: [UUID: [Float]] = [
            a: [1, 0, 0],
            b: [0.99, 0.01, 0],
            c: [0.98, 0.02, 0],
        ]
        let angle28 = 28.0 * Double.pi / 180.0
        let angle56 = 56.0 * Double.pi / 180.0
        let embeddings: [UUID: [Float]] = [
            a: [1, 0],
            b: [Float(cos(angle28)), Float(sin(angle28))],
            c: [Float(cos(angle56)), Float(sin(angle56))],
        ]

        let clusters = NearDuplicateSceneClusterService().cluster(
            featurePrints: featurePrints,
            embeddings: embeddings,
            modelIdentity: sceneModelIdentity
        )
        XCTAssertFalse(clusters.contains(where: { $0.memberAssetIDs.count == 3 }))
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].memberAssetIDs.count, 2)
    }

    func testIdenticalMembersExcludedFromSceneClusters() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }

        let bytes = try XCTUnwrap(SimilarityTestSupport.patternedImageData(seed: 7, uti: .jpeg))
        let a = try env.seedAsset(relativePath: "dup-a.jpg", contents: bytes)
        let b = try env.seedAsset(relativePath: "dup-b.jpg", contents: bytes)
        let cID = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
        let dID = UUID(uuidString: "dddddddd-dddd-4ddd-8ddd-dddddddddddd")!

        let completion = env.makeCompletionService()
        _ = try completion.completeFolderAsset(assetID: a.assetID)
        _ = try completion.completeFolderAsset(assetID: b.assetID)

        let featureLoader = DictionarySlimmingFeatureLoader(vectors: [
            a.assetID: [1, 0, 0],
            cID: [0.99, 0.01, 0],
            dID: [0.98, 0.02, 0],
        ])
        let embeddingLoader = DictionarySlimmingEmbeddingLoader(
            vectors: [
                a.assetID: [1, 0, 0],
                cID: [0.99, 0.01, 0],
                dID: [0.98, 0.02, 0],
            ],
            modelIdentity: sceneModelIdentity
        )

        let scan = LibrarySlimmingScanService(
            database: env.database,
            identicalScan: IdenticalDuplicateClusterService(database: env.database),
            fingerprintCompletion: nil,
            featureLoader: featureLoader,
            embeddingLoader: embeddingLoader
        )
        let result = try scan.scan(assetIDs: [a.assetID, b.assetID, cID, dID])

        let identical = result.clusters.filter { $0.kind == .byteIdentical }
        let scene = result.clusters.filter { $0.kind == .nearDuplicateScene }
        XCTAssertEqual(identical.count, 1)
        XCTAssertEqual(Set(identical[0].memberAssetIDs), Set([a.assetID, b.assetID]))
        XCTAssertEqual(scene.count, 1)
        XCTAssertEqual(Set(scene[0].memberAssetIDs), Set([cID, dID]))
        XCTAssertFalse(scene[0].memberAssetIDs.contains(a.assetID))
    }

    func testMissingEmbeddingMarkedPendingNotEmptySuccess() throws {
        let a = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let b = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!

        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }

        let scan = LibrarySlimmingScanService(
            database: env.database,
            identicalScan: IdenticalDuplicateClusterService(database: env.database),
            fingerprintCompletion: nil,
            featureLoader: DictionarySlimmingFeatureLoader(vectors: [
                a: [1, 0],
                b: [0.99, 0.01],
            ]),
            embeddingLoader: DictionarySlimmingEmbeddingLoader(vectors: [
                a: [1, 0],
            ])
        )
        let result = try scan.scan(assetIDs: [a, b])
        XCTAssertTrue(result.clusters.isEmpty)
        XCTAssertEqual(result.pendingAnalysisAssetIDs, [b])
    }

    func testScanReportsProgressPhases() throws {
        let a = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let b = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!

        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }

        let scan = LibrarySlimmingScanService(
            database: env.database,
            identicalScan: IdenticalDuplicateClusterService(database: env.database),
            fingerprintCompletion: nil,
            featureLoader: DictionarySlimmingFeatureLoader(vectors: [
                a: [1, 0],
                b: [0.99, 0.01],
            ]),
            embeddingLoader: DictionarySlimmingEmbeddingLoader(vectors: [
                a: [1, 0],
                b: [0.99, 0.01],
            ])
        )

        final class ProgressBox: @unchecked Sendable {
            var samples: [LibrarySlimmingScanProgress] = []
        }
        let box = ProgressBox()
        _ = try scan.scan(assetIDs: [a, b]) { progress in
            box.samples.append(progress)
        }
        let phases = box.samples.map(\.phase)
        XCTAssertTrue(phases.contains(.loadingFeaturePrints))
        XCTAssertTrue(phases.contains(.loadingEmbeddings))
        XCTAssertTrue(phases.contains(.clustering))
    }

    func testHardwareScaledBudgetsNeverExceedAssetCount() {
        let budgets = SlimmingScanBudgetPolicy.budgets(forAssetCount: 12)
        XCTAssertLessThanOrEqual(budgets.featurePrintGenerations, 12)
        XCTAssertLessThanOrEqual(budgets.embeddingGenerations, 12)
    }

    func testCosineAndL2Helpers() {
        XCTAssertEqual(
            SimilarityVectorMath.cosineSimilarity([1, 0], [1, 0])!,
            1.0,
            accuracy: 1e-6
        )
        XCTAssertEqual(
            SimilarityVectorMath.l2Distance([0, 0], [3, 4])!,
            5.0,
            accuracy: 1e-6
        )
    }
}
