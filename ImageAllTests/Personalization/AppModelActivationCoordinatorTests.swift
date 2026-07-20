import Foundation
import XCTest
@testable import ImageAll

final class AppModelActivationCoordinatorTests: XCTestCase {
    func testNewInstallStartsDisabledWithoutCreatingModelService() async {
        let defaults = makeIsolatedUserDefaults()
        let store = UserDefaultsModelEnablementPreferenceStore(defaults: defaults)
        let factory = ModelServiceFactoryRecorder()
        let coordinator = AppModelActivationCoordinator(
            preferenceStore: store,
            serviceFactory: factory.makeMissingService
        )

        let state = await coordinator.start()

        XCTAssertEqual(state, .disabled)
        XCTAssertFalse(store.isEnabled)
        XCTAssertEqual(factory.callCount, 0)
    }

    @MainActor
    func testEnablingValidatesOffMainAndReturnsReadyIdentity() async {
        let store = UserDefaultsModelEnablementPreferenceStore(
            defaults: makeIsolatedUserDefaults()
        )
        let factory = ModelServiceFactoryRecorder(
            artifactDirectory: projectArtifactDirectory()
        )
        let coordinator = AppModelActivationCoordinator(
            preferenceStore: store,
            serviceFactory: factory.makeService
        )

        let state = await coordinator.setEnabled(true)

        guard case let .ready(identity) = state else {
            return XCTFail("expected fixed Core ML artifact to be ready")
        }
        XCTAssertTrue(store.isEnabled)
        XCTAssertEqual(factory.callCount, 1)
        XCTAssertFalse(factory.wasCalledOnMainThread)
        XCTAssertEqual(identity.modelID, "facebook/dinov2-small")
        XCTAssertEqual(identity.elementCount, 384)
    }

    func testMissingArtifactKeepsEnabledIntentAndReportsUnavailable() async {
        let store = UserDefaultsModelEnablementPreferenceStore(
            defaults: makeIsolatedUserDefaults()
        )
        let factory = ModelServiceFactoryRecorder()
        let coordinator = AppModelActivationCoordinator(
            preferenceStore: store,
            serviceFactory: factory.makeMissingService
        )

        let state = await coordinator.setEnabled(true)

        XCTAssertEqual(state, .unavailable(.artifactMissing))
        XCTAssertTrue(store.isEnabled)
        XCTAssertEqual(factory.callCount, 1)
    }

    func testRepeatedEnableDoesNotRetryInitialization() async {
        let store = UserDefaultsModelEnablementPreferenceStore(
            defaults: makeIsolatedUserDefaults()
        )
        let factory = ModelServiceFactoryRecorder()
        let coordinator = AppModelActivationCoordinator(
            preferenceStore: store,
            serviceFactory: factory.makeMissingService
        )

        let firstState = await coordinator.setEnabled(true)
        let repeatedState = await coordinator.setEnabled(true)

        XCTAssertEqual(firstState, .unavailable(.artifactMissing))
        XCTAssertEqual(repeatedState, firstState)
        XCTAssertEqual(factory.callCount, 1)
    }

    @MainActor
    func testSettingsModelShowsValidatingWhileActivationRuns() async {
        let store = UserDefaultsModelEnablementPreferenceStore(
            defaults: makeIsolatedUserDefaults()
        )
        let factory = ModelServiceFactoryRecorder(blocksUntilReleased: true)
        let coordinator = AppModelActivationCoordinator(
            preferenceStore: store,
            serviceFactory: factory.makeMissingService
        )
        let model = AppModelSettingsModel(coordinator: coordinator)

        model.setEnabled(true)

        XCTAssertTrue(model.isEnabled)
        XCTAssertEqual(model.state, .validating)
        let didStart = await waitUntil { factory.callCount == 1 }
        XCTAssertTrue(didStart)
        factory.release()
        let didFinish = await waitUntil {
            model.state == .unavailable(.artifactMissing)
        }
        XCTAssertTrue(didFinish)
    }

    @MainActor
    func testSettingsModelStartRevalidatesPersistedEnabledPreferenceOnce() async {
        let store = UserDefaultsModelEnablementPreferenceStore(
            defaults: makeIsolatedUserDefaults()
        )
        store.isEnabled = true
        let factory = ModelServiceFactoryRecorder()
        let coordinator = AppModelActivationCoordinator(
            preferenceStore: store,
            serviceFactory: factory.makeMissingService
        )
        let model = AppModelSettingsModel(coordinator: coordinator)

        XCTAssertTrue(model.isEnabled)
        XCTAssertEqual(model.state, .validating)

        await model.start()
        await model.start()

        XCTAssertEqual(model.state, .unavailable(.artifactMissing))
        XCTAssertEqual(factory.callCount, 1)
    }

    @MainActor
    func testUnavailableSettingsPresentationIsSanitized() async {
        let store = UserDefaultsModelEnablementPreferenceStore(
            defaults: makeIsolatedUserDefaults()
        )
        let factory = ModelServiceFactoryRecorder()
        let coordinator = AppModelActivationCoordinator(
            preferenceStore: store,
            serviceFactory: factory.makeMissingService
        )
        let model = AppModelSettingsModel(coordinator: coordinator)

        model.setEnabled(true)
        _ = await waitUntil {
            model.state == .unavailable(.artifactMissing)
        }

        XCTAssertEqual(model.statusText, "模型不可用")
        XCTAssertEqual(model.modelText, "DINOv2 Small")
        XCTAssertEqual(model.runtimeText, "App 内 Core ML（本机）")
        XCTAssertEqual(
            model.detailText,
            "模型文件缺失。浏览和人工标签仍可使用。"
        )
        XCTAssertFalse(model.detailText.contains("/"))
        XCTAssertFalse(model.detailText.localizedCaseInsensitiveContains("http"))
        XCTAssertFalse(model.detailText.localizedCaseInsensitiveContains("python"))
    }

