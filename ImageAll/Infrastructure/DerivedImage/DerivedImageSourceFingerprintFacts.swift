import Foundation

enum DerivedImageSourceFingerprintFacts {
    static func fileDescriptorURL(for fd: Int32) -> URL {
        URL(fileURLWithPath: "/dev/fd/\(fd)")
    }

    static func handleFacts(
        fd: Int32,
        reader: any FolderFileResourceReading
    ) throws -> DerivedImageOpenedFingerprint {
        try DerivedImageSecureIO.verifyRegularFileFD(fd)
        let fdURL = fileDescriptorURL(for: fd)
        guard let sizeBytes = reader.fileSizeBytes(for: fdURL),
              let modifiedAtNs = reader.modifiedAtNs(for: fdURL)
        else {
            throw DerivedImageSecureIOError.ioFailure
        }
        let resourceID = reader.resourceIdentifier(for: fdURL)
        return DerivedImageOpenedFingerprint(
            sizeBytes: sizeBytes,
            modifiedAtNs: modifiedAtNs,
            resourceID: resourceID
        )
    }

    static func reopenedLocatorFacts(
        fd: Int32,
        reader: any FolderFileResourceReading
    ) throws -> DerivedImageOpenedFingerprint {
        try handleFacts(fd: fd, reader: reader)
    }
}
