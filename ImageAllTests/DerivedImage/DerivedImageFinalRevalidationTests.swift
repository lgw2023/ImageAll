import GRDB
import XCTest
@testable import ImageAll

final class DerivedImageFinalRevalidationTests: XCTestCase {
    func testFinalRevalidationContentRevisionIncreaseReturnsSourceChanged() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "final-rev-content")
        defer { env.cleanup() }
        let fileURL = try env.seedAvailableAsset(contentRevision: 1)
        let sourceSnapshot = try env.sourceFileSnapshot(for: fileURL)
        let factsBefore = try await env.generationCatalogFacts()
        let jobCountBefore = try await env.jobRecordCount()
        let tagCountBefore = try await env.tagRecordCount()

        let checkpoint = DerivedImageTestSupport.FinalPublishCheckpoint()
        let (service, bookmarkPort) = env.makeService(
            finalPublishCheckpoint: checkpoint,
            volumeReader: DerivedImageTestSupport.generousVolume
        )

        let loadTask = Task {
            try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
        }
        defer { checkpoint.releaseFinalPublish() }

        let snapshot = try checkpoint.waitUntilFinalObjectPublished(timeout: 10)
        DerivedImageTestSupport.assertCheckpointReachedWithPublishedObject(env: env, snapshot: snapshot)

        try await env.database.pool.write { db in
            try db.execute(
                sql: "UPDATE asset SET content_revision = ? WHERE id = ?",
                arguments: [factsBefore.contentRevision + 1, env.assetID.uuidString.lowercased()]
            )
        }

        checkpoint.releaseFinalPublish()
        try await DerivedImageTestSupport.awaitDerivedSourceChanged(from: loadTask)

        let expectedFacts = DerivedImageTestSupport.GenerationCatalogFacts(
            assetID: factsBefore.assetID,
            sourceID: factsBefore.sourceID,
            sourceKind: factsBefore.sourceKind,
            locatorKind: factsBefore.locatorKind,
            locatorState: factsBefore.locatorState,
            mediaType: factsBefore.mediaType,
            contentRevision: factsBefore.contentRevision + 1,
            availability: factsBefore.availability,
            relativePath: factsBefore.relativePath,
            fileName: factsBefore.fileName,
            sourceState: factsBefore.sourceState,
            fingerprintSizeBytes: factsBefore.fingerprintSizeBytes,
            fingerprintModifiedAtNs: factsBefore.fingerprintModifiedAtNs,
            fingerprintResourceID: factsBefore.fingerprintResourceID
        )
        try await DerivedImageTestSupport.assertFinalRevalidationRejected(
            env: env,
            bookmarkPort: bookmarkPort,
            snapshot: snapshot,
            expectedFacts: expectedFacts,
            sourceFiles: [sourceSnapshot],
            jobCountBefore: jobCountBefore,
            tagCountBefore: tagCountBefore
        )
    }

    func testFinalRevalidationLocatorStateChangeReturnsSourceChanged() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "final-rev-locator-state")
        defer { env.cleanup() }
        let fileURL = try env.seedAvailableAsset()
        let sourceSnapshot = try env.sourceFileSnapshot(for: fileURL)
        let factsBefore = try await env.generationCatalogFacts()
        let jobCountBefore = try await env.jobRecordCount()
        let tagCountBefore = try await env.tagRecordCount()

        let checkpoint = DerivedImageTestSupport.FinalPublishCheckpoint()
        let (service, bookmarkPort) = env.makeService(
            finalPublishCheckpoint: checkpoint,
            volumeReader: DerivedImageTestSupport.generousVolume
        )

        let loadTask = Task {
            try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
        }
        defer { checkpoint.releaseFinalPublish() }

        let snapshot = try checkpoint.waitUntilFinalObjectPublished(timeout: 10)
        DerivedImageTestSupport.assertCheckpointReachedWithPublishedObject(env: env, snapshot: snapshot)

        try await env.database.pool.write { db in
            try db.execute(
                sql: "UPDATE asset SET locator_state = ? WHERE id = ?",
                arguments: ["historical", env.assetID.uuidString.lowercased()]
            )
        }

        checkpoint.releaseFinalPublish()
        try await DerivedImageTestSupport.awaitDerivedSourceChanged(from: loadTask)

        let expectedFacts = DerivedImageTestSupport.GenerationCatalogFacts(
            assetID: factsBefore.assetID,
            sourceID: factsBefore.sourceID,
            sourceKind: factsBefore.sourceKind,
            locatorKind: factsBefore.locatorKind,
            locatorState: "historical",
            mediaType: factsBefore.mediaType,
            contentRevision: factsBefore.contentRevision,
            availability: factsBefore.availability,
            relativePath: factsBefore.relativePath,
            fileName: factsBefore.fileName,
            sourceState: factsBefore.sourceState,
            fingerprintSizeBytes: factsBefore.fingerprintSizeBytes,
            fingerprintModifiedAtNs: factsBefore.fingerprintModifiedAtNs,
            fingerprintResourceID: factsBefore.fingerprintResourceID
        )
        try await DerivedImageTestSupport.assertFinalRevalidationRejected(
            env: env,
            bookmarkPort: bookmarkPort,
            snapshot: snapshot,
            expectedFacts: expectedFacts,
            sourceFiles: [sourceSnapshot],
            jobCountBefore: jobCountBefore,
            tagCountBefore: tagCountBefore
        )
    }

    func testFinalRevalidationRelativeLocatorChangeReturnsSourceChanged() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "final-rev-relative-locator")
        defer { env.cleanup() }
        let originalURL = try env.seedAvailableAsset(relativePath: "photos/sample.jpg", fileName: "sample.jpg")
        let alternateBytes = try XCTUnwrap(
            FolderReconcileTestSupport.minimalEncodedImageData(uti: "public.jpeg", width: 8, height: 8)
        )
        let alternateURL = try env.writeSource(relativePath: "photos/alternate.jpg", contents: alternateBytes)
        let originalSnapshot = try env.sourceFileSnapshot(for: originalURL)
        let alternateSnapshot = try env.sourceFileSnapshot(for: alternateURL)
        let factsBefore = try await env.generationCatalogFacts()
        let jobCountBefore = try await env.jobRecordCount()
        let tagCountBefore = try await env.tagRecordCount()

        let checkpoint = DerivedImageTestSupport.FinalPublishCheckpoint()
        let (service, bookmarkPort) = env.makeService(
            finalPublishCheckpoint: checkpoint,
            volumeReader: DerivedImageTestSupport.generousVolume
        )

        let loadTask = Task {
            try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
        }
        defer { checkpoint.releaseFinalPublish() }

        let snapshot = try checkpoint.waitUntilFinalObjectPublished(timeout: 10)
        DerivedImageTestSupport.assertCheckpointReachedWithPublishedObject(env: env, snapshot: snapshot)

        let newRelativePath = "photos/alternate.jpg"
        let newFileName = "alternate.jpg"
        try await env.database.pool.write { db in
            try db.execute(
                sql: """
                UPDATE asset
                SET relative_path = ?, file_name = ?
                WHERE id = ?
                """,
                arguments: [newRelativePath, newFileName, env.assetID.uuidString.lowercased()]
            )
        }

        checkpoint.releaseFinalPublish()
        try await DerivedImageTestSupport.awaitDerivedSourceChanged(from: loadTask)

        let expectedFacts = DerivedImageTestSupport.GenerationCatalogFacts(
            assetID: factsBefore.assetID,
            sourceID: factsBefore.sourceID,
            sourceKind: factsBefore.sourceKind,
            locatorKind: factsBefore.locatorKind,
            locatorState: factsBefore.locatorState,
            mediaType: factsBefore.mediaType,
            contentRevision: factsBefore.contentRevision,
            availability: factsBefore.availability,
            relativePath: newRelativePath,
            fileName: newFileName,
            sourceState: factsBefore.sourceState,
            fingerprintSizeBytes: factsBefore.fingerprintSizeBytes,
            fingerprintModifiedAtNs: factsBefore.fingerprintModifiedAtNs,
            fingerprintResourceID: factsBefore.fingerprintResourceID
        )
        try await DerivedImageTestSupport.assertFinalRevalidationRejected(
            env: env,
            bookmarkPort: bookmarkPort,
            snapshot: snapshot,
            expectedFacts: expectedFacts,
            sourceFiles: [originalSnapshot, alternateSnapshot],
            jobCountBefore: jobCountBefore,
            tagCountBefore: tagCountBefore
        )
    }

    func testFinalRevalidationAvailabilityChangeReturnsSourceChanged() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "final-rev-availability")
        defer { env.cleanup() }
        let fileURL = try env.seedAvailableAsset()
        let sourceSnapshot = try env.sourceFileSnapshot(for: fileURL)
        let factsBefore = try await env.generationCatalogFacts()
        let jobCountBefore = try await env.jobRecordCount()
        let tagCountBefore = try await env.tagRecordCount()

        let checkpoint = DerivedImageTestSupport.FinalPublishCheckpoint()
        let (service, bookmarkPort) = env.makeService(
            finalPublishCheckpoint: checkpoint,
            volumeReader: DerivedImageTestSupport.generousVolume
        )

        let loadTask = Task {
            try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
        }
        defer { checkpoint.releaseFinalPublish() }

        let snapshot = try checkpoint.waitUntilFinalObjectPublished(timeout: 10)
        DerivedImageTestSupport.assertCheckpointReachedWithPublishedObject(env: env, snapshot: snapshot)

        try await env.database.pool.write { db in
            try db.execute(
                sql: "UPDATE asset SET availability = ? WHERE id = ?",
                arguments: ["missing", env.assetID.uuidString.lowercased()]
            )
        }

        checkpoint.releaseFinalPublish()
        try await DerivedImageTestSupport.awaitDerivedSourceChanged(from: loadTask)

        let expectedFacts = DerivedImageTestSupport.GenerationCatalogFacts(
            assetID: factsBefore.assetID,
            sourceID: factsBefore.sourceID,
            sourceKind: factsBefore.sourceKind,
            locatorKind: factsBefore.locatorKind,
            locatorState: factsBefore.locatorState,
            mediaType: factsBefore.mediaType,
            contentRevision: factsBefore.contentRevision,
            availability: "missing",
            relativePath: factsBefore.relativePath,
            fileName: factsBefore.fileName,
            sourceState: factsBefore.sourceState,
            fingerprintSizeBytes: factsBefore.fingerprintSizeBytes,
            fingerprintModifiedAtNs: factsBefore.fingerprintModifiedAtNs,
            fingerprintResourceID: factsBefore.fingerprintResourceID
        )
        try await DerivedImageTestSupport.assertFinalRevalidationRejected(
            env: env,
            bookmarkPort: bookmarkPort,
            snapshot: snapshot,
            expectedFacts: expectedFacts,
            sourceFiles: [sourceSnapshot],
            jobCountBefore: jobCountBefore,
            tagCountBefore: tagCountBefore
        )
    }

    func testFinalRevalidationSourceStateChangeReturnsSourceChanged() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "final-rev-source-state")
        defer { env.cleanup() }
        let fileURL = try env.seedAvailableAsset()
        let sourceSnapshot = try env.sourceFileSnapshot(for: fileURL)
        let factsBefore = try await env.generationCatalogFacts()
        let jobCountBefore = try await env.jobRecordCount()
        let tagCountBefore = try await env.tagRecordCount()

        let checkpoint = DerivedImageTestSupport.FinalPublishCheckpoint()
        let (service, bookmarkPort) = env.makeService(
            finalPublishCheckpoint: checkpoint,
            volumeReader: DerivedImageTestSupport.generousVolume
        )

        let loadTask = Task {
            try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
        }
        defer { checkpoint.releaseFinalPublish() }

        let snapshot = try checkpoint.waitUntilFinalObjectPublished(timeout: 10)
        DerivedImageTestSupport.assertCheckpointReachedWithPublishedObject(env: env, snapshot: snapshot)

        try await env.database.pool.write { db in
            try db.execute(
                sql: "UPDATE source SET state = ? WHERE id = ?",
                arguments: ["disabled", factsBefore.sourceID.uuidString.lowercased()]
            )
        }

        checkpoint.releaseFinalPublish()
        try await DerivedImageTestSupport.awaitDerivedSourceChanged(from: loadTask)

        let expectedFacts = DerivedImageTestSupport.GenerationCatalogFacts(
            assetID: factsBefore.assetID,
            sourceID: factsBefore.sourceID,
            sourceKind: factsBefore.sourceKind,
            locatorKind: factsBefore.locatorKind,
            locatorState: factsBefore.locatorState,
            mediaType: factsBefore.mediaType,
            contentRevision: factsBefore.contentRevision,
            availability: factsBefore.availability,
            relativePath: factsBefore.relativePath,
            fileName: factsBefore.fileName,
            sourceState: "disabled",
            fingerprintSizeBytes: factsBefore.fingerprintSizeBytes,
            fingerprintModifiedAtNs: factsBefore.fingerprintModifiedAtNs,
            fingerprintResourceID: factsBefore.fingerprintResourceID
        )
        try await DerivedImageTestSupport.assertFinalRevalidationRejected(
            env: env,
            bookmarkPort: bookmarkPort,
            snapshot: snapshot,
            expectedFacts: expectedFacts,
            sourceFiles: [sourceSnapshot],
            jobCountBefore: jobCountBefore,
            tagCountBefore: tagCountBefore
        )
    }

    func testFinalRevalidationFingerprintSizeChangeReturnsSourceChanged() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "final-rev-fp-size")
        defer { env.cleanup() }
        let fileURL = try env.seedAvailableAsset()
        let sourceSnapshot = try env.sourceFileSnapshot(for: fileURL)
        let factsBefore = try await env.generationCatalogFacts()
        let mutatedSizeBytes = try XCTUnwrap(factsBefore.fingerprintSizeBytes) + 512
        let jobCountBefore = try await env.jobRecordCount()
        let tagCountBefore = try await env.tagRecordCount()

        let checkpoint = DerivedImageTestSupport.FinalPublishCheckpoint()
        let (service, bookmarkPort) = env.makeService(
            finalPublishCheckpoint: checkpoint,
            volumeReader: DerivedImageTestSupport.generousVolume
        )

        let loadTask = Task {
            try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
        }
        defer { checkpoint.releaseFinalPublish() }

        let snapshot = try checkpoint.waitUntilFinalObjectPublished(timeout: 10)
        DerivedImageTestSupport.assertCheckpointReachedWithPublishedObject(env: env, snapshot: snapshot)

        try await env.database.pool.write { db in
            try db.execute(
                sql: "UPDATE file_fingerprint SET size_bytes = ? WHERE asset_id = ?",
                arguments: [mutatedSizeBytes, env.assetID.uuidString.lowercased()]
            )
        }

        checkpoint.releaseFinalPublish()
        try await DerivedImageTestSupport.awaitDerivedSourceChanged(from: loadTask)

        let expectedFacts = DerivedImageTestSupport.GenerationCatalogFacts(
            assetID: factsBefore.assetID,
            sourceID: factsBefore.sourceID,
            sourceKind: factsBefore.sourceKind,
            locatorKind: factsBefore.locatorKind,
            locatorState: factsBefore.locatorState,
            mediaType: factsBefore.mediaType,
            contentRevision: factsBefore.contentRevision,
            availability: factsBefore.availability,
            relativePath: factsBefore.relativePath,
            fileName: factsBefore.fileName,
            sourceState: factsBefore.sourceState,
            fingerprintSizeBytes: mutatedSizeBytes,
            fingerprintModifiedAtNs: factsBefore.fingerprintModifiedAtNs,
            fingerprintResourceID: factsBefore.fingerprintResourceID
        )
        try await DerivedImageTestSupport.assertFinalRevalidationRejected(
            env: env,
            bookmarkPort: bookmarkPort,
            snapshot: snapshot,
            expectedFacts: expectedFacts,
            sourceFiles: [sourceSnapshot],
            jobCountBefore: jobCountBefore,
            tagCountBefore: tagCountBefore
        )
    }

    func testFinalRevalidationFingerprintMtimeChangeReturnsSourceChanged() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "final-rev-fp-mtime")
        defer { env.cleanup() }
        let fileURL = try env.seedAvailableAsset()
        let sourceSnapshot = try env.sourceFileSnapshot(for: fileURL)
        let factsBefore = try await env.generationCatalogFacts()
        let mutatedModifiedAtNs = try XCTUnwrap(factsBefore.fingerprintModifiedAtNs) + 9_876_543_210
        let jobCountBefore = try await env.jobRecordCount()
        let tagCountBefore = try await env.tagRecordCount()

        let checkpoint = DerivedImageTestSupport.FinalPublishCheckpoint()
        let (service, bookmarkPort) = env.makeService(
            finalPublishCheckpoint: checkpoint,
            volumeReader: DerivedImageTestSupport.generousVolume
        )

        let loadTask = Task {
            try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
        }
        defer { checkpoint.releaseFinalPublish() }

        let snapshot = try checkpoint.waitUntilFinalObjectPublished(timeout: 10)
        DerivedImageTestSupport.assertCheckpointReachedWithPublishedObject(env: env, snapshot: snapshot)

        try await env.database.pool.write { db in
            try db.execute(
                sql: "UPDATE file_fingerprint SET modified_at_ns = ? WHERE asset_id = ?",
                arguments: [mutatedModifiedAtNs, env.assetID.uuidString.lowercased()]
            )
        }

        checkpoint.releaseFinalPublish()
        try await DerivedImageTestSupport.awaitDerivedSourceChanged(from: loadTask)

        let expectedFacts = DerivedImageTestSupport.GenerationCatalogFacts(
            assetID: factsBefore.assetID,
            sourceID: factsBefore.sourceID,
            sourceKind: factsBefore.sourceKind,
            locatorKind: factsBefore.locatorKind,
            locatorState: factsBefore.locatorState,
            mediaType: factsBefore.mediaType,
            contentRevision: factsBefore.contentRevision,
            availability: factsBefore.availability,
            relativePath: factsBefore.relativePath,
            fileName: factsBefore.fileName,
            sourceState: factsBefore.sourceState,
            fingerprintSizeBytes: factsBefore.fingerprintSizeBytes,
            fingerprintModifiedAtNs: mutatedModifiedAtNs,
            fingerprintResourceID: factsBefore.fingerprintResourceID
        )
        try await DerivedImageTestSupport.assertFinalRevalidationRejected(
            env: env,
            bookmarkPort: bookmarkPort,
            snapshot: snapshot,
            expectedFacts: expectedFacts,
            sourceFiles: [sourceSnapshot],
            jobCountBefore: jobCountBefore,
            tagCountBefore: tagCountBefore
        )
    }

    func testFinalRevalidationFingerprintResourceIDChangeReturnsSourceChanged() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "final-rev-fp-resource-id")
        defer { env.cleanup() }
        let fileURL = try env.seedAvailableAsset()
        let sourceSnapshot = try env.sourceFileSnapshot(for: fileURL)
        let factsBefore = try await env.generationCatalogFacts()
        let mutatedResourceID = Data([0xDE, 0xAD, 0xBE, 0xEF])
        XCTAssertNotEqual(factsBefore.fingerprintResourceID, mutatedResourceID)
        let jobCountBefore = try await env.jobRecordCount()
        let tagCountBefore = try await env.tagRecordCount()

        let checkpoint = DerivedImageTestSupport.FinalPublishCheckpoint()
        let (service, bookmarkPort) = env.makeService(
            finalPublishCheckpoint: checkpoint,
            volumeReader: DerivedImageTestSupport.generousVolume
        )

        let loadTask = Task {
            try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
        }
        defer { checkpoint.releaseFinalPublish() }

        let snapshot = try checkpoint.waitUntilFinalObjectPublished(timeout: 10)
        DerivedImageTestSupport.assertCheckpointReachedWithPublishedObject(env: env, snapshot: snapshot)

        try await env.database.pool.write { db in
            try db.execute(
                sql: "UPDATE file_fingerprint SET resource_id = ? WHERE asset_id = ?",
                arguments: [mutatedResourceID, env.assetID.uuidString.lowercased()]
            )
        }

        checkpoint.releaseFinalPublish()
        try await DerivedImageTestSupport.awaitDerivedSourceChanged(from: loadTask)

        let expectedFacts = DerivedImageTestSupport.GenerationCatalogFacts(
            assetID: factsBefore.assetID,
            sourceID: factsBefore.sourceID,
            sourceKind: factsBefore.sourceKind,
            locatorKind: factsBefore.locatorKind,
            locatorState: factsBefore.locatorState,
            mediaType: factsBefore.mediaType,
            contentRevision: factsBefore.contentRevision,
            availability: factsBefore.availability,
            relativePath: factsBefore.relativePath,
            fileName: factsBefore.fileName,
            sourceState: factsBefore.sourceState,
            fingerprintSizeBytes: factsBefore.fingerprintSizeBytes,
            fingerprintModifiedAtNs: factsBefore.fingerprintModifiedAtNs,
            fingerprintResourceID: mutatedResourceID
        )
        try await DerivedImageTestSupport.assertFinalRevalidationRejected(
            env: env,
            bookmarkPort: bookmarkPort,
            snapshot: snapshot,
            expectedFacts: expectedFacts,
            sourceFiles: [sourceSnapshot],
            jobCountBefore: jobCountBefore,
            tagCountBefore: tagCountBefore
        )
    }
}
