import Foundation
import Security

public enum RemoteSessionCredentialVaultError: Error, Equatable, Sendable {
    case invalidRefreshToken
}

extension RemoteSessionCredentialVaultError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidRefreshToken:
            "会话刷新凭据无效"
        }
    }
}

protocol RemoteSecureCredentialStoring {
    func load() throws -> Data?
    func save(_ data: Data) throws
    func delete() throws
}

public struct RemoteSessionCredentialLoadResult: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case secureStorage
        case migratedLegacy
    }

    public let refreshToken: String
    public let source: Source

    public init(refreshToken: String, source: Source) {
        self.refreshToken = refreshToken
        self.source = source
    }
}

public struct RemoteSessionCredentialVault {
    private let secureStore: any RemoteSecureCredentialStoring

    public init(service: String, account: String) {
        secureStore = RemoteKeychainCredentialStore(
            service: service,
            account: account
        )
    }

    init(secureStore: any RemoteSecureCredentialStoring) {
        self.secureStore = secureStore
    }

    public func loadRefreshToken() throws -> String? {
        guard let data = try secureStore.load() else { return nil }
        guard let refreshToken = String(data: data, encoding: .utf8) else {
            throw RemoteSessionCredentialVaultError.invalidRefreshToken
        }
        try Self.validate(refreshToken)
        return refreshToken
    }

    public func loadMigratingLegacy(
        loadLegacy: () -> String?,
        removeLegacy: () -> Void
    ) throws -> RemoteSessionCredentialLoadResult? {
        if let refreshToken = try loadRefreshToken() {
            removeLegacy()
            return RemoteSessionCredentialLoadResult(
                refreshToken: refreshToken,
                source: .secureStorage
            )
        }
        guard let refreshToken = loadLegacy() else { return nil }
        try Self.validate(refreshToken)
        try secureStore.save(Data(refreshToken.utf8))
        removeLegacy()
        return RemoteSessionCredentialLoadResult(
            refreshToken: refreshToken,
            source: .migratedLegacy
        )
    }

    public func saveRefreshToken(_ refreshToken: String) throws {
        try Self.validate(refreshToken)
        try secureStore.save(Data(refreshToken.utf8))
    }

    public func deleteRefreshToken() throws {
        try secureStore.delete()
    }

    private static func validate(_ refreshToken: String) throws {
        guard !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RemoteSessionCredentialVaultError.invalidRefreshToken
        }
    }
}

private final class RemoteKeychainCredentialStore: RemoteSecureCredentialStoring {
    private enum Operation: String {
        case load
        case save
        case delete

        var localizedName: String {
            switch self {
            case .load:
                "读取"
            case .save:
                "保存"
            case .delete:
                "删除"
            }
        }
    }

    private let service: String
    private let account: String

    init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    func load() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw RemoteSessionCredentialVaultError.invalidRefreshToken
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw RemoteKeychainCredentialStoreError(
                operation: .load,
                status: status
            )
        }
    }

    func save(_ data: Data) throws {
        let changes: [String: Any] = [
            kSecValueData as String: data,
        ]
        var status = SecItemUpdate(
            baseQuery as CFDictionary,
            changes as CFDictionary
        )
        if status == errSecItemNotFound {
            var item = baseQuery
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] =
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
            if status == errSecDuplicateItem {
                status = SecItemUpdate(
                    baseQuery as CFDictionary,
                    changes as CFDictionary
                )
            }
        }
        guard status == errSecSuccess else {
            throw RemoteKeychainCredentialStoreError(
                operation: .save,
                status: status
            )
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw RemoteKeychainCredentialStoreError(
                operation: .delete,
                status: status
            )
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }

    private struct RemoteKeychainCredentialStoreError: Error, LocalizedError {
        let operation: Operation
        let status: OSStatus

        var errorDescription: String? {
            let message = SecCopyErrorMessageString(status, nil) as String?
            return "无法\(operation.localizedName)系统 Keychain 会话凭据"
                + (message.map { "：\($0)" } ?? "（错误 \(status)）")
        }
    }
}
