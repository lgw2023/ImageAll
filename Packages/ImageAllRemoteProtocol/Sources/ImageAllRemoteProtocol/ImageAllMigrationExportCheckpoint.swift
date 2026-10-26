import CryptoKit
import Darwin
import Foundation

/// App-owned resource cache for an interrupted export, never itself a published archive.
/// Callers must re-hash cached bytes and the current source before reusing a resource.
public final class ImageAllMigrationExportCheckpoint {
    private struct Identity: Codable {
        let bindingSHA256: String
        let migrationID: UUID
        let payloadOwnerVersion: Int?
    }
    public let root: URL
    public let migrationID: UUID
    let payloadOwnerVersion: Int?
    private var descriptor: Int32

    public convenience init(parent: URL, binding: Data) throws {
        try self.init(parent: parent, digest: Self.hex(SHA256.hash(data: binding)))
    }

    private struct StreamingScope: Codable {
        let scopeSHA256: String
        let stagingName: String
        let migrationID: UUID
    }

    /// The active batch is identified by the frozen selection and destination,
    /// not by mutable PhotoKit observations. A legacy batch must be explicitly
    /// selected; callers still validate its frozen context before remembering it.
    public static func streaming(parent: URL, binding: Data, scope: Data,
                                 legacyMigrationID: UUID? = nil, requireExisting: Bool = false) throws -> ImageAllMigrationExportCheckpoint {
        let digest = hex(SHA256.hash(data: scope))
        let index = parent.appendingPathComponent(".active-\(digest).json")
        if let data = try readMetadata(index, maximum: 4096) {
            let saved = try JSONDecoder().decode(StreamingScope.self, from: data)
            guard saved.scopeSHA256 == digest,
                  saved.stagingName.hasPrefix(".staging-"),
                  !saved.stagingName.contains("/"),
                  legacyMigrationID == nil || legacyMigrationID == saved.migrationID else {
                throw ImageAllMigrationArchiveError.resourceChanged
            }
            let checkpoint = try ImageAllMigrationExportCheckpoint(
                streamingRoot: parent.appendingPathComponent(saved.stagingName))
            guard checkpoint.migrationID == saved.migrationID else {
                checkpoint.close()
                throw ImageAllMigrationArchiveError.resourceChanged
            }
            return checkpoint
        }
        if let legacyMigrationID {
            let files = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
            for identityURL in files where identityURL.lastPathComponent.hasPrefix(".export-") && identityURL.pathExtension == "json" {
                guard let data = try readMetadata(identityURL, maximum: 4096) else { continue }
                let identity = try JSONDecoder().decode(Identity.self, from: data)
                guard identity.migrationID == legacyMigrationID else { continue }
                guard identity.bindingSHA256.count == 64,
                      identity.bindingSHA256.allSatisfy({ $0.isASCII && $0.isHexDigit && !$0.isUppercase }),
                      identityURL.lastPathComponent == ".export-\(identity.bindingSHA256).json" else {
                    throw ImageAllMigrationArchiveError.unsafeResourcePath
                }
                let checkpoint = try ImageAllMigrationExportCheckpoint(
                    streamingRoot: parent.appendingPathComponent(".staging-\(identity.bindingSHA256)"))
                guard checkpoint.migrationID == legacyMigrationID else {
                    checkpoint.close()
                    throw ImageAllMigrationArchiveError.resourceChanged
                }
                return checkpoint
            }
            throw ImageAllMigrationArchiveError.resourceChanged
        }
        guard !requireExisting else { throw ImageAllMigrationArchiveError.resourceChanged }
        return try ImageAllMigrationExportCheckpoint(parent: parent, binding: binding)
    }

    public func matchesOriginalBinding(_ binding: Data) -> Bool {
        root.lastPathComponent == ".staging-\(Self.hex(SHA256.hash(data: binding)))"
    }

    public func rememberStreamingScope(_ scope: Data) throws {
        try checkOpenRoot()
        let digest = Self.hex(SHA256.hash(data: scope))
        let url = root.deletingLastPathComponent().appendingPathComponent(".active-\(digest).json")
        let record = StreamingScope(scopeSHA256: digest, stagingName: root.lastPathComponent, migrationID: migrationID)
        if let data = try Self.readMetadata(url, maximum: 4096) {
            let old = try JSONDecoder().decode(StreamingScope.self, from: data)
            guard old.scopeSHA256 == digest, old.stagingName == record.stagingName,
                  old.migrationID == migrationID else { throw ImageAllMigrationArchiveError.resourceChanged }
        }
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
    }

