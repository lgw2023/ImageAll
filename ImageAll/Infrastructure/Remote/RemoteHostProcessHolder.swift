import Darwin
import Foundation
import GRDB
import ImageAllRemoteProtocol
import UniformTypeIdentifiers
import os

final class RemoteMediaResource: @unchecked Sendable {
    let contentType: String
    let contentLength: Int64

    private let descriptor: Int32
    private let lock = NSLock()
    private var releaseAction: (@Sendable () -> Void)?

    init(
        descriptor: Int32,
        contentType: String,
        contentLength: Int64,
        release: @escaping @Sendable () -> Void
    ) {
        self.descriptor = descriptor
        self.contentType = contentType
        self.contentLength = contentLength
        releaseAction = release
    }

    func read(offset: Int64, count: Int) throws -> Data {
        guard offset >= 0, count >= 0 else {
            throw RemoteAPIError(code: .badRequest, message: "invalid media byte range")
        }
        var bytes = [UInt8](repeating: 0, count: count)
        let readCount = bytes.withUnsafeMutableBytes { buffer in
            pread(descriptor, buffer.baseAddress, buffer.count, off_t(offset))
        }
        guard readCount >= 0 else {
            throw RemoteAPIError(code: .internalError, message: "media read failed")
        }
        return Data(bytes.prefix(readCount))
    }

    func release() {
        lock.lock()
        let action = releaseAction
        releaseAction = nil
        lock.unlock()
        action?()
    }

    deinit {
        release()
    }
}

protocol RemoteMediaResourceProviding: Sendable {
    func openMediaResource(assetID: UUID) async throws -> RemoteMediaResource
}

struct UnavailableRemoteMediaResourceProvider: RemoteMediaResourceProviding {
    func openMediaResource(assetID _: UUID) async throws -> RemoteMediaResource {
        throw RemoteAPIError(code: .notFound, message: "media unavailable")
    }
}

struct ProductionRemoteMediaResourceProvider: RemoteMediaResourceProviding {
    private struct Locator: Sendable {
        let sourceID: UUID
        let sourceKind: SourceKind
        let locatorKind: AssetLocatorKind
        let mediaKind: MediaKind
        let mediaType: String
        let relativePath: String?
        let photosLocalIdentifier: String?
        let availability: AssetAvailability
    }

    let database: CatalogDatabase
    let folderAuthorization: FolderAuthorizationCoordinator
    let photosLibrary: PhotoKitPhotosLibraryAdapter

    func openMediaResource(assetID: UUID) async throws -> RemoteMediaResource {
        let locator = try fetchLocator(assetID: assetID)
        guard locator.availability == .available, locator.mediaKind == .video else {
            throw RemoteAPIError(code: .notFound, message: "video unavailable")
        }

        switch (locator.sourceKind, locator.locatorKind) {
        case (.folder, .file):
            guard let relativePath = locator.relativePath,
                  case let .success(validatedPath) = RelativePathRules.validate(relativePath)
            else {
                throw RemoteAPIError(code: .notFound, message: "unsafe video locator")
            }
            let accessLease: FolderSourceAccessLease
            do {
                accessLease = try folderAuthorization.acquireFolderSourceAccess(
                    sourceID: locator.sourceID
                )
            } catch {
                throw RemoteAPIError(code: .notFound, message: "video source unavailable")
            }
            do {
                let rootFD = try DerivedImageSecureIO.openDirectoryNoFollow(
                    at: accessLease.rootURL
                )
                defer { Darwin.close(rootFD) }
                let descriptor = try DerivedImageSecureIO.openRelativeReadOnlyNoFollow(
                    directoryFD: rootFD,
                    relativePath: validatedPath
                )
                do {
                    let facts = try DerivedImageSecureIO.fstatRegularFile(fd: descriptor)
                    guard facts.sizeBytes > 0 else {
                        throw RemoteAPIError(code: .notFound, message: "video file is empty")
                    }
                    return RemoteMediaResource(
                        descriptor: descriptor,
                        contentType: Self.contentType(
                            mediaType: locator.mediaType,
                            url: URL(fileURLWithPath: validatedPath)
                        ),
                        contentLength: facts.sizeBytes
                    ) {
                        Darwin.close(descriptor)
                        accessLease.release()
                    }
                } catch {
                    Darwin.close(descriptor)
                    throw error
                }
            } catch {
                accessLease.release()
                throw RemoteAPIError(code: .notFound, message: "video file unavailable")
            }
        case (.photos, .photos):
            guard let identifier = locator.photosLocalIdentifier else {
                throw RemoteAPIError(code: .notFound, message: "unsafe Photos video locator")
            }
            let url: URL
            do {
                url = try await photosLibrary.requestOriginalVideoURL(
                    localIdentifier: identifier
                )
            } catch {
                throw RemoteAPIError(code: .notFound, message: "Photos video unavailable")
            }
            do {
                let descriptor = try DerivedImageSecureIO.openReadOnlyNoFollow(at: url)
                do {
                    let facts = try DerivedImageSecureIO.fstatRegularFile(fd: descriptor)
                    guard facts.sizeBytes > 0 else {
                        throw RemoteAPIError(code: .notFound, message: "Photos video is empty")
                    }
                    return RemoteMediaResource(
                        descriptor: descriptor,
                        contentType: Self.contentType(mediaType: locator.mediaType, url: url),
                        contentLength: facts.sizeBytes
                    ) {
                        Darwin.close(descriptor)
                    }
                } catch {
                    Darwin.close(descriptor)
                    throw error
                }
            } catch {
                throw RemoteAPIError(code: .notFound, message: "Photos video resource unavailable")
            }
        default:
            throw RemoteAPIError(code: .notFound, message: "video unavailable")
        }
    }

