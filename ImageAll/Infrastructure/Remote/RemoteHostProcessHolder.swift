import Foundation
import ImageAllRemoteProtocol
import os

/// Process-scoped remote host lifecycle. Kept out of `LibraryWorkspaceModel` on purpose.
///
/// Per ADR-044, Release builds are no longer hard-closed: the same user-facing defaults
/// switch as Debug governs whether the host attempts to start, but Release additionally
/// requires an already-established TLS identity (no cleartext fallback outside Debug).
enum RemoteHostProcessHolder {
    private static let logger = Logger(subsystem: "com.gwlee.ImageAll", category: "RemoteHost")
    private static let enabledKey = "imageall.remoteHost.enabled"
    private static let legacyDebugTokenKey = "imageall.remoteHost.accessToken"
    private static let portKey = "imageall.remoteHost.port"
    private static let state = State()

    private actor State {
        var server: RemoteHTTPServer?
        var pairingStore: RemotePairingStore?
        var eventBroker: RemoteEventBroker?
        var identity: RemoteHostIdentity?

        func replace(
            server: RemoteHTTPServer?,
            pairingStore: RemotePairingStore?,
            eventBroker: RemoteEventBroker?,
            identity: RemoteHostIdentity?
        ) async {
            await self.server?.stop()
            self.server = server
            self.pairingStore = pairingStore
            self.eventBroker = eventBroker
            self.identity = identity
        }
    }

    /// Attach catalog + review ports and optionally start the LAN helper host.
    /// Enable with `defaults write com.gwlee.ImageAll imageall.remoteHost.enabled -bool YES`
    /// or environment `IMAGEALL_REMOTE_HOST=1`.
    static func attach(
        catalog: any RemoteCatalogServing,
        review: any PersonalizationReviewPort,
        hostAppVersion: String
    ) {
        guard isEnabled() else {
            Task { await state.replace(server: nil, pairingStore: nil, eventBroker: nil, identity: nil) }
            logger.info("Remote host disabled")
            return
        }

        let defaults = UserDefaults.standard
        let identity = RemoteHostIdentity.loadOrCreate(defaults: defaults)

#if !DEBUG
        guard identity.usesTLS else {
            logger.error(
                "Remote host enabled but no TLS identity is available; refusing to start cleartext in a Release build"
            )
            Task { await state.replace(server: nil, pairingStore: nil, eventBroker: nil, identity: identity) }
            return
        }
#endif

        let configuredPort = defaults.object(forKey: portKey) as? Int
            ?? Int(RemoteHTTPServer.defaultPort)
        let port = UInt16(exactly: configuredPort) ?? RemoteHTTPServer.defaultPort
        let legacyDebugToken = existingOrCreateLegacyDebugToken(defaults: defaults)

        let hostContext = RemotePairingStore.HostContext(
            hostID: identity.hostID,
            hostDisplayName: RemoteHTTPServer.defaultAdvertisementName(),
            listenPort: Int(port),
            usesTLS: identity.usesTLS,
            certificateFingerprintSHA256: identity.certificateFingerprintSHA256
        )
        let pairingStore = RemotePairingStore(
            hostContext: hostContext,
            storageURL: remoteHostDirectory().appendingPathComponent("pairing.json"),
            legacyDebugToken: legacyDebugToken
        )
        let idempotency = RemoteIdempotencyStore(
            storageURL: remoteHostDirectory().appendingPathComponent("idempotency.json")
        )
        let eventBroker = RemoteEventBroker()
        let facade = RemoteCatalogFacade(
            catalog: catalog,
            review: review,
            idempotency: idempotency,
            hostAppVersion: hostAppVersion,
            listenPort: Int(port),
            hostID: identity.hostID,
            usesTLS: identity.usesTLS,
            certificateFingerprintSHA256: identity.usesTLS ? identity.certificateFingerprintSHA256 : nil
        )
        let server = RemoteHTTPServer(
            facade: facade,
            pairingStore: pairingStore,
            eventBroker: eventBroker,
            secIdentity: identity.secIdentity,
            port: port,
            hostID: identity.hostID
        )
        Task {
            do {
                try await server.start()
                await state.replace(
                    server: server,
                    pairingStore: pairingStore,
                    eventBroker: eventBroker,
                    identity: identity
                )
                logger.info(
                    "Remote host ready on port \(port, privacy: .public); tls=\(identity.usesTLS, privacy: .public)"
                )
            } catch {
                logger.error("Remote host failed to start: \(String(describing: error), privacy: .public)")
            }
        }
    }

    static func isEnabled() -> Bool {
        if ProcessInfo.processInfo.environment["IMAGEALL_REMOTE_HOST"] == "1" {
            return true
        }
        return UserDefaults.standard.bool(forKey: enabledKey)
    }

    static func currentAccessToken() -> String? {
#if DEBUG
        UserDefaults.standard.string(forKey: legacyDebugTokenKey)
#else
        nil
#endif
    }

    // MARK: - Mac UI surface (Debug/Settings panel)

    /// Starts (or restarts) a pairing session and returns the offer to render as a QR code
    /// / passcode. Returns `nil` if the host is not currently running.
    static func startPairingSession(
        ttl: TimeInterval = RemotePairingStore.defaultOfferLifetime
    ) async -> RemotePairingOffer? {
        guard let pairingStore = await state.pairingStore else { return nil }
        return await pairingStore.issueOffer(ttl: ttl)
    }

    static func currentOffer() async -> RemotePairingOffer? {
        await state.pairingStore?.currentOffer()
    }

    static func cancelPairingSession() async {
        await state.pairingStore?.cancelOffer()
    }

    static func pairedDevices() async -> [RemotePairedDeviceSummary] {
        await state.pairingStore?.listDevices() ?? []
    }

    static func revoke(deviceID: UUID) async {
        await state.pairingStore?.revoke(deviceID: deviceID)
    }

    struct IdentitySummary: Equatable {
        let hostID: UUID
        let usesTLS: Bool
        let certificateFingerprintSHA256: String
    }

    static func identitySummary() async -> IdentitySummary? {
        guard let identity = await state.identity else { return nil }
        return IdentitySummary(
            hostID: identity.hostID,
            usesTLS: identity.usesTLS,
            certificateFingerprintSHA256: identity.certificateFingerprintSHA256
        )
    }

    static func isRunning() async -> Bool {
        await state.server != nil
    }

    // MARK: - Internals

    private static func remoteHostDirectory() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("ImageAll", isDirectory: true)
            .appendingPathComponent("RemoteHost", isDirectory: true)
    }

    private static func existingOrCreateLegacyDebugToken(defaults: UserDefaults) -> String? {
#if DEBUG
        if let existing = defaults.string(forKey: legacyDebugTokenKey), !existing.isEmpty {
            return existing
        }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        defaults.set(token, forKey: legacyDebugTokenKey)
        return token
#else
        return nil
#endif
    }
}
