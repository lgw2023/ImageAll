import Foundation
import GRDB
import XCTest
@testable import ImageAll

final class FolderOverlapAndConnectTests: XCTestCase {
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

    func testAtomicConnectCreatesExactlyOneSourceAndOneJobWithExactPayload() async throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let root = try registry.makeRoot(label: "connect")
        let picker = FolderAuthorizationTestSupport.FakeDirectoryPicker()
        let sourceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let jobID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let (coordinator, _, _, _) = FolderAuthorizationTestSupport.makeCoordinator(
            database: database,
            picker: picker,
            ids: [sourceID, jobID]
        )

        picker.configuredResponses = [root]
        let outcome = try await coordinator.connectFolder()
        XCTAssertEqual(outcome, .connected(sourceID: sourceID))
        XCTAssertEqual(try FolderAuthorizationTestSupport.sourceCount(database), 1)
        XCTAssertEqual(try FolderAuthorizationTestSupport.jobCount(database), 1)

        let row = try database.pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM job WHERE id = ?", arguments: [jobID.uuidString.lowercased()])
        }
        let jobRow = try XCTUnwrap(row)
        XCTAssertEqual(jobRow["kind"] as String, FolderReconcileJobFactory.kind)
        XCTAssertEqual(jobRow["payload_version"] as Int, 1)
        XCTAssertEqual(jobRow["source_id"] as String, sourceID.uuidString.lowercased())
        XCTAssertEqual(
            jobRow["coalescing_key"] as String,
            FolderReconcileJobFactory.coalescingKey(sourceID: sourceID)
        )
        XCTAssertEqual(jobRow["priority"] as Int, 0)
        XCTAssertEqual(jobRow["attempts"] as Int, 0)
        XCTAssertEqual(jobRow["max_attempts"] as Int, 5)
        XCTAssertEqual(jobRow["state"] as String, JobState.pending.rawValue)
        XCTAssertEqual(jobRow["control_request"] as String, JobControlRequest.none.rawValue)
        XCTAssertEqual(jobRow["progress_completed"] as Int, 0)
        XCTAssertNil(jobRow["progress_total"] as Int?)
        XCTAssertNil(jobRow["checkpoint_version"] as Int?)
        XCTAssertNil(jobRow["checkpoint"] as Data?)
        XCTAssertNil(jobRow["last_error_code"] as String?)
        XCTAssertNil(jobRow["last_error_message"] as String?)

        let payload = jobRow["payload"] as Data
        let decoded = try FolderReconcileJobFactory.decodedPayloadKeys(payload)
        XCTAssertEqual(decoded.keys.sorted(), ["contract_version", "source_id"])
        XCTAssertEqual(decoded["contract_version"] as? Int, 1)
        XCTAssertEqual(decoded["source_id"] as? String, sourceID.uuidString.lowercased())
        let payloadText = String(data: payload, encoding: .utf8) ?? ""
        XCTAssertFalse(payloadText.contains("bookmark"))
        XCTAssertFalse(payloadText.contains("path"))
    }

    func testConnectJobInsertFailureRollsBackSourceAndJob() async throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        try FolderAuthorizationTestSupport.AuthorizationDatabaseTestFaults
            .installConnectJobInsertAbortTrigger(database)

        let root = try registry.makeRoot(label: "connect-fault")
        let picker = FolderAuthorizationTestSupport.FakeDirectoryPicker()
        let (coordinator, _, _, _) = FolderAuthorizationTestSupport.makeCoordinator(
            database: database,
            picker: picker,
            ids: [UUID(), UUID()]
        )
        picker.configuredResponses = [root]

        do {
            _ = try await coordinator.connectFolder()
            XCTFail("Expected persistenceFailure")
        } catch {
            XCTAssertEqual(error as? FolderAuthorizationError, .persistenceFailure)
            FolderAuthorizationTestSupport.assertErrorDescriptionIsSanitized(error)
        }
        XCTAssertEqual(try FolderAuthorizationTestSupport.sourceCount(database), 0)
        XCTAssertEqual(try FolderAuthorizationTestSupport.jobCount(database), 0)
    }

    func testFoundationRelationshipDetectsSameAncestorAndDescendantOverlap() throws {
        let checker = FoundationFolderRootRelationshipChecker()
        let parent = try registry.makeRoot(label: "parent")
        let child = parent.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)

        XCTAssertEqual(checker.relationship(between: parent, and: parent), .same)
        XCTAssertEqual(checker.relationship(between: child, and: parent), .existingAncestor)
        XCTAssertEqual(checker.relationship(between: parent, and: child), .newAncestor)
    }

    func testOverlapSameAncestorAndDescendantRejectWithoutWrites() async throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let parent = try registry.makeRoot(label: "parent")
        let child = parent.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)

        let existingID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let bookmarkPort = FoundationSecurityScopedBookmarkAdapter()
        try FolderAuthorizationTestSupport.insertFolderSource(
            database: database,
            sourceID: existingID,
            bookmark: try bookmarkPort.createReadOnlyBookmark(for: parent)
        )

        let picker = FolderAuthorizationTestSupport.FakeDirectoryPicker()
        let (coordinator, _, _, _) = FolderAuthorizationTestSupport.makeCoordinator(
            database: database,
            picker: picker
        )

        for candidate in [parent, child] {
            picker.configuredResponses = [candidate]
            do {
                _ = try await coordinator.connectFolder()
                XCTFail("Expected overlap")
            } catch {
                XCTAssertEqual(error as? FolderAuthorizationError, .sourceOverlap, "Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try FolderAuthorizationTestSupport.sourceCount(database), 1)
        XCTAssertEqual(try FolderAuthorizationTestSupport.jobCount(database), 0)
    }

    func testDisjointRootsAcceptSecondSource() async throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let first = try registry.makeRoot(label: "first")
        let second = try registry.makeRoot(label: "second")
        let bookmarkPort = FoundationSecurityScopedBookmarkAdapter()
        let existingID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        try FolderAuthorizationTestSupport.insertFolderSource(
            database: database,
            sourceID: existingID,
            bookmark: try bookmarkPort.createReadOnlyBookmark(for: first)
        )

        let picker = FolderAuthorizationTestSupport.FakeDirectoryPicker()
        let newID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let jobID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        let (coordinator, _, _, _) = FolderAuthorizationTestSupport.makeCoordinator(
            database: database,
            picker: picker,
            ids: [newID, jobID]
        )
        picker.configuredResponses = [second]

        let outcome = try await coordinator.connectFolder()
        XCTAssertEqual(outcome, .connected(sourceID: newID))
        XCTAssertEqual(try FolderAuthorizationTestSupport.sourceCount(database), 2)
    }

    func testUnresolvableExistingBookmarkCausesOverlapIndeterminate() async throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let existingID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        try FolderAuthorizationTestSupport.insertFolderSource(
            database: database,
            sourceID: existingID,
            bookmark: Data([0x00, 0x01, 0x02])
        )

        let root = try registry.makeRoot(label: "new")
        let picker = FolderAuthorizationTestSupport.FakeDirectoryPicker()
        let bookmarkPort = FolderAuthorizationTestSupport.ScopeTrackingBookmarkPort()
        bookmarkPort.resolveFailure = true
        let (coordinator, _, _, _) = FolderAuthorizationTestSupport.makeCoordinator(
            database: database,
            picker: picker,
            bookmarkPort: bookmarkPort
        )
        picker.configuredResponses = [root]

        do {
            _ = try await coordinator.connectFolder()
            XCTFail("Expected indeterminate overlap")
        } catch {
            XCTAssertEqual(error as? FolderAuthorizationError, .overlapIndeterminate)
        }
        XCTAssertEqual(try FolderAuthorizationTestSupport.sourceCount(database), 1)
    }
}
