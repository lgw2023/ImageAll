import AppKit
import CryptoKit
import Foundation
import GRDB

protocol PortableExportDestinationPicking: Sendable {
    @MainActor func chooseParentDirectory() -> URL?
}

struct AppKitPortableExportDestinationPicker: PortableExportDestinationPicking {
    @MainActor
    func chooseParentDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "导出用户数据"
        panel.message = "导出未加密，会包含标签、相对路径和 Photos 标识符。请选择可信位置。"
        panel.prompt = "导出到此处"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.resolvesAliases = false
        panel.treatsFilePackagesAsDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}

enum PortableExportBundleNamer {
    static func bundleName(createdAtMs: Int64) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss'Z'"
        let date = Date(timeIntervalSince1970: Double(createdAtMs) / 1_000)
        return "ImageAll-Export-\(formatter.string(from: date))"
    }
}

enum PortableCatalogExportError: Error, Equatable, Sendable {
    case invalidRequest
    case destinationCollision
    case destinationOverlapsSource
    case destinationIsolationIndeterminate
    case databaseReadFailed
    case writeFailed
    case validationFailed
    case publicationFailed
}

struct PortableExportSourceIsolationValidator: Sendable {
    let sourceRepository: GRDBFolderSourceAuthorizationRepository
    let bookmarkPort: any SecurityScopedBookmarkPort
    let relationshipChecker: any FolderRootRelationshipChecking

    func validate(parentDirectoryURL: URL) throws {
        let didAccessDestination = parentDirectoryURL.startAccessingSecurityScopedResource()
        defer {
            if didAccessDestination {
                parentDirectoryURL.stopAccessingSecurityScopedResource()
            }
        }
        let sources: [StoredFolderSourceRecord]
        do {
            sources = try sourceRepository.fetchAllFolderSources()
        } catch {
            throw PortableCatalogExportError.destinationIsolationIndeterminate
        }

        for source in sources {
            let sourceURL: URL
            do {
                sourceURL = try bookmarkPort.resolveBookmark(source.bookmark).url
            } catch {
                throw PortableCatalogExportError.destinationIsolationIndeterminate
            }
            guard bookmarkPort.startAccessing(sourceURL) else {
                throw PortableCatalogExportError.destinationIsolationIndeterminate
            }
            defer { bookmarkPort.stopAccessing(sourceURL) }

            switch relationshipChecker.relationship(
                between: parentDirectoryURL,
                and: sourceURL
            ) {
            case .same, .existingAncestor, .newAncestor:
                throw PortableCatalogExportError.destinationOverlapsSource
            case .disjoint:
                continue
            case .indeterminate:
                throw PortableCatalogExportError.destinationIsolationIndeterminate
            }
        }
    }
}

struct PortableCatalogExportRequest: Equatable, Sendable {
    let parentDirectoryURL: URL
    let bundleName: String
    let createdAtMs: Int64
    let appVersion: String
}

struct PortableCatalogExportResult: Equatable, Sendable {
    let bundleURL: URL
    let totalRecordCount: Int
}

struct PortableExportManifestFile: Codable, Equatable, Sendable {
    let filename: String
    let recordCount: Int
    let byteCount: Int64
    let sha256: String

    enum CodingKeys: String, CodingKey {
        case filename
        case recordCount = "record_count"
        case byteCount = "byte_count"
        case sha256
    }
}

struct PortableExportManifest: Codable, Equatable, Sendable {
    let format: String
    let formatVersion: Int
    let createdAtMs: Int64
    let appVersion: String
    let appliedMigrations: [String]
    let files: [PortableExportManifestFile]

    enum CodingKeys: String, CodingKey {
        case format
        case formatVersion = "format_version"
        case createdAtMs = "created_at_ms"
        case appVersion = "app_version"
        case appliedMigrations = "applied_migrations"
        case files
    }
}

protocol PortableExportFaultInjecting: Sendable {
    func beforeWritingFile(filename: String) throws
    func beforePublication() throws
}

extension PortableExportFaultInjecting {
    func beforeWritingFile(filename _: String) throws {}
}

struct NoPortableExportFaultInjector: PortableExportFaultInjecting {
    func beforePublication() throws {}
}

struct PortableCatalogExporter: Sendable {
    let database: CatalogDatabase

