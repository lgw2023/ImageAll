import Foundation

struct CatalogSnapshotManifest: Codable, Equatable, Sendable {
    let formatVersion: Int
    let snapshotID: String
    let createdAtMs: Int64
    let appVersion: String
    let appliedMigrations: [String]
    let databaseFilename: String
    let databaseBytes: Int64
    let databaseSHA256: String

    enum CodingKeys: String, CodingKey {
        case formatVersion = "format_version"
        case snapshotID = "snapshot_id"
        case createdAtMs = "created_at_ms"
        case appVersion = "app_version"
        case appliedMigrations = "applied_migrations"
        case databaseFilename = "database_filename"
        case databaseBytes = "database_bytes"
        case databaseSHA256 = "database_sha256"
    }
}

enum CatalogSnapshotManifestCodec {
    static func encode(_ manifest: CatalogSnapshotManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(manifest)
    }

    static func decode(from data: Data) throws -> CatalogSnapshotManifest {
        let decoder = JSONDecoder()
        return try decoder.decode(CatalogSnapshotManifest.self, from: data)
    }
}

enum CatalogSnapshotManifestValidator {
    private static let lowercaseUUIDPattern = #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#
    private static let sha256Pattern = #"^[0-9a-f]{64}$"#

    static func validate(
        _ manifest: CatalogSnapshotManifest,
        expectedSnapshotID: String? = nil
    ) throws {
        guard manifest.formatVersion == CatalogSnapshotConstants.manifestFormatVersion else {
            throw CatalogSnapshotError.unsupportedManifestFormat(version: manifest.formatVersion)
        }

        guard isLowercaseCanonicalUUID(manifest.snapshotID) else {
            throw CatalogSnapshotError.invalidSnapshotID
        }

        if let expectedSnapshotID {
            guard manifest.snapshotID == expectedSnapshotID else {
                throw CatalogSnapshotError.snapshotIDMismatch
            }
        }

        guard manifest.createdAtMs >= 0 else {
            throw CatalogSnapshotError.invalidCreatedAt
        }

        guard !manifest.appVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CatalogSnapshotError.invalidAppVersion
        }

        guard manifest.databaseFilename == CatalogSnapshotConstants.databaseFilename else {
            throw CatalogSnapshotError.invalidDatabaseFilename
        }

        guard manifest.databaseBytes > 0 else {
            throw CatalogSnapshotError.invalidDatabaseBytes
        }

        guard manifest.databaseSHA256.range(of: sha256Pattern, options: .regularExpression) != nil else {
            throw CatalogSnapshotError.invalidDatabaseChecksum
        }

        try validateMigrationPrefix(manifest.appliedMigrations)
    }

    static func validateMigrationPrefix(_ migrations: [String]) throws {
        guard Set(migrations).count == migrations.count else {
            throw CatalogSnapshotError.invalidMigrationHistory
        }

        let expected = Array(CatalogMigrationID.knownOrdered.prefix(migrations.count))
        guard migrations == expected else {
            throw CatalogSnapshotError.invalidMigrationHistory
        }
    }

    static func validateMigrationHistoryMatchesDatabase(
        manifestMigrations: [String],
        databaseMigrations: [String]
    ) throws {
        try validateMigrationPrefix(manifestMigrations)
        guard manifestMigrations == databaseMigrations else {
            throw CatalogSnapshotError.migrationHistoryMismatch
        }
    }

    static func isLowercaseCanonicalUUID(_ value: String) -> Bool {
        value.range(of: lowercaseUUIDPattern, options: .regularExpression) != nil
    }
}
