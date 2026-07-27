import GRDB
import UniformTypeIdentifiers
import XCTest
@testable import ImageAll

final class SourceSimilarityIndexTests: XCTestCase {
    func testBuildIndexProducesReadyStatusAndBucketMembers() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let a = try env.seedAsset(
            relativePath: "idx-a.jpg",
            contents: try XCTUnwrap(SimilarityTestSupport.patternedImageData(seed: 1, uti: .jpeg))
        )
        let b = try env.seedAsset(
            relativePath: "idx-b.jpg",
            contents: try XCTUnwrap(SimilarityTestSupport.patternedImageData(seed: 2, uti: .jpeg))
        )
        let c = try env.seedAsset(
            relativePath: "idx-c.jpg",
            contents: try XCTUnwrap(SimilarityTestSupport.patternedImageData(seed: 3, uti: .jpeg))
        )

        let vectors: [UUID: [Float]] = [
            a.assetID: [1, 2, 3, 4, 5, 6, 7, 8],
            b.assetID: [1.0001, 2.0001, 3.0001, 4.0001, 5.0001, 6.0001, 7.0001, 8.0001],
            c.assetID: [-1, -2, -3, -4, -5, -6, -7, -8],
        ]
        let service = SourceSimilarityIndexService(
            database: env.database,
            queue: JobTestSupport.makeQueue(database: env.database),
            featureLoader: DictionarySlimmingFeatureLoader(vectors: vectors),
            clock: FixedJobClock(nowMs: JobTestSupport.baseTimeMs)
        )

        _ = try service.enqueueBuild(sourceID: env.sourceID)
        try service.runPending()

        let status = try XCTUnwrap(service.status(sourceID: env.sourceID))
        XCTAssertEqual(status.state, .ready)
        XCTAssertEqual(status.assetCount, 3)
        XCTAssertEqual(status.indexedCount, 3)
        XCTAssertEqual(status.pendingCount, 0)
        XCTAssertGreaterThanOrEqual(status.clusterCount, 1)

