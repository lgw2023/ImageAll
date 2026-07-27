import Darwin
import CryptoKit
import Foundation

enum QuarantinePathLayout {
    static let rootFolderName = "Quarantine"

    static func rootURL(applicationSupportDirectory: URL) -> URL {
        applicationSupportDirectory.appendingPathComponent(rootFolderName, isDirectory: true)
    }

    /// Relative to quarantine root: `{sourceID}/{assetID}/{fileName}`
    static func relativePath(sourceID: UUID, assetID: UUID, fileName: String) -> String {
        "\(sourceID.uuidString.lowercased())/\(assetID.uuidString.lowercased())/\(fileName)"
    }
}

enum FolderQuarantineIOError: Error, Equatable {
    case unsafePath
    case ioFailure
    case targetExists
    case verificationFailed
}

struct FolderQuarantineExpectedIdentity: Sendable, Equatable {
    let sizeBytes: Int64
    let modifiedAtNs: Int64
    let resourceID: Data?
    let sha256: Data
}

/// FD-based move/copy between a writable source root and the app quarantine root.
struct FolderQuarantineIO: Sendable {
    /// When true, always use copy+verify+unlink even on the same device (tests).
    var forceCrossVolumeCopy: Bool = false

    func ensureQuarantineRoot(at url: URL) throws {
        try DerivedImageSecureIO.ensureDirectory(at: url)
    }

    func moveIntoQuarantine(
        sourceRootURL: URL,
        sourceRelativePath: String,
        quarantineRootURL: URL,
        quarantineRelativePath: String,
        expectedIdentity: FolderQuarantineExpectedIdentity
    ) throws {
        guard case let .success(validatedSource) = RelativePathRules.validate(sourceRelativePath),
              case let .success(validatedDest) = RelativePathRules.validate(quarantineRelativePath)
        else {
            throw FolderQuarantineIOError.unsafePath
        }

        try ensureQuarantineRoot(at: quarantineRootURL)
        let sourceRootFD = try DerivedImageSecureIO.openDirectoryNoFollow(at: sourceRootURL)
        defer { Darwin.close(sourceRootFD) }
        let quarantineRootFD = try DerivedImageSecureIO.openDirectoryNoFollow(at: quarantineRootURL)
        defer { Darwin.close(quarantineRootFD) }

        let (sourceParentFD, ownsSourceParent, sourceName) = try DerivedImageSecureIO.openRelativeDirectory(
            directoryFD: sourceRootFD,
            relativePath: validatedSource
        )
        defer {
            if ownsSourceParent { Darwin.close(sourceParentFD) }
        }

        let destParentFD = try ensureRelativeDirectories(
            rootFD: quarantineRootFD,
            relativePath: validatedDest
        )
        defer { Darwin.close(destParentFD) }
        let destName = validatedDest.split(separator: "/").map(String.init).last
            ?? validatedDest

        // Conflict check at destination.
        var probe = stat()
        if fstatat(destParentFD, destName, &probe, AT_SYMLINK_NOFOLLOW) == 0 {
            throw FolderQuarantineIOError.targetExists
        }

        let openedSource = try openVerifiedRegularFile(
            parentFD: sourceParentFD,
            name: sourceName,
            expectedIdentity: expectedIdentity
        )
        defer { Darwin.close(openedSource.fd) }

        let sameVolume = !forceCrossVolumeCopy && isSameDevice(
            leftFD: sourceParentFD,
            rightFD: destParentFD
        )
        if sameVolume {
            try requirePathStillReferencesOpenFile(
                parentFD: sourceParentFD,
                name: sourceName,
                openedStat: openedSource.stat
            )
            do {
                try DerivedImageSecureIO.renameatExclusive(
                    fromDirectoryFD: sourceParentFD,
                    fromName: sourceName,
                    toDirectoryFD: destParentFD,
                    toName: destName
                )
                return
            } catch DerivedImageSecureIOError.targetExists {
                throw FolderQuarantineIOError.targetExists
            } catch {
                throw FolderQuarantineIOError.ioFailure
            }
        }

        try copyVerifiedOpenFileAndUnlink(
            sourceFD: openedSource.fd,
            sourceStat: openedSource.stat,
            expectedDigest: openedSource.digest,
            sourceParentFD: sourceParentFD,
            sourceName: sourceName,
            destParentFD: destParentFD,
            destName: destName
        )
    }

