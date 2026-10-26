import CryptoKit
import Darwin
import Foundation

public enum ImageAllMigrationCleanupError: LocalizedError, Equatable {
    case busy, unsafePath, unowned, changed, incompleteReferences, ioFailure, retired

    public var errorDescription: String? {
        switch self {
        case .busy: "接收目录仍被使用，请停止连接服务并等待读取完成。"
        case .unsafePath: "暂存路径、链接或文件类型不符合安全要求。"
        case .unowned: "暂存所有权登记不完整，不能执行收尾。"
        case .changed: "暂存或目标对象已变化，请先核查。"
        case .incompleteReferences: "最终副本、发布状态或资源引用尚未完整核对。"
        case .ioFailure: "暂存释放未完成，收尾记录已保留。"
        case .retired: "此批次接收暂存已进入收尾，请查询 Mac 已导入结果，勿重新传输。"
        }
    }
}

public struct ImageAllMigrationCleanupResult: Sendable, Equatable {
    public let resourceCount: Int
    public let logicalBytesReleased: Int64
    public let alreadyReleased: Bool
}

public enum ImageAllMigrationStagingCleanup {
    static let recordName = "payload-retirement.json"
    static func hasIntent(in session: URL) throws -> Bool {
        var info = stat()
        if lstat(session.appendingPathComponent(recordName).path, &info) == 0 { return true }
        guard errno == ENOENT else { throw ImageAllMigrationCleanupError.unsafePath }
        return false
    }
    struct ObjectVersion: Codable, Equatable {
        let device: Int32, inode: UInt64, birth: Int64, birthNS: Int64
        let size: Int64, modified: Int64, modifiedNS: Int64, changed: Int64, changedNS: Int64
        init(_ fd: Int32) throws {
            var s = stat()
            guard fstat(fd, &s) == 0, s.st_mode & S_IFMT == S_IFREG, s.st_nlink == 1 else {
                throw ImageAllMigrationCleanupError.unsafePath
            }
            device = s.st_dev; inode = s.st_ino
            birth = Int64(s.st_birthtimespec.tv_sec); birthNS = Int64(s.st_birthtimespec.tv_nsec)
            size = s.st_size
            modified = Int64(s.st_mtimespec.tv_sec); modifiedNS = Int64(s.st_mtimespec.tv_nsec)
            changed = Int64(s.st_ctimespec.tv_sec); changedNS = Int64(s.st_ctimespec.tv_nsec)
        }
        func sameObject(_ other: Self) -> Bool {
            device == other.device && inode == other.inode && birth == other.birth && birthNS == other.birthNS
        }
    }
    private struct Entry: Codable {
        let path: String
        let object: ObjectVersion
    }
    private struct Record: Codable {
        let version: Int
        let migrationID: UUID
        let finalPath: String
        let sessionSHA256: String
        let manifestSHA256: String
        let factsSHA256: String?
        let metadataSHA256: [String: String]
        let directories: [ImageAllMigrationTransferStore.StorageObject]
        let targetObjects: [String: ImageAllMigrationTransferStore.StorageObject]
        let entries: [Entry]
    }

    public static func release(root: URL, migrationID: UUID, finalArchive: URL,
                               publicationVerification: (() throws -> ImageAllMigrationVerification)? = nil,
                               sourceVerification: ImageAllMigrationVerification? = nil,
                               reuseVerifiedContents: Bool = false,
                               validatePublication: () throws -> Void) throws -> ImageAllMigrationCleanupResult {
        try release(root: root, migrationID: migrationID, finalArchive: finalArchive,
                    validatePublication: validatePublication, beforeRelease: { _ in },
                    publicationVerification: publicationVerification, sourceVerification: sourceVerification,
                    reuseVerifiedContents: reuseVerifiedContents)
    }

