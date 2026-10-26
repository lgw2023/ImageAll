import Darwin
import Foundation

/// Explicit phone cache retirement. Never touches PhotoKit or discovers batches.
public enum ImageAllMigrationExportCleanup {
    static let recordName = "export-retirement.json"
    private typealias IO = ImageAllMigrationStagingCleanup
    private typealias Object = ImageAllMigrationTransferStore.StorageObject
    private struct Record: Codable {
        let version: Int
        let query: RemoteImportTaskQuery
        let hostID: UUID, deviceID: UUID, sourceID: UUID
        let directories: [Object]
        let metadata: [String: String]
        let entries: [String: IO.ObjectVersion]
    }
    static func hasIntent(in root: URL) throws -> Bool {
        var info = stat()
        if lstat(root.appendingPathComponent(recordName).path, &info) == 0 { return true }
        guard errno == ENOENT else { throw ImageAllMigrationCleanupError.unsafePath }
        return false
    }
    public static func release(root: URL, query: RemoteImportTaskQuery, hostID: UUID, deviceID: UUID,
                               nonce: UUID, receipt: RemoteExportCleanupReceipt) throws -> ImageAllMigrationCleanupResult {
        try release(root: root, query: query, hostID: hostID, deviceID: deviceID, nonce: nonce,
                    receipt: receipt, beforeRelease: { _ in })
    }
    static func release(root: URL, query: RemoteImportTaskQuery, hostID: UUID, deviceID: UUID,
                        nonce: UUID, receipt: RemoteExportCleanupReceipt,
                        beforeRelease: (Int) throws -> Void) throws -> ImageAllMigrationCleanupResult {
        try receipt.validate(query: query, nonce: nonce, hostID: hostID, deviceID: deviceID)
        guard try ImageAllMigrationStagingLease.isCanonical(root) else { throw ImageAllMigrationCleanupError.unsafePath }
        let checkpoint = try ImageAllMigrationExportCheckpoint(streamingRoot: root)
        defer { checkpoint.close() }
        guard checkpoint.payloadOwnerVersion == 1, checkpoint.migrationID == query.migrationID else {
            throw ImageAllMigrationCleanupError.unowned
        }
        let fd = try ImageAllMigrationStagingLease.openDirectory(root); defer { close(fd) }
        let stream = try ImageAllMigrationStreamRecord.read(in: root)
        guard stream.hostID == hostID, stream.deviceID == deviceID, stream.header.migrationID == query.migrationID,
              stream.header.sourceDeviceID == query.sourceInstallID, stream.header.sourceEpoch == query.sourceEpoch,
              stream.receipt.manifestSHA256 == query.manifestSHA256,
              stream.receipt.itemCount == receipt.itemCount, stream.receipt.resourceCount == receipt.resourceCount,
              stream.receipt.verifiedBytes == receipt.verifiedBytes else { throw ImageAllMigrationCleanupError.incompleteReferences }
        var expected: [String: ImageAllMigrationResource] = [:]
        for resource in stream.items.flatMap(\.resources) {
            guard let path = resource.relativePath, IO.validResource(path), expected[path] == nil else {
                throw ImageAllMigrationCleanupError.unowned
            }
            expected[path] = resource
        }
        let names = try IO.names(fd)
        // Exporter metadata is retained, hashed and identity checked. Unknown entries fail closed.
        var allowed: Set<String> = ["manifest.jsonl", ImageAllMigrationStreamRecord.filename, "stream-context.json", recordName, "resources", "facts"]
        for resource in expected.values {
            allowed.insert("verified-\(resource.id.uuidString.lowercased()).json")
            allowed.insert("source-verified-\(resource.id.uuidString.lowercased()).json")
        }
        guard names.isSubset(of: allowed) else { throw ImageAllMigrationCleanupError.unowned }
        var metadata: [String: String] = [:]
        for name in names.subtracting([recordName, "resources", "facts"]) { metadata[name] = IO.hash(try IO.read(fd, name)) }
        let factsFD: Int32 = names.contains("facts") ? try IO.directory(fd, "facts") : -1
        defer { if factsFD >= 0 { close(factsFD) } }
        if factsFD >= 0 {
            _ = try ImageAllMigrationFacts.inspectPublished(at: root,
                sourceDeviceID: stream.header.sourceDeviceID, sourceEpoch: stream.header.sourceEpoch,
                scopeRevision: stream.header.scopeRevision, inventoryWatermark: stream.header.inventoryWatermark,
                // Inventory and fact revisions use independent counters. Match archive verification.
                minimumFactWatermark: stream.items.reduce(Int64(0)) { max($0, $1.factRevision) },
                mediaIDs: Set(stream.items.map(\.mediaID)))
            for name in try IO.names(factsFD) { metadata["facts/" + name] = IO.hash(try IO.read(factsFD, name)) }
        }
        let resourceFD: Int32 = names.contains("resources") ? try IO.directory(fd, "resources") : -1
        defer { if resourceFD >= 0 { close(resourceFD) } }
        let present = resourceFD >= 0 ? try IO.names(resourceFD) : []
        guard present.isSubset(of: Set(expected.keys.map { String($0.dropFirst(10)) })) else { throw ImageAllMigrationCleanupError.unowned }
        let directoryURLs = [root.deletingLastPathComponent(), root]
            + (resourceFD >= 0 ? [root.appendingPathComponent("resources")] : [])
            + (factsFD >= 0 ? [root.appendingPathComponent("facts")] : [])
        let directories = try directoryURLs.map(Object.init)
        var current: [String: IO.ObjectVersion] = [:]
        for name in present {
            let file = try IO.file(resourceFD, name, write: false); defer { close(file) }
            current["resources/" + name] = try IO.ObjectVersion(file)
        }
        let record: Record
        if names.contains(recordName) {
            record = try JSONDecoder().decode(Record.self, from: IO.read(fd, recordName))
            guard record.version == 1, record.query == query, record.hostID == hostID, record.deviceID == deviceID,
                  record.sourceID == receipt.sourceID, record.directories == directories, record.metadata == metadata,
                  Set(record.entries.keys) == Set(current.keys) else { throw ImageAllMigrationCleanupError.changed }
        } else {
            record = Record(version: 1, query: query, hostID: hostID, deviceID: deviceID, sourceID: receipt.sourceID,
                directories: directories, metadata: metadata, entries: current)
        }
        for (path, object) in current {
            guard let old = record.entries[path], old.sameObject(object),
                  old.size == expected[path]?.byteCount,
                  object.size == old.size || (names.contains(recordName) && object.size == 0) else { throw ImageAllMigrationCleanupError.changed }
            // Before first truncation and after interruption, hash every remaining byte.
            if object.size > 0 {
                let file = try IO.file(resourceFD, String(path.dropFirst(10)), write: false); defer { close(file) }
                guard try IO.resourceHash(file) == expected[path]?.sha256, try IO.ObjectVersion(file) == object else {
                    throw ImageAllMigrationCleanupError.changed
                }
            }
        }
        func validatePaths() throws {
            guard try ImageAllMigrationStagingLease.isCanonical(root), directories == (try directoryURLs.map(Object.init)) else { throw ImageAllMigrationCleanupError.changed }
        }
        try validatePaths()
        for (name, digest) in metadata {
            let parent = name.hasPrefix("facts/") ? factsFD : fd
            let component = name.hasPrefix("facts/") ? String(name.dropFirst(6)) : name
            guard try IO.hash(IO.read(parent, component)) == digest else { throw ImageAllMigrationCleanupError.changed }
        }
        if !names.contains(recordName) {
            let intent = openat(fd, recordName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard intent >= 0 else { throw ImageAllMigrationCleanupError.ioFailure }
            let handle = FileHandle(fileDescriptor: intent, closeOnDealloc: true)
            try handle.write(contentsOf: JSONEncoder().encode(record)); try handle.synchronize()
            guard fsync(fd) == 0 else { throw ImageAllMigrationCleanupError.ioFailure }
        }
        var bytes: Int64 = 0
        for (index, path) in current.keys.sorted().enumerated() {
            try Task.checkCancellation(); try beforeRelease(index); try validatePaths()
            let name = String(path.dropFirst(10))
            let file = try IO.file(resourceFD, name, write: true); defer { close(file) }
            let version = try IO.ObjectVersion(file)
            guard version == current[path] else { throw ImageAllMigrationCleanupError.changed }
            if version.size == 0 { continue }
            guard ftruncate(file, 0) == 0, fsync(file) == 0 else { throw ImageAllMigrationCleanupError.ioFailure }
            bytes += version.size
        }
        return .init(resourceCount: expected.count, logicalBytesReleased: bytes, alreadyReleased: bytes == 0)
    }
}
