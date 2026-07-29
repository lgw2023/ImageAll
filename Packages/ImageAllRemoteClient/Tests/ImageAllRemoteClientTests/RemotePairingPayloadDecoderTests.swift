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
