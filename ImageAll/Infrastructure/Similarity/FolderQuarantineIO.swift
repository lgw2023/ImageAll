import Darwin
import CryptoKit
import Foundation
import OSLog

private let folderQuarantinePerformanceLogger = Logger(
    subsystem: "com.gwlee.ImageAll",
    category: "RecyclePerformance"
)

enum FolderQuarantineIOPhase: String, Sendable, Equatable {
    case sourceInitialHash
    case copy
    case destinationSync
    case destinationHash
    case destinationDirectorySync
    case sourceFinalVerification
    case unlinkSource
    case sourceDirectorySync
}

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
    /// The namespace mutation succeeded, but a following directory sync did
    /// not. Callers must keep their transient DB intent for recovery instead
    /// of pretending that the move/delete never happened.
    case durabilityUncertain
}

struct FolderQuarantineExpectedIdentity: Sendable, Equatable {
    let sizeBytes: Int64
    let modifiedAtNs: Int64
    let resourceID: Data?
    let sha256: Data?
}

/// FD-based move/copy between a writable source root and the app quarantine root.
struct FolderQuarantineIO: Sendable {
    /// When true, always use copy+verify+unlink even on the same device (tests).
    var forceCrossVolumeCopy: Bool = false
    /// Deterministic test seam for a writer racing the final source check.
    var beforeSourceFinalVerification: @Sendable () -> Void = {}
    /// Phase-only telemetry deliberately excludes paths and asset identifiers.
    var onPhaseCompleted: @Sendable (FolderQuarantineIOPhase, Double) -> Void = {
        phase,
        elapsedMs in
        folderQuarantinePerformanceLogger.debug(
            "phase=\(phase.rawValue, privacy: .public) elapsed_ms=\(elapsedMs, privacy: .public)"
        )
    }
    /// Deterministic test seam for failures after a namespace mutation commits.
    var synchronizeDirectoryFD: @Sendable (Int32) throws -> Void = { fd in
        guard fsync(fd) == 0 else {
            throw FolderQuarantineIOError.ioFailure
        }
    }

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