    // Failure seam is internal; the public operation cannot bypass ownership checks.
    static func release(root: URL, migrationID: UUID, finalArchive: URL,
                        validatePublication: () throws -> Void,
                        beforeRelease: (Int) throws -> Void,
                        publicationVerification: (() throws -> ImageAllMigrationVerification)? = nil,
                        sourceVerification: ImageAllMigrationVerification? = nil,
                        reuseVerifiedContents: Bool = false) throws -> ImageAllMigrationCleanupResult {
        let root = root.standardizedFileURL, final = finalArchive.standardizedFileURL
        guard try ImageAllMigrationStagingLease.isCanonical(root), try ImageAllMigrationStagingLease.isCanonical(final) else {
            throw ImageAllMigrationCleanupError.unsafePath
        }
        let lease = try ImageAllMigrationStagingLease(root: root, exclusive: true)
        defer { withExtendedLifetime(lease) {} }
        let name = ".imageall-transfer-\(migrationID.uuidString.lowercased())"
        let sessionURL = root.appendingPathComponent(name), package = sessionURL.appendingPathComponent("package")
        guard !final.path.hasPrefix(sessionURL.path + "/"), final != sessionURL,
              !sessionURL.path.hasPrefix(final.path + "/") else { throw ImageAllMigrationCleanupError.unsafePath }
        let sessionFD = try directory(lease.fd, name)
        defer { close(sessionFD) }
        let packageFD = try directory(sessionFD, "package")
        defer { close(packageFD) }
        let resourcesFD = try directory(packageFD, "resources")
        defer { close(resourcesFD) }
        let finalFD = try ImageAllMigrationStagingLease.openDirectory(final)
        defer { close(finalFD) }
        let finalResourcesFD = try directory(finalFD, "resources")
        defer { close(finalResourcesFD) }
        let boundDirectories = [package.appendingPathComponent("resources"), final, final.appendingPathComponent("resources")]
        let directoryObjects = try boundDirectories.map(ImageAllMigrationTransferStore.StorageObject.init)
        let journal = try read(sessionFD, "session.json")
        let session = try JSONDecoder().decode(ImageAllMigrationTransferStore.Session.self, from: journal)
        guard session.ownershipVersion == 1 else { throw ImageAllMigrationCleanupError.unowned }
        guard session.formatVersion == 1, session.migrationID == migrationID, session.sealed,
              session.factsUpdatePending == false,
              session.directoryObjects == (try [root, sessionURL, package].map(ImageAllMigrationTransferStore.StorageObject.init)),
              Set(session.storageObjects?.keys.map { $0 } ?? []) == Set(session.chunksByPath.keys) else {
            throw ImageAllMigrationCleanupError.changed
        }
        // Unfinished HTTP bodies and unknown files are never adopted as garbage.
        if FileManager.default.fileExists(atPath: sessionURL.appendingPathComponent("incoming").path) {
            let incomingFD = try directory(sessionFD, "incoming"); defer { close(incomingFD) }
            guard try names(incomingFD).isEmpty else { throw ImageAllMigrationCleanupError.busy }
        }
        let allowedSessionNames: Set<String> = Set(["package", "incoming", "session.json", recordName])
            .union(session.hostHandoff == nil ? [] : ["host-processing.json"])
        guard try names(sessionFD).isSubset(of: allowedSessionNames),
              try names(packageFD).isSubset(of: ["resources", "facts", "manifest.jsonl"]) else {
            throw ImageAllMigrationCleanupError.unowned
        }
        var metadata = ["manifest.jsonl": hash(try read(packageFD, "manifest.jsonl"))]
        let factPaths = Set(session.chunksByPath.keys.filter { $0.hasPrefix("facts/") })
        if try names(packageFD).contains("facts") {
            let fd = try directory(packageFD, "facts"); defer { close(fd) }
            guard try names(fd) == Set(factPaths.map { String($0.dropFirst(6)) }) else {
                throw ImageAllMigrationCleanupError.incompleteReferences
            }
            for path in factPaths { metadata[path] = hash(try read(fd, String(path.dropFirst(6)))) }
        } else if !factPaths.isEmpty { throw ImageAllMigrationCleanupError.incompleteReferences }
        guard Set(metadata.keys).union(session.chunksByPath.keys.filter { validResource($0) }) == Set(session.chunksByPath.keys) else {
            throw ImageAllMigrationCleanupError.unowned
        }
        try validatePublication()
        // A publisher may supply its just-completed full audit while this
        // exclusive lease is held. Reuse only the preflight; the records visitor
        // below performs a full pass unless ADR-121 scoped reuse is explicit.
        let prior = try publicationVerification?()
        let (header, verification) = try ImageAllMigrationArchive.readVerifiedHeader(at: final, priorVerification: prior)
        guard verification.migrationID == migrationID, verification.isComplete,
              header.sourceDeviceID == (session.sourceInstallID ?? session.deviceID) else {
            throw ImageAllMigrationCleanupError.incompleteReferences
        }
        var expected: [String: Int64] = [:], expectedHashes: [String: String] = [:]
        _ = try ImageAllMigrationArchive.visitVerifiedRecords(at: final, priorVerification: verification,
            reuseVerifiedContents: reuseVerifiedContents, onHeader: { _ in }, onItem: { item in
                for resource in item.resources {
                    guard let path = resource.relativePath, let size = resource.byteCount, let digest = resource.sha256,
                          validResource(path), expected[path] == nil else { throw ImageAllMigrationCleanupError.incompleteReferences }
                    expected[path] = size
                    expectedHashes[path] = digest
                }
            })
        guard Set(expected.keys) == Set(session.chunksByPath.keys.filter { $0.hasPrefix("resources/") }),
              try names(resourcesFD) == Set(expected.keys.map { String($0.dropFirst(10)) }),
              hash(try read(packageFD, "manifest.jsonl")) == verification.manifestSHA256 else {
            throw ImageAllMigrationCleanupError.incompleteReferences
        }
        for (path, size) in expected {
            var end: Int64 = 0
            for chunk in session.chunksByPath[path] ?? [] {
                guard chunk.offset == end, chunk.byteCount > 0,
                      Int64(chunk.byteCount) <= size - end else { throw ImageAllMigrationCleanupError.changed }
                end += Int64(chunk.byteCount)
            }
            guard end == size else { throw ImageAllMigrationCleanupError.incompleteReferences }
        }
        var targetObjects: [String: ImageAllMigrationTransferStore.StorageObject] = [:]
        for path in expected.keys {
            targetObjects[path] = try .init(at: final.appendingPathComponent(path))
        }
        let record: Record
        if try names(sessionFD).contains(recordName) {
            record = try JSONDecoder().decode(Record.self, from: read(sessionFD, recordName))
            guard record.version == 1, record.migrationID == migrationID, record.finalPath == final.path,
                  record.sessionSHA256 == hash(journal), record.manifestSHA256 == verification.manifestSHA256,
                  record.factsSHA256 == verification.factsSHA256,
                  record.metadataSHA256 == metadata,
                  record.directories == directoryObjects, record.targetObjects == targetObjects,
                  record.entries.count == expected.count, Set(record.entries.map(\.path)) == Set(expected.keys) else {
                throw ImageAllMigrationCleanupError.changed
            }
        } else {
            // Initial retirement proves staging contents too. Subsequent retries
            // rely on immutable identity records because payloads may be zero.
            let staged: ImageAllMigrationVerification
            if reuseVerifiedContents, let sourceVerification {
                try sourceVerification.validateStorageIdentity(at: package)
                staged = sourceVerification
            } else { staged = try ImageAllMigrationArchive.verify(at: package) }
            guard staged == verification else { throw ImageAllMigrationCleanupError.incompleteReferences }
            var entries: [Entry] = []
            for path in expected.keys.sorted() {
                guard try ImageAllMigrationTransferStore.StorageObject(at: package.appendingPathComponent(path)) == session.storageObjects?[path] else {
                    throw ImageAllMigrationCleanupError.changed
                }
                let fd = try file(resourcesFD, String(path.dropFirst(10)), write: false)
                defer { close(fd) }
                entries.append(.init(path: path, object: try ObjectVersion(fd)))
            }
            record = Record(version: 1, migrationID: migrationID, finalPath: final.path,
                sessionSHA256: hash(journal), manifestSHA256: verification.manifestSHA256,
                factsSHA256: verification.factsSHA256, metadataSHA256: metadata,
                directories: directoryObjects, targetObjects: targetObjects, entries: entries)
        }
        // Preflight EVERY object before any destructive action. No partial release
        // from a pre-existing identity, link, coverage or version mismatch.
        var targets: [String: ObjectVersion] = [:]
        var stagedVersions: [String: ObjectVersion] = [:]
        for entry in record.entries {
            let name = String(entry.path.dropFirst(10))
            let fd = try file(resourcesFD, name, write: false); defer { close(fd) }
            let current = try ObjectVersion(fd)
            guard entry.object.size == expected[entry.path],
                  entry.object.sameObject(current), current.size == entry.object.size || current.size == 0 else {
                throw ImageAllMigrationCleanupError.changed
            }
            if current.size != 0 && current != entry.object {
                // Restoring write permission changes ctime. Re-admit the same
                // object only after reading and hashing its complete payload.
                guard try resourceHash(fd) == expectedHashes[entry.path], try ObjectVersion(fd) == current else {
                    throw ImageAllMigrationCleanupError.changed
                }
            }
            stagedVersions[entry.path] = current
            let targetFD = try file(finalResourcesFD, name, write: false); defer { close(targetFD) }
            let target = try ObjectVersion(targetFD)
            guard !target.sameObject(current) else { throw ImageAllMigrationCleanupError.unsafePath }
            targets[entry.path] = target
        }
        try verification.validateStorageIdentity(at: final)
        try validatePublication()
        if !(try names(sessionFD).contains(recordName)) {
            // Exclusive create + fsync, deliberately no remove-on-failure: a
            // partial/corrupt intent blocks resume and requires inspection.
            let fd = openat(sessionFD, recordName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw ImageAllMigrationCleanupError.ioFailure }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: JSONEncoder().encode(record))
            try handle.synchronize()
            guard fsync(sessionFD) == 0 else { throw ImageAllMigrationCleanupError.ioFailure }
        }
        var bytes: Int64 = 0
        for (index, entry) in record.entries.enumerated() {
            try Task.checkCancellation()
            try beforeRelease(index)
            guard directoryObjects == (try boundDirectories.map(ImageAllMigrationTransferStore.StorageObject.init)) else {
                throw ImageAllMigrationCleanupError.changed
            }
            let name = String(entry.path.dropFirst(10))
            let fd = try file(resourcesFD, name, write: true); defer { close(fd) }
            let current = try ObjectVersion(fd)
            guard entry.object.sameObject(current), current == stagedVersions[entry.path],
                  try ImageAllMigrationTransferStore.StorageObject(at: package.appendingPathComponent(entry.path)) == session.storageObjects?[entry.path],
                  session.directoryObjects == (try [root, sessionURL, package].map(ImageAllMigrationTransferStore.StorageObject.init)) else {
                throw ImageAllMigrationCleanupError.changed
            }
            let targetFD = try file(finalResourcesFD, name, write: false); defer { close(targetFD) }
            guard try ObjectVersion(targetFD) == targets[entry.path] else { throw ImageAllMigrationCleanupError.changed }
            if current.size == 0 { continue }
            guard ftruncate(fd, 0) == 0, fsync(fd) == 0 else { throw ImageAllMigrationCleanupError.ioFailure }
            bytes += current.size
        }
        return .init(resourceCount: record.entries.count, logicalBytesReleased: bytes, alreadyReleased: bytes == 0)
    }

    static func directory(_ parent: Int32, _ name: String) throws -> Int32 {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ImageAllMigrationCleanupError.unsafePath }; return fd
    }
    static func file(_ parent: Int32, _ name: String, write: Bool) throws -> Int32 {
        let fd = openat(parent, name, (write ? O_RDWR : O_RDONLY) | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ImageAllMigrationCleanupError.unsafePath }
        do { _ = try ObjectVersion(fd); return fd } catch { close(fd); throw error }
    }
    static func read(_ parent: Int32, _ name: String) throws -> Data {
        let fd = try file(parent, name, write: false)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard try ObjectVersion(fd).size <= 64 * 1024 * 1024 else { throw ImageAllMigrationCleanupError.unowned }
        return try handle.readToEnd() ?? Data()
    }
    static func names(_ fd: Int32) throws -> Set<String> {
        let copy = dup(fd)
        guard copy >= 0, let stream = fdopendir(copy) else { if copy >= 0 { close(copy) }; throw ImageAllMigrationCleanupError.ioFailure }
        defer { closedir(stream) }
        rewinddir(stream)
        var result = Set<String>()
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { result.insert(name) }
        }
        return result
    }
    static func validResource(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "resources" else { return false }
        let name = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        return name.count == 2 && UUID(uuidString: String(name[0]))?.uuidString.lowercased() == String(name[0])
            && (1...12).contains(name[1].count) && name[1].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func resourceHash(_ fd: Int32) throws -> String {
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        try handle.seek(toOffset: 0)
        var digest = SHA256()
        while let block = try ImageAllMigrationFileIO.read(handle, upToCount: ImageAllMigrationFileIO.resourceBlockBytes), !block.isEmpty {
            try Task.checkCancellation()
            digest.update(data: block)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
