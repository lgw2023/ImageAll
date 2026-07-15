import Darwin
import Foundation

enum DerivedImageSecureIOError: Error, Equatable {
    case unsafePath
    case ioFailure
}

enum DerivedImageSecureIO {
    static func ensureDirectory(at url: URL) throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw DerivedImageSecureIOError.unsafePath
            }
            guard !isSymlink(at: url) else {
                throw DerivedImageSecureIOError.unsafePath
            }
            return
        }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        guard !isSymlink(at: url) else {
            throw DerivedImageSecureIOError.unsafePath
        }
    }

    static func isSymlink(at url: URL) -> Bool {
        var status = stat()
        if lstat(url.path, &status) == 0 {
            return (status.st_mode & S_IFMT) == S_IFLNK
        }
        return (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    static func isRegularFile(at url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    static func openReadOnlyNoFollow(at url: URL) throws -> Int32 {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            throw DerivedImageSecureIOError.ioFailure
        }
        return fd
    }

    static func openDirectoryNoFollow(at url: URL) throws -> Int32 {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else {
            throw DerivedImageSecureIOError.ioFailure
        }
        return fd
    }

    static func openRelativeReadOnlyNoFollow(
        directoryFD: Int32,
        relativePath: String
    ) throws -> Int32 {
        guard case let .success(validated) = RelativePathRules.validate(relativePath) else {
            throw DerivedImageSecureIOError.unsafePath
        }
        var currentFD = directoryFD
        var ownsCurrent = false
        defer {
            if ownsCurrent {
                close(currentFD)
            }
        }

        let components = validated.split(separator: "/").map(String.init)
        guard let fileName = components.last else {
            throw DerivedImageSecureIOError.unsafePath
        }

        for component in components.dropLast() {
            let nextFD = openat(currentFD, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard nextFD >= 0 else {
                throw DerivedImageSecureIOError.ioFailure
            }
            if ownsCurrent {
                close(currentFD)
            }
            currentFD = nextFD
            ownsCurrent = true
        }

        let fileFD = openat(currentFD, fileName, O_RDONLY | O_NOFOLLOW)
        guard fileFD >= 0 else {
            throw DerivedImageSecureIOError.ioFailure
        }
        return fileFD
    }

    static func readAllBytes(from fd: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let readCount = buffer.withUnsafeMutableBytes { raw in
                read(fd, raw.baseAddress, raw.count)
            }
            if readCount < 0 {
                throw DerivedImageSecureIOError.ioFailure
            }
            if readCount == 0 {
                break
            }
            data.append(buffer, count: readCount)
        }
        return data
    }

    static func writeExclusiveCreate(at url: URL, bytes: Data) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw DerivedImageSecureIOError.ioFailure
        }
        defer { close(fd) }
        try bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = write(fd, base.advanced(by: offset), raw.count - offset)
                guard written > 0 else {
                    throw DerivedImageSecureIOError.ioFailure
                }
                offset += written
            }
        }
        guard fsync(fd) == 0 else {
            throw DerivedImageSecureIOError.ioFailure
        }
    }

    static func atomicRename(from source: URL, to destination: URL) throws {
        guard rename(source.path, destination.path) == 0 else {
            throw DerivedImageSecureIOError.ioFailure
        }
    }

    static func removeIfPresent(at url: URL) {
        unlink(url.path)
    }

    static func fileSize(at url: URL) -> Int64? {
        guard isRegularFile(at: url) else { return nil }
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize, size >= 0
        else {
            return nil
        }
        return Int64(size)
    }
}