    private func fetchLocator(assetID: UUID) throws -> Locator {
        try database.pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT
                    asset.source_id,
                    source.kind AS source_kind,
                    asset.locator_kind,
                    asset.media_kind,
                    asset.media_type,
                    asset.relative_path,
                    asset.photos_local_identifier,
                    asset.availability
                FROM asset
                INNER JOIN source ON source.id = asset.source_id
                WHERE asset.id = ? AND asset.locator_state = 'current'
                """,
                arguments: [assetID.uuidString.lowercased()]
            ),
                let sourceID = UUID(uuidString: row["source_id"]),
                let sourceKind = SourceKind(rawValue: row["source_kind"]),
                let locatorKind = AssetLocatorKind(rawValue: row["locator_kind"]),
                let mediaKind = MediaKind(rawValue: row["media_kind"]),
                let availability = AssetAvailability(rawValue: row["availability"])
            else {
                throw RemoteAPIError(code: .notFound, message: "video unavailable")
            }
            return Locator(
                sourceID: sourceID,
                sourceKind: sourceKind,
                locatorKind: locatorKind,
                mediaKind: mediaKind,
                mediaType: row["media_type"],
                relativePath: row["relative_path"],
                photosLocalIdentifier: row["photos_local_identifier"],
                availability: availability
            )
        }
    }

    private static func contentType(mediaType: String, url: URL?) -> String {
        if let mime = UTType(mediaType)?.preferredMIMEType, mime.hasPrefix("video/") {
            return mime
        }
        if let extensionName = url?.pathExtension,
           let mime = UTType(filenameExtension: extensionName)?.preferredMIMEType,
           mime.hasPrefix("video/")
        {
            return mime
        }
        return "application/octet-stream"
    }
}

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
        let trainingWorkspace: any TrainingWorkspacePort
        let trainingCommands: any RemoteTrainingCommandPort
        let librarySlimmingAnalysis: any LibrarySlimmingAnalysisJobPort
        let librarySlimmingCommands: any RemoteLibrarySlimmingCommandPort
        let sourceManagementCommands: any RemoteSourceManagementCommandPort
        let storageMaintenanceCommands: any RemoteStorageMaintenanceCommandPort
        let generalSettingsCommands: (any RemoteGeneralSettingsCommandPort)?
        let workspaceNotices: any RemoteWorkspaceNoticePort
        let mediaResources: any RemoteMediaResourceProviding
        let originalAssetOpener: any LibraryOriginalAssetOpening
        let hostAppVersion: String
    }

    private struct Runtime {
        let server: RemoteHTTPServer
        let pairingStore: RemotePairingStore
        let accessAccountStore: RemoteAccessAccountStore
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
        var accessAccountStore: RemoteAccessAccountStore?
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
                accessAccountStore = runtime.accessAccountStore
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
            accessAccountStore = nil
            eventBroker = nil
            identity = nil
        }
    }

    /// Attach catalog + review ports and start the companion host when enabled. New installs
    /// default to enabled; the Settings switch can stop/start this same process immediately.
    static func attach(
        catalog: any RemoteCatalogServing,
        review: any PersonalizationReviewPort,
        trainingWorkspace: any TrainingWorkspacePort,
        trainingCommands: any RemoteTrainingCommandPort,
        librarySlimmingAnalysis: any LibrarySlimmingAnalysisJobPort,
        librarySlimmingCommands: any RemoteLibrarySlimmingCommandPort,
        sourceManagementCommands: any RemoteSourceManagementCommandPort,
        storageMaintenanceCommands: any RemoteStorageMaintenanceCommandPort,
        generalSettingsCommands: (any RemoteGeneralSettingsCommandPort)? = nil,
        workspaceNotices: any RemoteWorkspaceNoticePort,
        mediaResources: any RemoteMediaResourceProviding = UnavailableRemoteMediaResourceProvider(),
        originalAssetOpener: any LibraryOriginalAssetOpening,
        hostAppVersion: String
    ) {
        let attachment = Attachment(
            catalog: catalog,
            review: review,
            trainingWorkspace: trainingWorkspace,
            trainingCommands: trainingCommands,
            librarySlimmingAnalysis: librarySlimmingAnalysis,
            librarySlimmingCommands: librarySlimmingCommands,
            sourceManagementCommands: sourceManagementCommands,
            storageMaintenanceCommands: storageMaintenanceCommands,
            generalSettingsCommands: generalSettingsCommands,
            workspaceNotices: workspaceNotices,
            mediaResources: mediaResources,
            originalAssetOpener: originalAssetOpener,
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

    static func accessAccounts() async -> [RemoteAccessAccountSummary] {
        let store: RemoteAccessAccountStore
        if let runningStore = await state.accessAccountStore {
            store = runningStore
        } else {
            store = makeAccessAccountStore()
        }
        return await store.listAccounts()
    }

    @discardableResult
    static func upsertAccessAccount(
        username: String,
        password: String
    ) async throws -> RemoteAccessAccountSummary {
        let store: RemoteAccessAccountStore
        if let runningStore = await state.accessAccountStore {
            store = runningStore
        } else {
            store = makeAccessAccountStore()
        }
        return try await store.upsert(username: username, password: password)
    }

    static func removeAccessAccount(username: String) async throws {
        let store: RemoteAccessAccountStore
        if let runningStore = await state.accessAccountStore {
            store = runningStore
        } else {
            store = makeAccessAccountStore()
        }
        try await store.remove(username: username)
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
        let accessAccountStore = makeAccessAccountStore()
        let idempotency = RemoteIdempotencyStore(
            storageURL: remoteHostDirectory().appendingPathComponent("idempotency.json")
        )
        let eventBroker = RemoteEventBroker()
        let facade = RemoteCatalogFacade(
            catalog: attachment.catalog,
            review: attachment.review,
            trainingWorkspace: attachment.trainingWorkspace,
            trainingCommands: attachment.trainingCommands,
            librarySlimmingAnalysis: attachment.librarySlimmingAnalysis,
            librarySlimmingCommands: attachment.librarySlimmingCommands,
            sourceManagementCommands: attachment.sourceManagementCommands,
            storageMaintenanceCommands: attachment.storageMaintenanceCommands,
            generalSettingsCommands: attachment.generalSettingsCommands,
            workspaceNotices: attachment.workspaceNotices,
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
                accessAccountStore: accessAccountStore,
                eventBroker: eventBroker,
                mediaResources: attachment.mediaResources,
                originalAssetOpener: attachment.originalAssetOpener,
                secIdentity: identity.secIdentity,
                port: port,
                localWebPort: RemoteHTTPServer.defaultLocalWebPort,
                hostID: identity.hostID
            ),
            pairingStore: pairingStore,
            accessAccountStore: accessAccountStore,
            eventBroker: eventBroker,
            identity: identity,
            port: port,
            hasPublicBaseURL: publicBaseURL != nil
        )
    }

    static var localWebURL: URL {
        URL(string: "http://127.0.0.1:\(RemoteHTTPServer.defaultLocalWebPort)")!
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

    private static func makeAccessAccountStore() -> RemoteAccessAccountStore {
        RemoteAccessAccountStore(
            storageURL: remoteHostDirectory().appendingPathComponent("access-accounts.json")
        )
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