    func moveOutOfQuarantine(
        quarantineRootURL: URL,
        quarantineRelativePath: String,
        sourceRootURL: URL,
        originalRelativePath: String
    ) throws {
        guard case let .success(validatedQuarantine) = RelativePathRules.validate(quarantineRelativePath),
              case let .success(validatedOriginal) = RelativePathRules.validate(originalRelativePath)
        else {
            throw FolderQuarantineIOError.unsafePath
        }

        let quarantineRootFD = try DerivedImageSecureIO.openDirectoryNoFollow(at: quarantineRootURL)
        defer { Darwin.close(quarantineRootFD) }
        let sourceRootFD = try DerivedImageSecureIO.openDirectoryNoFollow(at: sourceRootURL)
        defer { Darwin.close(sourceRootFD) }

        let (qParentFD, ownsQParent, qName) = try DerivedImageSecureIO.openRelativeDirectory(
            directoryFD: quarantineRootFD,
            relativePath: validatedQuarantine
        )
        defer {
            if ownsQParent { Darwin.close(qParentFD) }
        }

        let destParentFD = try ensureRelativeDirectories(
            rootFD: sourceRootFD,
            relativePath: validatedOriginal
        )
        defer { Darwin.close(destParentFD) }
        let destName = validatedOriginal.split(separator: "/").map(String.init).last
            ?? validatedOriginal

        var probe = stat()
        if fstatat(destParentFD, destName, &probe, AT_SYMLINK_NOFOLLOW) == 0 {
            throw FolderQuarantineIOError.targetExists
        }

        let openedSource = try openVerifiedRegularFile(
            parentFD: qParentFD,
            name: qName,
            expectedIdentity: nil
        )
        defer { Darwin.close(openedSource.fd) }

        let sameVolume = !forceCrossVolumeCopy && isSameDevice(
            leftFD: qParentFD,
            rightFD: destParentFD
        )
        if sameVolume {
            try requirePathStillReferencesOpenFile(
                parentFD: qParentFD,
                name: qName,
                openedStat: openedSource.stat
            )
            do {
                try DerivedImageSecureIO.renameatExclusive(
                    fromDirectoryFD: qParentFD,
                    fromName: qName,
                    toDirectoryFD: destParentFD,
                    toName: destName
                )
                return
            } catch DerivedImageSecureIOError.targetExists {
                throw FolderQuarantineIOError.targetExists
            } catch {
                throw FolderQuarantineIOError.ioFailure
            }
        }

        try copyVerifiedOpenFileAndUnlink(
            sourceFD: openedSource.fd,
            sourceStat: openedSource.stat,
            expectedDigest: openedSource.digest,
            sourceParentFD: qParentFD,
            sourceName: qName,
            destParentFD: destParentFD,
            destName: destName
        )
    }

    func deleteQuarantineObject(
        quarantineRootURL: URL,
        quarantineRelativePath: String
    ) throws {
        guard case let .success(validated) = RelativePathRules.validate(quarantineRelativePath) else {
            throw FolderQuarantineIOError.unsafePath
        }
        let rootFD = try DerivedImageSecureIO.openDirectoryNoFollow(at: quarantineRootURL)
        defer { Darwin.close(rootFD) }
        let (parentFD, ownsParent, name) = try DerivedImageSecureIO.openRelativeDirectory(
            directoryFD: rootFD,
            relativePath: validated
        )
        defer {
            if ownsParent { Darwin.close(parentFD) }
        }
        try DerivedImageSecureIO.unlinkatEntry(directoryFD: parentFD, name: name)
    }

