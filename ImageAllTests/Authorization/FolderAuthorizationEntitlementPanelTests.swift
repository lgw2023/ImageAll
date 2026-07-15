import AppKit
import XCTest
@testable import ImageAll

final class FolderAuthorizationEntitlementPanelTests: XCTestCase {
    func testProductionEntitlementsContainApprovedSandboxCapabilities() throws {
        let entitlementsURL = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ImageAll.entitlements")

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceEntitlements = repoRoot
            .appendingPathComponent("ImageAll/ImageAll.entitlements")

        let data = try Data(contentsOf: sourceEntitlements)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        XCTAssertEqual(plist["com.apple.security.app-sandbox"] as? Bool, true)
        XCTAssertEqual(plist["com.apple.security.files.user-selected.read-only"] as? Bool, true)
        XCTAssertEqual(plist["com.apple.security.files.bookmarks.app-scope"] as? Bool, true)
        XCTAssertNil(plist["com.apple.security.files.user-selected.read-write"])
        XCTAssertEqual(plist.keys.sorted(), [
            "com.apple.security.app-sandbox",
            "com.apple.security.files.bookmarks.app-scope",
            "com.apple.security.files.user-selected.read-only",
        ])
        _ = entitlementsURL
    }

    func testOpenPanelConfigurationIsDirectoryOnlySingleSelectionWithoutAliasResolution() {
        let panel = NSOpenPanel()
        FolderDirectoryPickerPanelConfiguration.apply(to: panel)

        XCTAssertFalse(panel.canChooseFiles)
        XCTAssertTrue(panel.canChooseDirectories)
        XCTAssertFalse(panel.allowsMultipleSelection)
        XCTAssertFalse(panel.resolvesAliases)
        XCTAssertFalse(panel.treatsFilePackagesAsDirectories)
        XCTAssertFalse(panel.canCreateDirectories)
    }

    func testPickerIsNotTriggeredBeforeExplicitConnectCommand() throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let picker = FolderAuthorizationTestSupport.FakeDirectoryPicker()
        let (coordinator, _, fakePicker, _) = FolderAuthorizationTestSupport.makeCoordinator(
            database: database,
            picker: picker
        )

        XCTAssertEqual(fakePicker.callCount, 0)

        fakePicker.configuredResponses = [nil]
        let outcome = try FolderAuthorizationTestSupport.awaitResult {
            try await coordinator.connectFolder()
        }
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(fakePicker.callCount, 1)
    }

    func testAppKitPickerUsesInjectedPanelWithoutShowingSystemUI() {
        final class CallTracker: @unchecked Sendable {
            var factoryCalled = false
            var modalCalled = false
        }
        let tracker = CallTracker()
        let panel = NSOpenPanel()
        FolderDirectoryPickerPanelConfiguration.apply(to: panel)

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