    func export(
        _ request: PortableCatalogExportRequest,
        faultInjector: any PortableExportFaultInjecting = NoPortableExportFaultInjector()
    ) throws -> PortableCatalogExportResult {
        try validate(request)

        let fileManager = FileManager.default
        let finalURL = request.parentDirectoryURL
            .appendingPathComponent(request.bundleName, isDirectory: true)
        let tempURL = request.parentDirectoryURL.appendingPathComponent(
            ".\(request.bundleName).tmp-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        guard !fileManager.fileExists(atPath: finalURL.path),
              !fileManager.fileExists(atPath: tempURL.path)
        else {
            throw PortableCatalogExportError.destinationCollision
        }

        let didAccessSecurityScope = request.parentDirectoryURL.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScope {
                request.parentDirectoryURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            do {
                try fileManager.createDirectory(at: tempURL, withIntermediateDirectories: false)
            } catch {
                throw PortableCatalogExportError.writeFailed
            }

            let specs = PortableExportFileSpec.all.sorted { $0.filename < $1.filename }
            var writtenCounts: [String: Int] = [:]
            var appliedMigrations: [String] = []
            do {
                try database.pool.read { db in
                    appliedMigrations = try CatalogDatabase.readAppliedMigrationIDs(from: db)
                    for spec in specs {
                        do {
                            try faultInjector.beforeWritingFile(filename: spec.filename)
                        } catch {
                            throw PortableCatalogExportError.writeFailed
                        }
                        writtenCounts[spec.filename] = try write(spec, from: db, to: tempURL)
                    }
                }
            } catch let error as PortableCatalogExportError {
                throw error
            } catch {
                throw PortableCatalogExportError.databaseReadFailed
            }

            var manifestFiles: [PortableExportManifestFile] = []
            for spec in specs {
                guard let expectedCount = writtenCounts[spec.filename] else {
                    throw PortableCatalogExportError.validationFailed
                }
                let descriptor = try PortableExportFileValidator.validate(
                    tempURL.appendingPathComponent(spec.filename),
                    filename: spec.filename,
                    expectedRecordCount: expectedCount
                )
                manifestFiles.append(descriptor)
            }

            let manifest = PortableExportManifest(
                format: "imageall-portable-export",
                formatVersion: 1,
                createdAtMs: request.createdAtMs,
                appVersion: request.appVersion,
                appliedMigrations: appliedMigrations,
                files: manifestFiles
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let manifestData: Data
            do {
                manifestData = try encoder.encode(manifest)
                try manifestData.write(
                    to: tempURL.appendingPathComponent("manifest.json"),
                    options: .atomic
                )
            } catch {
                throw PortableCatalogExportError.writeFailed
            }

            let decoded: PortableExportManifest
            do {
                decoded = try JSONDecoder().decode(
                    PortableExportManifest.self,
                    from: Data(contentsOf: tempURL.appendingPathComponent("manifest.json"))
                )
            } catch {
                throw PortableCatalogExportError.validationFailed
            }
            guard decoded == manifest,
                  decoded.files.map(\.filename) == specs.map(\.filename)
            else {
                throw PortableCatalogExportError.validationFailed
            }

            do {
                try faultInjector.beforePublication()
            } catch {
                throw PortableCatalogExportError.publicationFailed
            }
            do {
                try fileManager.moveItem(at: tempURL, to: finalURL)
            } catch {
                throw PortableCatalogExportError.publicationFailed
            }

            return PortableCatalogExportResult(
                bundleURL: finalURL,
                totalRecordCount: manifestFiles.reduce(0) { $0 + $1.recordCount }
            )
        } catch let error as PortableCatalogExportError {
            if fileManager.fileExists(atPath: tempURL.path) {
                try? fileManager.removeItem(at: tempURL)
            }
            throw error
        } catch {
            if fileManager.fileExists(atPath: tempURL.path) {
                try? fileManager.removeItem(at: tempURL)
            }
            throw PortableCatalogExportError.writeFailed
        }
    }
}

private extension PortableCatalogExporter {
    func validate(_ request: PortableCatalogExportRequest) throws {
        guard request.createdAtMs >= 0,
              !request.appVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.bundleName.hasPrefix("ImageAll-Export-"),
              !request.bundleName.contains("/"),
              !request.bundleName.contains("\\"),
              !request.bundleName.contains("\0"),
              request.bundleName != ".",
              request.bundleName != ".."
        else {
            throw PortableCatalogExportError.invalidRequest
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: request.parentDirectoryURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw PortableCatalogExportError.invalidRequest
        }
    }

    func write(_ spec: PortableExportFileSpec, from db: Database, to directoryURL: URL) throws -> Int {
        let fileURL = directoryURL.appendingPathComponent(spec.filename)
        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
            throw PortableCatalogExportError.writeFailed
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: fileURL)
        } catch {
            throw PortableCatalogExportError.writeFailed
        }

        var count = 0
        do {
            let cursor = try Row.fetchCursor(db, sql: spec.sql)
            while let row = try cursor.next() {
                let object = try spec.jsonObject(from: row)
                guard JSONSerialization.isValidJSONObject(object) else {
                    throw PortableCatalogExportError.validationFailed
                }
                let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                try handle.write(contentsOf: data)
                try handle.write(contentsOf: Data([0x0a]))
                count += 1
            }
            try handle.synchronize()
            try handle.close()
            return count
        } catch let error as PortableCatalogExportError {
            try? handle.close()
            throw error
        } catch {
            try? handle.close()
            throw PortableCatalogExportError.writeFailed
        }
    }
}

