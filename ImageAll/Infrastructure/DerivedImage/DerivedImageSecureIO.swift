import Darwin
import Foundation

enum DerivedImageSecureIOError: Error, Equatable {
    case unsafePath
    case ioFailure
    case targetExists
}

private enum DerivedImageRenameFlag {
    static let exclusive: UInt32 = 0x0000_0004 // RENAME_EXCL
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
            if errno == ELOOP || errno == ENOTDIR {
                throw DerivedImageSecureIOError.unsafePath
            }
            throw DerivedImageSecureIOError.ioFailure
        }
        try verifyDirectoryFD(fd)
        return fd
    }

    static func openRelativeReadOnlyNoFollow(
        directoryFD: Int32,
        relativePath: String
    ) throws -> Int32 {
        guard case let .success(validated) = RelativePathRules.validate(relativePath) else {
            throw DerivedImageSecureIOError.unsafePath
        }
        let (parentFD, ownsParent, fileName) = try openRelativeDirectory(
            directoryFD: directoryFD,
            relativePath: validated
        )
        defer {
            if ownsParent {
                Darwin.close(parentFD)
            }
        }
        let (entryMode, _) = try fstatatEntry(directoryFD: parentFD, name: fileName, follow: false)
        guard entryMode == S_IFREG else {
            throw DerivedImageSecureIOError.unsafePath
        }
        let fileFD = openat(parentFD, fileName, O_RDONLY | O_NOFOLLOW)
        guard fileFD >= 0 else {
            throw DerivedImageSecureIOError.ioFailure
        }
        try verifyRegularFileFD(fileFD)
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

    static func fstatRegularFile(fd: Int32) throws -> (sizeBytes: Int64, modifiedAtNs: Int64) {
        try verifyRegularFileFD(fd)
        var status = stat()
        guard fstat(fd, &status) == 0 else {
            throw DerivedImageSecureIOError.ioFailure
        }
        let modifiedAtNs = Int64(status.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(status.st_mtimespec.tv_nsec)
        return (Int64(status.st_size), modifiedAtNs)
    }

    static func verifyDirectoryFD(_ fd: Int32) throws {
        var status = stat()
        guard fstat(fd, &status) == 0 else {
            throw DerivedImageSecureIOError.ioFailure
        }
        let mode = status.st_mode & S_IFMT
        guard mode == S_IFDIR else {
            throw DerivedImageSecureIOError.unsafePath
        }
    }

    static func verifyRegularFileFD(_ fd: Int32) throws {
        var status = stat()
        guard fstat(fd, &status) == 0 else {
            throw DerivedImageSecureIOError.ioFailure
        }
        let mode = status.st_mode & S_IFMT
        guard mode == S_IFREG else {
            throw DerivedImageSecureIOError.unsafePath
        }
    }

    static func fstatatEntry(
        directoryFD: Int32,
        name: String,
        follow: Bool
    ) throws -> (mode: mode_t, sizeBytes: Int64) {
        var status = stat()
        let flags = follow ? 0 : AT_SYMLINK_NOFOLLOW
        guard fstatat(directoryFD, name, &status, flags) == 0 else {
            throw DerivedImageSecureIOError.ioFailure
        }
        return (status.st_mode & S_IFMT, Int64(status.st_size))
    }

    static func createExclusiveEmptyAt(
        directoryFD: Int32,
        name: String
    ) throws -> Int32 {
        let fd = openat(directoryFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw DerivedImageSecureIOError.ioFailure
        }
        return fd
    }

    static func writeExclusiveCreateAt(
        directoryFD: Int32,
        name: String,
        bytes: Data
    ) throws -> Int32 {
        let fd = openat(directoryFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw DerivedImageSecureIOError.ioFailure
        }
        do {
            try writeAll(bytes: bytes, to: fd)
            guard fsync(fd) == 0 else {
                throw DerivedImageSecureIOError.ioFailure
            }
            return fd
        } catch {
            Darwin.close(fd)
            _ = unlinkat(directoryFD, name, 0)
            throw error
        }
    }

    static func writeAll(bytes: Data, to fd: Int32) throws {
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
    }

    static func fsyncFile(_ fd: Int32) throws {
        guard fsync(fd) == 0 else {
            throw DerivedImageSecureIOError.ioFailure
        }
    }

    static func renameatExclusive(
        fromDirectoryFD: Int32,
        fromName: String,
        toDirectoryFD: Int32,
        toName: String
    ) throws {
        guard renameatx_np(
            fromDirectoryFD,
            fromName,
            toDirectoryFD,
            toName,
            DerivedImageRenameFlag.exclusive
        ) == 0 else {
            if errno == EEXIST {
                throw DerivedImageSecureIOError.targetExists
            }
            throw DerivedImageSecureIOError.ioFailure
        }
    }

    static func unlinkatEntry(directoryFD: Int32, name: String) throws {
        guard unlinkat(directoryFD, name, 0) == 0 else {
            if errno == ENOENT {
                return
            }
            throw DerivedImageSecureIOError.ioFailure
        }
    }

    static func ensureSubdirectory(parentFD: Int32, name: String) throws -> Int32 {
        var status = stat()
        if fstatat(parentFD, name, &status, AT_SYMLINK_NOFOLLOW) == 0 {
            let mode = status.st_mode & S_IFMT
            if mode == S_IFLNK {
                throw DerivedImageSecureIOError.unsafePath
            }
            if mode == S_IFDIR {
                return try openVerifiedSubdirectoryFD(parentFD: parentFD, name: name)
            }
            throw DerivedImageSecureIOError.unsafePath
        }
        guard errno == ENOENT else {
            throw DerivedImageSecureIOError.ioFailure
        }
        if mkdirat(parentFD, name, S_IRWXU) != 0, errno != EEXIST {
            throw DerivedImageSecureIOError.ioFailure
        }
        return try openVerifiedSubdirectoryFD(parentFD: parentFD, name: name)
    }

    private static func openVerifiedSubdirectoryFD(parentFD: Int32, name: String) throws -> Int32 {
        let fd = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ELOOP || errno == ENOTDIR {
                throw DerivedImageSecureIOError.unsafePath
            }
            throw DerivedImageSecureIOError.ioFailure
        }
        do {
            try verifyDirectoryFD(fd)
        } catch DerivedImageSecureIOError.unsafePath {
            Darwin.close(fd)
            throw DerivedImageSecureIOError.unsafePath
        } catch {
            Darwin.close(fd)
            throw error
        }
        return fd
    }

    static func openRelativeDirectory(
        directoryFD: Int32,
        relativePath: String
    ) throws -> (directoryFD: Int32, ownsDirectory: Bool, fileName: String) {
        var currentFD = directoryFD
        var ownsCurrent = false
        defer {
            if ownsCurrent {
                Darwin.close(currentFD)
            }
        }

        let components = relativePath.split(separator: "/").map(String.init)
        guard let fileName = components.last else {
            throw DerivedImageSecureIOError.unsafePath
        }

        for component in components.dropLast() {
            let nextFD = openat(currentFD, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard nextFD >= 0 else {
                throw DerivedImageSecureIOError.ioFailure
            }
            try verifyDirectoryFD(nextFD)
            if ownsCurrent {
                Darwin.close(currentFD)
            }
            currentFD = nextFD
            ownsCurrent = true
        }

        if ownsCurrent {
            ownsCurrent = false
            return (currentFD, true, fileName)
        }
        return (directoryFD, false, fileName)
    }

    static func listDirectoryEntryNames(directoryFD: Int32) throws -> [String] {
        let independent = openat(directoryFD, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard independent >= 0 else {
            throw DerivedImageSecureIOError.ioFailure
        }
        guard let directory = fdopendir(independent) else {
            Darwin.close(independent)
            throw DerivedImageSecureIOError.ioFailure
        }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 {
                    closedir(directory)
                    throw DerivedImageSecureIOError.ioFailure
                }
                break
            }
            let name = copyDirentName(entry)
            guard !name.isEmpty else { continue }
            if name == "." || name == ".." {
                continue
            }
            names.append(name)
        }
        closedir(directory)
        return names
    }

    private static func copyDirentName(_ entry: UnsafePointer<Darwin.dirent>) -> String {
        let length = Int(entry.pointee.d_namlen)
        guard length > 0 else { return "" }
        return withUnsafePointer(to: entry.pointee.d_name) { rawName in
            rawName.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) { rebound in
                let buffer = UnsafeBufferPointer(start: rebound, count: length)
                guard let decoded = String(bytes: buffer, encoding: .utf8), decoded.utf8.count == length else {
                    return ""
                }
                return decoded
            }
        }
    }
}