    private struct SourceVerification: Codable {
        let versionSHA256: String
        let resource: ImageAllMigrationResource
    }

    public func isStreamingSourceVerified(_ resource: ImageAllMigrationResource, version: Data) throws -> Bool {
        try checkOpenRoot()
        try validateVerifiedDescriptor(resource, id: resource.id)
        guard let data = try Self.readMetadata(sourceVerificationURL(resource.id), maximum: 65_536) else { return false }
        let record = try JSONDecoder().decode(SourceVerification.self, from: data)
        return record.resource == resource && record.versionSHA256 == Self.hex(SHA256.hash(data: version))
    }

    /// Persist only after matching independently read source bytes against the
    /// receiver-verified descriptor. Version changes invalidate this shortcut.
    public func recordStreamingSourceVerification(_ resource: ImageAllMigrationResource, version: Data,
                                                  byteCount: Int64, sha256: String) throws {
        try checkOpenRoot()
        guard try verifiedStreamingResource(id: resource.id) == resource,
              resource.byteCount == byteCount, resource.sha256 == sha256 else {
            throw ImageAllMigrationArchiveError.resourceChanged
        }
        let url = sourceVerificationURL(resource.id)
        _ = try Self.readMetadata(url, maximum: 65_536)
        let record = SourceVerification(versionSHA256: Self.hex(SHA256.hash(data: version)), resource: resource)
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
    }

    private func sourceVerificationURL(_ id: UUID) -> URL {
        root.appendingPathComponent("source-verified-\(id.uuidString.lowercased()).json")
    }

    private static func readMetadata(_ url: URL, maximum: Int) throws -> Data? {
        var info = stat()
        guard Darwin.lstat(url.path, &info) == 0 else {
            guard errno == ENOENT else { throw ImageAllMigrationArchiveError.unsafeResourcePath }
            return nil
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_size > 0, info.st_size <= maximum else {
            throw ImageAllMigrationArchiveError.unsafeResourcePath
        }
        return try Data(contentsOf: url)
    }

    /// Reopen an existing streaming batch under the same process lock used by
    /// the exporter. No resource reset or new source binding is performed.
    public convenience init(streamingRoot: URL) throws {
        let name = streamingRoot.lastPathComponent
        let prefix = ".staging-"
        guard name.hasPrefix(prefix) else { throw ImageAllMigrationArchiveError.unsafeResourcePath }
        let digest = String(name.dropFirst(prefix.count))
        let values = try streamingRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard digest.count == 64, digest.allSatisfy({ $0.isASCII && $0.isHexDigit && !$0.isUppercase }),
              values.isDirectory == true, values.isSymbolicLink != true else {
            throw ImageAllMigrationArchiveError.unsafeResourcePath
        }
        try self.init(parent: streamingRoot.deletingLastPathComponent(), digest: digest)
        guard root == streamingRoot.resolvingSymlinksInPath().standardizedFileURL else {
            close()
            throw ImageAllMigrationArchiveError.unsafeResourcePath
        }
    }

    private init(parent: URL, digest: String) throws {
        let manager = FileManager.default
        let values = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ImageAllMigrationArchiveError.unsafeResourcePath
        }
        let parent = parent.resolvingSymlinksInPath().standardizedFileURL
        let lock = parent.appendingPathComponent(".export-\(digest).lock")
        descriptor = Darwin.open(lock.path, O_RDWR | O_CREAT | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ImageAllMigrationArchiveError.unsafeResourcePath }
        var lockInfo = stat()
        guard fstat(descriptor, &lockInfo) == 0, (lockInfo.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(descriptor)
            descriptor = -1
            throw ImageAllMigrationArchiveError.unsafeResourcePath
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            descriptor = -1
            throw ImageAllMigrationArchiveError.resourceChanged
        }
        let folder = parent.appendingPathComponent(".staging-\(digest)", isDirectory: true)
        let identityURL = parent.appendingPathComponent(".export-\(digest).json")
        do {
            let identity: Identity
            if manager.fileExists(atPath: folder.path) {
                let folderValues = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                let identityValues = try identityURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard folderValues.isDirectory == true, folderValues.isSymbolicLink != true,
                      identityValues.isRegularFile == true, identityValues.isSymbolicLink != true,
                      (identityValues.fileSize ?? Int.max) <= 4096 else {
                    throw ImageAllMigrationArchiveError.unsafeResourcePath
                }
                identity = try JSONDecoder().decode(Identity.self, from: Data(contentsOf: identityURL))
                guard identity.bindingSHA256 == digest else { throw ImageAllMigrationArchiveError.resourceChanged }
            } else {
                identity = Identity(bindingSHA256: digest, migrationID: UUID(), payloadOwnerVersion: 1)
                // Write identity first: an interruption before mkdir leaves no reusable resources.
                if manager.fileExists(atPath: identityURL.path) {
                    let v = try identityURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard v.isRegularFile == true, v.isSymbolicLink != true else {
                        throw ImageAllMigrationArchiveError.unsafeResourcePath
                    }
                }
                try JSONEncoder().encode(identity).write(to: identityURL, options: .atomic)
                try manager.createDirectory(at: folder, withIntermediateDirectories: false)
            }
            root = folder
            migrationID = identity.migrationID
            payloadOwnerVersion = identity.payloadOwnerVersion
        } catch {
            Darwin.close(descriptor)
            descriptor = -1
            throw error
        }
    }