enum PortableExportHashing {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private enum PortableExportFileValidator {
    static func validate(
        _ url: URL,
        filename: String,
        expectedRecordCount: Int
    ) throws -> PortableExportManifestFile {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw PortableCatalogExportError.validationFailed
        }

        var hasher = SHA256()
        var buffer = Data()
        var byteCount: Int64 = 0
        var recordCount = 0
        do {
            while true {
                let chunk = try handle.read(upToCount: 65_536) ?? Data()
                if chunk.isEmpty { break }
                guard byteCount <= Int64.max - Int64(chunk.count) else {
                    throw PortableCatalogExportError.validationFailed
                }
                byteCount += Int64(chunk.count)
                hasher.update(data: chunk)
                buffer.append(chunk)

                while let newline = buffer.firstIndex(of: 0x0a) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    guard !line.isEmpty,
                          (try JSONSerialization.jsonObject(with: line)) is [String: Any]
                    else {
                        throw PortableCatalogExportError.validationFailed
                    }
                    recordCount += 1
                }
            }
            try handle.close()
        } catch let error as PortableCatalogExportError {
            try? handle.close()
            throw error
        } catch {
            try? handle.close()
            throw PortableCatalogExportError.validationFailed
        }

        guard buffer.isEmpty, recordCount == expectedRecordCount else {
            throw PortableCatalogExportError.validationFailed
        }
        let sha256 = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return PortableExportManifestFile(
            filename: filename,
            recordCount: recordCount,
            byteCount: byteCount,
            sha256: sha256
        )
    }
}

private struct PortableExportFileSpec {
    enum FieldKind {
        case requiredString
        case optionalString
        case requiredInteger
        case optionalInteger
        case requiredNumber
    }

    struct Field {
        let name: String
        let kind: FieldKind
    }

    let filename: String
    let sql: String
    let fields: [Field]

    func jsonObject(from row: Row) throws -> [String: Any] {
        var object: [String: Any] = [:]
        for field in fields {
            switch field.kind {
            case .requiredString:
                guard let value: String = row[field.name] else {
                    throw PortableCatalogExportError.validationFailed
                }
                object[field.name] = value
            case .optionalString:
                let value: String? = row[field.name]
                object[field.name] = value ?? NSNull()
            case .requiredInteger:
                guard let value: Int64 = row[field.name] else {
                    throw PortableCatalogExportError.validationFailed
                }
                object[field.name] = value
            case .optionalInteger:
                let value: Int64? = row[field.name]
                object[field.name] = value ?? NSNull()
            case .requiredNumber:
                guard let value: Double = row[field.name] else {
                    throw PortableCatalogExportError.validationFailed
                }
                object[field.name] = value
            }
        }
        return object
    }

    private static func strings(_ names: String...) -> [Field] {
        names.map { Field(name: $0, kind: .requiredString) }
    }

    private static func integers(_ names: String...) -> [Field] {
        names.map { Field(name: $0, kind: .requiredInteger) }
    }

