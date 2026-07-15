import Foundation

struct DerivedImageSourceReader: Sendable {
    let fileResourceReader: any FolderFileResourceReading

    init(fileResourceReader: any FolderFileResourceReading = FoundationFolderFileResourceReader()) {
        self.fileResourceReader = fileResourceReader
    }

    func readSourceBytes(rootURL: URL, relativePath: String) throws -> (bytes: Data, fingerprint: DerivedImageOpenedFingerprint) {
        let rootFD = try DerivedImageSecureIO.openDirectoryNoFollow(at: rootURL)
        defer { close(rootFD) }
        let fileFD = try DerivedImageSecureIO.openRelativeReadOnlyNoFollow(
            directoryFD: rootFD,
            relativePath: relativePath
        )
        defer { close(fileFD) }
        let bytes = try DerivedImageSecureIO.readAllBytes(from: fileFD)
        let fileURL = rootURL.appendingPathComponent(relativePath)
        let fingerprint = DerivedImageOpenedFingerprint(
            sizeBytes: fileResourceReader.fileSizeBytes(for: fileURL) ?? Int64(bytes.count),
            modifiedAtNs: fileResourceReader.modifiedAtNs(for: fileURL) ?? 0,
            resourceID: fileResourceReader.resourceIdentifier(for: fileURL)
        )
        return (bytes, fingerprint)
    }

    func openedFingerprint(rootURL: URL, relativePath: String) throws -> DerivedImageOpenedFingerprint {
        let rootFD = try DerivedImageSecureIO.openDirectoryNoFollow(at: rootURL)
        defer { close(rootFD) }
        let fileFD = try DerivedImageSecureIO.openRelativeReadOnlyNoFollow(
            directoryFD: rootFD,
            relativePath: relativePath
        )
        defer { close(fileFD) }
        let fileURL = rootURL.appendingPathComponent(relativePath)
        return DerivedImageOpenedFingerprint(
            sizeBytes: fileResourceReader.fileSizeBytes(for: fileURL) ?? 0,
            modifiedAtNs: fileResourceReader.modifiedAtNs(for: fileURL) ?? 0,
            resourceID: fileResourceReader.resourceIdentifier(for: fileURL)
        )
    }
}
