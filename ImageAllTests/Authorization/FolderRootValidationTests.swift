import Foundation
import XCTest
@testable import ImageAll

final class FolderRootValidationTests: XCTestCase {
    private var registry: FolderAuthorizationTestSupport.TempRootRegistry!

    override func setUp() {
        super.setUp()
        registry = FolderAuthorizationTestSupport.TempRootRegistry()
    }

    override func tearDown() {
        registry.cleanup()
        registry = nil
        super.tearDown()
    }

    func testValidDirectoryRootAcceptsDisplayName() throws {
        let root = try registry.makeRoot(label: "valid")
        let reader = FolderAuthorizationTestSupport.FixedResourceReader()
        reader.snapshots[root] = FolderRootResourceSnapshot(
            isDirectory: true,
            isSymbolicLink: false,
            isAliasFile: false,
            isPackage: false,
            isReadable: true,
            localizedName: "Vacation",
            pathExtension: ""
        )
        let validator = FolderRootValidator(resourceReader: reader)

        XCTAssertEqual(validator.validateRoot(at: root), .valid(displayName: "Vacation"))
    }

    func testRejectsFileSymlinkAliasPackageAndPhotosLibrary() throws {
        let reader = FolderAuthorizationTestSupport.FixedResourceReader()
        let validator = FolderRootValidator(resourceReader: reader)

        let file = URL(fileURLWithPath: "/tmp/file.txt")
        reader.snapshots[file] = FolderRootResourceSnapshot(
            isDirectory: false, isSymbolicLink: false, isAliasFile: false, isPackage: false,
            isReadable: true, localizedName: "file", pathExtension: "txt"
        )
        XCTAssertEqual(validator.validateRoot(at: file), .invalid(.file))

        let symlink = URL(fileURLWithPath: "/tmp/link")
        reader.snapshots[symlink] = FolderRootResourceSnapshot(
            isDirectory: true, isSymbolicLink: true, isAliasFile: false, isPackage: false,
            isReadable: true, localizedName: "link", pathExtension: ""
        )
        XCTAssertEqual(validator.validateRoot(at: symlink), .invalid(.symbolicLink))

        let alias = URL(fileURLWithPath: "/tmp/alias")
        reader.snapshots[alias] = FolderRootResourceSnapshot(
            isDirectory: true, isSymbolicLink: false, isAliasFile: true, isPackage: false,
            isReadable: true, localizedName: "alias", pathExtension: ""
        )
        XCTAssertEqual(validator.validateRoot(at: alias), .invalid(.alias))

        let package = URL(fileURLWithPath: "/tmp/pkg.app")
        reader.snapshots[package] = FolderRootResourceSnapshot(
            isDirectory: true, isSymbolicLink: false, isAliasFile: false, isPackage: true,
            isReadable: true, localizedName: "pkg", pathExtension: "app"
        )
        XCTAssertEqual(validator.validateRoot(at: package), .invalid(.package))

        let photos = URL(fileURLWithPath: "/tmp/Library.photoslibrary")
        reader.snapshots[photos] = FolderRootResourceSnapshot(
            isDirectory: true, isSymbolicLink: false, isAliasFile: false, isPackage: false,
            isReadable: true, localizedName: "Library", pathExtension: "photoslibrary"
        )
        XCTAssertEqual(validator.validateRoot(at: photos), .invalid(.photosLibrary))
    }

    func testUnreadableRootRejectedViaResourceReaderFailure() throws {
        let root = try registry.makeRoot(label: "unreadable")
        let reader = FolderAuthorizationTestSupport.FixedResourceReader()
        reader.failureURLs.insert(root)
        let validator = FolderRootValidator(resourceReader: reader)

        XCTAssertEqual(validator.validateRoot(at: root), .invalid(.unreadable))
    }

    func testCancelSelectionWritesNothing() throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let picker = FolderAuthorizationTestSupport.FakeDirectoryPicker()
        let (coordinator, _, fakePicker, _) = FolderAuthorizationTestSupport.makeCoordinator(
            database: database,
            picker: picker
        )

        fakePicker.configuredResponses = [nil]

        let baselineSources = try FolderAuthorizationTestSupport.sourceCount(database)
        let baselineJobs = try FolderAuthorizationTestSupport.jobCount(database)

        let outcome = try FolderAuthorizationTestSupport.awaitResult {
            try await coordinator.connectFolder()
        }
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(try FolderAuthorizationTestSupport.sourceCount(database), baselineSources)
        XCTAssertEqual(try FolderAuthorizationTestSupport.jobCount(database), baselineJobs)
        XCTAssertEqual(fakePicker.callCount, 1)
    }

    func testSuccessfulSelectionReleasesImplicitScopeOnce() throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let root = try registry.makeRoot(label: "implicit-stop")
        let picker = FolderAuthorizationTestSupport.FakeDirectoryPicker()
        let bookmarkPort = FolderAuthorizationTestSupport.ScopeTrackingBookmarkPort()
        let (coordinator, _, _, _) = FolderAuthorizationTestSupport.makeCoordinator(
            database: database,
            picker: picker,
            bookmarkPort: bookmarkPort,
            ids: [UUID(), UUID()]
        )
        picker.configuredResponses = [root]

        _ = try FolderAuthorizationTestSupport.awaitResult {
            try await coordinator.connectFolder()
        }
        XCTAssertEqual(bookmarkPort.stopCount, 1)
    }

    func testInvalidRootAfterSelectionReleasesImplicitScopeWithoutWrites() throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let root = try registry.makeRoot(label: "invalid")
        let picker = FolderAuthorizationTestSupport.FakeDirectoryPicker()
        let reader = FolderAuthorizationTestSupport.FixedResourceReader()
        reader.snapshots[root] = FolderRootResourceSnapshot(
            isDirectory: false, isSymbolicLink: false, isAliasFile: false, isPackage: false,
            isReadable: true, localizedName: "bad", pathExtension: "txt"
        )
        let bookmarkPort = FolderAuthorizationTestSupport.ScopeTrackingBookmarkPort()
        let (coordinator, _, _, _) = FolderAuthorizationTestSupport.makeCoordinator(
            database: database,
            picker: picker,
            bookmarkPort: bookmarkPort,
            resourceReader: reader
        )

        picker.configuredResponses = [root]

        XCTAssertThrowsError(try FolderAuthorizationTestSupport.awaitResult {
            try await coordinator.connectFolder()
        }) { error in
            XCTAssertEqual(error as? FolderAuthorizationError, .invalidRoot)
        }
        XCTAssertEqual(try FolderAuthorizationTestSupport.sourceCount(database), 0)
        XCTAssertEqual(bookmarkPort.stopCount, 1)
    }
}
