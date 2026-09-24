@testable import ImageAllRemoteClient
import ImageAllRemoteProtocol
import XCTest

final class RemoteEventRecoveryStateMachineTests: XCTestCase {
    func testUnexpectedDisconnectReconnectsAndReturnsToConnected() {
        var machine = RemoteEventRecoveryStateMachine()
        let generation = machine.beginConnection()
        XCTAssertTrue(machine.markConnected(generation: generation))

        let retry = machine.unexpectedDisconnect(generation: generation)

        XCTAssertEqual(
            retry,
            RemoteEventRetryPlan(
                generation: generation,
                attempt: 1,
                delaySeconds: 1,
                health: .reconnecting(attempt: 1)
            )
        )
        XCTAssertTrue(machine.markConnected(generation: generation))
        XCTAssertEqual(machine.health, .connected)
    }

    func testActiveStopRejectsOldSocketAndRetryCallbacks() {
        var machine = RemoteEventRecoveryStateMachine()
        let generation = machine.beginConnection()

        machine.stop()

        XCTAssertNil(machine.unexpectedDisconnect(generation: generation))
        XCTAssertNil(machine.retryFailed(generation: generation))
        XCTAssertFalse(machine.markConnected(generation: generation))
        XCTAssertEqual(machine.health, .stopped)
        XCTAssertFalse(machine.automaticRecoveryEnabled)
    }

    func testContinuousFailuresEnterOfflineAndCapBackoff() {
        var machine = RemoteEventRecoveryStateMachine()
        let generation = machine.beginConnection()

        var plan = machine.unexpectedDisconnect(generation: generation)
        XCTAssertEqual(plan?.delaySeconds, 1)
        XCTAssertEqual(plan?.health, .reconnecting(attempt: 1))

        plan = machine.retryFailed(generation: generation)
        XCTAssertEqual(plan?.delaySeconds, 2)
        XCTAssertEqual(plan?.health, .reconnecting(attempt: 2))

        plan = machine.retryFailed(generation: generation)
        XCTAssertEqual(plan?.delaySeconds, 4)
        XCTAssertEqual(plan?.health, .hostOffline(attempt: 3))

        for _ in 0..<8 {
            plan = machine.retryFailed(generation: generation)
        }
        XCTAssertEqual(plan?.delaySeconds, 30)
        guard case .hostOffline = plan?.health else {
            return XCTFail("expected offline health")
        }
    }

    func testRefreshCanOnlyBeClaimedOncePerGeneration() {
        var machine = RemoteEventRecoveryStateMachine()
        let first = machine.beginConnection()

        XCTAssertTrue(machine.claimRefreshAttempt(generation: first))
        XCTAssertFalse(machine.claimRefreshAttempt(generation: first))

        let second = machine.beginConnection()
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(machine.claimRefreshAttempt(generation: first))
        XCTAssertTrue(machine.claimRefreshAttempt(generation: second))
    }

    func testSuspendInvalidatesOldGenerationAndResumeIsImmediate() {
        var machine = RemoteEventRecoveryStateMachine()
        let first = machine.beginConnection()
        XCTAssertTrue(machine.markConnected(generation: first))

        machine.suspend()
        XCTAssertNil(machine.unexpectedDisconnect(generation: first))
        guard case .hostOffline = machine.health else {
            return XCTFail("expected offline while suspended")
        }

        let retry = machine.resumeImmediately()
        XCTAssertEqual(retry?.delaySeconds, 0)
        XCTAssertEqual(retry?.health, .reconnecting(attempt: 1))
        XCTAssertNotEqual(retry?.generation, first)
    }

    func testEventSocketRejectsMalformedPinnedFingerprintBeforeConnecting() throws {
        let socket = RemoteEventSocket()
        let endpoint = try RemoteHostEndpoint(
            host: "127.0.0.1",
            port: 8787,
            accessToken: "fixture",
            usesTLS: true
        )

        XCTAssertThrowsError(
            try socket.connect(
                endpoint: endpoint,
                certificateFingerprintSHA256: "not-a-fingerprint",
                onEvent: { _ in },
                onStateChange: { _ in }
            )
        ) { error in
            XCTAssertEqual((error as? RemoteAPIError)?.code, .badRequest)
        }
    }

    func testEventSocketLifecycleRejectsCallbacksFromReplacedConnection() {
        var lifecycle = RemoteEventSocketLifecycle()
        let first = lifecycle.activate()

        XCTAssertTrue(lifecycle.allows(first))

        lifecycle.invalidate()
        let second = lifecycle.activate()

        XCTAssertFalse(lifecycle.allows(first))
        XCTAssertTrue(lifecycle.allows(second))
        XCTAssertNotEqual(first, second)
    }
}
