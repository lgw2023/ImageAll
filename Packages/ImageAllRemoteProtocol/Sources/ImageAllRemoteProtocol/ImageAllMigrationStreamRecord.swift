import CryptoKit
import Foundation

/// Phone-owned planning metadata bound to a previously compared receiver seal.
/// This is not a local media archive or evidence that the receiver is still intact.
public struct ImageAllMigrationStreamRecord: Codable, Sendable, Equatable {
    public static let filename = "stream-record.json"
    public let formatVersion: Int
    public let hostID: UUID
    public let deviceID: UUID
    public let header: ImageAllMigrationHeader
    public let items: [ImageAllMigrationItem]
    public let receipt: ImageAllMigrationTransferSealReceipt

    public init(hostID: UUID, deviceID: UUID, header: ImageAllMigrationHeader,
                items: [ImageAllMigrationItem], receipt: ImageAllMigrationTransferSealReceipt) throws {
        formatVersion = 1
        self.hostID = hostID
        self.deviceID = deviceID
        self.header = header
        self.items = items
        self.receipt = receipt
        try validate()
    }

    public static func manifestSHA256(header: ImageAllMigrationHeader,
                                      items: [ImageAllMigrationItem]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var digest = SHA256()
        func append<T: Encodable>(_ value: T) throws {
            var line = try encoder.encode(value)
            guard line.count < 1_048_576 else { throw ImageAllMigrationArchiveError.invalidManifest }
            line.append(0x0A)
            digest.update(data: line)
        }
        try append(header)
        for item in items { try append(item) }
        return hex(digest.finalize())
    }

    public func validate() throws {
        guard formatVersion == 1, [1, 2].contains(header.formatVersion), header.recordType == "header",
              header.declaredItemCount == items.count,
              Set(items.map(\.mediaID)).count == items.count,
              Set(items.map(\.sourceLocalIdentifier)).count == items.count,
              receipt.migrationID == header.migrationID,
              receipt.itemCount == items.count,
              receipt.manifestSHA256 == (try Self.manifestSHA256(header: header, items: items)) else {
            throw ImageAllMigrationArchiveError.invalidManifest
        }
        let catalog = try ImageAllMigrationArchive.validatedAlbumCatalog(header)
        for item in items {
            try ImageAllMigrationArchive.validateAlbumMemberships(item.appleAlbums ?? [], catalog: catalog)
        }
        var total: Int64 = 0
        var count = 0
        var resources = Set<UUID>()
        var paths = Set<String>()
        for resource in items.flatMap(\.resources) {
            guard resource.status == .present, let bytes = resource.byteCount, bytes > 0,
                  bytes <= Int64.max - total, resources.insert(resource.id).inserted,
                  let path = resource.relativePath, paths.insert(path).inserted,
                  let hash = resource.sha256, hash.count == 64,
                  hash.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
                throw ImageAllMigrationArchiveError.invalidManifest
            }
            total += bytes
            count += 1
        }
        guard total == receipt.verifiedBytes, count == receipt.resourceCount else {
            throw ImageAllMigrationArchiveError.invalidManifest
        }
    }

    /// Facts can advance while the original media manifest stays fixed.
    public func matchesMedia(_ current: ImageAllMigrationTransferSealReceipt) -> Bool {
        current.migrationID == receipt.migrationID
            && current.manifestSHA256 == receipt.manifestSHA256
            && current.itemCount == receipt.itemCount && current.resourceCount == receipt.resourceCount
            && current.verifiedBytes == receipt.verifiedBytes
    }

    /// Call while holding the export checkpoint lock. Existing media and pairing
    /// identities cannot be replaced by another batch's record.
    public func save(in root: URL) throws {
        try validate()
        try Self.validateRootAndManifest(root, expected: receipt.manifestSHA256)
        let url = root.appendingPathComponent(Self.filename)
        if FileManager.default.fileExists(atPath: url.path) {
            let old = try Self.read(in: root)
            guard old.hostID == hostID, old.deviceID == deviceID,
                  old.header == header, old.items == items, old.matchesMedia(receipt) else {
                throw ImageAllMigrationArchiveError.resourceChanged
            }
        } else if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw ImageAllMigrationArchiveError.unsafeResourcePath
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= 128 * 1_024 * 1_024 else { throw ImageAllMigrationArchiveError.invalidManifest }
        try data.write(to: url, options: .atomic)
    }

    public static func read(in root: URL) throws -> Self {
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ImageAllMigrationArchiveError.unsafeResourcePath
        }
        let url = root.appendingPathComponent(filename)
        let file = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard file.isRegularFile == true, file.isSymbolicLink != true,
              let size = file.fileSize, size > 0, size <= 128 * 1_024 * 1_024 else {
            throw ImageAllMigrationArchiveError.unsafeResourcePath
        }
        let record = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try record.validate()
        try validateRootAndManifest(root, expected: record.receipt.manifestSHA256)
        return record
    }

    private static func validateRootAndManifest(_ root: URL, expected: String) throws {
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let manifest = root.appendingPathComponent(ImageAllMigrationArchive.manifestFilename)
        let file = try manifest.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              file.isRegularFile == true, file.isSymbolicLink != true else {
            throw ImageAllMigrationArchiveError.unsafeResourcePath
        }
        let handle = try FileHandle(forReadingFrom: manifest)
        defer { try? handle.close() }
        var digest = SHA256()
        while let bytes = try handle.read(upToCount: 64 * 1_024), !bytes.isEmpty {
            try Task.checkCancellation()
            digest.update(data: bytes)
        }
        guard hex(digest.finalize()) == expected else { throw ImageAllMigrationArchiveError.resourceChanged }
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
