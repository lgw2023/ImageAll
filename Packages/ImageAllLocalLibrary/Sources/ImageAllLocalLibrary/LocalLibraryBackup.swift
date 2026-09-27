import CryptoKit
import Foundation
import SQLite3

public struct LocalLibraryBackupReport: Sendable {
    public let url: URL
    public let assetCount: Int
    public let tagCount: Int
    public let collectionCount: Int
    public let pendingSharedCount: Int
    public let byteCount: Int64
    public let sha256: String
}

public enum LocalLibraryBackup {
    /// SQLite's backup API includes committed WAL state in a consistent snapshot.
    /// Called synchronously on the store actor; the live database is never replaced.
    static func write(source: OpaquePointer, to destination: URL) throws -> LocalLibraryBackupReport {
        guard destination.isFileURL else { throw LocalLibraryError.database("backup requires a local file") }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Never overwrite an earlier backup, the live database, or a symlink target.
        try Data().write(to: destination, options: .withoutOverwriting)
        var success = false
        defer { if !success { try? FileManager.default.removeItem(at: destination) } }
        var output: OpaquePointer?
        let opened = sqlite3_open_v2(destination.path, &output, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard opened == SQLITE_OK, let output else {
            if let output { sqlite3_close(output) }
            throw LocalLibraryError.database("cannot create local library backup")
        }
        do {
            guard let backup = sqlite3_backup_init(output, "main", source, "main") else {
                throw LocalLibraryError.database("cannot start local library backup")
            }
            let copied = sqlite3_backup_step(backup, -1)
            let finished = sqlite3_backup_finish(backup)
            guard copied == SQLITE_DONE, finished == SQLITE_OK else {
                throw LocalLibraryError.database("local library backup did not complete")
            }
            guard sqlite3_exec(output, "PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK else {
                throw LocalLibraryError.database("cannot seal local library backup")
            }
        } catch {
            sqlite3_close(output)
            throw error
        }
        guard sqlite3_close(output) == SQLITE_OK else { throw LocalLibraryError.database("cannot close backup") }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.synchronize()
        let report = try verify(at: destination)
        success = true
        return report
    }

    /// Opens only the supplied standalone copy, read-only; no schema migration,
    /// pairing, source reads, or replay of pending operations is performed.
    public static func verify(at url: URL) throws -> LocalLibraryBackupReport {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard url.isFileURL, values.isRegularFile == true, values.isSymbolicLink != true else {
            throw LocalLibraryError.database("backup must be a regular file")
        }
        guard ["-wal", "-journal"].allSatisfy({ !FileManager.default.fileExists(atPath: url.path + $0) }) else {
            throw LocalLibraryError.database("backup must be a standalone closed snapshot")
        }
        var connection: OpaquePointer?
        let opened = sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard opened == SQLITE_OK, let connection else {
            if let connection { sqlite3_close(connection) }
            throw LocalLibraryError.database("cannot open backup for verification")
        }
        defer { sqlite3_close(connection) }
        func rows(_ sql: String) throws -> [String] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw LocalLibraryError.database("backup schema is not supported")
            }
            defer { sqlite3_finalize(statement) }
            var result: [String] = []
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { return result }
                guard code == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else {
                    throw LocalLibraryError.database("backup verification failed")
                }
                result.append(String(cString: value))
            }
        }
        guard try rows("PRAGMA integrity_check") == ["ok"],
              try rows("PRAGMA foreign_key_check").isEmpty else {
            throw LocalLibraryError.database("backup integrity check failed")
        }
        func count(_ table: String) throws -> Int {
            guard let count = try rows("SELECT count(*) FROM \(table)").first.flatMap(Int.init) else {
                throw LocalLibraryError.database("backup count unavailable")
            }
            return count
        }
        let assets = try count("assets"), tags = try count("tags")
        let collections = try count("collections"), pending = try count("shared_outbox")
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hash = SHA256()
        var bytes: Int64 = 0
        while let block = try input.read(upToCount: 1_024 * 1_024), !block.isEmpty {
            hash.update(data: block)
            bytes += Int64(block.count)
        }
        return .init(url: url, assetCount: assets, tagCount: tags, collectionCount: collections,
                     pendingSharedCount: pending, byteCount: bytes,
                     sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