struct DerivedImageAnchoredCacheSession {
    let versionRootURL: URL
    private let versionRootFD: Int32
    private let stagingFD: Int32
    private let objectsFD: Int32

    var stagingDirectoryFD: Int32 { stagingFD }
    var objectsDirectoryFD: Int32 { objectsFD }

    static func open(cachesDirectory: URL) throws -> DerivedImageAnchoredCacheSession {
        guard cachesDirectory.lastPathComponent == DerivedImageCachePathLayout.cachesLeafComponent,
              cachesDirectory.deletingLastPathComponent().lastPathComponent
              == DerivedImageCachePathLayout.cachesParentComponent
        else {
            throw DerivedImageError.derivedCacheUnsafePath
        }

        let anchorURL = cachesDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        do {
            let anchorFD = try DerivedImageSecureIO.openDirectoryNoFollow(at: anchorURL)
            defer { Darwin.close(anchorFD) }

            let cachesFD = try DerivedImageSecureIO.ensureSubdirectory(
                parentFD: anchorFD,
                name: DerivedImageCachePathLayout.cachesParentComponent
            )
            defer { Darwin.close(cachesFD) }

            let imageAllFD = try DerivedImageSecureIO.ensureSubdirectory(
                parentFD: cachesFD,
                name: DerivedImageCachePathLayout.cachesLeafComponent
            )
            defer { Darwin.close(imageAllFD) }

            let derivedImagesFD = try DerivedImageSecureIO.ensureSubdirectory(
                parentFD: imageAllFD,
                name: DerivedImageCachePathLayout.rootComponent
            )
            defer { Darwin.close(derivedImagesFD) }

            var versionRootFD = try DerivedImageSecureIO.ensureSubdirectory(
                parentFD: derivedImagesFD,
                name: DerivedImageCachePathLayout.versionComponent
            )
            var stagingFD: Int32 = -1
            var objectsFD: Int32 = -1
            defer {
                if objectsFD >= 0 { Darwin.close(objectsFD) }
                if stagingFD >= 0 { Darwin.close(stagingFD) }
                if versionRootFD >= 0 { Darwin.close(versionRootFD) }
            }

            stagingFD = try DerivedImageSecureIO.ensureSubdirectory(
                parentFD: versionRootFD,
                name: DerivedImageCachePathLayout.stagingComponent
            )
            objectsFD = try DerivedImageSecureIO.ensureSubdirectory(
                parentFD: versionRootFD,
                name: DerivedImageCachePathLayout.objectsComponent
            )

            let versionRootURL = DerivedImageCachePathLayout.versionRoot(under: cachesDirectory)
            let session = DerivedImageAnchoredCacheSession(
                versionRootURL: versionRootURL,
                versionRootFD: versionRootFD,
                stagingFD: stagingFD,
                objectsFD: objectsFD
            )
            versionRootFD = -1
            stagingFD = -1
            objectsFD = -1
            return session
        } catch DerivedImageSecureIOError.unsafePath {
            throw DerivedImageError.derivedCacheUnsafePath
        } catch DerivedImageSecureIOError.ioFailure {
            throw DerivedImageError.derivedCachePersistenceFailed
        }
    }

