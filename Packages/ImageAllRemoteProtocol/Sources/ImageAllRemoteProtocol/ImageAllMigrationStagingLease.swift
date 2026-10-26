import Darwin
import Foundation

/// Cooperative cross-process lifetime lease, anchored to the receiver directory
/// inode. No lock file that can be replaced or expired while a writer is alive.
public final class ImageAllMigrationStagingLease: @unchecked Sendable {
    let fd: Int32

    public init(root: URL, exclusive: Bool = false) throws {
        fd = try Self.openDirectory(root)
        guard flock(fd, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
            close(fd)
            throw ImageAllMigrationCleanupError.busy
        }
    }

    deinit { close(fd) }

    /// Import can outlive the discovery store; keep its own lease across reads.
    public static func readingPackage(_ package: URL) throws -> ImageAllMigrationStagingLease? {
        let parent = package.deletingLastPathComponent()
        guard package.lastPathComponent == "package", parent.lastPathComponent.hasPrefix(".imageall-transfer-") else { return nil }
        let lease = try Self(root: parent.deletingLastPathComponent())
        guard try !ImageAllMigrationStagingCleanup.hasIntent(in: parent) else {
            throw ImageAllMigrationCleanupError.retired
        }
        return lease
    }

    static func openDirectory(_ url: URL) throws -> Int32 {
        // Resolve system aliases (e.g. /var) for read leases. Destructive callers
        // separately require the supplied path itself to be canonical.
        let path = try resolvedPath(url)
        #if os(iOS)
        // iOS sandboxes cannot enumerate/open the filesystem root. The caller
        // validates the canonical container path and binds its directory inode;
        // all child access remains descriptor-relative and O_NOFOLLOW.
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ImageAllMigrationCleanupError.unsafePath }
        return fd
        #else
        var current = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw ImageAllMigrationCleanupError.unsafePath }
        for component in path.split(separator: "/") {
            let next = openat(current, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(current)
            guard next >= 0 else { throw ImageAllMigrationCleanupError.unsafePath }
            current = next
        }
        return current
        #endif
    }

    static func resolvedPath(_ url: URL) throws -> String {
        guard let pointer = realpath(url.path, nil) else { throw ImageAllMigrationCleanupError.unsafePath }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    static func isCanonical(_ url: URL) throws -> Bool {
        let path = url.standardizedFileURL.path, resolved = try resolvedPath(url)
        return path == resolved || ((path.hasPrefix("/var/") || path.hasPrefix("/tmp/")) && "/private" + path == resolved)
    }
}
