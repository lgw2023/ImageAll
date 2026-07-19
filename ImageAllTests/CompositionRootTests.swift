import XCTest
@testable import ImageAll

@MainActor
final class CompositionRootTests: XCTestCase {
    func testBundledStandardOntologyMatchesRuntimeIdentityAndConcepts() throws {
        let package = StandardOntologyCatalog.bundledSceneFixture
        let runtime = try XCTUnwrap(
            CompositionRoot.makeLocalModelSuggestionRuntime(catalogScopeID: "catalog-fixture")
        )

        XCTAssertEqual(
            runtime.target,
            .standard(
                StandardModelSuggestionTarget(
                    standardPackID: package.standardPackID,
                    standardPackRevision: package.standardPackRevision
                )
            )
        )
        XCTAssertEqual(package.ontologyID, "imageall-public-fixture")
        XCTAssertEqual(package.ontologyRevision, "ontology-v1")
        XCTAssertEqual(package.provider, "rgb-linear")
        XCTAssertEqual(package.modelRevision, "model-v1")
        XCTAssertEqual(package.preprocessingRevision, "rgb-channel-mean-v1")
        XCTAssertEqual(package.mappingRevision, "mapping-v1")
        XCTAssertEqual(package.policyRevision, "policy-v1")
        XCTAssertEqual(package.concepts.map(\.conceptID), [
            "scene.environment", "scene.outdoor", "scene.water",
        ])
    }

    func testProductionLocalModelRuntimePinsTheStandardFixtureIdentity() throws {
        let runtime = try XCTUnwrap(
            CompositionRoot.makeLocalModelSuggestionRuntime(
                catalogScopeID: "catalog-fixture"
            )
        )

        XCTAssertEqual(
            runtime.target,
            .standard(
                StandardModelSuggestionTarget(
                    standardPackID: "imageall-public-fixture",
                    standardPackRevision: "pack-v1"
                )
            )
        )
        XCTAssertEqual(runtime.catalogScopeID, "catalog-fixture")
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
}
