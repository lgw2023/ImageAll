import Foundation
import ImageAllRemoteClient
import ImageAllRemoteProtocol
import XCTest

final class RemotePairingPayloadDecoderTests: XCTestCase {
    private let hostID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!

    func testDecodesCurrentMacQRCodePayload() throws {
        let offer = makeOffer()
        let payload = try XCTUnwrap(String(data: JSONEncoder().encode(offer), encoding: .utf8))

        let decoded = try RemotePairingPayloadDecoder.decode(
            "  \n\(payload)\n",
            nowMs: 1_000
        )

        XCTAssertEqual(decoded, offer)
    }

    func testRejectsExpiredPayloadBeforeMakingNetworkRequest() throws {
        let payload = try XCTUnwrap(
            String(data: JSONEncoder().encode(makeOffer(expiresAtMs: 999)), encoding: .utf8)
        )

        XCTAssertThrowsError(
            try RemotePairingPayloadDecoder.decode(payload, nowMs: 1_000)
        ) { error in
            XCTAssertEqual(error as? RemotePairingPayloadError, .expired)
        }
    }

    func testRejectsUnsupportedProtocolVersion() throws {
        let payload = try XCTUnwrap(
            String(
                data: JSONEncoder().encode(
                    makeOffer(protocolVersion: RemoteProtocolVersion.current + 1)
                ),
                encoding: .utf8
            )
        )

        XCTAssertThrowsError(
            try RemotePairingPayloadDecoder.decode(payload, nowMs: 1_000)
        ) { error in
            XCTAssertEqual(error as? RemotePairingPayloadError, .unsupportedProtocol)
        }
    }

    func testRejectsTLSPayloadWithoutFingerprint() throws {
        let payload = try XCTUnwrap(
            String(
                data: JSONEncoder().encode(makeOffer(certificateFingerprint: "")),
                encoding: .utf8
            )
        )

        XCTAssertThrowsError(
            try RemotePairingPayloadDecoder.decode(payload, nowMs: 1_000)
        ) { error in
            XCTAssertEqual(error as? RemotePairingPayloadError, .missingTLSFingerprint)
        }
    }

    func testRejectsTLSFingerprintWithUnexpectedCharacters() throws {
        let fingerprint = String(repeating: "ab", count: 32) + "-unexpected"
        let payload = try XCTUnwrap(
            String(
                data: JSONEncoder().encode(makeOffer(certificateFingerprint: fingerprint)),
                encoding: .utf8
            )
        )

        XCTAssertThrowsError(
            try RemotePairingPayloadDecoder.decode(payload, nowMs: 1_000)
        ) { error in
            XCTAssertEqual(error as? RemotePairingPayloadError, .invalidTLSFingerprint)
        }
    }

    func testAcceptsColonSeparatedTLSFingerprint() throws {
        let fingerprint = Array(repeating: "ab", count: 32).joined(separator: ":")
        let payload = try XCTUnwrap(
            String(
                data: JSONEncoder().encode(makeOffer(certificateFingerprint: fingerprint)),
                encoding: .utf8
            )
        )

        let decoded = try RemotePairingPayloadDecoder.decode(payload, nowMs: 1_000)

        XCTAssertEqual(decoded.certificateFingerprintSHA256, fingerprint)
    }

    func testRejectsMalformedPayload() {
        XCTAssertThrowsError(
            try RemotePairingPayloadDecoder.decode("not json", nowMs: 1_000)
        ) { error in
            XCTAssertEqual(error as? RemotePairingPayloadError, .malformed)
        }
    }

    private func makeOffer(
        certificateFingerprint: String = String(repeating: "ab", count: 32),
        expiresAtMs: Int64 = 2_000,
        protocolVersion: Int = RemoteProtocolVersion.current
    ) -> RemotePairingOffer {
        RemotePairingOffer(
            hostID: hostID,
            hostDisplayName: "Mac Studio",
            listenPort: 8787,
            usesTLS: true,
            certificateFingerprintSHA256: certificateFingerprint,
            pairingToken: "pair-token",
            expiresAtMs: expiresAtMs,
            protocolVersion: protocolVersion
        )
    }
}

final class RemoteSessionIdentityValidatorTests: XCTestCase {
    private let expectedHostID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
    private let expectedFingerprint = String(repeating: "ab", count: 32)

    func testAcceptsMatchingPairingSessionIdentity() throws {
        let tokens = makeTokens()

        XCTAssertNoThrow(
            try RemoteSessionIdentityValidator.validate(
                tokens,
                expectedHostID: expectedHostID,
                expectedUsesTLS: true,
                expectedCertificateFingerprintSHA256: expectedFingerprint
            )
        )
    }

    func testRejectsHostIdentityChange() {
        let tokens = makeTokens(hostID: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!)

        XCTAssertThrowsError(
            try RemoteSessionIdentityValidator.validate(
                tokens,
                expectedHostID: expectedHostID,
                expectedUsesTLS: true,
                expectedCertificateFingerprintSHA256: expectedFingerprint
            )
        ) { error in
            XCTAssertEqual(error as? RemoteSessionIdentityError, .hostIdentityMismatch)
        }
    }

    func testRejectsFingerprintChangeDuringRefresh() {
        let tokens = makeTokens(certificateFingerprint: String(repeating: "cd", count: 32))

        XCTAssertThrowsError(
            try RemoteSessionIdentityValidator.validate(
                tokens,
                expectedHostID: expectedHostID,
                expectedUsesTLS: true,
                expectedCertificateFingerprintSHA256: expectedFingerprint
            )
        ) { error in
            XCTAssertEqual(error as? RemoteSessionIdentityError, .tlsFingerprintMismatch)
        }
    }

    func testAllowsMissingExpectedHostIDForLegacyStoredSession() throws {
        XCTAssertNoThrow(
            try RemoteSessionIdentityValidator.validate(
                makeTokens(),
                expectedHostID: nil,
                expectedUsesTLS: true,
                expectedCertificateFingerprintSHA256: expectedFingerprint
            )
        )
    }

    private func makeTokens(
        hostID: UUID? = nil,
        certificateFingerprint: String? = nil
    ) -> RemoteSessionTokens {
        RemoteSessionTokens(
            deviceID: UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!,
            hostID: hostID ?? expectedHostID,
            accessToken: "access",
            accessExpiresAtMs: 2_000,
            refreshToken: "refresh",
            certificateFingerprintSHA256: certificateFingerprint ?? expectedFingerprint,
            usesTLS: true,
            listenPort: 8787
        )
    }
}
