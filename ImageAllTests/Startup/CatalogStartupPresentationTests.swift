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

    func testStartupModelPublishesMigrationProgressAndCancelOutcome() async throws {
        let root = try StartupTestSupport.makeTempRoot(testCase: self)
        var dependencies = StartupTestSupport.makeDependencies(root: root)
        let resolver = CancellableMigrationPathsResolver(
            base: StartupTestSupport.makePathsResolver(root: root)
        )
        dependencies.pathsResolver = resolver
        let model = CatalogStartupModel(dependencies: dependencies)

        let sawProgress = await waitUntil(timeoutSeconds: 5) {
            model.presentation.storageMigrationProgress != nil
        }
        XCTAssertTrue(sawProgress)
        model.cancelStorageMigration()

        let cancelled = await waitUntil(timeoutSeconds: 5) {
            if case .catalogUnavailable(.storageMigrationCancelled) = model.presentation.catalogState {
                return true
            }
            return false
        }
        XCTAssertTrue(cancelled)
        XCTAssertEqual(model.presentation.storageMigrationProgress?.phase, .cancelled)
        XCTAssertEqual(
            model.presentation.catalogState.displayToken,
            "catalogUnavailable(storageMigrationCancelled)"
        )
    }

    func testRetryBootstrapDiscardsSupersededReadyResult() async throws {
        let root = try StartupTestSupport.makeTempRoot(testCase: self)
        let gated = GatedPathsResolver(
            base: StartupTestSupport.makePathsResolver(root: root)
        )
        var dependencies = StartupTestSupport.makeDependencies(root: root)
        dependencies.pathsResolver = gated
        let appliedReadyCount = ReadyApplyCounter()

        let model = CatalogStartupModel(
            dependencies: dependencies,
            workspaceFactory: { _ in
                appliedReadyCount.increment()
                return nil
            }
        )
        let firstStarted = await waitUntil(timeoutSeconds: 5) {
            gated.startedCount >= 1
        }
        XCTAssertTrue(firstStarted)

        model.retryBootstrap()
        let secondStarted = await waitUntil(timeoutSeconds: 5) {
            gated.startedCount >= 2
        }
        XCTAssertTrue(secondStarted)

        gated.releaseOne()
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(appliedReadyCount.value, 0)
        if case .catalogReady = model.presentation.catalogState {
            XCTFail("superseded first bootstrap must not become catalogReady")
        }

        gated.releaseOne()
        let ready = await waitUntil(timeoutSeconds: 5) {
            if case .catalogReady = model.presentation.catalogState {
                return true
            }
            return false
        }
        XCTAssertTrue(ready)
        XCTAssertEqual(appliedReadyCount.value, 1)
        try model.closeForTesting()
    }

    func testRetryAfterMigrationFailureSurfacesFailedPhaseThenRecovers() async throws {
        let root = try StartupTestSupport.makeTempRoot(testCase: self)
        let failing = ControllableMigrationPathsResolver(
            base: StartupTestSupport.makePathsResolver(root: root),
            mode: .failAfterProgress
        )
        var dependencies = StartupTestSupport.makeDependencies(root: root)
        dependencies.pathsResolver = failing
        let model = CatalogStartupModel(dependencies: dependencies)

        let failed = await waitUntil(timeoutSeconds: 5) {
            if case .catalogUnavailable(.pathsFailed) = model.presentation.catalogState {
                return true
            }
            return false
        }
        XCTAssertTrue(failed)
        XCTAssertEqual(model.presentation.storageMigrationProgress?.phase, .failed)

        failing.mode = .succeed
        model.retryBootstrap()
        let ready = await waitUntil(timeoutSeconds: 5) {
            if case .catalogReady = model.presentation.catalogState {
                return true
            }
            return false
        }
        XCTAssertTrue(ready)
        try model.closeForTesting()
    }

    func testInsufficientSpaceDisplayTokenIncludesRequiredBytes() {
        let outcome = CatalogStartupOutcome.catalogUnavailable(
            .insufficientSpace(requiredBytes: 42)
        )
        XCTAssertEqual(outcome.displayToken, "catalogUnavailable(insufficientSpace:42)")
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

private final class GatedPathsResolver: AppPathsResolving, @unchecked Sendable {
    private let base: TemporaryAppPathsResolver
    private let lock = NSLock()
    private var pendingGates: [DispatchSemaphore] = []
    private(set) var startedCount = 0

    init(base: TemporaryAppPathsResolver) {
        self.base = base
    }

    func resolve() throws -> AppPaths {
        let gate = DispatchSemaphore(value: 0)
        lock.withLock {
            startedCount += 1
            pendingGates.append(gate)
        }
        gate.wait()
        return try base.resolve()
    }

    func ensureRequiredDirectories(for paths: AppPaths) throws {
        try base.ensureRequiredDirectories(for: paths)
    }

    func releaseOne() {
        let gate: DispatchSemaphore? = lock.withLock {
            guard !pendingGates.isEmpty else { return nil }
            return pendingGates.removeFirst()
        }
        gate?.signal()
    }
}

private struct CancellableMigrationPathsResolver: AppPathsResolving {
    let base: TemporaryAppPathsResolver
    private let onProgressBox = MigrationHookBox()
    private let isCancelledBox = MigrationCancelHookBox()

    func resolve() throws -> AppPaths {
        var progress = ExternalAppStorageMigrationProgress.zero
        progress.phase = .copyingApplicationSupport
        progress.totalBytes = 1_024
        progress.totalFiles = 1
        onProgressBox.value?(progress)

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if isCancelledBox.value?() == true {
                progress.phase = .cancelled
                onProgressBox.value?(progress)
                throw AppStorageLocationError.cancelled
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return try base.resolve()
    }

    func ensureRequiredDirectories(for paths: AppPaths) throws {
        try base.ensureRequiredDirectories(for: paths)
    }

    func resolvingWithMigrationHooks(
        onProgress: (@Sendable (ExternalAppStorageMigrationProgress) -> Void)?,
        isCancelled: (@Sendable () -> Bool)?
    ) -> any AppPathsResolving {
        onProgressBox.value = onProgress
        isCancelledBox.value = isCancelled
        return self
    }
}

private final class ControllableMigrationPathsResolver: AppPathsResolving, @unchecked Sendable {
    enum Mode {
        case failAfterProgress
        case succeed
    }

    let base: TemporaryAppPathsResolver
    private let lock = NSLock()
    private var storedMode: Mode
    private let onProgressBox = MigrationHookBox()

    init(base: TemporaryAppPathsResolver, mode: Mode) {
        self.base = base
        storedMode = mode
    }

    var mode: Mode {
        get { lock.withLock { storedMode } }
        set { lock.withLock { storedMode = newValue } }
    }

    func resolve() throws -> AppPaths {
        var progress = ExternalAppStorageMigrationProgress.zero
        progress.phase = .mergingCaches
        progress.totalBytes = 512
        progress.totalFiles = 2
        progress.bytesCopied = 128
        progress.filesCopied = 1
        onProgressBox.value?(progress)

        switch mode {
        case .failAfterProgress:
            throw AppStorageLocationError.migrationFailed
        case .succeed:
            progress.phase = .completed
            progress.bytesCopied = progress.totalBytes
            progress.filesCopied = progress.totalFiles
            onProgressBox.value?(progress)
            return try base.resolve()
        }
    }

    func ensureRequiredDirectories(for paths: AppPaths) throws {
        try base.ensureRequiredDirectories(for: paths)
    }

    func resolvingWithMigrationHooks(
        onProgress: (@Sendable (ExternalAppStorageMigrationProgress) -> Void)?,
        isCancelled _: (@Sendable () -> Bool)?
    ) -> any AppPathsResolving {
        onProgressBox.value = onProgress
        return self
    }
}

private final class ReadyApplyCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    var value: Int {
        lock.withLock { stored }
    }

    func increment() {
        lock.withLock { stored += 1 }
    }
}

private final class MigrationHookBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (@Sendable (ExternalAppStorageMigrationProgress) -> Void)?

    var value: (@Sendable (ExternalAppStorageMigrationProgress) -> Void)? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class MigrationCancelHookBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (@Sendable () -> Bool)?

    var value: (@Sendable () -> Bool)? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
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
