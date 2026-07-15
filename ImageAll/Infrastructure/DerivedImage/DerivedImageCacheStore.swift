import Foundation

enum DerivedImageCacheStoreFaultPoint: Equatable, Sendable {
    case stagingCreate
    case stagingWrite
    case stagingSync
    case stagingValidate
    case finalRename
    case afterRenameBeforeDB
    case dbPublish
    case oldObjectDelete
}

protocol DerivedImageCacheStoreFaultInjecting: Sendable {
    func shouldFault(at point: DerivedImageCacheStoreFaultPoint) -> Bool
}

struct NoDerivedImageCacheStoreFaultInjector: DerivedImageCacheStoreFaultInjecting {
    func shouldFault(at point: DerivedImageCacheStoreFaultPoint) -> Bool { false }
}

struct DerivedImageCacheStore: Sendable {
    let versionRoot: URL
    let faultInjector: any DerivedImageCacheStoreFaultInjecting

    init(versionRoot: URL, faultInjector: any DerivedImageCacheStoreFaultInjecting = NoDerivedImageCacheStoreFaultInjector()) {
        self.versionRoot = versionRoot
        self.faultInjector = faultInjector
    }

    func ensureLayout() throws {
        if DerivedImageSecureIO.isSymlink(at: versionRoot) {
            throw DerivedImageError.derivedCacheUnsafePath
        }
        guard !DerivedImageSecureIO.isSymlink(at: versionRoot.deletingLastPathComponent()) else {
            throw DerivedImageError.derivedCacheUnsafePath
        }
        try DerivedImageSecureIO.ensureDirectory(at: versionRoot)
        try DerivedImageSecureIO.ensureDirectory(at: DerivedImageCachePathLayout.stagingDirectory(under: versionRoot))
        try DerivedImageSecureIO.ensureDirectory(at: DerivedImageCachePathLayout.objectsDirectory(under: versionRoot))
    }

    func readObjectBytes(entry: DerivedImageCacheEntryRow) throws -> Data? {
        let url = DerivedImageCachePathLayout.objectURL(
            versionRoot: versionRoot,
            entryID: entry.id,
            format: entry.storageFormat
        )
        guard DerivedImageSecureIO.isRegularFile(at: url) else { return nil }
        guard DerivedImageSecureIO.fileSize(at: url) == entry.byteSize else { return nil }
        return try Data(contentsOf: url)
    }

    @discardableResult
    func publish(
        artifact: DerivedImageEncodedArtifact,
        entryID: UUID,
        format: DerivedImageStorageFormat
    ) throws -> URL {
        if faultInjector.shouldFault(at: .stagingCreate) {
            throw DerivedImageError.derivedCachePersistenceFailed
        }

        let stagingDir = DerivedImageCachePathLayout.stagingDirectory(under: versionRoot)
        let stagingURL = stagingDir.appendingPathComponent(DerivedImageCachePathLayout.stagingFileName())

        do {
            if faultInjector.shouldFault(at: .stagingWrite) {
                throw DerivedImageError.derivedCachePersistenceFailed
            }
            try DerivedImageSecureIO.writeExclusiveCreate(at: stagingURL, bytes: artifact.bytes)
            if faultInjector.shouldFault(at: .stagingSync) {
                DerivedImageSecureIO.removeIfPresent(at: stagingURL)
                throw DerivedImageError.derivedCachePersistenceFailed
            }
            if faultInjector.shouldFault(at: .stagingValidate) {
                DerivedImageSecureIO.removeIfPresent(at: stagingURL)
                throw DerivedImageError.derivedCachePersistenceFailed
            }
            let renderer = DerivedImageRenderer()
            try renderer.validateEncoded(
                artifact,
                expectedFormat: format,
                expectedWidth: artifact.pixelWidth,
                expectedHeight: artifact.pixelHeight
            )

            let objectURL = DerivedImageCachePathLayout.objectURL(
                versionRoot: versionRoot,
                entryID: entryID,
                format: format
            )
            try DerivedImageSecureIO.ensureDirectory(at: objectURL.deletingLastPathComponent())
            if faultInjector.shouldFault(at: .finalRename) {
                DerivedImageSecureIO.removeIfPresent(at: stagingURL)
                throw DerivedImageError.derivedCachePersistenceFailed
            }
            try DerivedImageSecureIO.atomicRename(from: stagingURL, to: objectURL)
            if faultInjector.shouldFault(at: .afterRenameBeforeDB) {
                throw DerivedImageError.derivedCachePersistenceFailed
            }
            return objectURL
        } catch let error as DerivedImageError {
            DerivedImageSecureIO.removeIfPresent(at: stagingURL)
            throw error
        } catch {
            DerivedImageSecureIO.removeIfPresent(at: stagingURL)
            throw DerivedImageError.derivedCachePersistenceFailed
        }
    }

    func deleteObject(entryID: UUID, format: DerivedImageStorageFormat) {
        let url = DerivedImageCachePathLayout.objectURL(
            versionRoot: versionRoot,
            entryID: entryID,
            format: format
        )
        DerivedImageSecureIO.removeIfPresent(at: url)
    }

    func removeInvalidEntryArtifacts(entry: DerivedImageCacheEntryRow) {
        deleteObject(entryID: entry.id, format: entry.storageFormat)
    }

    func listReferencedObjectPaths(entries: [DerivedImageCacheEntryRow]) -> Set<String> {
        Set(entries.map {
            DerivedImageCachePathLayout.objectRelativePath(entryID: $0.id, format: $0.storageFormat)
        })
    }
}
