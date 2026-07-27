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
    func testAppKitPickerUsesInjectedPanelWithoutShowingSystemUI() {
        final class CallTracker: @unchecked Sendable {
            var factoryCalled = false
            var modalCalled = false
        }
        let tracker = CallTracker()
        let panel = AppKitFolderDirectoryPicker.makeProductionPanel()

        let picker = AppKitFolderDirectoryPicker(
            panelFactory: {
                tracker.factoryCalled = true
                return panel
            },
            runModal: { _ in
                tracker.modalCalled = true
                return .cancel
            }
        )

        XCTAssertNil(picker.pickDirectory())
        XCTAssertTrue(tracker.factoryCalled)
        XCTAssertTrue(tracker.modalCalled)
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