    static let all: [PortableExportFileSpec] = [
        PortableExportFileSpec(
            filename: "sources.jsonl",
            sql: """
                SELECT id, kind, display_name, state, created_at_ms, updated_at_ms
                FROM source ORDER BY id
                """,
            fields: strings("id", "kind", "display_name", "state")
                + integers("created_at_ms", "updated_at_ms")
        ),
        PortableExportFileSpec(
            filename: "assets.jsonl",
            sql: """
                SELECT id, source_id, locator_kind, relative_path, photos_local_identifier,
                       locator_state, file_name, media_type, width, height,
                       media_created_at_ms, media_modified_at_ms, content_revision,
                       availability, record_created_at_ms, record_updated_at_ms
                FROM asset ORDER BY id
                """,
            fields: strings("id", "source_id", "locator_kind")
                + [Field(name: "relative_path", kind: .optionalString)]
                + [Field(name: "photos_local_identifier", kind: .optionalString)]
                + strings("locator_state")
                + [Field(name: "file_name", kind: .optionalString)]
                + strings("media_type")
                + [Field(name: "width", kind: .optionalInteger)]
                + [Field(name: "height", kind: .optionalInteger)]
                + [Field(name: "media_created_at_ms", kind: .optionalInteger)]
                + [Field(name: "media_modified_at_ms", kind: .optionalInteger)]
                + integers("content_revision")
                + strings("availability")
                + integers("record_created_at_ms", "record_updated_at_ms")
        ),
        PortableExportFileSpec(
            filename: "file_fingerprints.jsonl",
            sql: """
                SELECT asset_id, size_bytes, modified_at_ns,
                       CASE WHEN sha256 IS NULL THEN NULL ELSE lower(hex(sha256)) END AS sha256
                FROM file_fingerprint ORDER BY asset_id
                """,
            fields: strings("asset_id")
                + integers("size_bytes", "modified_at_ns")
                + [Field(name: "sha256", kind: .optionalString)]
        ),
        PortableExportFileSpec(
            filename: "tags.jsonl",
            sql: """
                SELECT id, name, normalized_name, state, created_at_ms, updated_at_ms
                FROM tag ORDER BY id
                """,
            fields: strings("id", "name", "normalized_name", "state")
                + integers("created_at_ms", "updated_at_ms")
        ),
        PortableExportFileSpec(
            filename: "decisions.jsonl",
            sql: """
                SELECT asset_id, tag_id, decision, updated_at_ms
                FROM asset_tag_decision ORDER BY asset_id, tag_id
                """,
            fields: strings("asset_id", "tag_id", "decision") + integers("updated_at_ms")
        ),
        PortableExportFileSpec(
            filename: "tag_models.jsonl",
            sql: """
                SELECT tag_id, current_revision, updated_at_ms
                FROM tag_model ORDER BY tag_id
                """,
            fields: strings("tag_id") + integers("current_revision", "updated_at_ms")
        ),
        PortableExportFileSpec(
            filename: "model_revisions.jsonl",
            sql: """
                SELECT tag_id, revision, provider, request_revision, preprocessing_revision,
                       threshold, positive_count, negative_count, neighbor_count,
                       sample_budget_per_role, created_at_ms
                FROM tag_model_revision ORDER BY tag_id, revision
                """,
            fields: strings("tag_id")
                + integers("revision")
                + strings("provider")
                + integers("request_revision", "preprocessing_revision")
                + [Field(name: "threshold", kind: .requiredNumber)]
                + integers(
                    "positive_count", "negative_count", "neighbor_count",
                    "sample_budget_per_role", "created_at_ms"
                )
        ),
        PortableExportFileSpec(
            filename: "model_samples.jsonl",
            sql: """
                SELECT tag_id, model_revision, asset_id, content_revision, role, rank,
                       provider, request_revision, preprocessing_revision
                FROM tag_model_sample
                ORDER BY tag_id, model_revision, role, rank, asset_id
                """,
            fields: strings("tag_id")
                + integers("model_revision")
                + strings("asset_id")
                + integers("content_revision")
                + strings("role")
                + integers("rank")
                + strings("provider")
                + integers("request_revision", "preprocessing_revision")
        ),
    ]
}
