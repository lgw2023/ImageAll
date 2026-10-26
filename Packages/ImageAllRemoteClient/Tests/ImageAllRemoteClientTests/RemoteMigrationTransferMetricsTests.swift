import XCTest
import ImageAllRemoteClient

final class RemoteMigrationTransferMetricsTests: XCTestCase {
    func testPhaseDurationsIncludeWaitingFreezeAtFinishAndResetForNextRun() {
        var meter = RemoteMigrationTransferMetrics()
        meter.enterPhase(.upload, at: 0) // ignore phase changes outside a run
        meter.begin(at: 10)
        meter.enterPhase(.upload, at: 20)
        meter.enterPhase(.upload, at: 23) // repeated ACK updates must not lose time
        meter.enterPhase(.recovery, at: 25)
        meter.enterPhase(.upload, at: 28)
        meter.enterPhase(.verification, at: 30)
        meter.enterPhase(.finalization, at: 35)
        meter.finish(at: 40)
        meter.enterPhase(.preparation, at: 90)
        let durations = meter.phaseSeconds(at: 100)
        XCTAssertEqual(durations, ["preparation": 10, "upload": 7, "recovery": 3,
                                   "verification": 5, "finalization": 5])
        XCTAssertEqual(durations.values.reduce(0, +), meter.elapsedSeconds(at: 100))
        meter.begin(at: 100)
        XCTAssertEqual(meter.phaseSeconds(at: 102)["preparation"], 2)
        XCTAssertEqual(meter.phaseSeconds(at: 102)["upload"], 0)
    }

    func testPreparationVerificationAndPausedTimeDoNotInflateUploadDuration() {
        var meter = RemoteMigrationTransferMetrics()
        meter.begin(at: 10)
        XCTAssertNil(meter.uploadBytesPerSecond(at: 30))
        meter.beginUpload(at: 30)
        meter.beginUpload(at: 31) // nested start does not lose the original timestamp
        meter.recordCommittedBytes(1_024)
        meter.endUpload(at: 32)
        XCTAssertEqual(meter.uploadBytesPerSecond(at: 60), 512)
        meter.beginUpload(at: 60)
        meter.recordCommittedBytes(1_024)
        meter.finish(at: 62)
        XCTAssertEqual(meter.activeUploadSeconds(at: 100), 4)
        XCTAssertEqual(meter.elapsedSeconds(at: 100), 52)
        XCTAssertEqual(meter.uploadBytesPerSecond(at: 100), 512)
        meter.begin(at: 100)
        XCTAssertEqual(meter.confirmedBytes, 0)
        XCTAssertNil(meter.uploadBytesPerSecond(at: 100))
    }
}
