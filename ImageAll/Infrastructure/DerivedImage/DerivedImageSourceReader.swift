import Darwin
import Foundation

struct DerivedImageSourceHandleFstat: Sendable {
    let sizeBytes: Int64
    let modifiedAtNs: Int64
}

struct DerivedImageSourceReadResult: Sendable {
    let bytes: Data
    let initialFingerprint: DerivedImageOpenedFingerprint
    let preHandleFstat: DerivedImageSourceHandleFstat
    let postHandleFstat: DerivedImageSourceHandleFstat
    let postResourceID: Data?
}

struct DerivedImageSourceReader: Sendable {
    let fileResourceReader: any FolderFileResourceReading

    init(fileResourceReader: any FolderFileResourceReading = FoundationFolderFileResourceReader()) {
        self.fileResourceReader = fileResourceReader
    }

    func readSourceBytes(rootURL: URL, relativePath: String) throws -> DerivedImageSourceReadResult {
        let rootFD = try DerivedImageSecureIO.openDirectoryNoFollow(at: rootURL)
        defer { Darwin.close(rootFD) }
        let fileFD = try DerivedImageSecureIO.openRelativeReadOnlyNoFollow(
            directoryFD: rootFD,
            relativePath: relativePath
        )
        defer { Darwin.close(fileFD) }

        let preHandleFstatValues = try DerivedImageSecureIO.fstatRegularFile(fd: fileFD)
        let initialFingerprint = try DerivedImageSourceFingerprintFacts.handleFacts(
            fd: fileFD,
            reader: fileResourceReader
        )
        let bytes = try DerivedImageSecureIO.readAllBytes(from: fileFD)
        let postHandleFstatValues = try DerivedImageSecureIO.fstatRegularFile(fd: fileFD)
        let fdURL = DerivedImageSourceFingerprintFacts.fileDescriptorURL(for: fileFD)
        let postResourceID = fileResourceReader.resourceIdentifier(for: fdURL)
        return DerivedImageSourceReadResult(
            bytes: bytes,
            initialFingerprint: initialFingerprint,
            preHandleFstat: DerivedImageSourceHandleFstat(
                sizeBytes: preHandleFstatValues.sizeBytes,
                modifiedAtNs: preHandleFstatValues.modifiedAtNs
            ),
            postHandleFstat: DerivedImageSourceHandleFstat(
                sizeBytes: postHandleFstatValues.sizeBytes,
                modifiedAtNs: postHandleFstatValues.modifiedAtNs
            ),
            postResourceID: postResourceID
        )
    }

    func reopenedLocatorFingerprint(rootURL: URL, relativePath: String) throws -> DerivedImageOpenedFingerprint {
        let rootFD = try DerivedImageSecureIO.openDirectoryNoFollow(at: rootURL)
        defer { Darwin.close(rootFD) }
        let fileFD = try DerivedImageSecureIO.openRelativeReadOnlyNoFollow(
            directoryFD: rootFD,
            relativePath: relativePath
        )
        defer { Darwin.close(fileFD) }
        return try DerivedImageSourceFingerprintFacts.reopenedLocatorFacts(
            fd: fileFD,
            reader: fileResourceReader
        )
    }
}
