import AppKit
import Security
import XCTest
@testable import ImageAll

final class FolderAuthorizationEntitlementPanelTests: XCTestCase {
    func testProductionEntitlementsContainApprovedSandboxCapabilities() throws {
        let task = SecTaskCreateFromSelf(nil)
        let sourceEntitlements = try Self.loadSourceEntitlements()

        func entitlement(_ key: String) -> Any? {
            if let task,
               let value = SecTaskCopyValueForEntitlement(task, key as CFString, nil)
            {
                return value
            }
            // The standard test command deliberately disables code signing.
            // In that host there is no embedded entitlement blob, so validate
            // the production entitlement plist instead.
            return sourceEntitlements[key]
        }

        func boolEntitlement(_ key: String) -> Bool? {
            (entitlement(key) as? NSNumber)?.boolValue
        }

        XCTAssertEqual(boolEntitlement("com.apple.security.app-sandbox"), true)
        XCTAssertEqual(boolEntitlement("com.apple.security.files.user-selected.read-write"), true)
        XCTAssertEqual(boolEntitlement("com.apple.security.files.bookmarks.app-scope"), true)
        XCTAssertEqual(boolEntitlement("com.apple.security.network.client"), true)
        XCTAssertEqual(boolEntitlement("com.apple.security.network.server"), true)
        XCTAssertNil(entitlement("com.apple.security.files.user-selected.read-only"))
    }

    @MainActor
    func testOpenPanelConfigurationIsDirectoryOnlySingleSelectionWithoutAliasResolution() {
        let panel = AppKitFolderDirectoryPicker.makeProductionPanel()

        XCTAssertFalse(panel.canChooseFiles)
        XCTAssertTrue(panel.canChooseDirectories)
        XCTAssertFalse(panel.allowsMultipleSelection)
        XCTAssertFalse(panel.resolvesAliases)
        XCTAssertFalse(panel.treatsFilePackagesAsDirectories)
        XCTAssertFalse(panel.canCreateDirectories)
    }

    @MainActor
    func testLegacyMutationAuthorizationPanelExplainsOneTimeUpgrade() {
        let panel = AppKitFolderDirectoryPicker.makeMutationAuthorizationPanel()

        XCTAssertEqual(panel.title, "升级旧来源的一次性权限")
        XCTAssertEqual(panel.prompt, "授权并继续")
        XCTAssertTrue(panel.message.contains("旧版本"))
        XCTAssertTrue(panel.message.contains("今后各功能不会再次要求授权"))
    }

    @MainActor
    func testSourceImportPanelExplainsOneImportGrantsDurableAccess() {
        let panel = AppKitFolderDirectoryPicker.makeSourceImportPanel()

        XCTAssertEqual(panel.title, "导入 ImageAll 图库来源")
        XCTAssertEqual(panel.prompt, "导入来源")
        XCTAssertTrue(panel.message.contains("选择一次来源文件夹"))
        XCTAssertTrue(panel.message.contains("确认快速删除或可恢复回收"))
    }

    func testPickerIsNotTriggeredBeforeExplicitConnectCommand() async throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let picker = FolderAuthorizationTestSupport.FakeDirectoryPicker()
        let (coordinator, _, fakePicker, _) = FolderAuthorizationTestSupport.makeCoordinator(
            database: database,
            picker: picker
        )

        XCTAssertEqual(fakePicker.callCount, 0)

        fakePicker.configuredResponses = [nil]
        let outcome = try await coordinator.connectFolder()
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(fakePicker.callCount, 1)
    }

    @MainActor
    func testAppKitPickerUsesInjectedPanelAndInitialDirectoryWithoutShowingSystemUI() async {
        final class CallTracker: @unchecked Sendable {
            var factoryCalled = false
            var modalCalled = false
            var displayedDirectoryURL: URL?
        }
        let tracker = CallTracker()
        let panel = AppKitFolderDirectoryPicker.makeProductionPanel()
        let initialDirectoryURL = URL(fileURLWithPath: "/tmp/source-root", isDirectory: true)

        let picker = AppKitFolderDirectoryPicker(
            panelFactory: {
                tracker.factoryCalled = true
                return panel
            },
            runModal: { presentedPanel in
                tracker.modalCalled = true
                tracker.displayedDirectoryURL = presentedPanel.directoryURL
                return .cancel
            }
        )

        let result = await picker.pickDirectory(initialDirectoryURL: initialDirectoryURL)
        XCTAssertNil(result)
        XCTAssertTrue(tracker.factoryCalled)
        XCTAssertTrue(tracker.modalCalled)
        XCTAssertEqual(tracker.displayedDirectoryURL, initialDirectoryURL)
    }

    private static func loadSourceEntitlements() throws -> [String: Any] {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repositoryRoot.appendingPathComponent(
            "ImageAll/ImageAll.entitlements"
        )
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any]
        )
    }
}
