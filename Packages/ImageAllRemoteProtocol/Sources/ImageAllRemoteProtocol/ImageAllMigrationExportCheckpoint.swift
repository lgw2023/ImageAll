import CryptoKit
import Darwin
import Foundation

/// App-owned resource cache for an interrupted export, never itself a published archive.
/// Callers must re-hash cached bytes and the current source before reusing a resource.
public final class ImageAllMigrationExportCheckpoint {
    private struct Identity: Codable {
        let bindingSHA256: String
        let migrationID: UUID
    }
    public let root: URL
    public let migrationID: UUID
    private var descriptor: Int32

    public init(parent: URL, binding: Data) throws {
        let manager = FileManager.default
        let values = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ImageAllMigrationArchiveError.unsafeResourcePath
        }
        let digest = Self.hex(SHA256.hash(data: binding))
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
                identity = Identity(bindingSHA256: digest, migrationID: UUID())
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

    /// The caller must first confirm all pending resources remain locally
    /// readable from their source. Revalidate paths immediately before removal.
    public func resetStreamingResourceWindow() throws {
        let files = try streamingResourceWindow()
        for file in files { try FileManager.default.removeItem(at: file) }
    }

    private func checkOpenRoot() throws {
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
