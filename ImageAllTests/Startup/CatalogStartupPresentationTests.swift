import XCTest
@testable import ImageAll

@MainActor
final class CatalogStartupPresentationTests: XCTestCase {
    func testPresentationEventuallyReachesCatalogReady() async throws {
        let root = try StartupTestSupport.makeTempRoot(testCase: self)
        let dependencies = StartupTestSupport.makeDependencies(root: root)
        let model = CatalogStartupModel(dependencies: dependencies)

        let ready = await waitUntil(timeoutSeconds: 5) {
            if case .catalogReady = model.presentation.catalogState {
                return true
            }
            return false
        }
        XCTAssertTrue(ready)
        XCTAssertTrue(model.presentation.foundationReady)
        XCTAssertEqual(model.presentation.productName, "ImageAll")
        try model.closeForTesting()
    }

    func testFailurePresentationUsesStableReasonTokensWithoutSensitiveText() async throws {
        let root = try StartupTestSupport.makeTempRoot(testCase: self)
        let paths = try StartupTestSupport.resolvedPaths(root: root)
        try StartupTestSupport.seedFutureSchemaDatabase(at: paths.catalogDatabaseURL)

        let dependencies = StartupTestSupport.makeDependencies(root: root)
        let model = CatalogStartupModel(dependencies: dependencies)

        let failed = await waitUntil(timeoutSeconds: 5) {
            if case .catalogUnavailable = model.presentation.catalogState {
                return true
            }
            return false
        }
        XCTAssertTrue(failed)

        let token = model.presentation.catalogState.displayToken
        XCTAssertEqual(token, "catalogUnavailable(schemaUnsupported)")
        XCTAssertFalse(token.contains("/"))
        XCTAssertFalse(token.contains("v999"))
    }

    func testStartupModelBootstrapBlockingWorkDoesNotRunOnMainThread() async throws {
        let root = try StartupTestSupport.makeTempRoot(testCase: self)
        let probe = MainThreadProbe()
        let dependencies = StartupTestSupport.makeDependencies(
            root: root,
            blockingWorkProbe: { _ in
                probe.markIfMainThread()
            }
        )
        let model = CatalogStartupModel(dependencies: dependencies)

        let ready = await waitUntil(timeoutSeconds: 5) {
            if case .catalogReady = model.presentation.catalogState {
                return true
            }
            return false
        }
        XCTAssertTrue(ready)
        XCTAssertFalse(probe.sawMainThread)
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

final class CatalogStartupConcurrencyTests: XCTestCase {
    func testCapacityCheckRunsOffMainThread() throws {
        let root = try StartupTestSupport.makeTempRoot(testCase: self)
        let paths = try StartupTestSupport.resolvedPaths(root: root)
        try StartupTestSupport.seedEmptySQLite(at: paths.catalogDatabaseURL)

        let expectation = expectation(description: "capacity check")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try CatalogCapacityChecker(
                    provider: FixedCapacityProvider(bytes: UInt64.max)
                ).assertSufficientSpace(for: paths.catalogDatabaseURL, at: paths.catalogDirectory)
                XCTAssertFalse(Thread.isMainThread)
            } catch {
                XCTFail("Unexpected error \(error)")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
    }
}
