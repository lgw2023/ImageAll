import XCTest
import ImageAllRemoteClient

final class RemoteMigrationDiagnosticHeartbeatTests: XCTestCase {
    @MainActor
    func testLongVerificationTicksAndStopCannotOverwriteTerminalOrNextAttempt() async throws {
        let heartbeat = RemoteMigrationDiagnosticHeartbeat()
        var outcome = "verification"
        let first = expectation(description: "long verification remains observable")
        heartbeat.start(interval: .milliseconds(10)) {
            outcome = "running"
            heartbeat.stop()
            first.fulfill()
        }
        await fulfillment(of: [first], timeout: 2)
        XCTAssertEqual(outcome, "running")
        XCTAssertFalse(heartbeat.isRunning)
        outcome = "received"
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(outcome, "received")

        heartbeat.start(interval: .milliseconds(10)) { XCTFail("replaced attempt must not tick") }
        let next = expectation(description: "next attempt has one active heartbeat")
        heartbeat.start(interval: .milliseconds(10)) {
            heartbeat.stop()
            next.fulfill()
        }
        await fulfillment(of: [next], timeout: 2)
        XCTAssertFalse(heartbeat.isRunning)
    }
}
