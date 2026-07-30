import Foundation
import ImageAllRemoteProtocol
import XCTest
@testable import ImageAll

final class RemotePairingStoreTests: XCTestCase {
    private func tempStorageURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("RemotePairingStoreTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("pairing.json")
    }

    private func makeContext(
        hostID: UUID = UUID(),
        publicBaseURL: String? = nil
    ) -> RemotePairingStore.HostContext {
        RemotePairingStore.HostContext(
            hostID: hostID,
            hostDisplayName: "Test Host",
            listenPort: 8787,
            usesTLS: true,
            certificateFingerprintSHA256: "fingerprint",
            publicBaseURL: publicBaseURL
        )
    }

    func testAccessAccountWhitelistAuthenticatesOnlyPersistedCorrectCredentials() async throws {
        let storageURL = tempStorageURL()
            .deletingLastPathComponent()
            .appendingPathComponent("access-accounts.json")
        let firstStore = RemoteAccessAccountStore(
            storageURL: storageURL,
            passwordHashIterations: 100
        )

        let account = try await firstStore.upsert(
            username: "photo-owner",
            password: "correct horse battery staple"
        )

        XCTAssertEqual(account.username, "photo-owner")
        let accountNames = await firstStore.listAccounts().map(\.username)
        let correctCredentials = await firstStore.authenticate(
            username: "photo-owner",
            password: "correct horse battery staple"
        )
        let wrongPassword = await firstStore.authenticate(
            username: "photo-owner",
            password: "wrong-password"
        )
        let unknownAccount = await firstStore.authenticate(
            username: "not-whitelisted",
            password: "correct horse battery staple"
        )
        XCTAssertEqual(accountNames, ["photo-owner"])
        XCTAssertTrue(correctCredentials)
        XCTAssertFalse(wrongPassword)
        XCTAssertFalse(unknownAccount)

        let restartedStore = RemoteAccessAccountStore(
            storageURL: storageURL,
            passwordHashIterations: 100
        )
        let persistedCredentials = await restartedStore.authenticate(
            username: "photo-owner",
            password: "correct horse battery staple"
        )
        XCTAssertTrue(persistedCredentials)
    }

    func testAccessAccountPasswordUpdateAndRemovalTakeEffectImmediately() async throws {
        let store = RemoteAccessAccountStore(
            storageURL: tempStorageURL()
                .deletingLastPathComponent()
                .appendingPathComponent("access-accounts.json"),
            passwordHashIterations: 100
        )
        _ = try await store.upsert(username: "web-owner", password: "first-password")
        let initiallyAuthorized = await store.authenticate(
            username: "web-owner",
            password: "first-password"
        )
        XCTAssertTrue(initiallyAuthorized)

        _ = try await store.upsert(username: "web-owner", password: "second-password")
        let oldPasswordAuthorized = await store.authenticate(
            username: "web-owner",
            password: "first-password"
        )
        let newPasswordAuthorized = await store.authenticate(
            username: "web-owner",
            password: "second-password"
        )
        XCTAssertFalse(oldPasswordAuthorized)
        XCTAssertTrue(newPasswordAuthorized)

        try await store.remove(username: "web-owner")
        let removedAccountAuthorized = await store.authenticate(
            username: "web-owner",
            password: "second-password"
        )
        XCTAssertFalse(removedAccountAuthorized)
        let accounts = await store.listAccounts()
        XCTAssertTrue(accounts.isEmpty)
    }

    func testCompletePairingConsumesOfferAndIssuesTokens() async throws {
        let store = RemotePairingStore(hostContext: makeContext(), storageURL: tempStorageURL())
        let offer = await store.issueOffer()

        let tokens = try await store.completePairing(
            RemotePairingCompleteRequest(
                pairingToken: offer.pairingToken,
                deviceName: "iPhone 15",
                devicePublicKeySPKI_SHA256: "pubkey-hash"
            )
        )

        XCTAssertFalse(tokens.accessToken.isEmpty)
        XCTAssertFalse(tokens.refreshToken.isEmpty)
        XCTAssertEqual(tokens.certificateFingerprintSHA256, "fingerprint")

        // Single-use: the same offer cannot be completed twice.
        let currentOffer = await store.currentOffer()
        XCTAssertNil(currentOffer)

        let devices = await store.listDevices()
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.deviceName, "iPhone 15")

