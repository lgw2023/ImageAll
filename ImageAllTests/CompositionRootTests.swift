import CoreGraphics
import XCTest
@testable import ImageAll

@MainActor
final class CompositionRootTests: XCTestCase {
    func testBundledStandardOntologyIncludesApprovedIdentityAndConcepts() {
        let package = StandardOntologyCatalog.bundledSceneFixture
        XCTAssertEqual(package.ontologyID, "imageall-public-fixture")
        XCTAssertEqual(package.ontologyRevision, "ontology-v1")
        XCTAssertEqual(package.provider, "rgb-linear")
        XCTAssertEqual(package.modelID, "imageall/fixture-scene-linear")
        XCTAssertEqual(package.modelRevision, "model-v1")
        XCTAssertEqual(package.preprocessingRevision, "rgb-channel-mean-v1")
        XCTAssertEqual(package.mappingRevision, "mapping-v1")
        XCTAssertEqual(package.policyRevision, "policy-v1")
        XCTAssertEqual(package.concepts.map(\.conceptID), [
            "scene.environment", "scene.outdoor", "scene.water",
        ])
    }

    func testProductionCompositionRootDoesNotCreateLoopbackRuntime() {
        XCTAssertNil(
            CompositionRoot.makeLocalModelSuggestionRuntime()
        )
    }

    func testProductionCoreMLFactoryLoadsBundledArtifactWhenEnabled() throws {
        let testBundleURL = Bundle(for: CompositionRootTests.self).bundleURL
        let appBundleURL = testBundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appBundle = try XCTUnwrap(Bundle(url: appBundleURL))

        let service = CompositionRoot.makeAppCoreMLEmbeddingService(
            isEnabled: true,
            bundle: appBundle
        )

        guard case let .ready(identity) = service.availability else {
            return XCTFail(
                "expected the bundled Core ML artifact to be ready, got \(service.availability)"
            )
        }
        XCTAssertEqual(identity.modelID, "facebook/dinov2-small")
        XCTAssertEqual(identity.elementCount, 384)
    }

    func testProductionCoreMLCacheFactoryGeneratesAnIdentityMatchedEmbedding() throws {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let cache = CompositionRoot.makeAppCoreMLEmbeddingCache(
            isEnabled: true,
            cachesDirectory: cacheRoot,
            bundle: try appBundle()
        )

        let result = try cache.embedding(
            for: generatedImage(),
            key: AppCoreMLEmbeddingCacheKey(
                catalogScopeID: UUID(),
                assetID: UUID(),
                contentRevision: 1
            )
        )

        XCTAssertEqual(result.origin, .generated)
        XCTAssertEqual(result.identity.modelID, "facebook/dinov2-small")
        XCTAssertEqual(result.values.count, 384)
    }

    func testProductionModelSettingsFactoryStartsNewInstallDisabled() async {
        let suiteName = "CompositionRootTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = CompositionRoot.makeAppModelSettingsModel(
            defaults: defaults
        )

        await model.start()

        XCTAssertFalse(model.isEnabled)
        XCTAssertEqual(model.state, .disabled)
    }

    func testProductionCompositionSharesActivatedCoreMLWithWorkspaceRebuild() async throws {
        let suiteName = "CompositionRootTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let activation = CompositionRoot.makeAppModelActivationCoordinator(
            defaults: defaults,
            bundle: try appBundle()
        )
        let settings = CompositionRoot.makeAppModelSettingsModel(
            coordinator: activation
        )
        settings.setEnabled(true)
        let activated = await waitUntil(timeoutSeconds: 5) {
            if case .ready = settings.state { return true }
            return false
        }
        XCTAssertTrue(activated)
        let tempRoot = try StartupTestSupport.makeTempRoot(testCase: self)
        let startup = CompositionRoot().makeStartupModel(
            modelActivationCoordinator: activation,
            dependencies: StartupTestSupport.makeDependencies(root: tempRoot)
        )

        let ready = await waitUntil(timeoutSeconds: 5) {
            startup.workspaceModel != nil
        }

        XCTAssertTrue(ready)
        XCTAssertTrue(startup.workspaceModel?.supportsPersonalModelRebuild == true)
        try startup.closeForTesting()
    }

    func testCompositionRootProducesFoundationReadyPresentation() async throws {
        let root = try StartupTestSupport.makeTempRoot(testCase: self)
        let dependencies = StartupTestSupport.makeDependencies(root: root)
        let model = CatalogStartupModel(dependencies: dependencies)

        XCTAssertEqual(model.presentation.productName, "ImageAll")
        XCTAssertTrue(
            model.presentation.foundationReady,
            "foundationReady must indicate the app shell and dependency assembly have started"
        )

        let ready = await waitUntil(timeoutSeconds: 5) {
            if case .catalogReady = model.presentation.catalogState {
                return true
            }
            return false
        }
        XCTAssertTrue(ready)
        try model.closeForTesting()
    }

    private func waitUntil(timeoutSeconds: TimeInterval, condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    private func appBundle() throws -> Bundle {
        let testBundleURL = Bundle(for: CompositionRootTests.self).bundleURL
        let appBundleURL = testBundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try XCTUnwrap(Bundle(url: appBundleURL))
    }

    private func generatedImage() throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: 64,
            height: 64,
            bitsPerComponent: 8,
            bytesPerRow: 64 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw CompositionRootTestError.imageCreationFailed
        }
        context.setFillColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        guard let image = context.makeImage() else {
            throw CompositionRootTestError.imageCreationFailed
        }
        return image
    }

    private enum CompositionRootTestError: Error {
        case imageCreationFailed
    }
}
