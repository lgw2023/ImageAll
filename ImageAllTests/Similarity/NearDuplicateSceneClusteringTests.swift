import XCTest
@testable import ImageAll

final class NearDuplicateSceneClusteringTests: XCTestCase {
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
            embeddings: embeddings
        )
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].kind, .nearDuplicateScene)
        XCTAssertEqual(Set(clusters[0].memberAssetIDs), Set([a, b]))
        XCTAssertGreaterThanOrEqual(
            clusters[0].score,
            NearDuplicateScenePolicy.dinoCosineMinSimilarity
        )
    }

    func testDINOBelowThresholdDoesNotClusterDespiteCloseFeaturePrint() throws {
        let a = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let b = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!

        let featurePrints: [UUID: [Float]] = [
            a: [1, 0],
            b: [0.99, 0.01],
        ]
        // Orthogonal embeddings → cosine ~ 0
        let embeddings: [UUID: [Float]] = [
            a: [1, 0],
            b: [0, 1],
        ]

        let clusters = NearDuplicateSceneClusterService().cluster(
            featurePrints: featurePrints,
            embeddings: embeddings
        )
        XCTAssertTrue(clusters.isEmpty)
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

        // Inject scene vectors that would otherwise cluster a with c — but a is claimed by identical.
        let featureLoader = DictionarySlimmingFeatureLoader(vectors: [
            a.assetID: [1, 0, 0],
            cID: [0.99, 0.01, 0],
            dID: [0.98, 0.02, 0],
        ])
        let embeddingLoader = DictionarySlimmingEmbeddingLoader(vectors: [
            a.assetID: [1, 0, 0],
            cID: [0.99, 0.01, 0],
            dID: [0.98, 0.02, 0],
        ])

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
                // b missing → pending
            ])
        )
        let result = try scan.scan(assetIDs: [a, b])
        XCTAssertTrue(result.clusters.isEmpty)
        XCTAssertEqual(result.pendingAnalysisAssetIDs, [b])
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
