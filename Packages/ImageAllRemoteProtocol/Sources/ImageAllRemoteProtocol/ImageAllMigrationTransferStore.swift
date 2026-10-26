import CryptoKit
import Foundation
import Darwin

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

    /// A chunk ACK can contain only its file. Preserve the initial batch view
    /// when returning the public file-upload result; begin/status remain full.
    public func includingEarlierFiles(from earlier: Self) -> Self {
        var combined = Dictionary(earlier.files.map { ($0.relativePath, $0) }, uniquingKeysWith: { _, new in new })
        for file in files { combined[file.relativePath] = file }
        return .init(migrationID: migrationID, maximumChunkBytes: maximumChunkBytes,
            maximumSessionBytes: maximumSessionBytes,
            files: combined.values.sorted { $0.relativePath < $1.relativePath },
            sealed: sealed, sourceInstallID: sourceInstallID)
    }
}

/// Legacy seal, or explicitly versioned durable handoff. `verifiedBytes` keeps
/// the wire name: for handoff it sums durably received extents, NOT a fresh
/// full-archive audit. Neither kind proves catalog publication.
public struct ImageAllMigrationTransferSealReceipt: Codable, Sendable, Equatable {
    public let migrationID: UUID
    public let manifestSHA256: String
    public let itemCount: Int
    public let resourceCount: Int
    public let verifiedBytes: Int64
    public let factsSHA256: String?
    public let hostProcessingVersion: Int?

    public init(verification: ImageAllMigrationVerification) {
        hostProcessingVersion = nil
        migrationID = verification.migrationID
        manifestSHA256 = verification.manifestSHA256
        itemCount = verification.itemCount
        resourceCount = verification.resourceCount
        verifiedBytes = verification.verifiedBytes
        factsSHA256 = verification.factsSHA256
    }
    init(handoff summary: ImageAllMigrationVerification) {
        migrationID = summary.migrationID; manifestSHA256 = summary.manifestSHA256
        itemCount = summary.itemCount; resourceCount = summary.resourceCount
        verifiedBytes = summary.verifiedBytes; factsSHA256 = summary.factsSHA256
        hostProcessingVersion = 1
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
    /// Explicit opt-in custody of fsynced, individually SHA-checked chunks.
    /// The resource's declared SHA is still pending the Mac full-file gate.
    public var custodyVersion: Int? = nil
}

/// Receiver-owned durable acknowledgments for fast reconnect. Legacy entries
/// describe earlier whole-resource SHA verification. Explicit custody clients
/// may also receive custodyVersion=1 entries with a declared resource digest;
/// those prove committed chunks only, not a fresh integrity audit or completion.
/// Final sealing and catalog import must still independently verify all bytes.
public struct ImageAllMigrationResumeCheckpoint: Codable, Sendable, Equatable {
    public let migrationID: UUID
    public let deviceID: UUID
    public let sourceInstallID: UUID?
    public let sealed: Bool
    public let resources: [ImageAllMigrationResourceVerificationReceipt]
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

    struct Chunk: Codable, Equatable {
        let offset: Int64
        let byteCount: Int
        let sha256: String
    }

    struct StorageObject: Codable, Equatable {
        let device: Int32
        let inode: UInt64
        let birthSeconds: Int64
        let birthNanoseconds: Int64

        init(at url: URL) throws {
            var info = stat()
            guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) != S_IFLNK else {
                throw ImageAllMigrationTransferError.invalidSession
            }
            device = info.st_dev
            inode = info.st_ino
            birthSeconds = Int64(info.st_birthtimespec.tv_sec)
            birthNanoseconds = Int64(info.st_birthtimespec.tv_nsec)
        }
    }

    private struct LedgerBinding: Codable {
        let path: String
        let chunks: [Chunk]
        let receipt: ImageAllMigrationResourceVerificationReceipt?
    }

    public enum RecoveryPolicy: Sendable {
        case verifiedBytes
        /// Restores receiving progress only; sealing/import must still verify actual bytes.
        case receiveProgress
    }

    struct Session: Codable {
        let formatVersion: Int
        let migrationID: UUID
        let deviceID: UUID
        var chunksByPath: [String: [Chunk]]
        var sealed: Bool
        // Optional for legacy journals; immutable media lock stays sealed while facts change.
        var factsUpdatePending: Bool? = nil
        var sourceInstallID: UUID? = nil
        var verifiedResources: [String: ImageAllMigrationResourceVerificationReceipt]? = nil
        // Absent on legacy journals, which must pass strict byte verification first.
        var storageObjects: [String: StorageObject]? = nil
        var directoryObjects: [StorageObject]? = nil
        var ledgerDigests: [String: String]? = nil
        var ownerBinding: String? = nil
        var ownershipVersion: Int? = nil
        var automaticCleanupVersion: Int? = nil
        var hostHandoff: ImageAllMigrationHostJob? = nil
    }

