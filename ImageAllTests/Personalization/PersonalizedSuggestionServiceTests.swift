import CryptoKit
import GRDB
import XCTest
@testable import ImageAll

final class PersonalizedSuggestionServiceTests: XCTestCase {
    func testBuildsVersionedModelAndKeepsManualDecisionAuthoritative() async throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()
        let accepted = [fixture.ids.assetNewest, fixture.ids.assetMiddle]
        let rejected = [fixture.ids.assetDuplicateTimeA, fixture.ids.assetDuplicateTimeB]
        let positiveCandidate = fixture.ids.assetNocaseLower
        let negativeCandidate = fixture.ids.assetNocaseUpper
        _ = try fixture.tags.batchReject(
            tagID: fixture.ids.tagFamily,
            assetIDs: rejected,
            timestampMs: DatabaseTestSupport.timestampMs + 1
        )
        try await fixture.database.pool.write { db in
            try db.execute(
                sql: "UPDATE source SET state = 'active' WHERE id = ?",
                arguments: [fixture.ids.sourceA.uuidString.lowercased()]
            )
        }

        let loader = StubFeatureVectorLoader(
            database: fixture.database,
            vectors: [
                accepted[0]: [0, 0],
                accepted[1]: [0, 1],
                rejected[0]: [10, 10],
                rejected[1]: [10, 9],
                positiveCandidate: [0, 0.5],
                negativeCandidate: [10, 9.5],
            ]
        )
        let service = PersonalizedSuggestionService(
            database: fixture.database,
            featureLoader: loader,
            clock: FixedJobClock(nowMs: DatabaseTestSupport.timestampMs + 2)
        )

        let result = try await service.generateSuggestions(
            tagID: fixture.ids.tagFamily,
            candidateAssetIDs: [positiveCandidate, negativeCandidate]
        )

        XCTAssertEqual(result.modelRevision, 1)
        XCTAssertEqual(result.positiveSampleCount, 2)
        XCTAssertEqual(result.negativeSampleCount, 2)
        XCTAssertEqual(result.evaluatedCandidateCount, 2)
        XCTAssertEqual(result.predictedCandidateCount, 1)
        let catalog = GRDBPersonalizationRepository(database: fixture.database)
        XCTAssertEqual(
            try catalog.pendingPredictions(tagID: fixture.ids.tagFamily, limit: 10).map(\.assetID),
            [positiveCandidate]
        )

        _ = try fixture.tags.batchReject(
            tagID: fixture.ids.tagFamily,
            assetIDs: [positiveCandidate],
            timestampMs: DatabaseTestSupport.timestampMs + 3
        )
        XCTAssertEqual(try catalog.pendingPredictions(tagID: fixture.ids.tagFamily, limit: 10), [])

        let revised = try await service.generateSuggestions(
            tagID: fixture.ids.tagFamily,
            candidateAssetIDs: [negativeCandidate]
        )
        XCTAssertEqual(revised.modelRevision, 2)
        XCTAssertEqual(revised.negativeSampleCount, 3)
        XCTAssertEqual(try catalog.pendingPredictions(tagID: fixture.ids.tagFamily, limit: 10), [])
        let modelFacts = try await fixture.database.pool.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT current_revision FROM tag_model WHERE tag_id = ?", arguments: [fixture.ids.tagFamily.uuidString.lowercased()]),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tag_model_revision WHERE tag_id = ?", arguments: [fixture.ids.tagFamily.uuidString.lowercased()])
            )
        }
        XCTAssertEqual(modelFacts.0, 2)
        XCTAssertEqual(modelFacts.1, 2)
    }
}

private actor StubFeatureVectorLoader: FeatureVectorLoading {
    let database: CatalogDatabase
    let vectors: [UUID: [Float]]

    init(database: CatalogDatabase, vectors: [UUID: [Float]]) {
        self.database = database
        self.vectors = vectors
    }

    func loadOrGenerate(assetID: UUID) async throws -> FeatureVectorPayload {
        guard let values = vectors[assetID] else {
            throw FeaturePrintError.assetNotFound
        }
        let contentRevision = try await database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT content_revision FROM asset WHERE id = ?",
                arguments: [assetID.uuidString.lowercased()]
            )
        }
        guard let contentRevision else {
            throw FeaturePrintError.assetNotFound
        }
        let data = values.withUnsafeBufferPointer { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Float>.size)
        }
        let digest = Data(SHA256.hash(data: data))
        let identity = FeatureIdentity(assetID: assetID, contentRevision: contentRevision)
        let canonical = assetID.uuidString.lowercased()
        let shard = String(canonical.replacingOccurrences(of: "-", with: "").prefix(2))
        try GRDBPersonalizationRepository(database: database).registerFeature(
            FeatureRegistration(
                identity: identity,
                elementCount: values.count,
                byteCount: data.count,
                vectorSHA256: digest,
                cacheKey: "objects/\(shard)/\(canonical)-stub.fprint",
                createdAtMs: DatabaseTestSupport.timestampMs
            )
        )
        return FeatureVectorPayload(
            identity: identity,
            elementCount: values.count,
            vectorData: data,
            vectorSHA256: digest,
            origin: .generated
        )
    }
}
