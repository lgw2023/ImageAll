import XCTest
@testable import ImageAll

@MainActor
final class CompositionRootTests: XCTestCase {
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
