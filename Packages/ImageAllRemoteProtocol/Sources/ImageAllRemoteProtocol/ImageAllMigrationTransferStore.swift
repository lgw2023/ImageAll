import CryptoKit
import Foundation

public enum ImageAllMigrationTransferError: Error, Equatable, Sendable {
    case unsafeRoot
    case unsafePath
    case identityConflict
    case invalidSession
    case chunkTooLarge
    case quotaExceeded
    case insufficientSpace
    case changedChunk
    case offsetConflict
    case sealed
    case incompleteArchive
}

public struct ImageAllMigrationTransferFileProgress: Codable, Sendable, Equatable {
    public let relativePath: String
    public let committedBytes: Int64
}

public struct ImageAllMigrationTransferProgress: Codable, Sendable, Equatable {
    public let migrationID: UUID
    public let maximumChunkBytes: Int
    public let maximumSessionBytes: Int64
    public let files: [ImageAllMigrationTransferFileProgress]
    public let sealed: Bool
    public let sourceInstallID: UUID?
}

/// A verified staging receipt. It is not a Mac catalog import receipt or a
/// migration-complete receipt.
public struct ImageAllMigrationTransferSealReceipt: Codable, Sendable, Equatable {
    public let migrationID: UUID
    public let manifestSHA256: String
    public let itemCount: Int
    public let resourceCount: Int
    public let verifiedBytes: Int64
    public let factsSHA256: String?

    public init(verification: ImageAllMigrationVerification) {
        migrationID = verification.migrationID
        manifestSHA256 = verification.manifestSHA256
        itemCount = verification.itemCount
        resourceCount = verification.resourceCount
        verifiedBytes = verification.verifiedBytes
        factsSHA256 = verification.factsSHA256
    }
}

/// A per-resource check of receiver-owned bytes, not an archive completion receipt.
public struct ImageAllMigrationResourceVerificationRequest: Codable, Sendable, Equatable {
    public let relativePath: String
    public let byteCount: Int64
    public let sha256: String

    public init(relativePath: String, byteCount: Int64, sha256: String) {
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public struct ImageAllMigrationResourceVerificationReceipt: Codable, Sendable, Equatable {
    public let migrationID: UUID
    public let deviceID: UUID
    public let resource: ImageAllMigrationResourceVerificationRequest
}

public struct ImageAllMigrationTransferSealedArchive: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let packageURL: URL
}

/// Durable, receiver-owned staging for one verified migration package. The
/// session journal is outside `package`, so the shared archive verifier sees
/// exactly the bytes the phone sent. Each chunk is synchronized before its
/// checksum and committed offset are atomically journaled. A crash in between
/// discards only the uncommitted tail on resume.
public actor ImageAllMigrationTransferStore {
    public static let defaultMaximumChunkBytes = 4 * 1_024 * 1_024
    public static let defaultMaximumSessionBytes: Int64 = 64 * 1_024 * 1_024 * 1_024
    private static let minimumFreeBytes: Int64 = 1 * 1_024 * 1_024 * 1_024

    private struct Chunk: Codable, Equatable {
        let offset: Int64
        let byteCount: Int
        let sha256: String
    }

    private struct Session: Codable {
        let formatVersion: Int
        let migrationID: UUID
        let deviceID: UUID
        var chunksByPath: [String: [Chunk]]
        var sealed: Bool
        var sourceInstallID: UUID? = nil
        var verifiedResources: [String: ImageAllMigrationResourceVerificationReceipt]? = nil
    }

    private let root: URL
    private let maximumChunkBytes: Int
    private var maximumSessionBytes: Int64
    private var loaded: [UUID: Session] = [:]

    public init(
        root: URL,
        maximumChunkBytes: Int = defaultMaximumChunkBytes,
        maximumSessionBytes: Int64 = defaultMaximumSessionBytes
    ) throws {
        guard maximumChunkBytes > 0, maximumChunkBytes <= Self.defaultMaximumChunkBytes,
              maximumSessionBytes > 0 else {
            throw ImageAllMigrationTransferError.invalidSession
        }
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ImageAllMigrationTransferError.unsafeRoot
        }
        self.root = root.standardizedFileURL
        self.maximumChunkBytes = maximumChunkBytes
        self.maximumSessionBytes = maximumSessionBytes
    }

