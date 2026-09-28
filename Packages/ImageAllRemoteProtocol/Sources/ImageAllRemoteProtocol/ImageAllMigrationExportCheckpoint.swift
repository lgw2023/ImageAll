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
