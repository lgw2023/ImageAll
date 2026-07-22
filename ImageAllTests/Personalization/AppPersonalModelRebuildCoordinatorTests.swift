import CoreGraphics
import XCTest
@testable import ImageAll

final class AppPersonalModelRebuildCoordinatorTests: XCTestCase {
    func testAppRuntimeWithoutReadyModelCreatesNoCacheOrHeadState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cachesDirectory = root.appendingPathComponent("Caches", isDirectory: true)
        let applicationSupportDirectory = root.appendingPathComponent(
            "ApplicationSupport",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let catalogScopeID = UUID().uuidString.lowercased()
        let activation = AppModelActivationCoordinator(
            preferenceStore: InMemoryModelEnablementPreferenceStore(),
            serviceFactory: {
                AppCoreMLEmbeddingService(
                    isEnabled: true,
                    artifactDirectory: Self.projectArtifactDirectory()
                )
            }
        )
        let runtime = AppPersonalModelRebuildRuntime(
            expectedCatalogScopeID: catalogScopeID,
            activationCoordinator: activation,
            cachesDirectory: cachesDirectory,
            applicationSupportDirectory: applicationSupportDirectory
        )

        do {
            _ = try await runtime.rebuild(
                snapshotSource: FixedSnapshotSource(
                    snapshot: makeTrainingSnapshot(catalogScopeID: catalogScopeID)
                )
            )
            XCTFail("expected disabled model to reject App personal rebuild")
        } catch {
            XCTAssertEqual(error as? AppPersonalModelRebuildError, .modelUnavailable)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: cachesDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: applicationSupportDirectory.path))
    }

    func testActivatedAppRuntimePublishesFromProductionCacheOnlySources() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cachesDirectory = root.appendingPathComponent("Caches", isDirectory: true)
        let applicationSupportDirectory = root.appendingPathComponent(
            "ApplicationSupport",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let catalogID = UUID()
        let snapshot = makeTrainingSnapshot(
            catalogScopeID: catalogID.uuidString.lowercased()
        )
        let preference = InMemoryModelEnablementPreferenceStore()
        let activation = AppModelActivationCoordinator(
            preferenceStore: preference,
            serviceFactory: {
                AppCoreMLEmbeddingService(
                    isEnabled: true,
                    artifactDirectory: Self.projectArtifactDirectory()
                )
            }
        )
        guard case let .ready(encoderIdentity) = await activation.setEnabled(true),
              let service = await activation.readyService()
        else {
            return XCTFail("expected fixed Core ML artifact to be ready")
        }
        let cache = AppCoreMLEmbeddingCache(
            cachesDirectory: cachesDirectory,
            service: service
        )
        for decision in snapshot.decisions {
            _ = try cache.embedding(
                for: generatedImage(decision.assetID),
                key: AppCoreMLEmbeddingCacheKey(
                    catalogScopeID: catalogID,
                    assetID: decision.assetID,
                    contentRevision: Int64(decision.contentRevision)
                )
            )
        }
        let runtime = AppPersonalModelRebuildRuntime(
            expectedCatalogScopeID: snapshot.catalogScopeID,
            activationCoordinator: activation,
            cachesDirectory: cachesDirectory,
            applicationSupportDirectory: applicationSupportDirectory
        )

        let identity = try await runtime.rebuild(
            snapshotSource: FixedSnapshotSource(snapshot: snapshot)
        )

        XCTAssertEqual(identity.catalogScopeID, snapshot.catalogScopeID)
        XCTAssertEqual(identity.encoderIdentity, encoderIdentity)
        XCTAssertEqual(identity.personalTagIDs, snapshot.personalTagIDs)
        let restarted = AppPersonalLinearHeadStore(
            applicationSupportDirectory: applicationSupportDirectory,
            expectedCatalogScopeID: snapshot.catalogScopeID,
            expectedEncoderIdentity: encoderIdentity
        )
        let restartedCapability = await restarted.start()
        XCTAssertEqual(restartedCapability, .ready(identity))
    }

    func testProductionSnapshotSourceReadsManualFactsThroughTheReviewBoundary() async throws {
        let expected = makeTrainingSnapshot()
        let source = AppPersonalTrainingSnapshotPortSource {
            expected
        }

        let actual = try await source.currentSnapshot()

        XCTAssertEqual(actual, expected)
    }

    func testExplicitRebuildPublishesAHeadFromReadOnlyFactsAndCachedEmbeddings() async throws {
        let applicationSupportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: applicationSupportDirectory) }
        let encoderIdentity = makeEncoderIdentity()
        let snapshot = makeTrainingSnapshot()
        let store = AppPersonalLinearHeadStore(
            applicationSupportDirectory: applicationSupportDirectory,
            expectedCatalogScopeID: snapshot.catalogScopeID,
            expectedEncoderIdentity: encoderIdentity
        )
        let coordinator = AppPersonalModelRebuildCoordinator(
            expectedCatalogScopeID: snapshot.catalogScopeID,
            encoderIdentity: encoderIdentity,
            snapshotSource: FixedSnapshotSource(snapshot: snapshot),
            embeddingSource: FixedCachedEmbeddingSource(
                encoder: PersonalTrainingEncoderIdentity(encoderIdentity),
                valuesByAssetID: embeddingValues(for: snapshot)
            ),
            store: store
        )

        let identity = try await coordinator.rebuild()

        XCTAssertEqual(identity.catalogScopeID, snapshot.catalogScopeID)
        XCTAssertEqual(identity.encoderIdentity, encoderIdentity)
        XCTAssertEqual(identity.personalTagIDs, snapshot.personalTagIDs)
        let activeCapability = await store.capability()
        XCTAssertEqual(activeCapability, .ready(identity))
        let restarted = AppPersonalLinearHeadStore(
            applicationSupportDirectory: applicationSupportDirectory,
            expectedCatalogScopeID: snapshot.catalogScopeID,
            expectedEncoderIdentity: encoderIdentity
        )
        let restartedCapability = await restarted.start()
        XCTAssertEqual(restartedCapability, .ready(identity))
    }

    func testChangedFactsBeforePublicationKeepThePreviousActiveHead() async throws {
        let applicationSupportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: applicationSupportDirectory) }
        let encoderIdentity = makeEncoderIdentity()
        let originalSnapshot = makeTrainingSnapshot(contentRevision: 1)
        let store = AppPersonalLinearHeadStore(
            applicationSupportDirectory: applicationSupportDirectory,
            expectedCatalogScopeID: originalSnapshot.catalogScopeID,
            expectedEncoderIdentity: encoderIdentity
        )
        let embeddings = FixedCachedEmbeddingSource(
            encoder: PersonalTrainingEncoderIdentity(encoderIdentity),
            valuesByAssetID: embeddingValues(for: originalSnapshot)
        )
        let originalIdentity = try await AppPersonalModelRebuildCoordinator(
            expectedCatalogScopeID: originalSnapshot.catalogScopeID,
            encoderIdentity: encoderIdentity,
            snapshotSource: FixedSnapshotSource(snapshot: originalSnapshot),
            embeddingSource: embeddings,
            store: store
        ).rebuild()
        let candidateSnapshot = makeTrainingSnapshot(contentRevision: 2)
        let changedSnapshot = makeTrainingSnapshot(contentRevision: 3)
        let coordinator = AppPersonalModelRebuildCoordinator(
            expectedCatalogScopeID: candidateSnapshot.catalogScopeID,
            encoderIdentity: encoderIdentity,
            snapshotSource: SequenceSnapshotSource(
                snapshots: [candidateSnapshot, changedSnapshot]
            ),
            embeddingSource: embeddings,
            store: store
        )

        do {
            _ = try await coordinator.rebuild()
            XCTFail("Expected the changed facts to reject publication")
        } catch {
            XCTAssertEqual(error as? AppPersonalModelRebuildError, .staleSnapshot)
        }

        let capability = await store.capability()
        XCTAssertEqual(capability, .ready(originalIdentity))
    }

    func testCancellationStopsBeforePublishingAHead() async throws {
        let applicationSupportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: applicationSupportDirectory) }
        let encoderIdentity = makeEncoderIdentity()
        let snapshot = makeTrainingSnapshot()
        let store = AppPersonalLinearHeadStore(
            applicationSupportDirectory: applicationSupportDirectory,
            expectedCatalogScopeID: snapshot.catalogScopeID,
            expectedEncoderIdentity: encoderIdentity
        )
        let embeddingSource = BlockingCachedEmbeddingSource(
            embedding: PersonalTrainingEmbedding(
                encoder: PersonalTrainingEncoderIdentity(encoderIdentity),
                values: [1, 0]
            )
        )
        let coordinator = AppPersonalModelRebuildCoordinator(
            expectedCatalogScopeID: snapshot.catalogScopeID,
            encoderIdentity: encoderIdentity,
            snapshotSource: FixedSnapshotSource(snapshot: snapshot),
            embeddingSource: embeddingSource,
            store: store
        )
        let rebuild = Task {
            try await coordinator.rebuild()
        }
        await embeddingSource.waitUntilRequested()

        await coordinator.cancel()
        await embeddingSource.resume()

        do {
            _ = try await rebuild.value
            XCTFail("Expected cancellation before publication")
        } catch {
            XCTAssertEqual(error as? AppPersonalModelRebuildError, .cancelled)
        }
        let capability = await store.capability()
        XCTAssertEqual(capability, .unavailable(.artifactMissing))
    }

    func testSecondExplicitRebuildIsRejectedWhileOneIsRunning() async throws {
        let applicationSupportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: applicationSupportDirectory) }
        let encoderIdentity = makeEncoderIdentity()
        let snapshot = makeTrainingSnapshot()
        let embeddingSource = BlockingCachedEmbeddingSource(
            embedding: PersonalTrainingEmbedding(
                encoder: PersonalTrainingEncoderIdentity(encoderIdentity),
                values: [1, 0]
            )
        )
        let coordinator = AppPersonalModelRebuildCoordinator(
            expectedCatalogScopeID: snapshot.catalogScopeID,
            encoderIdentity: encoderIdentity,
            snapshotSource: FixedSnapshotSource(snapshot: snapshot),
            embeddingSource: embeddingSource,
            store: AppPersonalLinearHeadStore(
                applicationSupportDirectory: applicationSupportDirectory,
                expectedCatalogScopeID: snapshot.catalogScopeID,
                expectedEncoderIdentity: encoderIdentity
            )
        )
        let first = Task {
            try await coordinator.rebuild()
        }
        await embeddingSource.waitUntilRequested()

        do {
            _ = try await coordinator.rebuild()
            XCTFail("Expected a single running rebuild")
        } catch {
            XCTAssertEqual(error as? AppPersonalModelRebuildError, .alreadyRunning)
        }

        await coordinator.cancel()
        await embeddingSource.resume()
        _ = try? await first.value
    }

    func testCacheFailureKeepsThePreviousActiveHead() async throws {
        let applicationSupportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: applicationSupportDirectory) }
        let encoderIdentity = makeEncoderIdentity()
        let snapshot = makeTrainingSnapshot()
        let store = AppPersonalLinearHeadStore(
            applicationSupportDirectory: applicationSupportDirectory,
            expectedCatalogScopeID: snapshot.catalogScopeID,
            expectedEncoderIdentity: encoderIdentity
        )
        let oldIdentity = try await AppPersonalModelRebuildCoordinator(
            expectedCatalogScopeID: snapshot.catalogScopeID,
            encoderIdentity: encoderIdentity,
            snapshotSource: FixedSnapshotSource(snapshot: snapshot),
            embeddingSource: FixedCachedEmbeddingSource(
                encoder: PersonalTrainingEncoderIdentity(encoderIdentity),
                valuesByAssetID: embeddingValues(for: snapshot)
            ),
            store: store
        ).rebuild()
        let coordinator = AppPersonalModelRebuildCoordinator(
            expectedCatalogScopeID: snapshot.catalogScopeID,
            encoderIdentity: encoderIdentity,
            snapshotSource: FixedSnapshotSource(snapshot: snapshot),
            embeddingSource: FailingCachedEmbeddingSource(),
            store: store
        )

        do {
            _ = try await coordinator.rebuild()
            XCTFail("Expected cache-only rebuild failure")
        } catch {
            XCTAssertEqual(error as? AppPersonalModelRebuildError, .embeddingUnavailable)
        }
        let capability = await store.capability()
        XCTAssertEqual(capability, .ready(oldIdentity))
    }

    func testInsufficientFactsKeepThePreviousActiveHead() async throws {
        let applicationSupportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: applicationSupportDirectory) }
        let encoderIdentity = makeEncoderIdentity()
        let completeSnapshot = makeTrainingSnapshot()
        let store = AppPersonalLinearHeadStore(
            applicationSupportDirectory: applicationSupportDirectory,
            expectedCatalogScopeID: completeSnapshot.catalogScopeID,
            expectedEncoderIdentity: encoderIdentity
        )
        let embeddings = FixedCachedEmbeddingSource(
            encoder: PersonalTrainingEncoderIdentity(encoderIdentity),
            valuesByAssetID: embeddingValues(for: completeSnapshot)
        )
        let oldIdentity = try await AppPersonalModelRebuildCoordinator(
            expectedCatalogScopeID: completeSnapshot.catalogScopeID,
            encoderIdentity: encoderIdentity,
            snapshotSource: FixedSnapshotSource(snapshot: completeSnapshot),
            embeddingSource: embeddings,
            store: store
        ).rebuild()
        let insufficientSnapshot = PersonalTrainingSnapshot(
            catalogScopeID: completeSnapshot.catalogScopeID,
            personalTagIDs: completeSnapshot.personalTagIDs,
            decisions: Array(completeSnapshot.decisions.prefix(1))
        )
        let coordinator = AppPersonalModelRebuildCoordinator(
            expectedCatalogScopeID: insufficientSnapshot.catalogScopeID,
            encoderIdentity: encoderIdentity,
            snapshotSource: FixedSnapshotSource(snapshot: insufficientSnapshot),
            embeddingSource: embeddings,
            store: store
        )

        do {
            _ = try await coordinator.rebuild()
            XCTFail("Expected insufficient facts to reject training")
        } catch {
            XCTAssertEqual(error as? AppPersonalModelRebuildError, .invalidSnapshot)
        }
        let capability = await store.capability()
        XCTAssertEqual(capability, .ready(oldIdentity))
    }

    private func makeTrainingSnapshot(
        catalogScopeID: String = "catalog-fixture",
        contentRevision: Int = 1
    ) -> PersonalTrainingSnapshot {
        let tagID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let accepted = [
            UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
        ]
        return PersonalTrainingSnapshot(
            catalogScopeID: catalogScopeID,
            personalTagIDs: [tagID],
            decisions: accepted.map {
                PersonalTrainingDecision(
                    assetID: $0,
                    contentRevision: contentRevision,
                    tagID: tagID,
                    state: .manualAccepted
                )
            }
        )
    }

    private func embeddingValues(
        for snapshot: PersonalTrainingSnapshot
    ) -> [UUID: [Float]] {
        Dictionary(
            uniqueKeysWithValues: snapshot.decisions.enumerated().map { index, decision in
                (
                    decision.assetID,
                    index == 0 ? [1, 0] : [0.8, 0.1]
                )
            }
        )
    }

    private func makeEncoderIdentity() -> AppCoreMLModelIdentity {
        AppCoreMLModelIdentity(
            provider: "dinov2",
            modelID: "facebook/dinov2-small",
            modelRevision: "encoder-revision",
            preprocessingRevision: "preprocessing-revision",
            embeddingSemantics: "dinov2-cls-token",
            postprocessingRevision: "raw-float32-v1",
            elementType: "float32",
            elementCount: 2,
            sourceModelSHA256: String(repeating: "1", count: 64),
            artifactSHA256: String(repeating: "2", count: 64),
            manifestSHA256: String(repeating: "3", count: 64),
            licenseID: "Apache-2.0",
            licenseSHA256: String(repeating: "4", count: 64)
        )
    }

    private static func projectArtifactDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ImageAll/Resources/Models/DINOv2Small")
    }

    private func generatedImage(_ assetID: UUID) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: 64,
            height: 64,
            bitsPerComponent: 8,
            bytesPerRow: 64 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw AppPersonalModelRebuildTestError.imageCreationFailed
        }
        let byte = assetID.uuid.0
        context.setFillColor(
            red: CGFloat(byte) / 255,
            green: 0.5,
            blue: 1 - CGFloat(byte) / 255,
            alpha: 1
        )
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        guard let image = context.makeImage() else {
            throw AppPersonalModelRebuildTestError.imageCreationFailed
        }
        return image
    }
}