    func objectExists(rootURL: URL, relativePath: String) throws -> Bool {
        guard case let .success(validated) = RelativePathRules.validate(relativePath) else {
            throw FolderQuarantineIOError.unsafePath
        }
        let rootFD = try DerivedImageSecureIO.openDirectoryNoFollow(at: rootURL)
        defer { Darwin.close(rootFD) }

        let components = validated.split(separator: "/").map(String.init)
        guard let name = components.last else {
            throw FolderQuarantineIOError.unsafePath
        }
        var parentFD = rootFD
        var ownsParent = false
        defer {
            if ownsParent {
                Darwin.close(parentFD)
            }
        }
        for component in components.dropLast() {
            let nextFD = openat(
                parentFD,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            if nextFD < 0 {
                if errno == ENOENT {
                    return false
                }
                if errno == ELOOP || errno == ENOTDIR {
                    throw FolderQuarantineIOError.unsafePath
                }
                throw FolderQuarantineIOError.ioFailure
            }
            if ownsParent {
                Darwin.close(parentFD)
            }
            parentFD = nextFD
            ownsParent = true
        }

        var entryStat = Darwin.stat()
        if fstatat(parentFD, name, &entryStat, AT_SYMLINK_NOFOLLOW) == 0 {
            return true
        }
        if errno == ENOENT {
            return false
        }
        throw FolderQuarantineIOError.ioFailure
    }

    // MARK: - Helpers

    private func ensureRelativeDirectories(rootFD: Int32, relativePath: String) throws -> Int32 {
        let components = relativePath.split(separator: "/").map(String.init)
        guard components.count >= 1 else {
            throw FolderQuarantineIOError.unsafePath
        }
        var current = rootFD
        var owns = false
        for component in components.dropLast() {
            let next: Int32
            do {
                next = try DerivedImageSecureIO.ensureSubdirectory(parentFD: current, name: component)
            } catch {
                if owns { Darwin.close(current) }
                throw FolderQuarantineIOError.ioFailure
            }
            if owns { Darwin.close(current) }
            current = next
            owns = true
        }
        if !owns {
            // Caller needs an owned FD for dest parent == root; duplicate via openat "."
            let dup = openat(rootFD, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard dup >= 0 else { throw FolderQuarantineIOError.ioFailure }
            return dup
        }
        return current
    }

    private func isSameDevice(leftFD: Int32, rightFD: Int32) -> Bool {
        var left = stat()
        var right = stat()
        guard fstat(leftFD, &left) == 0, fstat(rightFD, &right) == 0 else {
            return false
        }
        return left.st_dev == right.st_dev
    }

    private struct OpenedRegularFile {
        let fd: Int32
        let stat: Darwin.stat
        let digest: Data
    }

    private func openVerifiedRegularFile(
        parentFD: Int32,
        name: String,
        expectedIdentity: FolderQuarantineExpectedIdentity?
    ) throws -> OpenedRegularFile {
        let fd = openat(parentFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw FolderQuarantineIOError.ioFailure }

        var sourceStat = Darwin.stat()
        guard fstat(fd, &sourceStat) == 0 else {
            Darwin.close(fd)
            throw FolderQuarantineIOError.ioFailure
        }
        guard (sourceStat.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(fd)
            throw FolderQuarantineIOError.unsafePath
        }

        let digest: Data
        do {
            digest = try hashFile(fd: fd)
        } catch {
            Darwin.close(fd)
            throw error
        }
        if let expectedIdentity {
            let currentResourceID = resourceIdentifier(forOpenFileFD: fd)
            guard let currentModifiedAtNs = modificationTimeNanoseconds(sourceStat),
                  sourceStat.st_size == expectedIdentity.sizeBytes,
                  modificationTimesMatch(
                    currentModifiedAtNs,
                    expectedIdentity.modifiedAtNs
                  ),
                  expectedIdentity.sha256.count == SHA256.byteCount,
                  digest == expectedIdentity.sha256,
                  expectedIdentity.resourceID == nil
                    || currentResourceID == expectedIdentity.resourceID
            else {
                Darwin.close(fd)
                throw FolderQuarantineIOError.verificationFailed
            }
        }
        return OpenedRegularFile(fd: fd, stat: sourceStat, digest: digest)
    }

    private func modificationTimeNanoseconds(_ fileStat: Darwin.stat) -> Int64? {
        let seconds = Int64(fileStat.st_mtimespec.tv_sec)
            .multipliedReportingOverflow(by: 1_000_000_000)
        guard !seconds.overflow else { return nil }
        let total = seconds.partialValue.addingReportingOverflow(
            Int64(fileStat.st_mtimespec.tv_nsec)
        )
        return total.overflow ? nil : total.partialValue
    }

    private func modificationTimesMatch(_ lhs: Int64, _ rhs: Int64) -> Bool {
        let difference = lhs.subtractingReportingOverflow(rhs)
        return !difference.overflow && difference.partialValue.magnitude <= 1_000
    }

    private func resourceIdentifier(forOpenFileFD fd: Int32) -> Data? {
        FoundationFolderFileResourceReader().resourceIdentifier(
            for: URL(fileURLWithPath: "/dev/fd/\(fd)")
        )
    }

    private func copyVerifiedOpenFileAndUnlink(
        sourceFD: Int32,
        sourceStat: Darwin.stat,
        expectedDigest: Data,
        sourceParentFD: Int32,
        sourceName: String,
        destParentFD: Int32,
        destName: String
    ) throws {
        let expectedSize = sourceStat.st_size
        let destFD = openat(
            destParentFD,
            destName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard destFD >= 0 else {
            if errno == EEXIST {
                throw FolderQuarantineIOError.targetExists
            }
            throw FolderQuarantineIOError.ioFailure
        }
        var keepDestination = false
        defer {
            Darwin.close(destFD)
            if !keepDestination {
                try? DerivedImageSecureIO.unlinkatEntry(
                    directoryFD: destParentFD,
                    name: destName
                )
            }
        }

        try copyBytes(sourceFD: sourceFD, destFD: destFD)
        guard fsync(destFD) == 0 else {
            throw FolderQuarantineIOError.ioFailure
        }

        let written = try DerivedImageSecureIO.fstatatEntry(
            directoryFD: destParentFD,
            name: destName,
            follow: false
        )
        guard written.mode == S_IFREG, written.sizeBytes == expectedSize else {
            throw FolderQuarantineIOError.verificationFailed
        }

        let verifyFD = openat(destParentFD, destName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard verifyFD >= 0 else {
            throw FolderQuarantineIOError.ioFailure
        }
        let writtenDigest: Data
        do {
            writtenDigest = try hashFile(fd: verifyFD)
        } catch {
            Darwin.close(verifyFD)
            throw error
        }
        Darwin.close(verifyFD)
        guard writtenDigest == expectedDigest else {
            throw FolderQuarantineIOError.verificationFailed
        }

        try requirePathStillReferencesOpenFile(
            parentFD: sourceParentFD,
            name: sourceName,
            openedStat: sourceStat
        )
        // Only unlink source after verified copy.
        try DerivedImageSecureIO.unlinkatEntry(directoryFD: sourceParentFD, name: sourceName)
        keepDestination = true
    }

    private func copyBytes(sourceFD: Int32, destFD: Int32) throws {
        guard lseek(sourceFD, 0, SEEK_SET) >= 0 else {
            throw FolderQuarantineIOError.ioFailure
        }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { raw in
                read(sourceFD, raw.baseAddress, raw.count)
            }
            if n == 0 { break }
            if n < 0 { throw FolderQuarantineIOError.ioFailure }
            var offset = 0
            while offset < n {
                let written = buffer.withUnsafeBytes { raw in
                    write(destFD, raw.baseAddress!.advanced(by: offset), n - offset)
                }
                if written <= 0 {
                    throw FolderQuarantineIOError.ioFailure
                }
                offset += written
            }
        }
    }

    private func hashFile(fd: Int32) throws -> Data {
        guard lseek(fd, 0, SEEK_SET) >= 0 else {
            throw FolderQuarantineIOError.ioFailure
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw in
                read(fd, raw.baseAddress, raw.count)
            }
            if count == 0 { break }
            if count < 0 { throw FolderQuarantineIOError.ioFailure }
            hasher.update(data: Data(buffer.prefix(count)))
        }
        return Data(hasher.finalize())
    }

    private func requirePathStillReferencesOpenFile(
        parentFD: Int32,
        name: String,
        openedStat: Darwin.stat
    ) throws {
        var pathStat = Darwin.stat()
        guard fstatat(parentFD, name, &pathStat, AT_SYMLINK_NOFOLLOW) == 0,
              (pathStat.st_mode & S_IFMT) == S_IFREG,
              pathStat.st_dev == openedStat.st_dev,
              pathStat.st_ino == openedStat.st_ino
        else {
            throw FolderQuarantineIOError.verificationFailed
        }
    }
}