    func closeHandles() {
        Darwin.close(stagingFD)
        Darwin.close(objectsFD)
        Darwin.close(versionRootFD)
    }

    func preflightForClear() throws {
        let versionEntries = Set(
            try DerivedImageSecureIO.listDirectoryEntryNames(directoryFD: versionRootFD)
        )
        guard versionEntries == [
            DerivedImageCachePathLayout.objectsComponent,
            DerivedImageCachePathLayout.stagingComponent,
        ] else {
            throw DerivedImageSecureIOError.unsafePath
        }

        for shard in try DerivedImageSecureIO.listDirectoryEntryNames(directoryFD: objectsFD) {
            guard DerivedImageCachePathLayout.isValidShardComponent(shard) else {
                throw DerivedImageSecureIOError.unsafePath
            }
            let shardFacts = try DerivedImageSecureIO.fstatatEntry(
                directoryFD: objectsFD,
                name: shard,
                follow: false
            )
            guard shardFacts.mode == S_IFDIR else {
                throw DerivedImageSecureIOError.unsafePath
            }
            let shardFD = openat(objectsFD, shard, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard shardFD >= 0 else {
                throw DerivedImageSecureIOError.unsafePath
            }
            defer { Darwin.close(shardFD) }
            for objectName in try DerivedImageSecureIO.listDirectoryEntryNames(directoryFD: shardFD) {
                let relativePath = "\(DerivedImageCachePathLayout.objectsComponent)/\(shard)/\(objectName)"
                guard DerivedImageCachePathLayout.isKnownObjectRelativePath(relativePath),
                      try DerivedImageSecureIO.fstatatEntry(
                          directoryFD: shardFD,
                          name: objectName,
                          follow: false
                      ).mode == S_IFREG
                else {
                    throw DerivedImageSecureIOError.unsafePath
                }
            }
        }

        for stagingName in try DerivedImageSecureIO.listDirectoryEntryNames(directoryFD: stagingFD) {
            guard DerivedImageCachePathLayout.isKnownStagingFileName(stagingName),
                  try DerivedImageSecureIO.fstatatEntry(
                      directoryFD: stagingFD,
                      name: stagingName,
                      follow: false
                  ).mode == S_IFREG
            else {
                throw DerivedImageSecureIOError.unsafePath
            }
        }
    }

    func createStagingExclusiveEmpty(name: String) throws -> Int32 {
        try DerivedImageSecureIO.createExclusiveEmptyAt(directoryFD: stagingFD, name: name)
    }

    func writeStagingExclusive(name: String, bytes: Data) throws -> Int32 {
        try DerivedImageSecureIO.writeExclusiveCreateAt(
            directoryFD: stagingFD,
            name: name,
            bytes: bytes
        )
    }

    func readStaging(name: String) throws -> (bytes: Data, sizeBytes: Int64) {
        let fd = openat(stagingFD, name, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            throw DerivedImageError.derivedCachePersistenceFailed
        }
        defer { Darwin.close(fd) }
        let stats = try DerivedImageSecureIO.fstatRegularFile(fd: fd)
        let bytes = try DerivedImageSecureIO.readAllBytes(from: fd)
        guard Int64(bytes.count) == stats.sizeBytes else {
            throw DerivedImageError.derivedCachePersistenceFailed
        }
        return (bytes, stats.sizeBytes)
    }

    func removeStaging(name: String) throws {
        try DerivedImageSecureIO.unlinkatEntry(directoryFD: stagingFD, name: name)
    }

    func publishStagingFile(
        stagingName: String,
        entryID: UUID,
        format: DerivedImageStorageFormat
    ) throws {
        let objectName = objectFileName(entryID: entryID, format: format)
        let shard = shardName(entryID: entryID)
        let shardFD = try DerivedImageSecureIO.ensureSubdirectory(parentFD: objectsFD, name: shard)
        defer { Darwin.close(shardFD) }
        do {
            try DerivedImageSecureIO.renameatExclusive(
                fromDirectoryFD: stagingFD,
                fromName: stagingName,
                toDirectoryFD: shardFD,
                toName: objectName
            )
        } catch DerivedImageSecureIOError.targetExists {
            throw DerivedImageError.derivedCachePersistenceFailed
        } catch DerivedImageSecureIOError.unsafePath {
            throw DerivedImageError.derivedCacheUnsafePath
        } catch {
            throw DerivedImageError.derivedCachePersistenceFailed
        }
    }

    func readObject(entryID: UUID, format: DerivedImageStorageFormat, expectedSize: Int64) throws -> Data? {
        let shard = shardName(entryID: entryID)
        let objectName = objectFileName(entryID: entryID, format: format)

        var shardStatus = stat()
        switch fstatat(objectsFD, shard, &shardStatus, AT_SYMLINK_NOFOLLOW) {
        case 0:
            let shardMode = shardStatus.st_mode & S_IFMT
            if shardMode == S_IFLNK {
                throw DerivedImageSecureIOError.unsafePath
            }
            guard shardMode == S_IFDIR else {
                throw DerivedImageSecureIOError.unsafePath
            }
        case -1:
            if errno == ENOENT {
                return nil
            }
            if errno == ELOOP || errno == ENOTDIR {
                throw DerivedImageSecureIOError.unsafePath
            }
            throw DerivedImageSecureIOError.ioFailure
        default:
            throw DerivedImageSecureIOError.ioFailure
        }

        let shardFD = openat(objectsFD, shard, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard shardFD >= 0 else {
            if errno == ELOOP || errno == ENOTDIR {
                throw DerivedImageSecureIOError.unsafePath
            }
            throw DerivedImageSecureIOError.ioFailure
        }
        defer { Darwin.close(shardFD) }

        var objectStatus = stat()
        switch fstatat(shardFD, objectName, &objectStatus, AT_SYMLINK_NOFOLLOW) {
        case 0:
            let objectMode = objectStatus.st_mode & S_IFMT
            if objectMode == S_IFLNK {
                throw DerivedImageSecureIOError.unsafePath
            }
            guard objectMode == S_IFREG else {
                throw DerivedImageSecureIOError.unsafePath
            }
        case -1:
            if errno == ENOENT {
                return nil
            }
            if errno == ELOOP || errno == ENOTDIR {
                throw DerivedImageSecureIOError.unsafePath
            }
            throw DerivedImageSecureIOError.ioFailure
        default:
            throw DerivedImageSecureIOError.ioFailure
        }

        let fileFD = openat(shardFD, objectName, O_RDONLY | O_NOFOLLOW)
        guard fileFD >= 0 else {
            if errno == ELOOP || errno == ENOTDIR {
                throw DerivedImageSecureIOError.unsafePath
            }
            throw DerivedImageSecureIOError.ioFailure
        }
        defer { Darwin.close(fileFD) }
        try DerivedImageSecureIO.verifyRegularFileFD(fileFD)
        let stats = try DerivedImageSecureIO.fstatRegularFile(fd: fileFD)
        guard stats.sizeBytes == expectedSize else { return nil }
        return try DerivedImageSecureIO.readAllBytes(from: fileFD)
    }

    @discardableResult
    func deleteObject(entryID: UUID, format: DerivedImageStorageFormat) throws -> Bool {
        let shard = shardName(entryID: entryID)
        let objectName = objectFileName(entryID: entryID, format: format)

        var shardStatus = stat()
        guard fstatat(objectsFD, shard, &shardStatus, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return false }
            if errno == ELOOP || errno == ENOTDIR {
                throw DerivedImageSecureIOError.unsafePath
            }
            throw DerivedImageSecureIOError.ioFailure
        }
        guard shardStatus.st_mode & S_IFMT == S_IFDIR else {
            throw DerivedImageSecureIOError.unsafePath
        }

        let shardFD = openat(objectsFD, shard, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard shardFD >= 0 else {
            if errno == ELOOP || errno == ENOTDIR {
                throw DerivedImageSecureIOError.unsafePath
            }
            throw DerivedImageSecureIOError.ioFailure
        }
        defer { Darwin.close(shardFD) }

        var objectStatus = stat()
        guard fstatat(shardFD, objectName, &objectStatus, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return false }
            if errno == ELOOP || errno == ENOTDIR {
                throw DerivedImageSecureIOError.unsafePath
            }
            throw DerivedImageSecureIOError.ioFailure
        }
        guard objectStatus.st_mode & S_IFMT == S_IFREG else {
            throw DerivedImageSecureIOError.unsafePath
        }

        try DerivedImageSecureIO.unlinkatEntry(directoryFD: shardFD, name: objectName)
        return true
    }

    func objectByteSize(entryID: UUID, format: DerivedImageStorageFormat) throws -> UInt64? {
        let shard = shardName(entryID: entryID)
        let objectName = objectFileName(entryID: entryID, format: format)
        let shardFD = openat(objectsFD, shard, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard shardFD >= 0 else { return nil }
        defer { Darwin.close(shardFD) }
        var status = stat()
        guard fstatat(shardFD, objectName, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT {
                return nil
            }
            throw DerivedImageSecureIOError.ioFailure
        }
        let mode = status.st_mode & S_IFMT
        guard mode == S_IFREG else { return nil }
        guard status.st_size > 0 else { return 0 }
        return UInt64(status.st_size)
    }

    func sweepUnreferencedObjects(
        referenced: Set<String>,
        protectedStagingNames: Set<String>,
        removedBytes: inout UInt64,
        unsafeObjects: inout Int
    ) throws -> Int {
        var removedCount = 0
        let shardNames = try DerivedImageSecureIO.listDirectoryEntryNames(directoryFD: objectsFD)
        for shard in shardNames {
            guard DerivedImageCachePathLayout.isValidShardComponent(shard) else {
                unsafeObjects += 1
                continue
            }
            let mode = try DerivedImageSecureIO.fstatatEntry(directoryFD: objectsFD, name: shard, follow: false).mode
            if mode == S_IFLNK {
                unsafeObjects += 1
                continue
            }
            guard mode == S_IFDIR else {
                unsafeObjects += 1
                continue
            }
            let shardFD = openat(objectsFD, shard, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard shardFD >= 0 else {
                throw DerivedImageSecureIOError.ioFailure
            }
            defer { Darwin.close(shardFD) }
            let objectNames = try DerivedImageSecureIO.listDirectoryEntryNames(directoryFD: shardFD)
            for objectName in objectNames {
                let relative = "\(DerivedImageCachePathLayout.objectsComponent)/\(shard)/\(objectName)"
                guard DerivedImageCachePathLayout.isKnownObjectRelativePath(relative) else {
                    unsafeObjects += 1
                    continue
                }
                let entryMode: mode_t
                do {
                    entryMode = try DerivedImageSecureIO.fstatatEntry(
                        directoryFD: shardFD,
                        name: objectName,
                        follow: false
                    ).mode
                } catch {
                    throw DerivedImageSecureIOError.ioFailure
                }
                if entryMode == S_IFLNK {
                    unsafeObjects += 1
                    continue
                }
                guard entryMode == S_IFREG else {
                    unsafeObjects += 1
                    continue
                }
                if referenced.contains(relative) {
                    continue
                }
                let size = try DerivedImageSecureIO.fstatatEntry(
                    directoryFD: shardFD,
                    name: objectName,
                    follow: false
                ).sizeBytes
                if size > 0 {
                    removedBytes &+= UInt64(size)
                }
                try DerivedImageSecureIO.unlinkatEntry(directoryFD: shardFD, name: objectName)
                removedCount += 1
            }
        }
        _ = protectedStagingNames
        return removedCount
    }

    func sweepStaging(
        excluding protectedNames: Set<String>,
        removedBytes: inout UInt64,
        unsafeObjects: inout Int
    ) throws -> Int {
        var removedCount = 0
        let names = try DerivedImageSecureIO.listDirectoryEntryNames(directoryFD: stagingFD)
        for name in names {
            if protectedNames.contains(name) {
                continue
            }
            let mode: mode_t
            do {
                mode = try DerivedImageSecureIO.fstatatEntry(directoryFD: stagingFD, name: name, follow: false).mode
            } catch {
                unsafeObjects += 1
                continue
            }
            if mode == S_IFLNK {
                unsafeObjects += 1
                continue
            }
            guard mode == S_IFREG else {
                unsafeObjects += 1
                continue
            }
            let size = try DerivedImageSecureIO.fstatatEntry(directoryFD: stagingFD, name: name, follow: false).sizeBytes
            if size > 0 {
                removedBytes &+= UInt64(size)
            }
            try DerivedImageSecureIO.unlinkatEntry(directoryFD: stagingFD, name: name)
            removedCount += 1
        }
        return removedCount
    }

    private func shardName(entryID: UUID) -> String {
        String(entryID.uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(2))
    }

    private func objectFileName(entryID: UUID, format: DerivedImageStorageFormat) -> String {
        let canonical = entryID.uuidString.lowercased()
        let fileExtension = format == .jpeg ? "jpg" : "png"
        return "\(canonical).\(fileExtension)"
    }
}