        let outcome = await store.authenticate(bearer: tokens.accessToken)
        XCTAssertEqual(outcome, .device(tokens.deviceID))
    }

    func testExpiredOfferIsRejected() async throws {
        let store = RemotePairingStore(hostContext: makeContext(), storageURL: tempStorageURL())
        let offer = await store.issueOffer(ttl: -1)

        do {
            _ = try await store.completePairing(
                RemotePairingCompleteRequest(
                    pairingToken: offer.pairingToken,
                    deviceName: "iPhone",
                    devicePublicKeySPKI_SHA256: "pubkey-hash"
                )
            )
            XCTFail("expected noActiveOffer")
        } catch let error as RemotePairingStore.PairingError {
            XCTAssertEqual(error, .noActiveOffer)
        }
    }

    func testMismatchedPairingTokenIsRejected() async throws {
        let store = RemotePairingStore(hostContext: makeContext(), storageURL: tempStorageURL())
        _ = await store.issueOffer()

        do {
            _ = try await store.completePairing(
                RemotePairingCompleteRequest(
                    pairingToken: "wrong-token",
                    deviceName: "iPhone",
                    devicePublicKeySPKI_SHA256: "pubkey-hash"
                )
            )
            XCTFail("expected invalidToken")
        } catch let error as RemotePairingStore.PairingError {
            XCTAssertEqual(error, .invalidToken)
        }

        // The offer is only consumed once a token actually matches.
        let currentOffer = await store.currentOffer()
        XCTAssertNotNil(currentOffer)
    }

    func testRefreshRotatesTokensAndRejectsStaleRefreshToken() async throws {
        let store = RemotePairingStore(hostContext: makeContext(), storageURL: tempStorageURL())
        let offer = await store.issueOffer()
        let initial = try await store.completePairing(
            RemotePairingCompleteRequest(
                pairingToken: offer.pairingToken,
                deviceName: "iPhone",
                devicePublicKeySPKI_SHA256: "pubkey-hash"
            )
        )

        let refreshed = try await store.refresh(
            RemoteTokenRefreshRequest(deviceID: initial.deviceID, refreshToken: initial.refreshToken)
        )
        XCTAssertNotEqual(refreshed.accessToken, initial.accessToken)
        XCTAssertNotEqual(refreshed.refreshToken, initial.refreshToken)

        do {
            _ = try await store.refresh(
                RemoteTokenRefreshRequest(deviceID: initial.deviceID, refreshToken: initial.refreshToken)
            )
            XCTFail("expected invalidRefreshToken after rotation")
        } catch let error as RemotePairingStore.PairingError {
            XCTAssertEqual(error, .invalidRefreshToken)
        }
    }

    func testPublicEndpointIsBoundIntoOfferAndRotatedSession() async throws {
        let publicURL = "https://imageall.ultrahardcore.net"
        let store = RemotePairingStore(
            hostContext: makeContext(publicBaseURL: publicURL),
            storageURL: tempStorageURL()
        )
        let offer = await store.issueOffer()
        XCTAssertEqual(offer.publicBaseURL, publicURL)

        let initial = try await store.completePairing(
            RemotePairingCompleteRequest(
                pairingToken: offer.pairingToken,
                deviceName: "iPhone",
                devicePublicKeySPKI_SHA256: "pubkey-hash"
            )
        )
        XCTAssertEqual(initial.publicBaseURL, publicURL)

        let refreshed = try await store.refresh(
            RemoteTokenRefreshRequest(
                deviceID: initial.deviceID,
                refreshToken: initial.refreshToken
            )
        )
        XCTAssertEqual(refreshed.publicBaseURL, publicURL)
    }

    func testRevokeInvalidatesAccessTokenAndRemovesDevice() async throws {
        let store = RemotePairingStore(hostContext: makeContext(), storageURL: tempStorageURL())
        let offer = await store.issueOffer()
        let tokens = try await store.completePairing(
            RemotePairingCompleteRequest(
                pairingToken: offer.pairingToken,
                deviceName: "iPhone",
                devicePublicKeySPKI_SHA256: "pubkey-hash"
            )
        )

        await store.revoke(deviceID: tokens.deviceID)

        let outcome = await store.authenticate(bearer: tokens.accessToken)
        XCTAssertEqual(outcome, .unauthorized)
        let devices = await store.listDevices()
        XCTAssertTrue(devices.isEmpty)
    }

    func testLegacyDebugTokenAuthenticatesWithoutPairing() async throws {
        let store = RemotePairingStore(
            hostContext: makeContext(),
            storageURL: tempStorageURL(),
            legacyDebugToken: "debug-secret"
        )

        let outcome = await store.authenticate(bearer: "debug-secret")
        XCTAssertEqual(outcome, .legacyDebugToken)

        let wrongOutcome = await store.authenticate(bearer: "not-the-secret")
        XCTAssertEqual(wrongOutcome, .unauthorized)
    }

    func testPairedDevicesSurviveAcrossStoreInstancesViaDiskPersistence() async throws {
        let storageURL = tempStorageURL()
        let hostID = UUID()
        let firstStore = RemotePairingStore(hostContext: makeContext(hostID: hostID), storageURL: storageURL)
        let offer = await firstStore.issueOffer()
        let tokens = try await firstStore.completePairing(
            RemotePairingCompleteRequest(
                pairingToken: offer.pairingToken,
                deviceName: "iPad",
                devicePublicKeySPKI_SHA256: "pubkey-hash"
            )
        )

        // Simulates a Mac Host process restart: a fresh store instance reloads persisted devices.
        let secondStore = RemotePairingStore(hostContext: makeContext(hostID: hostID), storageURL: storageURL)
        let devices = await secondStore.listDevices()
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.deviceID, tokens.deviceID)

        // The prior access token does not survive (process-scoped only); refresh still works.
        let refreshed = try await secondStore.refresh(
            RemoteTokenRefreshRequest(deviceID: tokens.deviceID, refreshToken: tokens.refreshToken)
        )
        XCTAssertFalse(refreshed.accessToken.isEmpty)
    }
}
