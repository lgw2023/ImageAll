import Darwin
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
        quarantineRelativePath: String
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
        if sameVolume {
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

        try copyVerifyUnlink(
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

        let sameVolume = !forceCrossVolumeCopy && isSameDevice(
            leftFD: qParentFD,
            rightFD: destParentFD
        )
        if sameVolume {
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

        try copyVerifyUnlink(
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

    private func copyVerifyUnlink(
        sourceParentFD: Int32,
        sourceName: String,
        destParentFD: Int32,
        destName: String
    ) throws {
        let sourceFD = openat(sourceParentFD, sourceName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard sourceFD >= 0 else { throw FolderQuarantineIOError.ioFailure }
        defer { Darwin.close(sourceFD) }

        var sourceStat = stat()
        guard fstat(sourceFD, &sourceStat) == 0 else {
            throw FolderQuarantineIOError.ioFailure
        }
        guard (sourceStat.st_mode & S_IFMT) == S_IFREG else {
            throw FolderQuarantineIOError.unsafePath
        }
        let expectedSize = sourceStat.st_size

        let bytes = try readAll(fd: sourceFD, expectedSize: Int(expectedSize))
        guard bytes.count == expectedSize else {
            throw FolderQuarantineIOError.verificationFailed
        }

        let destFD: Int32
        do {
            destFD = try DerivedImageSecureIO.writeExclusiveCreateAt(
                directoryFD: destParentFD,
                name: destName,
                bytes: bytes
            )
        } catch DerivedImageSecureIOError.targetExists {
            throw FolderQuarantineIOError.targetExists
        } catch {
            throw FolderQuarantineIOError.ioFailure
        }
        Darwin.close(destFD)

        let written = try DerivedImageSecureIO.fstatatEntry(
            directoryFD: destParentFD,
            name: destName,
            follow: false
        )
        guard written.mode == S_IFREG, written.sizeBytes == expectedSize else {
            try? DerivedImageSecureIO.unlinkatEntry(directoryFD: destParentFD, name: destName)
            throw FolderQuarantineIOError.verificationFailed
        }

        // Only unlink source after verified copy.
        try DerivedImageSecureIO.unlinkatEntry(directoryFD: sourceParentFD, name: sourceName)
    }

    private func readAll(fd: Int32, expectedSize: Int) throws -> Data {
        var data = Data()
        data.reserveCapacity(max(expectedSize, 0))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { raw in
                read(fd, raw.baseAddress, raw.count)
            }
            if n == 0 { break }
            if n < 0 { throw FolderQuarantineIOError.ioFailure }
            data.append(contentsOf: buffer.prefix(n))
        }
        return data
    }
}