    @MainActor
    func testReadySettingsPresentationUsesValidatedModelIdentity() async {
        let store = UserDefaultsModelEnablementPreferenceStore(
            defaults: makeIsolatedUserDefaults()
        )
        let factory = ModelServiceFactoryRecorder(
            artifactDirectory: projectArtifactDirectory()
        )
        let coordinator = AppModelActivationCoordinator(
            preferenceStore: store,
            serviceFactory: factory.makeService
        )
        let model = AppModelSettingsModel(coordinator: coordinator)

        model.setEnabled(true)
        _ = await waitUntil {
            if case .ready = model.state { return true }
            return false
        }

        XCTAssertEqual(model.statusText, "模型已就绪")
        XCTAssertEqual(model.modelText, "facebook/dinov2-small")
    }

    func testDisablingReleasesLoadedServiceAndAllowsExplicitRetry() async {
        let store = UserDefaultsModelEnablementPreferenceStore(
            defaults: makeIsolatedUserDefaults()
        )
        let factory = ModelServiceFactoryRecorder(
            artifactDirectory: projectArtifactDirectory()
        )
        let coordinator = AppModelActivationCoordinator(
            preferenceStore: store,
            serviceFactory: factory.makeService
        )

        _ = await coordinator.setEnabled(true)
        XCTAssertTrue(factory.isLastServiceAlive)

        let disabledState = await coordinator.setEnabled(false)

        XCTAssertEqual(disabledState, .disabled)
        XCTAssertFalse(store.isEnabled)
        XCTAssertFalse(factory.isLastServiceAlive)

        guard case .ready = await coordinator.setEnabled(true) else {
            return XCTFail("expected explicit off-on retry to reload the model")
        }
        XCTAssertEqual(factory.callCount, 2)
    }

    func testConcurrentEnableRequestsShareOneInitialization() async {
        let store = UserDefaultsModelEnablementPreferenceStore(
            defaults: makeIsolatedUserDefaults()
        )
        let factory = ModelServiceFactoryRecorder()
        let coordinator = AppModelActivationCoordinator(
            preferenceStore: store,
            serviceFactory: factory.makeMissingService
        )

        let states = await withTaskGroup(
            of: AppModelActivationState.self,
            returning: [AppModelActivationState].self
        ) { group in
            for _ in 0..<8 {
                group.addTask {
                    await coordinator.setEnabled(true)
                }
            }
            var values: [AppModelActivationState] = []
            for await state in group {
                values.append(state)
            }
            return values
        }

        XCTAssertEqual(states.count, 8)
        XCTAssertTrue(states.allSatisfy {
            $0 == .unavailable(.artifactMissing)
        })
        XCTAssertEqual(factory.callCount, 1)
    }

    func testNewCoordinatorRevalidatesPersistedIntentAfterArtifactChanges() async {
        let store = UserDefaultsModelEnablementPreferenceStore(
            defaults: makeIsolatedUserDefaults()
        )
        let missingFactory = ModelServiceFactoryRecorder()
        let oldCoordinator = AppModelActivationCoordinator(
            preferenceStore: store,
            serviceFactory: missingFactory.makeMissingService
        )

        let oldState = await oldCoordinator.setEnabled(true)
        XCTAssertEqual(oldState, .unavailable(.artifactMissing))

        let updatedFactory = ModelServiceFactoryRecorder(
            artifactDirectory: projectArtifactDirectory()
        )
        let newCoordinator = AppModelActivationCoordinator(
            preferenceStore: store,
            serviceFactory: updatedFactory.makeService
        )
        guard case .ready = await newCoordinator.start() else {
            return XCTFail("expected a new lifecycle to validate the updated artifact")
        }
        XCTAssertEqual(missingFactory.callCount, 1)
        XCTAssertEqual(updatedFactory.callCount, 1)
    }

    private func makeIsolatedUserDefaults() -> UserDefaults {
        let suiteName = "AppModelActivationCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?
                .removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    private func projectArtifactDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ImageAll/Resources/Models/DINOv2Small")
    }

    @MainActor
    private func waitUntil(
        timeoutSeconds: TimeInterval = 2,
        condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

private final class ModelServiceFactoryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let artifactDirectory: URL
    private let blocksUntilReleased: Bool
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var calls = 0
    private var mainThreadCalls = 0
    private weak var lastService: AppCoreMLEmbeddingService?

    init(
        artifactDirectory: URL = URL(
            fileURLWithPath: "/definitely/missing/coreml-artifact"
        ),
        blocksUntilReleased: Bool = false
    ) {
        self.artifactDirectory = artifactDirectory
        self.blocksUntilReleased = blocksUntilReleased
    }

    var callCount: Int {
        lock.withLock { calls }
    }

    var wasCalledOnMainThread: Bool {
        lock.withLock { mainThreadCalls > 0 }
    }

    var isLastServiceAlive: Bool {
        lock.withLock { lastService != nil }
    }

    func makeService() -> AppCoreMLEmbeddingService {
        lock.withLock {
            calls += 1
            if Thread.isMainThread {
                mainThreadCalls += 1
            }
        }
        if blocksUntilReleased {
            releaseSemaphore.wait()
        }
        let service = AppCoreMLEmbeddingService(
            isEnabled: true,
            artifactDirectory: artifactDirectory
        )
        lock.withLock { lastService = service }
        return service
    }

    func makeMissingService() -> AppCoreMLEmbeddingService {
        makeService()
    }

    func release() {
        releaseSemaphore.signal()
    }
}
