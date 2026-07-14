import Foundation

struct CatalogSnapshotDescriptor: Equatable, Sendable {
    let snapshotID: String
    let directoryURL: URL
    let manifest: CatalogSnapshotManifest
}

enum CatalogSnapshotCatalog {
    static func discoverPublishedSnapshots(
        in backupsDirectoryURL: URL,
        fileManager: FileManager = .default
    ) throws -> [CatalogSnapshotDescriptor] {
        guard fileManager.fileExists(atPath: backupsDirectoryURL.path) else {
            return []
        }

        let children = try fileManager.contentsOfDirectory(
            at: backupsDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var descriptors: [CatalogSnapshotDescriptor] = []
        for directoryURL in children {
            let name = directoryURL.lastPathComponent
            guard !name.hasSuffix(".tmp") else {
                continue
            }
            guard CatalogSnapshotManifestValidator.isLowercaseCanonicalUUID(name) else {
                continue
            }
            if let descriptor = try? validatePublishedSnapshotDirectory(directoryURL, fileManager: fileManager) {
                descriptors.append(descriptor)
            }
        }

        return descriptors.sorted {
            if $0.manifest.createdAtMs != $1.manifest.createdAtMs {
                return $0.manifest.createdAtMs > $1.manifest.createdAtMs
            }
            return $0.snapshotID < $1.snapshotID
        }
    }

    static func validatePublishedSnapshotDirectory(
        _ directoryURL: URL,
        fileManager: FileManager = .default
    ) throws -> CatalogSnapshotDescriptor {
        let snapshotID = directoryURL.lastPathComponent
        guard CatalogSnapshotManifestValidator.isLowercaseCanonicalUUID(snapshotID) else {
            throw CatalogSnapshotError.invalidSnapshotID
        }

        let databaseURL = directoryURL.appendingPathComponent(CatalogSnapshotConstants.databaseFilename)
        let manifestURL = directoryURL.appendingPathComponent(CatalogSnapshotConstants.manifestFilename)

        try validateRegularFile(at: databaseURL, fileManager: fileManager)
        try validateRegularFile(at: manifestURL, fileManager: fileManager)
        try CatalogDatabaseSidecarHelpers.requireNoSidecars(at: databaseURL, fileManager: fileManager)

        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try CatalogSnapshotManifestCodec.decode(from: manifestData)
        try CatalogSnapshotManifestValidator.validate(manifest, expectedSnapshotID: snapshotID)

        let bytes = try CatalogSnapshotHashing.fileSize(of: databaseURL)
        guard bytes == manifest.databaseBytes else {
            throw CatalogSnapshotError.databaseSizeMismatch
        }

        let sha256 = try CatalogSnapshotHashing.sha256Hex(of: databaseURL)
        guard sha256 == manifest.databaseSHA256 else {
            throw CatalogSnapshotError.databaseChecksumMismatch
        }

        return CatalogSnapshotDescriptor(
            snapshotID: snapshotID,
            directoryURL: directoryURL,
            manifest: manifest
        )
    }

    private static func validateRegularFile(at url: URL, fileManager: FileManager) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw CatalogSnapshotError.invalidManifest
        }

        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values.isSymbolicLink == true {
            throw CatalogSnapshotError.invalidManifest
        }
    }
}
