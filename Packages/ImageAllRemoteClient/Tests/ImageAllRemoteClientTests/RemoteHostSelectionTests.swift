import Foundation
import ImageAllRemoteClient
import XCTest

final class RemoteHostSelectionTests: XCTestCase {
    private let expectedHostID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!

    func testPrefersExactHostIdentityOverSameDisplayName() throws {
        let wrongHost = makeHost(
            name: "Mac Studio",
            address: "192.0.2.10",
            hostID: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
        )
        let expectedHost = makeHost(
            name: "Renamed Mac",
            address: "192.0.2.11",
            hostID: expectedHostID
        )

        let selected = RemoteHostSelection.bestMatch(
            hostID: expectedHostID,
            displayName: "Mac Studio",
            in: [wrongHost, expectedHost]
        )

        XCTAssertEqual(selected, expectedHost)
    }

    func testDoesNotUseSameNameFallbackForDifferentAdvertisedIdentity() {
        let wrongHost = makeHost(
            name: "Mac Studio",
            address: "192.0.2.10",
            hostID: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
        )

        let selected = RemoteHostSelection.bestMatch(
            hostID: expectedHostID,
            displayName: "Mac Studio",
            in: [wrongHost]
        )

        XCTAssertNil(selected)
    }

    func testUsesSameNameFallbackForLegacyAdvertisementWithoutHostIdentity() {
        let legacyHost = makeHost(
            name: "Mac Studio",
            address: "192.0.2.12",
            hostID: nil
        )

        let selected = RemoteHostSelection.bestMatch(
            hostID: expectedHostID,
            displayName: "mac studio",
            in: [legacyHost]
        )

        XCTAssertEqual(selected, legacyHost)
    }

    func testMatchesStoredPairingOnlyByExactHostIdentity() {
        let expectedHost = makeHost(
            name: "Mac Studio",
            address: "192.0.2.13",
            hostID: expectedHostID
        )

        XCTAssertEqual(
            RemoteHostSelection.bestMatch(hostID: expectedHostID, in: [expectedHost]),
            expectedHost
        )
    }

    func testPairingRejectsLoopbackWhenNoMatchingHostWasDiscovered() {
        XCTAssertThrowsError(
            try RemotePairingHostResolver.resolve(
                hostID: expectedHostID,
                displayName: "Mac Studio",
                currentHost: "127.0.0.1",
                discoveredHosts: []
            )
        ) { error in
            XCTAssertEqual(error as? RemotePairingHostError, .lanAddressRequired)
        }
    }

    func testPairingUsesExplicitLANAddressWhenNoMatchingHostWasDiscovered() throws {
        let resolved = try RemotePairingHostResolver.resolve(
            hostID: expectedHostID,
            displayName: "Mac Studio",
            currentHost: " 192.0.2.20 ",
            discoveredHosts: []
        )

        XCTAssertEqual(resolved, "192.0.2.20")
    }

    private func makeHost(
        name: String,
        address: String,
        hostID: UUID?
    ) -> RemoteDiscoveredHost {
        RemoteDiscoveredHost(
            name: name,
            domain: "local.",
            host: address,
            port: 8787,
            protocolVersion: 2,
            hostID: hostID
        )
    }
}