        let sameVolume = !forceCrossVolumeCopy && isSameDevice(
            leftFD: sourceParentFD,
            rightFD: destParentFD
        )
        let openedSource = try openVerifiedRegularFile(
            parentFD: sourceParentFD,
            name: sourceName,
            expectedIdentity: expectedIdentity,
            verifyExpectedDigest: sameVolume
        )
        defer { Darwin.close(openedSource.fd) }

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
            } catch DerivedImageSecureIOError.targetExists {
                throw FolderQuarantineIOError.targetExists
            } catch {
                throw FolderQuarantineIOError.ioFailure
            }
            do {
                try synchronizeDirectory(fd: destParentFD)
                if sourceParentFD != destParentFD {
                    try synchronizeDirectory(fd: sourceParentFD)
                }
            } catch {
                throw FolderQuarantineIOError.durabilityUncertain
            }
            return
        }

        try copyVerifiedOpenFileAndUnlink(
            sourceFD: openedSource.fd,
            sourceStat: openedSource.stat,
            expectedDigest: expectedIdentity.sha256,
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
        originalRelativePath: String,
        expectedIdentity: FolderQuarantineExpectedIdentity? = nil
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

        let sameVolume = !forceCrossVolumeCopy && isSameDevice(
            leftFD: qParentFD,
            rightFD: destParentFD
        )
        let openedSource = try openVerifiedRegularFile(
            parentFD: qParentFD,
            name: qName,
            expectedIdentity: expectedIdentity,
            verifyExpectedDigest: sameVolume
        )
        defer { Darwin.close(openedSource.fd) }

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
            } catch DerivedImageSecureIOError.targetExists {
                throw FolderQuarantineIOError.targetExists
            } catch {
                throw FolderQuarantineIOError.ioFailure
            }
            do {
                try synchronizeDirectory(fd: destParentFD)
                if qParentFD != destParentFD {
                    try synchronizeDirectory(fd: qParentFD)
                }
            } catch {
                throw FolderQuarantineIOError.durabilityUncertain
            }
            return
        }

        try copyVerifiedOpenFileAndUnlink(
            sourceFD: openedSource.fd,
            sourceStat: openedSource.stat,
            expectedDigest: expectedIdentity?.sha256,
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
        do {
            try synchronizeDirectory(fd: parentFD)
        } catch {
            throw FolderQuarantineIOError.durabilityUncertain
        }
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
        let digest: Data?
    }

    private func openVerifiedRegularFile(
        parentFD: Int32,
        name: String,
        expectedIdentity: FolderQuarantineExpectedIdentity?,
        verifyExpectedDigest: Bool = true
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

        var digest: Data?
        if let expectedIdentity {
            let currentResourceID = resourceIdentifier(forOpenFileFD: fd)
            guard let currentModifiedAtNs = modificationTimeNanoseconds(sourceStat),
                  sourceStat.st_size == expectedIdentity.sizeBytes,
                  modificationTimesMatch(
                      currentModifiedAtNs,
                      expectedIdentity.modifiedAtNs
                  ),
                  expectedIdentity.resourceID == nil
                    || currentResourceID == expectedIdentity.resourceID
            else {
                Darwin.close(fd)
                throw FolderQuarantineIOError.verificationFailed
            }
            if verifyExpectedDigest, let expectedSHA256 = expectedIdentity.sha256 {
                do {
                    digest = try measurePhase(.sourceInitialHash) {
                        try hashFile(fd: fd)
                    }
                } catch {
                    Darwin.close(fd)
                    throw error
                }
                guard expectedSHA256.count == SHA256.byteCount,
                      digest == expectedSHA256
                else {
                    Darwin.close(fd)
                    throw FolderQuarantineIOError.verificationFailed
                }
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
        expectedDigest: Data?,
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

        guard flock(sourceFD, LOCK_EX | LOCK_NB) == 0 else {
            throw FolderQuarantineIOError.verificationFailed
        }
        defer { flock(sourceFD, LOCK_UN) }

        try measurePhase(.copy) {
            guard lseek(sourceFD, 0, SEEK_SET) >= 0,
                  lseek(destFD, 0, SEEK_SET) >= 0,
                  fcopyfile(
                    sourceFD,
                    destFD,
                    nil,
                    copyfile_flags_t(COPYFILE_ALL | COPYFILE_NOCACHE)
                  ) == 0
            else {
                throw FolderQuarantineIOError.ioFailure
            }
        }
        try measurePhase(.destinationSync) {
            try synchronizeFile(fd: destFD)
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
            writtenDigest = try measurePhase(.destinationHash) {
                try hashFile(fd: verifyFD)
            }
        } catch {
            Darwin.close(verifyFD)
            throw error
        }
        Darwin.close(verifyFD)
        guard expectedDigest == nil || writtenDigest == expectedDigest else {
            throw FolderQuarantineIOError.verificationFailed
        }

        try measurePhase(.destinationDirectorySync) {
            try synchronizeDirectory(fd: destParentFD)
        }
        beforeSourceFinalVerification()
        try measurePhase(.sourceFinalVerification) {
            try requireOpenFileUnchanged(
                fd: sourceFD,
                openedStat: sourceStat,
                expectedDigest: expectedDigest ?? writtenDigest
            )
            try requirePathStillReferencesOpenFile(
                parentFD: sourceParentFD,
                name: sourceName,
                openedStat: sourceStat
            )
        }
        // Only unlink after the metadata-complete destination is durable and the
        // still-open source has been rehashed under an advisory exclusive lock.
        try measurePhase(.unlinkSource) {
            try DerivedImageSecureIO.unlinkatEntry(
                directoryFD: sourceParentFD,
                name: sourceName
            )
        }
        // From this point onward the verified destination is the only known
        // copy. Never let the cleanup defer remove it, even if the source
        // directory sync reports an error.
        keepDestination = true
        do {
            try measurePhase(.sourceDirectorySync) {
                try synchronizeDirectory(fd: sourceParentFD)
            }
        } catch {
            throw FolderQuarantineIOError.durabilityUncertain
        }
    }

    private func synchronizeFile(fd: Int32) throws {
        if fcntl(fd, F_FULLFSYNC) == 0 {
            return
        }
        guard fsync(fd) == 0 else {
            throw FolderQuarantineIOError.ioFailure
        }
    }

    private func synchronizeDirectory(fd: Int32) throws {
        try synchronizeDirectoryFD(fd)
    }

    private func requireOpenFileUnchanged(
        fd: Int32,
        openedStat: Darwin.stat,
        expectedDigest: Data
    ) throws {
        var currentStat = Darwin.stat()
        guard fstat(fd, &currentStat) == 0,
              (currentStat.st_mode & S_IFMT) == S_IFREG,
              currentStat.st_dev == openedStat.st_dev,
              currentStat.st_ino == openedStat.st_ino,
              currentStat.st_size == openedStat.st_size,
              modificationTimeNanoseconds(currentStat)
                == modificationTimeNanoseconds(openedStat),
              try hashFile(fd: fd) == expectedDigest
        else {
            throw FolderQuarantineIOError.verificationFailed
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

    private func measurePhase<T>(
        _ phase: FolderQuarantineIOPhase,
        operation: () throws -> T
    ) rethrows -> T {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        defer {
            let finishedAt = DispatchTime.now().uptimeNanoseconds
            let elapsedMs = Double(finishedAt - startedAt) / 1_000_000
            onPhaseCompleted(phase, elapsedMs)
        }
        return try operation()
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
              pathStat.st_ino == openedStat.st_ino,
              pathStat.st_size == openedStat.st_size,
              modificationTimeNanoseconds(pathStat)
                == modificationTimeNanoseconds(openedStat)
        else {
            throw FolderQuarantineIOError.verificationFailed
        }
    }
}