        let memberCount = try env.database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM source_similarity_bucket_member WHERE source_id = ?",
                arguments: [env.sourceID.uuidString.lowercased()]
            ) ?? 0
        }
        XCTAssertEqual(memberCount, 3)
    }

    func testCandidateAssetIDsRestrictsToNeighborBucketAndExcludesFarVector() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let a = try env.seedAsset(
            relativePath: "cand-a.jpg",
            contents: try XCTUnwrap(SimilarityTestSupport.patternedImageData(seed: 5, uti: .jpeg))
        )
        let b = try env.seedAsset(
            relativePath: "cand-b.jpg",
            contents: try XCTUnwrap(SimilarityTestSupport.patternedImageData(seed: 6, uti: .jpeg))
        )
        let c = try env.seedAsset(
            relativePath: "cand-c.jpg",
            contents: try XCTUnwrap(SimilarityTestSupport.patternedImageData(seed: 7, uti: .jpeg))
        )

        let vectors: [UUID: [Float]] = [
            a.assetID: [1, 2, 3, 4, 5, 6, 7, 8],
            b.assetID: [1.0000001, 2.0000001, 3.0000001, 4.0000001, 5.0000001, 6.0000001, 7.0000001, 8.0000001],
            c.assetID: [-1, -2, -3, -4, -5, -6, -7, -8],
        ]
        let service = SourceSimilarityIndexService(
            database: env.database,
            queue: JobTestSupport.makeQueue(database: env.database),
            featureLoader: DictionarySlimmingFeatureLoader(vectors: vectors),
            clock: FixedJobClock(nowMs: JobTestSupport.baseTimeMs)
        )
        _ = try service.enqueueBuild(sourceID: env.sourceID)
        try service.runPending()
        XCTAssertEqual(try service.status(sourceID: env.sourceID)?.state, .ready)

        let plan = try service.candidateAssetIDs(
            seedAssetIDs: [a.assetID],
            universeAssetIDs: [a.assetID, b.assetID, c.assetID]
        )
        guard case let .restricted(candidates) = plan else {
            XCTFail("expected a restricted candidate plan, got \(plan)")
            return
        }
        let candidateSet = Set(candidates)
        XCTAssertTrue(candidateSet.contains(a.assetID))
        XCTAssertTrue(candidateSet.contains(b.assetID), "near-identical vector must stay in the neighborhood")
        XCTAssertFalse(candidateSet.contains(c.assetID), "antipodal vector must fall outside the neighborhood")
    }

    func testCandidateAssetIDsFallsBackToFullUniverseWhenIndexMissing() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let a = try env.seedAsset(
            relativePath: "missing-a.jpg",
            contents: try XCTUnwrap(SimilarityTestSupport.patternedImageData(seed: 8, uti: .jpeg))
        )
        let b = try env.seedAsset(
            relativePath: "missing-b.jpg",
            contents: try XCTUnwrap(SimilarityTestSupport.patternedImageData(seed: 9, uti: .jpeg))
        )
        let service = SourceSimilarityIndexService(
            database: env.database,
            queue: JobTestSupport.makeQueue(database: env.database),
            featureLoader: DictionarySlimmingFeatureLoader(vectors: [:]),
            clock: FixedJobClock(nowMs: JobTestSupport.baseTimeMs)
        )

        let plan = try service.candidateAssetIDs(
            seedAssetIDs: [a.assetID],
            universeAssetIDs: [a.assetID, b.assetID]
        )
        XCTAssertEqual(plan, .fullUniverse)
    }

    func testScanSeedsUsesSourceIndexRestrictedPathAndStillFindsNeighbor() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let a = try env.seedAsset(
            relativePath: "scan-a.jpg",
            contents: try XCTUnwrap(SimilarityTestSupport.patternedImageData(seed: 21, uti: .jpeg))
        )
        let b = try env.seedAsset(
            relativePath: "scan-b.jpg",
            contents: try XCTUnwrap(SimilarityTestSupport.patternedImageData(seed: 240, uti: .jpeg))
        )

        let featureVectors: [UUID: [Float]] = [
            a.assetID: [1, 2, 3, 4, 5, 6, 7, 8],
            b.assetID: [1.0000001, 2.0000001, 3.0000001, 4.0000001, 5.0000001, 6.0000001, 7.0000001, 8.0000001],
        ]
        let embeddingVectors: [UUID: [Float]] = [
            a.assetID: [1, 1, 1, 1, 1, 1, 1, 1],
            b.assetID: [1, 1, 1, 1, 1, 1, 1, 1],
        ]
        let featureLoader = DictionarySlimmingFeatureLoader(vectors: featureVectors)
        let embeddingLoader = DictionarySlimmingEmbeddingLoader(
            vectors: embeddingVectors,
            modelIdentity: .featurePrintOnly
        )
        let sourceIndex = SourceSimilarityIndexService(
            database: env.database,
            queue: JobTestSupport.makeQueue(database: env.database),
            featureLoader: featureLoader,
            clock: FixedJobClock(nowMs: JobTestSupport.baseTimeMs)
        )
        _ = try sourceIndex.enqueueBuild(sourceID: env.sourceID)
        try sourceIndex.runPending()
        XCTAssertEqual(try sourceIndex.status(sourceID: env.sourceID)?.state, .ready)

        let completion = env.makeCompletionService()
        let scanner = LibrarySlimmingScanService(
            database: env.database,
            identicalScan: IdenticalDuplicateClusterService(database: env.database),
            fingerprintCompletion: completion,
            featureLoader: featureLoader,
            embeddingLoader: embeddingLoader,
            sourceIndex: sourceIndex
        )

        let result = try scanner.scanSeeds(
            seedAssetIDs: [a.assetID],
            universeAssetIDs: [a.assetID, b.assetID]
        )
        XCTAssertTrue(result.pendingAnalysisAssetIDs.isEmpty)
        let sceneClusters = result.clusters.filter { $0.kind == .nearDuplicateScene }
        XCTAssertEqual(sceneClusters.count, 1)
        XCTAssertEqual(Set(sceneClusters.first?.memberAssetIDs ?? []), Set([a.assetID, b.assetID]))
    }
}
