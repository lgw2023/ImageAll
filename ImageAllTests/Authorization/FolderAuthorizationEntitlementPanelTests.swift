import AppKit
import Security
import XCTest
@testable import ImageAll

final class FolderAuthorizationEntitlementPanelTests: XCTestCase {
    func testProductionEntitlementsContainApprovedSandboxCapabilities() throws {
        guard let task = SecTaskCreateFromSelf(nil) else {
            XCTFail("Unable to create security task for host entitlements")
            return
        }

        func boolEntitlement(_ key: String) -> Bool? {
            guard let value = SecTaskCopyValueForEntitlement(task, key as CFString, nil) else {
                return nil
            }
            return (value as? NSNumber)?.boolValue
        }

        XCTAssertEqual(boolEntitlement("com.apple.security.app-sandbox"), true)
        XCTAssertEqual(boolEntitlement("com.apple.security.files.user-selected.read-write"), true)
        XCTAssertEqual(boolEntitlement("com.apple.security.files.bookmarks.app-scope"), true)
        XCTAssertEqual(boolEntitlement("com.apple.security.network.client"), true)
        XCTAssertNil(
            SecTaskCopyValueForEntitlement(
                task,
                "com.apple.security.files.user-selected.read-only" as CFString,
                nil
            )
        )
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
}