private enum AppPersonalModelRebuildTestError: Error {
    case imageCreationFailed
}

private final class InMemoryModelEnablementPreferenceStore:
    ModelEnablementPreferenceStore,
    @unchecked Sendable
{
    var isEnabled = false
}

private struct FixedSnapshotSource: AppPersonalTrainingSnapshotSource {
    let snapshot: PersonalTrainingSnapshot

    func currentSnapshot() async throws -> PersonalTrainingSnapshot {
        snapshot
    }
}

private actor SequenceSnapshotSource: AppPersonalTrainingSnapshotSource {
    private var snapshots: [PersonalTrainingSnapshot]

    init(snapshots: [PersonalTrainingSnapshot]) {
        self.snapshots = snapshots
    }

    func currentSnapshot() async throws -> PersonalTrainingSnapshot {
        snapshots.removeFirst()
    }
}

private struct FixedCachedEmbeddingSource: AppPersonalTrainingEmbeddingSource {
    let encoder: PersonalTrainingEncoderIdentity
    let valuesByAssetID: [UUID: [Float]]

    func cachedEmbedding(
        for key: PersonalTrainingEmbeddingCacheKey
    ) async throws -> PersonalTrainingEmbedding? {
        valuesByAssetID[key.assetID].map {
            PersonalTrainingEmbedding(encoder: encoder, values: $0)
        }
    }
}

private actor BlockingCachedEmbeddingSource: AppPersonalTrainingEmbeddingSource {
    let embedding: PersonalTrainingEmbedding

    private var requested = false
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    init(embedding: PersonalTrainingEmbedding) {
        self.embedding = embedding
    }

    func cachedEmbedding(
        for key: PersonalTrainingEmbeddingCacheKey
    ) async throws -> PersonalTrainingEmbedding? {
        requested = true
        requestWaiters.forEach { $0.resume() }
        requestWaiters.removeAll()
        await withCheckedContinuation { continuation in
            resumeContinuation = continuation
        }
        return embedding
    }

    func waitUntilRequested() async {
        guard !requested else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

private struct FailingCachedEmbeddingSource: AppPersonalTrainingEmbeddingSource {
    func cachedEmbedding(
        for key: PersonalTrainingEmbeddingCacheKey
    ) async throws -> PersonalTrainingEmbedding? {
        throw Failure.unavailable
    }

    private enum Failure: Error {
        case unavailable
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
