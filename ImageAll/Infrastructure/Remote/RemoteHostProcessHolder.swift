import Foundation
import ImageAllRemoteProtocol
import os

/// Process-scoped remote host lifecycle. Kept out of `LibraryWorkspaceModel` on purpose.
///
/// Per ADR-044, Release builds are no longer hard-closed: the same user-facing switch as
/// Debug governs whether the host runs, but Release additionally requires an
/// already-established TLS identity (no cleartext fallback outside Debug).
enum RemoteHostProcessHolder {
    private static let logger = Logger(subsystem: "com.gwlee.ImageAll", category: "RemoteHost")
    static let enabledKey = "imageall.remoteHost.enabled"
    private static let legacyDebugTokenKey = "imageall.remoteHost.accessToken"
    private static let portKey = "imageall.remoteHost.port"
    static let publicBaseURLKey = "imageall.remoteHost.publicBaseURL"
    private static let state = State()

    enum LifecycleResult: Equatable, Sendable {
        case running
        case stopped
        case waitingForAttachment
        case superseded
        case failed(String)
    }

    private struct Attachment: Sendable {
        let catalog: any RemoteCatalogServing
        let review: any PersonalizationReviewPort
        let hostAppVersion: String
    }

    private struct Runtime {
        let server: RemoteHTTPServer
        let pairingStore: RemotePairingStore
        let eventBroker: RemoteEventBroker
        let identity: RemoteHostIdentity
        let port: UInt16
        let hasPublicBaseURL: Bool
    }

    private enum StartupError: LocalizedError {
        case tlsIdentityUnavailable

        var errorDescription: String? {
            switch self {
            case .tlsIdentityUnavailable:
                return "Release 版本未能取得 Host TLS 身份"
            }
        }
    }

    private actor State {
        var attachment: Attachment?
        var server: RemoteHTTPServer?
        var pairingStore: RemotePairingStore?
        var eventBroker: RemoteEventBroker?
        var identity: RemoteHostIdentity?
        private var configurationGeneration = 0

        func attach(_ attachment: Attachment, enabled: Bool) async {
            self.attachment = attachment
            _ = await apply(enabled: enabled, forceRestart: true)
        }

        func apply(enabled: Bool, forceRestart: Bool) async -> LifecycleResult {
            configurationGeneration += 1
            let generation = configurationGeneration

            guard enabled else {
                await stopRuntime()
                return generation == configurationGeneration ? .stopped : .superseded
            }
            guard let attachment else {
                return .waitingForAttachment
            }
            if server != nil, !forceRestart {
                return .running
            }

            await stopRuntime()
            guard generation == configurationGeneration else {
                return .superseded
            }

            do {
                let runtime = try RemoteHostProcessHolder.makeRuntime(attachment: attachment)
                server = runtime.server
                pairingStore = runtime.pairingStore
                eventBroker = runtime.eventBroker
                identity = runtime.identity
                try await runtime.server.start()

                guard generation == configurationGeneration else {
                    await runtime.server.stop()
                    return .superseded
                }
                RemoteHostProcessHolder.logger.info(
                    "Remote host ready on port \(runtime.port, privacy: .public); tls=\(runtime.identity.usesTLS, privacy: .public); public=\(runtime.hasPublicBaseURL, privacy: .public)"
                )
                return .running
            } catch {
                if generation == configurationGeneration {
                    await stopRuntime()
                }
                RemoteHostProcessHolder.logger.error(
                    "Remote host failed to start: \(String(describing: error), privacy: .public)"
                )
                return .failed(error.localizedDescription)
            }
        }

        private func stopRuntime() async {
            await server?.stop()
            server = nil
            pairingStore = nil
            eventBroker = nil
            identity = nil
        }
    }

    /// Attach catalog + review ports and start the companion host when enabled. New installs
    /// default to enabled; the Settings switch can stop/start this same process immediately.
    static func attach(
        catalog: any RemoteCatalogServing,
        review: any PersonalizationReviewPort,
        hostAppVersion: String
    ) {
        let attachment = Attachment(
            catalog: catalog,
            review: review,
            hostAppVersion: hostAppVersion,
        )
        Task {
            await state.attach(attachment, enabled: isEnabled())
        }
    }

    static func isEnabled(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if defaults.object(forKey: enabledKey) != nil {
            return defaults.bool(forKey: enabledKey)
        }
        if let environmentValue = environment["IMAGEALL_REMOTE_HOST"] {
            return ["1", "true", "yes"].contains(environmentValue.lowercased())
        }
        return true
    }

    static func setEnabled(_ enabled: Bool) async -> LifecycleResult {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
        let result = await state.apply(enabled: enabled, forceRestart: false)
        if result == .stopped {
            logger.info("Remote host stopped from Settings")
        }
        return result
    }

    static func reloadConfiguration() async -> LifecycleResult {
        await state.apply(enabled: isEnabled(), forceRestart: true)
    }

    static func currentAccessToken() -> String? {
#if DEBUG
        UserDefaults.standard.string(forKey: legacyDebugTokenKey)
#else
        nil
#endif
    }

    static func configuredPublicBaseURL(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let raw = environment["IMAGEALL_REMOTE_PUBLIC_BASE_URL"]
            ?? defaults.string(forKey: publicBaseURLKey)
        return RemotePublicEndpoint.normalizedHTTPSBaseURL(raw)
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

    private static func makeRuntime(attachment: Attachment) throws -> Runtime {
        let defaults = UserDefaults.standard
        let identity = RemoteHostIdentity.loadOrCreate(defaults: defaults)

#if !DEBUG
        guard identity.usesTLS else {
            throw StartupError.tlsIdentityUnavailable
        }
#endif

        let configuredPort = defaults.object(forKey: portKey) as? Int
            ?? Int(RemoteHTTPServer.defaultPort)
        let port = UInt16(exactly: configuredPort) ?? RemoteHTTPServer.defaultPort
        let publicBaseURL = configuredPublicBaseURL(defaults: defaults)
        let hostContext = RemotePairingStore.HostContext(
            hostID: identity.hostID,
            hostDisplayName: RemoteHTTPServer.defaultAdvertisementName(),
            listenPort: Int(port),
            usesTLS: identity.usesTLS,
            certificateFingerprintSHA256: identity.certificateFingerprintSHA256,
            publicBaseURL: publicBaseURL
        )
        let pairingStore = RemotePairingStore(
            hostContext: hostContext,
            storageURL: remoteHostDirectory().appendingPathComponent("pairing.json"),
            legacyDebugToken: existingOrCreateLegacyDebugToken(defaults: defaults)
        )
        let idempotency = RemoteIdempotencyStore(
            storageURL: remoteHostDirectory().appendingPathComponent("idempotency.json")
        )
        let eventBroker = RemoteEventBroker()
        let facade = RemoteCatalogFacade(
            catalog: attachment.catalog,
            review: attachment.review,
            idempotency: idempotency,
            hostAppVersion: attachment.hostAppVersion,
            listenPort: Int(port),
            hostID: identity.hostID,
            usesTLS: identity.usesTLS,
            certificateFingerprintSHA256: identity.usesTLS
                ? identity.certificateFingerprintSHA256
                : nil
        )
        return Runtime(
            server: RemoteHTTPServer(
                facade: facade,
                pairingStore: pairingStore,
                eventBroker: eventBroker,
                secIdentity: identity.secIdentity,
                port: port,
                hostID: identity.hostID
            ),
            pairingStore: pairingStore,
            eventBroker: eventBroker,
            identity: identity,
            port: port,
            hasPublicBaseURL: publicBaseURL != nil
        )
    }

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