    public func close() {
        if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
    }
    deinit { close() }

    public func resourceLocation(key: String, fileExtension: String) throws -> (id: UUID, url: URL, relativePath: String) {
        try checkOpenRoot()
        guard !key.isEmpty, !fileExtension.isEmpty, fileExtension.count <= 12,
              fileExtension.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw ImageAllMigrationArchiveError.unsafeResourcePath
        }
        let raw = Array(Self.hex(SHA256.hash(data: Data("\(migrationID.uuidString)|\(key)".utf8))).prefix(32))
        let text = String(raw[0..<8]) + "-" + String(raw[8..<12]) + "-" + String(raw[12..<16])
            + "-" + String(raw[16..<20]) + "-" + String(raw[20..<32])
        let id = UUID(uuidString: text)!
        let directory = root.appendingPathComponent("resources", isDirectory: true)
        let manager = FileManager.default
        if !manager.fileExists(atPath: directory.path) {
            try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        let dv = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard dv.isDirectory == true, dv.isSymbolicLink != true else { throw ImageAllMigrationArchiveError.unsafeResourcePath }
        let relative = "resources/\(id.uuidString.lowercased()).\(fileExtension)"
        let url = root.appendingPathComponent(relative)
        if manager.fileExists(atPath: url.path) {
            let v = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard v.isRegularFile == true, v.isSymbolicLink != true else { throw ImageAllMigrationArchiveError.unsafeResourcePath }
        } else if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw ImageAllMigrationArchiveError.unsafeResourcePath
        }
        return (id, url, relative)
    }

    /// A failed manifest is disposable; resource reuse still requires source validation.
    public func removeUnpublishedManifest() throws {
        try checkOpenRoot()
        let url = root.appendingPathComponent(ImageAllMigrationArchive.manifestFilename)
        if FileManager.default.fileExists(atPath: url.path) {
            let v = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard v.isRegularFile == true, v.isSymbolicLink != true else { throw ImageAllMigrationArchiveError.unsafeResourcePath }
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Freeze small planning state before any network writes. Kept only in an
    /// app-owned streaming staging root, never inside a published archive.
    public func frozenContext(_ proposed: Data) throws -> Data {
        try checkOpenRoot()
        let maximum = 128 * 1_024 * 1_024
        guard !proposed.isEmpty, proposed.count <= maximum else {
            throw ImageAllMigrationArchiveError.invalidManifest
        }
        let url = root.appendingPathComponent("stream-context.json")
        var info = stat()
        if Darwin.lstat(url.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_size > 0, info.st_size <= maximum else {
                throw ImageAllMigrationArchiveError.unsafeResourcePath
            }
            return try Data(contentsOf: url)
        }
        guard errno == ENOENT else { throw ImageAllMigrationArchiveError.unsafeResourcePath }
        try proposed.write(to: url, options: .atomic)
        return proposed
    }

    /// A new streaming attempt regenerates only its own disposable resource
    /// window. The server's committed offsets survive; Photos originals and
    /// frozen planning state are not touched. Validate every entry before edits.
    public func streamingResourceWindow() throws -> [URL] {
        try checkOpenRoot()
        let context = try root.appendingPathComponent("stream-context.json").resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard context.isRegularFile == true, context.isSymbolicLink != true else {
            throw ImageAllMigrationArchiveError.unsafeResourcePath
        }
        let directory = root.appendingPathComponent("resources", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ImageAllMigrationArchiveError.unsafeResourcePath
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        for file in files {
            let pieces = file.lastPathComponent.split(separator: ".", omittingEmptySubsequences: false)
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard pieces.count == 2, UUID(uuidString: String(pieces[0])) != nil,
                  (1...12).contains(pieces[1].count),
                  pieces[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
                  values.isRegularFile == true, values.isSymbolicLink != true else {
                throw ImageAllMigrationArchiveError.unsafeResourcePath
            }
        }
        return files
    }

    /// Stable package identities for an interrupted resource window. Foundation
    /// may spell a container URL through /var while root resolves to /private/var.
    /// Read/validate entries before deriving keys; never accept an arbitrary name.
    public func streamingResourceWindowRelativePaths() throws -> Set<String> {
        Set(try streamingResourceWindow().map { "resources/" + $0.lastPathComponent })
    }

    /// Only a receiver-verified descriptor may bypass local regeneration. This
    /// checkpoint root is already bound to scope, source versions and destination.
    /// The caller must revalidate the receiver receipt before using this record.
    public func verifiedStreamingResource(id: UUID) throws -> ImageAllMigrationResource? {
        try checkOpenRoot()
        let url = root.appendingPathComponent("verified-\(id.uuidString.lowercased()).json")
        var info = stat()
        guard Darwin.lstat(url.path, &info) == 0 else {
            guard errno == ENOENT else { throw ImageAllMigrationArchiveError.unsafeResourcePath }
            return nil
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_size > 0, info.st_size <= 65_536 else {
            throw ImageAllMigrationArchiveError.unsafeResourcePath
        }
        let resource = try JSONDecoder().decode(ImageAllMigrationResource.self, from: Data(contentsOf: url))
        try validateVerifiedDescriptor(resource, id: id)
        return resource
    }

    public func recordVerifiedStreamingResource(_ resource: ImageAllMigrationResource,
                                                receipt: ImageAllMigrationResourceVerificationReceipt) throws {
        try checkOpenRoot()
        try validateVerifiedDescriptor(resource, id: resource.id)
        guard receipt.migrationID == migrationID,
              receipt.resource.relativePath == resource.relativePath,
              receipt.resource.byteCount == resource.byteCount,
              receipt.resource.sha256 == resource.sha256 else { throw ImageAllMigrationArchiveError.resourceChanged }
        let previous = try verifiedStreamingResource(id: resource.id)
        guard previous == nil || previous == resource else { throw ImageAllMigrationArchiveError.resourceChanged }
        let data = try JSONEncoder().encode(resource)
        guard data.count <= 65_536 else { throw ImageAllMigrationArchiveError.invalidManifest }
        try data.write(to: root.appendingPathComponent("verified-\(resource.id.uuidString.lowercased()).json"), options: .atomic)
    }

    private func validateVerifiedDescriptor(_ resource: ImageAllMigrationResource, id: UUID) throws {
        guard resource.id == id, resource.status == .present, let size = resource.byteCount, size > 0,
              let hash = resource.sha256, hash.count == 64,
              hash.allSatisfy({ $0.isASCII && $0.isHexDigit && !$0.isUppercase }),
              let path = resource.relativePath,
              path.hasPrefix("resources/\(id.uuidString.lowercased()).") else {
            throw ImageAllMigrationArchiveError.invalidManifest
        }
        let ext = String(path.dropFirst("resources/\(id.uuidString.lowercased()).".count))
        guard (1...12).contains(ext.count), ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw ImageAllMigrationArchiveError.unsafeResourcePath
        }
    }

    /// The caller must first confirm all pending resources remain locally
    /// readable from their source. Revalidate paths immediately before removal.
    public func resetStreamingResourceWindow() throws {
        let files = try streamingResourceWindow()
        for file in files { try FileManager.default.removeItem(at: file) }
    }

    private func checkOpenRoot() throws {
        if try ImageAllMigrationExportCleanup.hasIntent(in: root) { throw ImageAllMigrationCleanupError.retired }
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard descriptor >= 0, values.isDirectory == true, values.isSymbolicLink != true,
              root.resolvingSymlinksInPath().standardizedFileURL == root else {
            throw ImageAllMigrationArchiveError.unsafeResourcePath
        }
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
