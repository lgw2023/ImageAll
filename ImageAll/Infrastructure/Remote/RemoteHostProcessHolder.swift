import Foundation
import ImageAllRemoteProtocol
import os

/// Process-scoped remote host lifecycle. Kept out of `LibraryWorkspaceModel` on purpose.
enum RemoteHostProcessHolder {
    private static let logger = Logger(subsystem: "com.gwlee.ImageAll", category: "RemoteHost")
    private static let enabledKey = "imageall.remoteHost.enabled"
    private static let tokenKey = "imageall.remoteHost.accessToken"
    private static let portKey = "imageall.remoteHost.port"
    private static let state = State()

    private actor State {
        var server: RemoteHTTPServer?

        func replace(with next: RemoteHTTPServer?) async {
            await server?.stop()
            server = next
        }
    }

    /// Attach catalog port and optionally start the LAN helper host.
    /// Enable with `defaults write com.gwlee.ImageAll imageall.remoteHost.enabled -bool YES`
    /// or environment `IMAGEALL_REMOTE_HOST=1`.
    static func attach(
        catalog: any RemoteCatalogServing,
        hostAppVersion: String
    ) {
        let enabled = isEnabled()
        guard enabled else {
            Task { await state.replace(with: nil) }
            logger.info("Remote host disabled")
            return
        }

        let defaults = UserDefaults.standard
        let port = UInt16(defaults.object(forKey: portKey) as? Int ?? Int(RemoteHTTPServer.defaultPort))
            ?? RemoteHTTPServer.defaultPort
        let token = existingOrCreateToken(defaults: defaults)
        let facade = RemoteCatalogFacade(
            catalog: catalog,
            hostAppVersion: hostAppVersion,
            listenPort: Int(port)
        )
        let next = RemoteHTTPServer(facade: facade, accessToken: token, port: port)
        Task {
            do {
                try await next.start()
                await state.replace(with: next)
                logger.info(
                    "Remote host ready on port \(port, privacy: .public); token length \(token.count, privacy: .public)"
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
        UserDefaults.standard.string(forKey: tokenKey)
    }

    private static func existingOrCreateToken(defaults: UserDefaults) -> String {
        if let existing = defaults.string(forKey: tokenKey), !existing.isEmpty {
            return existing
        }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        defaults.set(token, forKey: tokenKey)
        return token
    }
}