    /// Encoded values only; this cache is never an integrity receipt. Keep one
    /// task and bound both payload and per-entry dictionary overhead (ADR-112).
    private struct JournalRow {
        let digest: String
        let object: StorageObject
        let key: Data
        let chunks: Data
        let receipt: Data?
        let storage: Data
        let ledger: Data
        var byteCount: Int { key.count + chunks.count + (receipt?.count ?? 0) + storage.count + ledger.count }
    }

    private struct JournalEncodingCache {
        let migrationID: UUID
        var rows: [String: JournalRow] = [:]
        var byteCount = 0
    }

    /// Keep the existing wire keys while encoding the large maps separately.
    private struct JournalHeader: Encodable {
        let session: Session
        enum CodingKeys: String, CodingKey {
            case formatVersion, migrationID, deviceID, sealed, factsUpdatePending
            case sourceInstallID, directoryObjects, ownerBinding, ownershipVersion, automaticCleanupVersion, hostHandoff
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(session.formatVersion, forKey: .formatVersion)
            try c.encode(session.migrationID, forKey: .migrationID)
            try c.encode(session.deviceID, forKey: .deviceID)
            try c.encode(session.sealed, forKey: .sealed)
            try c.encodeIfPresent(session.factsUpdatePending, forKey: .factsUpdatePending)
            try c.encodeIfPresent(session.sourceInstallID, forKey: .sourceInstallID)
            try c.encodeIfPresent(session.directoryObjects, forKey: .directoryObjects)
            try c.encodeIfPresent(session.ownerBinding, forKey: .ownerBinding)
            try c.encodeIfPresent(session.ownershipVersion, forKey: .ownershipVersion)
            try c.encodeIfPresent(session.automaticCleanupVersion, forKey: .automaticCleanupVersion)
            try c.encodeIfPresent(session.hostHandoff, forKey: .hostHandoff)
        }
    }

    private var journalEncodingCache: JournalEncodingCache?
    private var journalEncodingCacheEnabled = true

    // Internal test seam: same binary, original encoder, no production UI or setting.
    func disableJournalEncodingCacheForDiagnostics() {
        journalEncodingCacheEnabled = false
        journalEncodingCache = nil
    }

    private let recoveryPolicy: RecoveryPolicy
    private let root: URL
    private var lifetimeLease: ImageAllMigrationStagingLease?
    private let maximumChunkBytes: Int
    private var maximumSessionBytes: Int64
    private var loaded: [UUID: Session] = [:]

