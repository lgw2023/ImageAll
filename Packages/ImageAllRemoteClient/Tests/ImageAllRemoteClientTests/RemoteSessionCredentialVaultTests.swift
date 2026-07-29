import XCTest
@testable import ImageAllRemoteClient

final class RemoteSessionCredentialVaultTests: XCTestCase {
    func testMigratesLegacyRefreshTokenBeforeRemovingLegacyValue() throws {
        let secureStore = InMemoryRemoteSecureCredentialStore()
        let vault = RemoteSessionCredentialVault(secureStore: secureStore)
        var legacyRefreshToken: String? = "legacy-refresh"

        let result = try vault.loadMigratingLegacy(
            loadLegacy: { legacyRefreshToken },
            removeLegacy: { legacyRefreshToken = nil }
        )

        XCTAssertEqual(
            result,
            RemoteSessionCredentialLoadResult(
                refreshToken: "legacy-refresh",
                source: .migratedLegacy
            )
        )
        XCTAssertEqual(try vault.loadRefreshToken(), "legacy-refresh")
        XCTAssertNil(legacyRefreshToken)
    }

    func testRejectsBlankLegacyRefreshTokenWithoutRemovingIt() throws {
        let secureStore = InMemoryRemoteSecureCredentialStore()
        let vault = RemoteSessionCredentialVault(secureStore: secureStore)
        var legacyRefreshToken: String? = "   "

        XCTAssertThrowsError(
            try vault.loadMigratingLegacy(
                loadLegacy: { legacyRefreshToken },
                removeLegacy: { legacyRefreshToken = nil }
            )
        ) { error in
            XCTAssertEqual(
                error as? RemoteSessionCredentialVaultError,
                .invalidRefreshToken
            )
        }
        XCTAssertEqual(legacyRefreshToken, "   ")
        XCTAssertNil(secureStore.data)
    }

    func testPreservesLegacyRefreshTokenWhenSecureSaveFails() throws {
        let secureStore = InMemoryRemoteSecureCredentialStore()
        secureStore.saveError = TestStoreError.unavailable
        let vault = RemoteSessionCredentialVault(secureStore: secureStore)
        var legacyRefreshToken: String? = "legacy-refresh"

        XCTAssertThrowsError(
            try vault.loadMigratingLegacy(
                loadLegacy: { legacyRefreshToken },
                removeLegacy: { legacyRefreshToken = nil }
            )
        ) { error in
            XCTAssertEqual(error as? TestStoreError, .unavailable)
        }
        XCTAssertEqual(legacyRefreshToken, "legacy-refresh")
        XCTAssertNil(secureStore.data)
    }

    func testPrefersSecureRefreshTokenAndRemovesStaleLegacyValue() throws {
        let secureStore = InMemoryRemoteSecureCredentialStore()
        secureStore.data = Data("secure-refresh".utf8)
        let vault = RemoteSessionCredentialVault(secureStore: secureStore)
        var legacyRefreshToken: String? = "stale-legacy-refresh"

        let result = try vault.loadMigratingLegacy(
            loadLegacy: { legacyRefreshToken },
            removeLegacy: { legacyRefreshToken = nil }
        )

        XCTAssertEqual(
            result,
            RemoteSessionCredentialLoadResult(
                refreshToken: "secure-refresh",
                source: .secureStorage
            )
        )
        XCTAssertNil(legacyRefreshToken)
    }

    func testDeletesStoredRefreshToken() throws {
        let secureStore = InMemoryRemoteSecureCredentialStore()
        secureStore.data = Data("secure-refresh".utf8)
        let vault = RemoteSessionCredentialVault(secureStore: secureStore)

        try vault.deleteRefreshToken()

        XCTAssertNil(try vault.loadRefreshToken())
    }

    func testPreservesStoredRefreshTokenWhenDeleteFails() throws {
        let secureStore = InMemoryRemoteSecureCredentialStore()
        secureStore.data = Data("secure-refresh".utf8)
        secureStore.deleteError = TestStoreError.unavailable
        let vault = RemoteSessionCredentialVault(secureStore: secureStore)

        XCTAssertThrowsError(try vault.deleteRefreshToken()) { error in
            XCTAssertEqual(error as? TestStoreError, .unavailable)
        }
        XCTAssertEqual(try vault.loadRefreshToken(), "secure-refresh")
    }
}

private final class InMemoryRemoteSecureCredentialStore: RemoteSecureCredentialStoring {
    var data: Data?
    var saveError: Error?
    var deleteError: Error?

    func load() throws -> Data? {
        data
    }

    func save(_ data: Data) throws {
        if let saveError {
            throw saveError
        }
        self.data = data
    }

    func delete() throws {
        if let deleteError {
            throw deleteError
        }
        data = nil
    }
}

private enum TestStoreError: Error, Equatable {
    case unavailable
}
