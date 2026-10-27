import XCTest
import Network
@testable import ImageAllRemoteProtocol

final class ImageAllUSBWireTests: XCTestCase, @unchecked Sendable {
    private func offer() -> RemotePairingOffer {
        .init(hostID: UUID(), hostDisplayName: "Synthetic Mac", listenPort: 8787, usesTLS: true,
              certificateFingerprintSHA256: String(repeating: "a", count: 64), pairingToken: "synthetic-only",
              expiresAtMs: Int64(Date().addingTimeInterval(120).timeIntervalSince1970 * 1000))
    }
    func testValidControlAndDataHeadersRoundTrip() throws {
        for hello in [ImageAllUSBHello(role: .control, sessionKey: String(repeating: "1", count: 64), offer: offer()),
                      ImageAllUSBHello(role: .data, sessionKey: String(repeating: "1", count: 64))] {
            let framed = try hello.framed()
            XCTAssertEqual(try ImageAllUSBHello.decode(Data(framed.dropFirst(4))), hello)
            XCTAssertEqual(framed.prefix(4).reduce(0) { ($0 << 8) | Int($1) }, framed.count - 4)
        }
    }
    func testRejectsInvalidIdentityRoleAndOversizedHeaders() throws {
        XCTAssertThrowsError(try ImageAllUSBHello(role: .control, sessionKey: "short", offer: offer()).framed())
        XCTAssertThrowsError(try ImageAllUSBHello(role: .control, sessionKey: String(repeating: "1", count: 64)).framed())
        XCTAssertThrowsError(try ImageAllUSBHello(role: .data, sessionKey: String(repeating: "1", count: 64), offer: offer()).framed())
        XCTAssertThrowsError(try ImageAllUSBHello.decode(Data(repeating: 0, count: ImageAllUSBHello.maximumHeaderBytes + 1)))
    }
    func testSavedPairingRequiresMatchingHostAndCertificate() {
        let candidate = offer()
        XCTAssertNil(ImageAllUSBPairingConflict.detect(hasStoredPairing: false, storedHostID: nil, storedFingerprint: nil, offer: candidate))
        XCTAssertNil(ImageAllUSBPairingConflict.detect(hasStoredPairing: true, storedHostID: candidate.hostID.uuidString.lowercased(), storedFingerprint: candidate.certificateFingerprintSHA256.uppercased(), offer: candidate))
        XCTAssertEqual(ImageAllUSBPairingConflict.detect(hasStoredPairing: true, storedHostID: UUID().uuidString, storedFingerprint: candidate.certificateFingerprintSHA256, offer: candidate), .differentHost)
        XCTAssertEqual(ImageAllUSBPairingConflict.detect(hasStoredPairing: true, storedHostID: candidate.hostID.uuidString, storedFingerprint: String(repeating: "b", count: 64), offer: candidate), .differentCertificate)
        XCTAssertEqual(ImageAllUSBPairingConflict.detect(hasStoredPairing: true, storedHostID: nil, storedFingerprint: nil, offer: candidate), .missingSavedIdentity)
    }
    func testAutomaticResumeRequiresCompleteExistingTrustAndLiveOffer() {
        let candidate = offer(), device = UUID().uuidString
        func allowed(paired: Bool = true, deviceID: String? = nil, tls: Bool = true,
                     hostID: String? = nil, pin: String? = nil, now: Int64 = 0) -> Bool {
            ImageAllUSBAutomaticResume.permits(hasStoredPairing: paired,
                storedDeviceID: deviceID ?? device, storedUsesTLS: tls,
                storedHostID: hostID ?? candidate.hostID.uuidString,
                storedFingerprint: pin ?? candidate.certificateFingerprintSHA256,
                offer: candidate, nowMs: now)
        }
        XCTAssertTrue(allowed())
        XCTAssertFalse(allowed(paired: false), "First pairing must be confirmed")
        XCTAssertFalse(allowed(deviceID: "missing"))
        XCTAssertFalse(allowed(tls: false))
        XCTAssertFalse(allowed(hostID: UUID().uuidString))
        XCTAssertFalse(allowed(pin: String(repeating: "b", count: 64)))
        XCTAssertFalse(allowed(pin: ""))
        XCTAssertFalse(allowed(now: candidate.expiresAtMs))
        XCTAssertFalse(ImageAllUSBAutomaticResume.permits(hasStoredPairing: true,
            storedDeviceID: device, storedUsesTLS: true, storedHostID: nil,
            storedFingerprint: nil, offer: candidate))
    }
    func testReplacementConsentCannotApplyToChangedClosedOrExpiredUSBRequest() {
        let candidate = offer(), transportID = UUID()
        let consent = ImageAllUSBPairingConsent(offer: candidate, transportID: transportID)
        XCTAssertTrue(consent.isCurrent(pendingOffer: candidate, transportID: transportID))
        XCTAssertFalse(consent.isCurrent(pendingOffer: candidate, transportID: UUID()))
        XCTAssertFalse(consent.isCurrent(pendingOffer: offer(), transportID: transportID))
        XCTAssertFalse(consent.isCurrent(pendingOffer: nil, transportID: transportID))
        XCTAssertFalse(consent.isCurrent(pendingOffer: candidate, transportID: transportID, nowMs: candidate.expiresAtMs))
    }
    func testApprovalTimeoutUsesOfferExpiryWithFiveMinuteBound() {
        let candidate = offer()
        let expiry = Date(timeIntervalSince1970: Double(candidate.expiresAtMs) / 1000)
        XCTAssertEqual(ImageAllUSBHello.approvalTimeoutSeconds(for: candidate, now: expiry.addingTimeInterval(-250)), 250)
        XCTAssertEqual(ImageAllUSBHello.approvalTimeoutSeconds(for: candidate, now: expiry.addingTimeInterval(-600)), 300)
        XCTAssertEqual(ImageAllUSBHello.approvalTimeoutSeconds(for: candidate, now: expiry), 1)
    }
    @MainActor
    func testBoundedReverseBridgeTransfersBytesAndClosesWithControl() async throws {
        let tunnel = ImageAllUSBPhoneTunnel()
        defer { tunnel.stop() }
        let ready = expectation(description: "loopback ready")
        let closed = expectation(description: "control disconnect stops bridge")
        var localPort: UInt16?
        tunnel.onOffer = { _ in try? tunnel.approve() }
        tunnel.onReady = { port, _ in localPort = port; ready.fulfill() }
        tunnel.onClosed = { _ in closed.fulfill() }
        try tunnel.start()
        let control = NWConnection(host: "127.0.0.1", port: .init(rawValue: ImageAllUSBHello.devicePort)!, using: .tcp)
        control.start(queue: .main)
        try await send(try ImageAllUSBHello(role: .control, sessionKey: String(repeating: "1", count: 64), offer: offer()).framed(), to: control)
        await fulfillment(of: [ready], timeout: 5)
        let controlAck = try await receive(control, count: 1)
        XCTAssertEqual(controlAck, Data([1]))
        guard let localPort else { XCTFail("No loopback port"); return }
        let remote = NWConnection(host: "127.0.0.1", port: .init(rawValue: ImageAllUSBHello.devicePort)!, using: .tcp)
        let local = NWConnection(host: "127.0.0.1", port: .init(rawValue: localPort)!, using: .tcp)
        defer { remote.cancel(); local.cancel() }
        remote.start(queue: .main); local.start(queue: .main)
        try await send(try ImageAllUSBHello(role: .data, sessionKey: String(repeating: "1", count: 64)).framed(), to: remote)
        let dataAck = try await receive(remote, count: 1)
        XCTAssertEqual(dataAck, Data([1]))
        let payload = Data((0..<1_048_576).map { UInt8($0 % 251) })
        async let transmitted: Void = send(payload, to: local)
        let received = try await receive(remote, count: payload.count)
        try await transmitted
        XCTAssertEqual(received, payload)
        // Half-close must drain the opposite direction rather than discard a
        // response that follows the request's final byte.
        try await finishWrites(local)
        let ended: Bool = try await withCheckedThrowingContinuation { continuation in
            remote.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, end, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: end) }
            }
        }
        XCTAssertTrue(ended)
        try await send(Data("verified".utf8), to: remote)
        let reply = try await receive(local, count: 8)
        XCTAssertEqual(reply, Data("verified".utf8))
        try await finishWrites(remote)
        control.cancel()
        await fulfillment(of: [closed], timeout: 5)
    }
    @MainActor
    func testRestartedListenerAcceptsOnlyCurrentSession() async throws {
        let tunnel = ImageAllUSBPhoneTunnel()
        defer { tunnel.stop() }
        let ready = expectation(description: "new listener remains usable")
        var closedReason = ""
        tunnel.onClosed = { closedReason = $0 }
        tunnel.onOffer = { _ in try? tunnel.approve() }
        tunnel.onReady = { _, _ in ready.fulfill() }
        try tunnel.start()
        tunnel.stop()
        try tunnel.start()
        for _ in 0..<100 where !tunnel.isListening {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(tunnel.isListening, closedReason)
        let control = NWConnection(host: "127.0.0.1",
            port: .init(rawValue: ImageAllUSBHello.devicePort)!, using: .tcp)
        defer { control.cancel() }
        control.start(queue: .main)
        try await send(try ImageAllUSBHello(role: .control,
            sessionKey: String(repeating: "3", count: 64), offer: offer()).framed(), to: control)
        await fulfillment(of: [ready], timeout: 5)
        let ack = try await receive(control, count: 1)
        XCTAssertEqual(ack, Data([1]))
    }

    @MainActor
    func testControlHeartbeatSurvivesMainActorBlockedPastMacDeadline() async throws {
        let tunnel = ImageAllUSBPhoneTunnel()
        defer { tunnel.stop() }
        let ready = expectation(description: "approved synthetic bridge")
        let closed = expectation(description: "explicit peer close still closes session")
        tunnel.onOffer = { _ in try? tunnel.approve() }
        tunnel.onReady = { _, _ in ready.fulfill() }
        tunnel.onClosed = { _ in closed.fulfill() }
        try tunnel.start()
        let control = NWConnection(host: "127.0.0.1",
            port: .init(rawValue: ImageAllUSBHello.devicePort)!, using: .tcp)
        control.start(queue: DispatchQueue(label: "USB.Heartbeat.TestPeer"))
        defer { control.cancel() }
        try await send(try ImageAllUSBHello(role: .control,
            sessionKey: String(repeating: "2", count: 64), offer: offer()).framed(), to: control)
        await fulfillment(of: [ready], timeout: 5)
        let ack = try await receive(control, count: 1)
        XCTAssertEqual(ack, Data([1]))
        let started = DispatchSemaphore(value: 0)
        let peer = Task.detached { [self] in
            let deadline = Task {
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
                control.cancel()
            }
            defer { deadline.cancel() }
            let start = ContinuousClock.now
            started.signal()
            try await send(Data([0x50]), to: control)
            let echoed = try await receive(control, count: 1)
            guard echoed == Data([0x50]) else { throw ImageAllUSBError.invalidHeader }
            return start.duration(to: .now)
        }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        // Simulate synchronous PhotoKit/catalog preparation on the UI actor.
        // The peer enforces the real Mac's 8-second control deadline.
        blockUIThread(seconds: 10)
        do {
            let elapsed = try await peer.value
            XCTAssertLessThan(elapsed, .seconds(8), "UI work must not close the USB control session")
        } catch {
            XCTFail("USB heartbeat stopped during UI preparation: \(error)")
        }
        control.cancel()
        await fulfillment(of: [closed], timeout: 5)
    }

    private func blockUIThread(seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

    private func send(_ data: Data, to connection: NWConnection) async throws {
        let deadline = Task.detached {
            do { try await Task.sleep(for: .seconds(5)); connection.cancel() } catch { }
        }
        defer { deadline.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    private func finishWrites(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    private func receive(_ connection: NWConnection, count: Int) async throws -> Data {
        var data = Data()
        while data.count < count {
            let size = count - data.count
            let part: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: size) { bytes, _, _, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let bytes, !bytes.isEmpty { continuation.resume(returning: bytes) }
                    else { continuation.resume(throwing: ImageAllUSBError.disconnected) }
                }
            }
            data.append(part)
        }
        return data
    }
}