    public init(
        root: URL,
        maximumChunkBytes: Int = defaultMaximumChunkBytes,
        maximumSessionBytes: Int64 = defaultMaximumSessionBytes,
        recoveryPolicy: RecoveryPolicy = .verifiedBytes
    ) throws {
        guard maximumChunkBytes > 0, maximumChunkBytes <= Self.defaultMaximumChunkBytes,
              maximumSessionBytes > 0 else {
            throw ImageAllMigrationTransferError.invalidSession
        }
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ImageAllMigrationTransferError.unsafeRoot
        }
        self.recoveryPolicy = recoveryPolicy
        self.root = root.standardizedFileURL
        self.lifetimeLease = try ImageAllMigrationStagingLease(root: root)
        self.maximumChunkBytes = maximumChunkBytes
        self.maximumSessionBytes = maximumSessionBytes
    }

    private func ensureLifetimeLease() throws {
        if lifetimeLease == nil { lifetimeLease = try ImageAllMigrationStagingLease(root: root) }
    }

    /// Synchronous actor critical section: no request can reenter while our own
    /// shared lease is suspended. Other readers still make cleanup fail busy.
    /// A failed reacquisition makes ALL later file entry points acquire first.
    public func performAutomaticCleanup<T: Sendable>(query: RemoteImportTaskQuery,
        authenticatedDeviceID: UUID, operation: @Sendable (URL) throws -> T) throws -> T {
        try ensureLifetimeLease()
        try validateDirectories(for: query.migrationID)
        let directory = try ImageAllMigrationStagingLease.openDirectory(sessionDirectory(query.migrationID))
        defer { close(directory) }
        let bytes = try ImageAllMigrationStagingCleanup.read(directory, "session.json")
        let session = try JSONDecoder().decode(Session.self, from: bytes)
        guard session.automaticCleanupVersion == 1, session.ownershipVersion == 1 else {
            throw ImageAllMigrationCleanupError.unowned
        }
        guard session.migrationID == query.migrationID, session.deviceID == authenticatedDeviceID,
              (session.sourceInstallID ?? session.deviceID) == query.sourceInstallID,
              session.sealed, session.factsUpdatePending == false else {
            throw ImageAllMigrationCleanupError.incompleteReferences
        }
        loaded.removeValue(forKey: query.migrationID)
        lifetimeLease = nil
        defer { lifetimeLease = try? ImageAllMigrationStagingLease(root: root) }
        return try operation(root)
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
                    try persist(&session)
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
        var session = Session(
            formatVersion: 1, migrationID: migrationID, deviceID: authenticatedDeviceID,
            chunksByPath: [:], sealed: false, sourceInstallID: sourceInstallID, ownershipVersion: 1, automaticCleanupVersion: 1
        )
        do {
            try persist(&session)
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

    /// UI observation only. No repair, resource reads or recovered-session cache.
    /// A seal flag says "received", never "published" or freshly reverified.
    public func recordedSealState(migrationID: UUID, authenticatedDeviceID: UUID,
                                  sourceInstallID: UUID) throws -> Bool {
        guard let session = try load(migrationID: migrationID, repair: false) else {
            throw ImageAllMigrationTransferError.invalidSession
        }
        guard session.deviceID == authenticatedDeviceID, session.sourceInstallID == sourceInstallID else {
            throw ImageAllMigrationTransferError.identityConflict
        }
        return session.sealed
    }

    /// One bounded control exchange replaces N per-resource full re-hashes.
    /// Cold process recovery retains load's committed-chunk integrity check.
    /// A reconnect in the same process only checks journal and file presence/size;
    /// same-size media corruption is still rejected by sealVerifiedArchive.
    public func resumeCheckpoint(migrationID: UUID, authenticatedDeviceID: UUID, allowDurableCustody: Bool = false) throws
        -> ImageAllMigrationResumeCheckpoint {
        guard let session = try load(migrationID: migrationID),
              session.deviceID == authenticatedDeviceID else {
            throw ImageAllMigrationTransferError.identityConflict
        }
        try validateDirectories(for: migrationID)
        try validateStorageObjects(in: session)
        try validateLedgerBindings(in: session)
        let receipts = session.verifiedResources ?? [:]
        for (path, receipt) in receipts {
            try Task.checkCancellation()
            let resource = receipt.resource
            guard receipt.migrationID == migrationID, receipt.deviceID == authenticatedDeviceID,
                  path == resource.relativePath, path.hasPrefix("resources/"), Self.isAllowed(path),
                  resource.byteCount > 0, resource.sha256.count == 64,
                  resource.sha256.allSatisfy({ $0.isASCII && $0.isHexDigit && !$0.isUppercase }),
                  let chunks = session.chunksByPath[path],
                  Self.committedLength(chunks) == resource.byteCount else {
                throw ImageAllMigrationTransferError.invalidSession
            }
            let file = packageDirectory(migrationID).appendingPathComponent(path)
            let parent = try file.deletingLastPathComponent().resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard parent.isDirectory == true, parent.isSymbolicLink != true else {
                throw ImageAllMigrationTransferError.unsafePath
            }
            guard FileManager.default.fileExists(atPath: file.path) else {
                throw ImageAllMigrationTransferError.invalidSession
            }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  values.fileSize.map(Int64.init) == resource.byteCount else {
                throw ImageAllMigrationTransferError.invalidSession
            }
        }
        return .init(migrationID: migrationID, deviceID: authenticatedDeviceID,
            sourceInstallID: session.sourceInstallID, sealed: session.sealed && session.factsUpdatePending != true,
            resources: receipts.values.filter { allowDurableCustody || $0.custodyVersion == nil }
                .sorted { $0.resource.relativePath < $1.resource.relativePath })
    }

    public func append(
        migrationID: UUID, authenticatedDeviceID: UUID,
        relativePath: String, offset: Int64, bytes: Data, sha256: String,
        fileProgressOnly: Bool = false
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
        guard session.hostHandoff == nil, !session.sealed || relativePath.hasPrefix("facts/") else {
            throw ImageAllMigrationTransferError.sealed
        }
        let file = packageDirectory(migrationID).appendingPathComponent(relativePath)
        try prepareFileParent(for: file, migrationID: migrationID)
        try validateStorageObject(relativePath, in: session)
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
            guard try ImageAllMigrationFileIO.read(handle, upToCount: prior.byteCount) == bytes else {
                throw ImageAllMigrationTransferError.changedChunk
            }
            return progress(session, relativePath: fileProgressOnly ? relativePath : nil)
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
        // Invalidate discovery BEFORE writing: a crash or partial fact upload
        // must remain hidden until a new complete seal, without unlocking media.
        if session.sealed, session.factsUpdatePending != true {
            session.factsUpdatePending = true
            try persist(&session)
            loaded[migrationID] = session
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
        try bindStorageObject(relativePath, in: &session)
        try persist(&session)
        loaded[migrationID] = session
        return progress(session, relativePath: fileProgressOnly ? relativePath : nil)
    }

    /// New handoff flow: confirm custody, not a fresh full-file SHA. Each chunk
    /// was checksum-checked and fsynced before its journal entry was committed.
    /// Only explicit custody clients receive this weaker progress credential;
    /// legacy resume and verify-resource continue to require actual full reads.
    public func acceptResource(migrationID: UUID, authenticatedDeviceID: UUID,
                               request: ImageAllMigrationResourceVerificationRequest) throws -> ImageAllMigrationResourceVerificationReceipt {
        guard request.relativePath.hasPrefix("resources/"), Self.isAllowed(request.relativePath),
              request.byteCount > 0, request.sha256.count == 64,
              request.sha256.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw ImageAllMigrationTransferError.unsafePath
        }
        guard var session = try load(migrationID: migrationID), session.deviceID == authenticatedDeviceID else {
            throw ImageAllMigrationTransferError.identityConflict
        }
        guard session.hostHandoff == nil else { throw ImageAllMigrationTransferError.sealed }
        try validateDirectories(for: migrationID)
        try validateStorageObject(request.relativePath, in: session)
        guard session.ownerBinding == ownerBinding(session),
              session.ledgerDigests?[request.relativePath] == (try ledgerDigest(request.relativePath, in: session)),
              let chunks = session.chunksByPath[request.relativePath],
              Self.committedLength(chunks) == request.byteCount else { throw ImageAllMigrationTransferError.incompleteArchive }
        let file = packageDirectory(migrationID).appendingPathComponent(request.relativePath)
        let descriptor = try FileHandle(forReadingFrom: file); defer { try? descriptor.close() }
        let version = try ImageAllMigrationStagingCleanup.ObjectVersion(descriptor.fileDescriptor)
        guard version.size == request.byteCount else { throw ImageAllMigrationTransferError.incompleteArchive }
        var receipt = ImageAllMigrationResourceVerificationReceipt(migrationID: migrationID, deviceID: authenticatedDeviceID,
            resource: .init(relativePath: request.relativePath, byteCount: request.byteCount, sha256: request.sha256.lowercased()))
        receipt.custodyVersion = 1
        if let prior = session.verifiedResources?[request.relativePath] {
            guard prior.migrationID == receipt.migrationID, prior.deviceID == receipt.deviceID,
                  prior.resource == receipt.resource else { throw ImageAllMigrationTransferError.identityConflict }
            return prior
        }
        session.verifiedResources = (session.verifiedResources ?? [:]).merging([request.relativePath: receipt]) { _, new in new }
        try bindStorageObject(request.relativePath, in: &session)
        try persist(&session)
        loaded[migrationID] = session
        return receipt
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
        while let bytes = try ImageAllMigrationFileIO.read(handle, upToCount: ImageAllMigrationFileIO.resourceBlockBytes), !bytes.isEmpty {
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
        if let prior = session.verifiedResources?[request.relativePath] {
            guard prior.migrationID == receipt.migrationID, prior.deviceID == receipt.deviceID,
                  prior.resource == receipt.resource else { throw ImageAllMigrationTransferError.identityConflict }
        }
        session.verifiedResources = (session.verifiedResources ?? [:]).merging(
            [request.relativePath: receipt]) { _, new in new }
        try bindStorageObject(request.relativePath, in: &session)
        try persist(&session)
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
        guard session.hostHandoff == nil, !session.sealed || relativePath.hasPrefix("facts/") else {
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
        byteCount: Int, sha256: String, fileProgressOnly: Bool = false
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
        while let block = try ImageAllMigrationFileIO.read(source, upToCount: 64 * 1_024), !block.isEmpty {
            sourceHash.update(data: block)
        }
        guard Self.hex(Data(sourceHash.finalize())) == sha256 else {
            throw ImageAllMigrationTransferError.changedChunk
        }
        guard var session = try load(migrationID: migrationID),
              session.deviceID == authenticatedDeviceID else {
            throw ImageAllMigrationTransferError.identityConflict
        }
        guard session.hostHandoff == nil, !session.sealed || relativePath.hasPrefix("facts/") else {
            throw ImageAllMigrationTransferError.sealed
        }
        let file = packageDirectory(migrationID).appendingPathComponent(relativePath)
        try prepareFileParent(for: file, migrationID: migrationID)
        try validateStorageObject(relativePath, in: session)
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
                guard let block = try ImageAllMigrationFileIO.read(target, upToCount: count), !block.isEmpty else {
                    throw ImageAllMigrationTransferError.changedChunk
                }
                priorHash.update(data: block)
                remaining -= block.count
            }
            guard Self.hex(Data(priorHash.finalize())) == sha256 else {
                throw ImageAllMigrationTransferError.changedChunk
            }
            return progress(session, relativePath: fileProgressOnly ? relativePath : nil)
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
        // Invalidate discovery BEFORE writing: a crash or partial fact upload
        // must remain hidden until a new complete seal, without unlocking media.
        if session.sealed, session.factsUpdatePending != true {
            session.factsUpdatePending = true
            try persist(&session)
            loaded[migrationID] = session
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
        while let block = try ImageAllMigrationFileIO.read(source, upToCount: 64 * 1_024), !block.isEmpty {
            try target.write(contentsOf: block)
        }
        try target.synchronize()
        session.chunksByPath[relativePath, default: []].append(.init(
            offset: offset, byteCount: byteCount, sha256: sha256
        ))
        try bindStorageObject(relativePath, in: &session)
        try persist(&session)
        loaded[migrationID] = session
        return progress(session, relativePath: fileProgressOnly ? relativePath : nil)
    }

    /// Persist custody before ACK. No media reads and no catalog trust are
    /// obtained here; the Mac worker still runs the full verification gates.
    public func acceptHandoff(migrationID: UUID, authenticatedDeviceID: UUID,
                              manifestSHA256: String) throws -> ImageAllMigrationTransferSealReceipt {
        let session = try readHostSession(migrationID)
        guard session.deviceID == authenticatedDeviceID else { throw ImageAllMigrationTransferError.identityConflict }
        if let job = session.hostHandoff {
            guard job.receipt.manifestSHA256 == manifestSHA256 else { throw ImageAllMigrationTransferError.identityConflict }
            try synchronizeHandoffJournal(migrationID)
            return job.receipt
        }
        try validateStorageObjects(in: session)
        try validateLedgerBindings(in: session)
        guard session.ownershipVersion == 1, session.ownerBinding != nil else { throw ImageAllMigrationTransferError.invalidSession }
        let package = packageDirectory(migrationID)
        for (path, chunks) in session.chunksByPath {
            let values = try package.appendingPathComponent(path).resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  values.fileSize.map(Int64.init) == Self.committedLength(chunks) else { throw ImageAllMigrationTransferError.incompleteArchive }
        }
        let (header, summary) = try ImageAllMigrationArchive.inspectReceived(at: package) { path, bytes, hash in
            guard let receipt = session.verifiedResources?[path], receipt.migrationID == migrationID,
                  receipt.deviceID == authenticatedDeviceID, receipt.resource.relativePath == path,
                  receipt.resource.byteCount == bytes, receipt.resource.sha256 == hash,
                  Self.committedLength(session.chunksByPath[path] ?? []) == bytes else {
                throw ImageAllMigrationTransferError.incompleteArchive
            }
        }
        guard summary.migrationID == migrationID, summary.manifestSHA256 == manifestSHA256,
              header.sourceDeviceID == (session.sourceInstallID ?? authenticatedDeviceID), summary.isComplete else {
            throw ImageAllMigrationTransferError.identityConflict
        }
        let incoming = sessionDirectory(migrationID).appendingPathComponent("incoming")
        if FileManager.default.fileExists(atPath: incoming.path),
           !(try FileManager.default.contentsOfDirectory(atPath: incoming.path)).isEmpty {
            throw ImageAllMigrationCleanupError.busy
        }
        // Make directory entries durable too, before publishing the custody journal.
        for url in [root, sessionDirectory(migrationID), package, package.appendingPathComponent("resources"),
                    package.appendingPathComponent("facts")] where FileManager.default.fileExists(atPath: url.path) {
            let fd = try ImageAllMigrationStagingLease.openDirectory(url); defer { close(fd) }
            guard fsync(fd) == 0 else { throw ImageAllMigrationCleanupError.ioFailure }
        }
        let receipt = ImageAllMigrationTransferSealReceipt(handoff: summary)
        var next = session
        next.sealed = true; next.factsUpdatePending = false
        next.hostHandoff = .init(receipt: receipt, deviceID: authenticatedDeviceID,
            sourceInstallID: header.sourceDeviceID, sourceEpoch: header.sourceEpoch)
        try persist(&next)
        // Chunk bodies were synchronized on receive. Synchronize the final
        // immutable journal and directory before the phone may disconnect.
        try synchronizeHandoffJournal(migrationID)
        loaded[migrationID] = next
        return receipt
    }

    private func synchronizeHandoffJournal(_ id: UUID) throws {
        let directory = try ImageAllMigrationStagingLease.openDirectory(sessionDirectory(id))
        defer { close(directory) }
        let fd = try ImageAllMigrationStagingCleanup.file(directory, "session.json", write: false)
        defer { close(fd) }
        guard fsync(fd) == 0, fsync(directory) == 0 else { throw ImageAllMigrationCleanupError.ioFailure }
    }

    public func handoffReceipt(migrationID: UUID, authenticatedDeviceID: UUID) throws -> ImageAllMigrationTransferSealReceipt? {
        guard FileManager.default.fileExists(atPath: sessionDirectory(migrationID).appendingPathComponent("session.json").path) else { return nil }
        let session = try readHostSession(migrationID)
        guard session.deviceID == authenticatedDeviceID else { throw ImageAllMigrationTransferError.identityConflict }
        // A prior request may have persisted the enrollment but failed its
        // fsync. A retried/read-back ACK must complete durability too.
        if session.hostHandoff != nil { try synchronizeHandoffJournal(migrationID) }
        return session.hostHandoff?.receipt
    }

    private func readHostSession(_ id: UUID) throws -> Session {
        try ensureLifetimeLease()
        try validateDirectories(for: id)
        let fd = try ImageAllMigrationStagingLease.openDirectory(sessionDirectory(id)); defer { close(fd) }
        let session = try JSONDecoder().decode(Session.self, from: ImageAllMigrationStagingCleanup.read(fd, "session.json"))
        guard session.formatVersion == 1, session.migrationID == id,
              (try session.hostHandoff == nil || session.directoryObjects == [root, sessionDirectory(id), packageDirectory(id)].map(StorageObject.init)) else {
            throw ImageAllMigrationTransferError.identityConflict
        }
        return session
    }

    /// Explicitly enrolled jobs only. No Photos scan and no legacy adoption.
    public func hostJobs() throws -> [ImageAllMigrationHostJob] {
        try ensureLifetimeLease()
        var result: [ImageAllMigrationHostJob] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: root.path) where name.hasPrefix(".imageall-transfer-") {
            guard let id = UUID(uuidString: String(name.dropFirst(".imageall-transfer-".count))),
                  name == ".imageall-transfer-\(id.uuidString.lowercased())" else { continue }
            guard FileManager.default.fileExists(atPath: sessionDirectory(id).appendingPathComponent("session.json").path),
                  var job = try readHostSession(id).hostHandoff else { continue }
            let dir = try ImageAllMigrationStagingLease.openDirectory(sessionDirectory(id)); defer { close(dir) }
            if try ImageAllMigrationStagingCleanup.names(dir).contains("host-processing.json") {
                let state = try JSONDecoder().decode(ImageAllMigrationHostJob.State.self,
                    from: ImageAllMigrationStagingCleanup.read(dir, "host-processing.json"))
                guard state.migrationID == id else { throw ImageAllMigrationTransferError.identityConflict }
                job.state = state
            }
            result.append(job)
        }
        return result.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    public func validateHostHandoff(_ job: ImageAllMigrationHostJob) throws {
        let session = try readHostSession(job.id)
        guard let enrolled = session.hostHandoff, enrolled.receipt == job.receipt,
              enrolled.deviceID == job.deviceID, enrolled.sourceInstallID == job.sourceInstallID,
              enrolled.sourceEpoch == job.sourceEpoch else { throw ImageAllMigrationTransferError.identityConflict }
        try validateStorageObjects(in: session)
        try validateLedgerBindings(in: session)
    }

    public func recordHostState(_ state: ImageAllMigrationHostJob.State) throws {
        guard try readHostSession(state.migrationID).hostHandoff != nil else { throw ImageAllMigrationCleanupError.unowned }
        let directory = sessionDirectory(state.migrationID)
        let url = directory.appendingPathComponent("host-processing.json")
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
        let dir = try ImageAllMigrationStagingLease.openDirectory(directory); defer { close(dir) }
        let fd = try ImageAllMigrationStagingCleanup.file(dir, "host-processing.json", write: false); defer { close(fd) }
        guard fsync(fd) == 0, fsync(dir) == 0 else { throw ImageAllMigrationCleanupError.ioFailure }
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
        if !session.sealed || session.factsUpdatePending != false {
            session.sealed = true
            session.factsUpdatePending = false
            try persist(&session)
            loaded[migrationID] = session
        }
        return (package, verification)
    }

    /// Local Mac UI discovery only: the journal records a previous seal.
    /// No resource bytes are read or repaired. This is NOT a current integrity
    /// receipt; the importer must independently verify all bytes before commit.
    public func sealedArchives() throws -> [ImageAllMigrationTransferSealedArchive] {
        try ensureLifetimeLease()
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        var archives: [ImageAllMigrationTransferSealedArchive] = []
        for name in names where name.hasPrefix(".imageall-transfer-") {
            let idText = String(name.dropFirst(".imageall-transfer-".count))
            guard let id = UUID(uuidString: idText),
                  name == ".imageall-transfer-\(id.uuidString.lowercased())" else {
                continue
            }
            if try ImageAllMigrationStagingCleanup.hasIntent(in: sessionDirectory(id)) { continue }
            guard let session = try load(migrationID: id, repair: false), session.sealed,
                  session.factsUpdatePending != true else { continue }
            try validateDirectories(for: id)
            let package = packageDirectory(id)
            let manifest = try package.appendingPathComponent(ImageAllMigrationArchive.manifestFilename).resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard manifest.isRegularFile == true, manifest.isSymbolicLink != true,
                  (manifest.fileSize ?? 0) > 0 else {
                throw ImageAllMigrationTransferError.invalidSession
            }
            if session.factsUpdatePending == nil {
                // Older writers did not invalidate the seal when appending facts.
                // Inspect only small organization sidecars, never resource bytes.
                let facts = package.appendingPathComponent(ImageAllMigrationFacts.sidecarDirectoryName)
                if FileManager.default.fileExists(atPath: facts.path) {
                    let values = try facts.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard values.isDirectory == true, values.isSymbolicLink != true else {
                        throw ImageAllMigrationTransferError.unsafePath
                    }
                    let files = try FileManager.default.contentsOfDirectory(at: facts, includingPropertiesForKeys: nil)
                    guard files.allSatisfy({ (try? ImageAllMigrationFacts.read(at: $0)) != nil }) else { continue }
                }
            }
            archives.append(.init(id: id, packageURL: package))
        }
        return archives.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private func load(migrationID: UUID, repair: Bool = true) throws -> Session? {
        try ensureLifetimeLease()
        if try ImageAllMigrationStagingCleanup.hasIntent(in: sessionDirectory(migrationID)) {
            throw ImageAllMigrationCleanupError.retired
        }
        if let cached = loaded[migrationID] { return cached }
        let url = sessionDirectory(migrationID).appendingPathComponent("session.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try validateDirectories(for: migrationID)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ImageAllMigrationTransferError.invalidSession
        }
        var session = try JSONDecoder().decode(Session.self, from: Data(contentsOf: url))
        guard session.formatVersion == 1, session.migrationID == migrationID,
              session.chunksByPath.keys.allSatisfy(Self.isAllowed) else {
            throw ImageAllMigrationTransferError.invalidSession
        }
        if repair {
            try validateStorageObjects(in: session)
            let hasBindings = session.storageObjects != nil && session.ledgerDigests != nil && session.ownerBinding != nil
            try validateLedgerBindings(in: session)
            try repairFiles(in: session, verifyCommittedHashes: recoveryPolicy == .verifiedBytes || !hasBindings)
            if !hasBindings {
                // A legacy receipt was not bound to its chunk ledger. Verify
                // its actual bytes before enrolling it into staged recovery.
                for receipt in (session.verifiedResources ?? [:]).values {
                    let file = packageDirectory(session.migrationID).appendingPathComponent(receipt.resource.relativePath)
                    guard receipt.migrationID == session.migrationID, receipt.deviceID == session.deviceID,
                          Self.isAllowed(receipt.resource.relativePath),
                          Self.committedLength(session.chunksByPath[receipt.resource.relativePath] ?? []) == receipt.resource.byteCount,
                          try Self.resourceHash(at: file) == receipt.resource.sha256 else {
                        throw ImageAllMigrationTransferError.invalidSession
                    }
                }
                session.storageObjects = [:]
                for path in session.chunksByPath.keys {
                    try bindStorageObject(path, in: &session)
                }
                try persist(&session)
            }
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

    private func validateStorageObject(_ path: String, in session: Session) throws {
        guard let object = session.storageObjects?[path] else { return }
        guard try StorageObject(at: packageDirectory(session.migrationID).appendingPathComponent(path)) == object else {
            throw ImageAllMigrationTransferError.identityConflict
        }
    }

    private func bindStorageObject(_ path: String, in session: inout Session) throws {
        let object = try StorageObject(at: packageDirectory(session.migrationID).appendingPathComponent(path))
        session.storageObjects = (session.storageObjects ?? [:]).merging([path: object]) { _, new in new }
        session.ledgerDigests = (session.ledgerDigests ?? [:]).merging([path: try ledgerDigest(path, in: session)]) { _, new in new }
    }

    private func ledgerDigest(_ path: String, in session: Session) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let binding = LedgerBinding(path: path, chunks: session.chunksByPath[path] ?? [],
            receipt: session.verifiedResources?[path])
        return Self.hex(Data(SHA256.hash(data: try encoder.encode(binding))))
    }

    private func ownerBinding(_ session: Session) -> String {
        [session.migrationID.uuidString, session.deviceID.uuidString, session.sourceInstallID?.uuidString ?? ""].joined(separator: "|")
    }

    private func validateLedgerBindings(in session: Session) throws {
        guard let digests = session.ledgerDigests else { return }
        guard session.ownerBinding == ownerBinding(session),
              Set(digests.keys) == Set(session.chunksByPath.keys),
              Set((session.verifiedResources ?? [:]).keys).isSubset(of: Set(digests.keys)) else {
            throw ImageAllMigrationTransferError.invalidSession
        }
        for (path, digest) in digests {
            guard try ledgerDigest(path, in: session) == digest else {
                throw ImageAllMigrationTransferError.invalidSession
            }
        }
    }

    private static func resourceHash(at file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var digest = SHA256()
        while let bytes = try ImageAllMigrationFileIO.read(handle, upToCount: ImageAllMigrationFileIO.resourceBlockBytes), !bytes.isEmpty {
            try Task.checkCancellation()
            digest.update(data: bytes)
        }
        return hex(Data(digest.finalize()))
    }

    private func validateStorageObjects(in session: Session) throws {
        guard let objects = session.storageObjects else { return }
        guard let directories = session.directoryObjects,
              directories == (try [root, sessionDirectory(session.migrationID), packageDirectory(session.migrationID)].map(StorageObject.init)),
              Set(objects.keys) == Set(session.chunksByPath.keys) else {
            throw ImageAllMigrationTransferError.identityConflict
        }
        for (path, object) in objects {
            guard try StorageObject(at: packageDirectory(session.migrationID).appendingPathComponent(path)) == object else {
                throw ImageAllMigrationTransferError.identityConflict
            }
        }
    }

    private func persist(_ session: inout Session) throws {
        if session.storageObjects == nil, session.chunksByPath.isEmpty { session.storageObjects = [:] }
        if session.directoryObjects == nil {
            session.directoryObjects = try [root, sessionDirectory(session.migrationID), packageDirectory(session.migrationID)].map(StorageObject.init)
        }
        if session.ledgerDigests == nil, session.chunksByPath.isEmpty { session.ledgerDigests = [:] }
        session.ownerBinding = ownerBinding(session)
        let (data, candidateCache) = try encodeJournal(session)
        try data.write(
            to: sessionDirectory(session.migrationID).appendingPathComponent("session.json"),
            options: .atomic
        )
        // Publish cache only after the durable snapshot operation succeeds.
        journalEncodingCache = candidateCache
    }

    private func encodeJournal(_ session: Session) throws -> (Data, JournalEncodingCache?) {
        let encoder = JSONEncoder()
        guard journalEncodingCacheEnabled, session.chunksByPath.count <= 8_192,
              let objects = session.storageObjects, let digests = session.ledgerDigests,
              objects.count == session.chunksByPath.count,
              digests.count == session.chunksByPath.count,
              (session.verifiedResources ?? [:]).keys.allSatisfy({ session.chunksByPath[$0] != nil }) else {
            return (try encoder.encode(session), nil)
        }
        var candidate = JournalEncodingCache(migrationID: session.migrationID)
        let previous = journalEncodingCache?.migrationID == session.migrationID ? journalEncodingCache : nil
        for (path, chunks) in session.chunksByPath {
            guard let digest = digests[path], let object = objects[path] else {
                return (try encoder.encode(session), nil)
            }
            let row: JournalRow
            if let cached = previous?.rows[path], cached.digest == digest, cached.object == object {
                row = cached
            } else {
                row = try JournalRow(digest: digest, object: object,
                    key: encoder.encode(path), chunks: encoder.encode(chunks),
                    receipt: session.verifiedResources?[path].map { try encoder.encode($0) },
                    storage: encoder.encode(object), ledger: encoder.encode(digest))
            }
            candidate.byteCount += row.byteCount
            guard candidate.byteCount <= 8 * 1_024 * 1_024 else {
                return (try encoder.encode(session), nil)
            }
            candidate.rows[path] = row
        }
        var data = try encoder.encode(JournalHeader(session: session))
        data.removeLast() // JSONEncoder's closing object brace.
        func appendMap(_ name: String, value: (JournalRow) -> Data?) {
            data.append(contentsOf: ",\"\(name)\":{".utf8)
            var first = true
            for row in candidate.rows.values {
                guard let encoded = value(row) else { continue }
                if !first { data.append(44) }
                first = false
                data.append(row.key); data.append(58); data.append(encoded)
            }
            data.append(125)
        }
        appendMap("chunksByPath") { $0.chunks }
        appendMap("storageObjects") { $0.storage }
        appendMap("ledgerDigests") { $0.ledger }
        if session.verifiedResources != nil { appendMap("verifiedResources") { $0.receipt } }
        data.append(125)
        return (data, candidate)
    }

    private func progress(_ session: Session, relativePath: String? = nil) -> ImageAllMigrationTransferProgress {
        let files: [ImageAllMigrationTransferFileProgress]
        if let relativePath {
            // Do not enumerate or sort thousands of unrelated files per chunk.
            files = [.init(relativePath: relativePath,
                committedBytes: Self.committedLength(session.chunksByPath[relativePath] ?? []))]
        } else {
            files = session.chunksByPath.map { path, chunks in
                .init(relativePath: path, committedBytes: Self.committedLength(chunks))
            }.sorted { $0.relativePath < $1.relativePath }
        }
        return .init(
            migrationID: session.migrationID,
            maximumChunkBytes: maximumChunkBytes,
            maximumSessionBytes: maximumSessionBytes,
            files: files,
            sealed: session.sealed && session.factsUpdatePending != true, sourceInstallID: session.sourceInstallID
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
                guard let bytes = try ImageAllMigrationFileIO.read(handle, upToCount: chunk.byteCount),
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