    /// Serializes policy changes with writes in this receiver. Lowering the
    /// limit never removes committed data or prevents read-only verification.
    public func updateMaximumSessionBytes(_ value: Int64) throws {
        guard value > 0 else { throw ImageAllMigrationTransferError.invalidSession }
        maximumSessionBytes = value
    }

    public func begin(migrationID: UUID, authenticatedDeviceID: UUID, sourceInstallID: UUID? = nil) throws
        -> ImageAllMigrationTransferProgress {
        if var session = try load(migrationID: migrationID) {
            guard session.deviceID == authenticatedDeviceID else {
                throw ImageAllMigrationTransferError.identityConflict
            }
            if let sourceInstallID {
                guard session.sourceInstallID == nil || session.sourceInstallID == sourceInstallID,
                      !session.sealed || (session.sourceInstallID ?? authenticatedDeviceID) == sourceInstallID else {
                    throw ImageAllMigrationTransferError.identityConflict
                }
                if session.sourceInstallID == nil {
                    session.sourceInstallID = sourceInstallID
                    try persist(session)
                    loaded[migrationID] = session
                }
            }
            return progress(session)
        }
        let directory = sessionDirectory(migrationID)
        if FileManager.default.fileExists(atPath: directory.path) {
            // A crash between creating the package directory and writing the
            // first journal leaves no authenticated session or payload. Reuse
            // only that exact empty receiver-owned structure.
            let package = packageDirectory(migrationID)
            let directoryValues = try directory.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            let packageValues = try package.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard directoryValues.isDirectory == true,
                  directoryValues.isSymbolicLink != true,
                  packageValues.isDirectory == true,
                  packageValues.isSymbolicLink != true,
                  try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["package"],
                  try FileManager.default.contentsOfDirectory(atPath: package.path).isEmpty else {
                throw ImageAllMigrationTransferError.invalidSession
            }
        }
        try FileManager.default.createDirectory(
            at: packageDirectory(migrationID), withIntermediateDirectories: true
        )
        let session = Session(
            formatVersion: 1, migrationID: migrationID, deviceID: authenticatedDeviceID,
            chunksByPath: [:], sealed: false, sourceInstallID: sourceInstallID
        )
        do {
            try persist(session)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        loaded[migrationID] = session
        return progress(session)
    }

    public func status(migrationID: UUID, authenticatedDeviceID: UUID) throws
        -> ImageAllMigrationTransferProgress {
        guard let session = try load(migrationID: migrationID) else {
            throw ImageAllMigrationTransferError.invalidSession
        }
        guard session.deviceID == authenticatedDeviceID else {
            throw ImageAllMigrationTransferError.identityConflict
        }
        try repairFiles(in: session, verifyCommittedHashes: false)
        return progress(session)
    }

    public func append(
        migrationID: UUID, authenticatedDeviceID: UUID,
        relativePath: String, offset: Int64, bytes: Data, sha256: String
    ) throws -> ImageAllMigrationTransferProgress {
        guard Self.isAllowed(relativePath) else {
            throw ImageAllMigrationTransferError.unsafePath
        }
        guard !bytes.isEmpty, bytes.count <= maximumChunkBytes else {
            throw ImageAllMigrationTransferError.chunkTooLarge
        }
        let hash = Self.hex(Data(SHA256.hash(data: bytes)))
        guard sha256 == hash else { throw ImageAllMigrationTransferError.changedChunk }
        guard var session = try load(migrationID: migrationID),
              session.deviceID == authenticatedDeviceID else {
            throw ImageAllMigrationTransferError.identityConflict
        }
        guard !session.sealed || relativePath.hasPrefix("facts/") else {
            throw ImageAllMigrationTransferError.sealed
        }
        let file = packageDirectory(migrationID).appendingPathComponent(relativePath)
        try prepareFileParent(for: file, migrationID: migrationID)
        let committed = try Self.repairFile(
            at: file, chunks: session.chunksByPath[relativePath] ?? []
        )
        if offset < committed {
            guard let prior = session.chunksByPath[relativePath]?.first(where: {
                $0.offset == offset && $0.byteCount == bytes.count && $0.sha256 == hash
            }) else { throw ImageAllMigrationTransferError.offsetConflict }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(prior.offset))
            guard try handle.read(upToCount: prior.byteCount) == bytes else {
                throw ImageAllMigrationTransferError.changedChunk
            }
            return progress(session)
        }
        guard session.verifiedResources?[relativePath] == nil else {
            throw ImageAllMigrationTransferError.sealed
        }
        guard offset == committed, offset >= 0,
              Int64(bytes.count) <= Int64.max - committed else {
            throw ImageAllMigrationTransferError.offsetConflict
        }
        let used = session.chunksByPath.values.flatMap { $0 }.reduce(Int64(0)) {
            $0 + Int64($1.byteCount)
        }
        guard Int64(bytes.count) <= maximumSessionBytes - used else {
            throw ImageAllMigrationTransferError.quotaExceeded
        }
        let volumeAttributes = try FileManager.default.attributesOfFileSystem(forPath: root.path)
        let free = volumeAttributes[.systemFreeSize] as? NSNumber
        guard let free, free.int64Value >= Self.minimumFreeBytes + Int64(bytes.count) else {
            throw ImageAllMigrationTransferError.insufficientSpace
        }
        if !FileManager.default.fileExists(atPath: file.path) {
            guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
                throw ImageAllMigrationTransferError.invalidSession
            }
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: bytes)
        try handle.synchronize()
        session.chunksByPath[relativePath, default: []].append(.init(
            offset: offset, byteCount: bytes.count, sha256: hash
        ))
        try persist(session)
        loaded[migrationID] = session
        return progress(session)
    }

    /// Re-read one resource independently of the phone. Persistently freeze its
    /// extent after verification; replay of existing chunks remains idempotent.
    /// Final archive sealing still checks all resources and the manifest again.
    public func verifyResource(
        migrationID: UUID, authenticatedDeviceID: UUID,
        request: ImageAllMigrationResourceVerificationRequest
    ) throws -> ImageAllMigrationResourceVerificationReceipt {
        guard request.relativePath.hasPrefix("resources/"), Self.isAllowed(request.relativePath),
              request.byteCount > 0, request.sha256.count == 64,
              request.sha256.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw ImageAllMigrationTransferError.unsafePath
        }
        guard var session = try load(migrationID: migrationID),
              session.deviceID == authenticatedDeviceID else {
            throw ImageAllMigrationTransferError.identityConflict
        }
        try validateDirectories(for: migrationID)
        let file = packageDirectory(migrationID).appendingPathComponent(request.relativePath)
        let parent = try file.deletingLastPathComponent().resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard parent.isDirectory == true, parent.isSymbolicLink != true else {
            throw ImageAllMigrationTransferError.unsafePath
        }
        guard let chunks = session.chunksByPath[request.relativePath],
              try Self.repairFile(at: file, chunks: chunks) == request.byteCount else {
            throw ImageAllMigrationTransferError.offsetConflict
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var digest = SHA256()
        var count: Int64 = 0
        while let bytes = try handle.read(upToCount: 64 * 1_024), !bytes.isEmpty {
            try Task.checkCancellation()
            guard Int64(bytes.count) <= request.byteCount - count else {
                throw ImageAllMigrationTransferError.changedChunk
            }
            digest.update(data: bytes)
            count += Int64(bytes.count)
        }
        let hash = Self.hex(Data(digest.finalize()))
        guard count == request.byteCount, hash == request.sha256.lowercased() else {
            throw ImageAllMigrationTransferError.changedChunk
        }
        let receipt = ImageAllMigrationResourceVerificationReceipt(
            migrationID: migrationID, deviceID: authenticatedDeviceID,
            resource: .init(relativePath: request.relativePath, byteCount: count, sha256: hash))
        if let prior = session.verifiedResources?[request.relativePath], prior != receipt {
            throw ImageAllMigrationTransferError.identityConflict
        }
        session.verifiedResources = (session.verifiedResources ?? [:]).merging(
            [request.relativePath: receipt]) { _, new in new }
        try persist(session)
        loaded[migrationID] = session
        return receipt
    }

    /// Reserve a receiver-owned temporary file for one HTTP request body.
    /// The caller writes it in bounded blocks, then calls `commitIncomingChunk`.
    public func allocateIncomingChunk(
        migrationID: UUID, authenticatedDeviceID: UUID,
        relativePath: String, byteCount: Int
    ) throws -> URL {
        guard Self.isAllowed(relativePath) else {
            throw ImageAllMigrationTransferError.unsafePath
        }
        guard byteCount > 0, byteCount <= maximumChunkBytes else {
            throw ImageAllMigrationTransferError.chunkTooLarge
        }
        guard let session = try load(migrationID: migrationID),
              session.deviceID == authenticatedDeviceID else {
            throw ImageAllMigrationTransferError.identityConflict
        }
        // A sealed media package may receive later immutable fact checkpoints.
        // Manifest and resource bytes stay locked after the first seal.
        guard !session.sealed || relativePath.hasPrefix("facts/") else {
            throw ImageAllMigrationTransferError.sealed
        }
        try validateDirectories(for: migrationID)
        let volumeAttributes = try FileManager.default.attributesOfFileSystem(forPath: root.path)
        let free = volumeAttributes[.systemFreeSize] as? NSNumber
        guard let free, free.int64Value >= Self.minimumFreeBytes + Int64(byteCount) else {
            throw ImageAllMigrationTransferError.insufficientSpace
        }
        let incoming = sessionDirectory(migrationID).appendingPathComponent(
            "incoming", isDirectory: true
        )
        if FileManager.default.fileExists(atPath: incoming.path) {
            let values = try incoming.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw ImageAllMigrationTransferError.unsafePath
            }
        } else {
            try FileManager.default.createDirectory(
                at: incoming, withIntermediateDirectories: false
            )
        }
        let url = incoming.appendingPathComponent(UUID().uuidString.lowercased())
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw ImageAllMigrationTransferError.invalidSession
        }
        return url
    }

    public func commitIncomingChunk(
        migrationID: UUID, authenticatedDeviceID: UUID,
        relativePath: String, offset: Int64, temporaryURL: URL,
        byteCount: Int, sha256: String
    ) throws -> ImageAllMigrationTransferProgress {
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        guard temporaryURL.deletingLastPathComponent().standardizedFileURL ==
                sessionDirectory(migrationID).appendingPathComponent("incoming").standardizedFileURL,
              Self.isAllowed(relativePath), byteCount > 0,
              byteCount <= maximumChunkBytes else {
            throw ImageAllMigrationTransferError.unsafePath
        }
        let values = try temporaryURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              values.fileSize == byteCount else {
            throw ImageAllMigrationTransferError.changedChunk
        }
        let source = try FileHandle(forReadingFrom: temporaryURL)
        defer { try? source.close() }
        var sourceHash = SHA256()
        while let block = try source.read(upToCount: 64 * 1_024), !block.isEmpty {
            sourceHash.update(data: block)
        }
        guard Self.hex(Data(sourceHash.finalize())) == sha256 else {
            throw ImageAllMigrationTransferError.changedChunk
        }
        guard var session = try load(migrationID: migrationID),
              session.deviceID == authenticatedDeviceID else {
            throw ImageAllMigrationTransferError.identityConflict
        }
        guard !session.sealed || relativePath.hasPrefix("facts/") else {
            throw ImageAllMigrationTransferError.sealed
        }
        let file = packageDirectory(migrationID).appendingPathComponent(relativePath)
        try prepareFileParent(for: file, migrationID: migrationID)
        let committed = try Self.repairFile(
            at: file, chunks: session.chunksByPath[relativePath] ?? []
        )
        if offset < committed {
            guard let prior = session.chunksByPath[relativePath]?.first(where: {
                $0.offset == offset && $0.byteCount == byteCount && $0.sha256 == sha256
            }) else { throw ImageAllMigrationTransferError.offsetConflict }
            let target = try FileHandle(forReadingFrom: file)
            defer { try? target.close() }
            try target.seek(toOffset: UInt64(prior.offset))
            var remaining = byteCount
            var priorHash = SHA256()
            while remaining > 0 {
                let count = min(remaining, 64 * 1_024)
                guard let block = try target.read(upToCount: count), !block.isEmpty else {
                    throw ImageAllMigrationTransferError.changedChunk
                }
                priorHash.update(data: block)
                remaining -= block.count
            }
            guard Self.hex(Data(priorHash.finalize())) == sha256 else {
                throw ImageAllMigrationTransferError.changedChunk
            }
            return progress(session)
        }
        guard offset == committed, offset >= 0,
              Int64(byteCount) <= Int64.max - committed else {
            throw ImageAllMigrationTransferError.offsetConflict
        }
        let used = session.chunksByPath.values.flatMap { $0 }.reduce(Int64(0)) {
            $0 + Int64($1.byteCount)
        }
        guard Int64(byteCount) <= maximumSessionBytes - used else {
            throw ImageAllMigrationTransferError.quotaExceeded
        }
        if !FileManager.default.fileExists(atPath: file.path) {
            guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
                throw ImageAllMigrationTransferError.invalidSession
            }
        }
        let target = try FileHandle(forWritingTo: file)
        defer { try? target.close() }
        try target.seekToEnd()
        try source.seek(toOffset: 0)
        while let block = try source.read(upToCount: 64 * 1_024), !block.isEmpty {
            try target.write(contentsOf: block)
        }
        try target.synchronize()
        session.chunksByPath[relativePath, default: []].append(.init(
            offset: offset, byteCount: byteCount, sha256: sha256
        ))
        try persist(session)
        loaded[migrationID] = session
        return progress(session)
    }

    /// Sealing proves the package independently. Catalog import and any
    /// archive-complete receipt remain separate operations.
    public func sealVerifiedArchive(
        migrationID: UUID, authenticatedDeviceID: UUID
    ) throws -> (URL, ImageAllMigrationVerification) {
        guard var session = try load(migrationID: migrationID),
              session.deviceID == authenticatedDeviceID else {
            throw ImageAllMigrationTransferError.identityConflict
        }
        let package = packageDirectory(migrationID)
        try repairFiles(in: session, verifyCommittedHashes: false)
        let (header, verification) = try ImageAllMigrationArchive.readVerifiedHeader(
            at: package
        )
        guard verification.migrationID == migrationID,
              header.sourceDeviceID == (session.sourceInstallID ?? authenticatedDeviceID),
              verification.isComplete else {
            throw ImageAllMigrationTransferError.incompleteArchive
        }
        if !session.sealed {
            session.sealed = true
            try persist(session)
            loaded[migrationID] = session
        }
        return (package, verification)
    }

    /// Local Mac UI only: lists completed staging packages for explicit
    /// catalog import. The package is verified again by the importer.
    public func sealedArchives() throws -> [ImageAllMigrationTransferSealedArchive] {
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        var archives: [ImageAllMigrationTransferSealedArchive] = []
        for name in names where name.hasPrefix(".imageall-transfer-") {
            let idText = String(name.dropFirst(".imageall-transfer-".count))
            guard let id = UUID(uuidString: idText),
                  name == ".imageall-transfer-\(id.uuidString.lowercased())" else {
                continue
            }
            guard let session = try load(migrationID: id, repair: false), session.sealed,
                  let verification = try? ImageAllMigrationArchive.verify(
                    at: packageDirectory(id)
                  ), verification.isComplete else { continue }
            archives.append(.init(id: id, packageURL: packageDirectory(id)))
        }
        return archives.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private func load(migrationID: UUID, repair: Bool = true) throws -> Session? {
        if let cached = loaded[migrationID] { return cached }
        let url = sessionDirectory(migrationID).appendingPathComponent("session.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ImageAllMigrationTransferError.invalidSession
        }
        let session = try JSONDecoder().decode(Session.self, from: Data(contentsOf: url))
        guard session.formatVersion == 1, session.migrationID == migrationID,
              session.chunksByPath.keys.allSatisfy(Self.isAllowed) else {
            throw ImageAllMigrationTransferError.invalidSession
        }
        if repair {
            try repairFiles(in: session, verifyCommittedHashes: true)
            loaded[migrationID] = session
        } else {
            // A separate UI reader must not truncate an active writer's
            // not-yet-journaled tail or cache an unrecovered session.
            try validateDirectories(for: migrationID)
        }
        return session
    }

    private func repairFiles(
        in session: Session, verifyCommittedHashes: Bool
    ) throws {
        try validateDirectories(for: session.migrationID)
        for (path, chunks) in session.chunksByPath {
            guard Self.isAllowed(path) else {
                throw ImageAllMigrationTransferError.invalidSession
            }
            let file = packageDirectory(session.migrationID).appendingPathComponent(path)
            let parent = file.deletingLastPathComponent()
            if parent != packageDirectory(session.migrationID) {
                let values = try parent.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                )
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    throw ImageAllMigrationTransferError.unsafePath
                }
            }
            _ = try Self.repairFile(
                at: file,
                chunks: chunks, verifyCommittedHashes: verifyCommittedHashes
            )
        }
    }

    private func validateDirectories(for id: UUID) throws {
        for directory in [root, sessionDirectory(id), packageDirectory(id)] {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw ImageAllMigrationTransferError.unsafeRoot
            }
        }
    }

    private func prepareFileParent(for file: URL, migrationID: UUID) throws {
        try validateDirectories(for: migrationID)
        let parent = file.deletingLastPathComponent()
        if parent == packageDirectory(migrationID) { return }
        let name = parent.lastPathComponent
        let entries = try FileManager.default.contentsOfDirectory(
            atPath: packageDirectory(migrationID).path
        )
        if entries.contains(name) {
            let values = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw ImageAllMigrationTransferError.unsafePath
            }
        } else {
            try FileManager.default.createDirectory(
                at: parent, withIntermediateDirectories: false
            )
        }
    }

    private func persist(_ session: Session) throws {
        let data = try JSONEncoder().encode(session)
        try data.write(
            to: sessionDirectory(session.migrationID).appendingPathComponent("session.json"),
            options: .atomic
        )
    }

    private func progress(_ session: Session) -> ImageAllMigrationTransferProgress {
        .init(
            migrationID: session.migrationID,
            maximumChunkBytes: maximumChunkBytes,
            maximumSessionBytes: maximumSessionBytes,
            files: session.chunksByPath.map { path, chunks in
                .init(relativePath: path, committedBytes: Self.committedLength(chunks))
            }.sorted { $0.relativePath < $1.relativePath },
            sealed: session.sealed, sourceInstallID: session.sourceInstallID
        )
    }

    private func sessionDirectory(_ id: UUID) -> URL {
        root.appendingPathComponent(
            ".imageall-transfer-\(id.uuidString.lowercased())", isDirectory: true
        )
    }

    private func packageDirectory(_ id: UUID) -> URL {
        sessionDirectory(id).appendingPathComponent("package", isDirectory: true)
    }

    private static func repairFile(
        at url: URL, chunks: [Chunk], verifyCommittedHashes: Bool = false
    ) throws -> Int64 {
        var end: Int64 = 0
        for chunk in chunks {
            guard chunk.offset == end, chunk.byteCount > 0,
                  chunk.byteCount <= defaultMaximumChunkBytes,
                  chunk.sha256.count == 64,
                  chunk.sha256.allSatisfy(\.isHexDigit),
                  Int64(chunk.byteCount) <= Int64.max - end else {
                throw ImageAllMigrationTransferError.invalidSession
            }
            end += Int64(chunk.byteCount)
        }
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else {
            guard chunks.isEmpty else { throw ImageAllMigrationTransferError.invalidSession }
            return 0
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, Int64(size) >= end else {
            throw ImageAllMigrationTransferError.invalidSession
        }
        if Int64(size) > end {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(end))
            try handle.synchronize()
        }
        if verifyCommittedHashes, !chunks.isEmpty {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            for chunk in chunks {
                guard let bytes = try handle.read(upToCount: chunk.byteCount),
                      bytes.count == chunk.byteCount,
                      hex(Data(SHA256.hash(data: bytes))) == chunk.sha256 else {
                    throw ImageAllMigrationTransferError.changedChunk
                }
            }
        }
        return end
    }

    private static func committedLength(_ chunks: [Chunk]) -> Int64 {
        chunks.reduce(0) { $0 + Int64($1.byteCount) }
    }

    private static func isAllowed(_ path: String) -> Bool {
        if path == ImageAllMigrationArchive.manifestFilename { return true }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let name = String(parts[1])
        if parts[0] == "resources" {
            let nameParts = name.split(separator: ".", omittingEmptySubsequences: false)
            return nameParts.count == 2
                && UUID(uuidString: String(nameParts[0]))?.uuidString.lowercased()
                    == String(nameParts[0])
                && (1...12).contains(nameParts[1].count)
                && nameParts[1].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        }
        if parts[0] == ImageAllMigrationFacts.sidecarDirectoryName {
            let pattern = #"^[0-9]{20}-[0-9a-f]{64}\.imageallfacts$"#
            return name.range(of: pattern, options: .regularExpression) != nil
        }
        return false
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
