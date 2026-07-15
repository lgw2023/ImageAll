import CryptoKit
import Darwin
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
    case evictObjectDelete
}

protocol DerivedImageCacheStoreFaultInjecting: Sendable {
    func shouldFault(at point: DerivedImageCacheStoreFaultPoint) -> Bool
}

struct NoDerivedImageCacheStoreFaultInjector: DerivedImageCacheStoreFaultInjecting {
    func shouldFault(at point: DerivedImageCacheStoreFaultPoint) -> Bool { false }
}

enum DerivedImageRepositoryFaultPoint: Equatable, Sendable {
    case insert
    case revalidation
    case lruTouch
}

protocol DerivedImageRepositoryFaultInjecting: Sendable {
    func shouldFault(at point: DerivedImageRepositoryFaultPoint) -> Bool
}

struct NoDerivedImageRepositoryFaultInjector: DerivedImageRepositoryFaultInjecting {
    func shouldFault(at point: DerivedImageRepositoryFaultPoint) -> Bool { false }
}

protocol DerivedImagePublishCheckpointing: Sendable {
    func blockAfterStagingWritten(stagingName: String)
}

struct NoDerivedImagePublishCheckpoint: DerivedImagePublishCheckpointing {
    func blockAfterStagingWritten(stagingName: String) {}
}

protocol DerivedImageFinalPublishCheckpointing: Sendable {
    func blockAfterFinalObjectPublished(
        entryID: UUID,
        storageFormat: DerivedImageStorageFormat,
        stagingName: String
    )
}

struct NoDerivedImageFinalPublishCheckpoint: DerivedImageFinalPublishCheckpointing {
    func blockAfterFinalObjectPublished(
        entryID: UUID,
        storageFormat: DerivedImageStorageFormat,
        stagingName: String
    ) {}
}

protocol DerivedImageMaintenanceCheckpointing: Sendable {
    func blockWhileMaintenanceHeld()
}

struct NoDerivedImageMaintenanceCheckpoint: DerivedImageMaintenanceCheckpointing {
    func blockWhileMaintenanceHeld() {}
}

struct DerivedImageCacheStore: Sendable {
    let cachesDirectory: URL
    let faultInjector: any DerivedImageCacheStoreFaultInjecting
    let publishCheckpoint: any DerivedImagePublishCheckpointing

    var versionRoot: URL {
        DerivedImageCachePathLayout.versionRoot(under: cachesDirectory)
    }

    init(
        cachesDirectory: URL,
        faultInjector: any DerivedImageCacheStoreFaultInjecting = NoDerivedImageCacheStoreFaultInjector(),
        publishCheckpoint: any DerivedImagePublishCheckpointing = NoDerivedImagePublishCheckpoint()
    ) {
        self.cachesDirectory = cachesDirectory
        self.faultInjector = faultInjector
        self.publishCheckpoint = publishCheckpoint
    }

    func ensureLayout() throws -> DerivedImageAnchoredCacheSession {
        try DerivedImageAnchoredCacheSession.open(cachesDirectory: cachesDirectory)
    }

    func readObjectBytes(entry: DerivedImageCacheEntryRow, session: DerivedImageAnchoredCacheSession) throws -> Data? {
        try session.readObject(
            entryID: entry.id,
            format: entry.storageFormat,
            expectedSize: entry.byteSize
        )
    }

    @discardableResult
    func publish(
        artifact: DerivedImageEncodedArtifact,
        entryID: UUID,
        format: DerivedImageStorageFormat,
        stagingName: String,
        session: DerivedImageAnchoredCacheSession
    ) throws -> String {
        if faultInjector.shouldFault(at: .stagingCreate) {
            throw DerivedImageError.derivedCachePersistenceFailed
        }

        var stagingFD: Int32 = -1
        defer {
            if stagingFD >= 0 {
                Darwin.close(stagingFD)
            }
            try? session.removeStaging(name: stagingName)
        }

        do {
            stagingFD = try session.createStagingExclusiveEmpty(name: stagingName)

            guard artifact.bytes.count > 1 else {
                throw DerivedImageError.derivedCachePersistenceFailed
            }
            let prefixLength = min(max(1, artifact.bytes.count / 8), artifact.bytes.count - 1)
            let prefix = artifact.bytes.prefix(prefixLength)
            let suffix = artifact.bytes.suffix(from: prefixLength)
            try DerivedImageSecureIO.writeAll(bytes: Data(prefix), to: stagingFD)

            if faultInjector.shouldFault(at: .stagingWrite) {
                throw DerivedImageError.derivedCachePersistenceFailed
            }

            try DerivedImageSecureIO.writeAll(bytes: Data(suffix), to: stagingFD)

            if faultInjector.shouldFault(at: .stagingSync) {
                throw DerivedImageError.derivedCachePersistenceFailed
            }
            try DerivedImageSecureIO.fsyncFile(stagingFD)
            Darwin.close(stagingFD)
            stagingFD = -1

            let (stagedBytes, stagedSize) = try session.readStaging(name: stagingName)
            guard stagedSize == artifact.byteSize else {
                throw DerivedImageError.derivedCachePersistenceFailed
            }
            let digest = SHA256.hash(data: stagedBytes)
            guard Data(digest) == artifact.sha256 else {
                throw DerivedImageError.derivedCachePersistenceFailed
            }

            let renderer = DerivedImageRenderer()
            try renderer.validateEncoded(
                DerivedImageEncodedArtifact(
                    bytes: stagedBytes,
                    byteSize: stagedSize,
                    sha256: Data(digest),
                    storageFormat: format,
                    pixelWidth: artifact.pixelWidth,
                    pixelHeight: artifact.pixelHeight
                ),
                expectedFormat: format,
                expectedWidth: artifact.pixelWidth,
                expectedHeight: artifact.pixelHeight
            )

            if faultInjector.shouldFault(at: .stagingValidate) {
                throw DerivedImageError.derivedCachePersistenceFailed
            }

            publishCheckpoint.blockAfterStagingWritten(stagingName: stagingName)

            if faultInjector.shouldFault(at: .finalRename) {
                throw DerivedImageError.derivedCachePersistenceFailed
            }
            try session.publishStagingFile(stagingName: stagingName, entryID: entryID, format: format)
            if faultInjector.shouldFault(at: .afterRenameBeforeDB) {
                throw DerivedImageError.derivedCachePersistenceFailed
            }
            return stagingName
        } catch let error as DerivedImageError {
            throw error
        } catch DerivedImageSecureIOError.unsafePath {
            throw DerivedImageError.derivedCacheUnsafePath
        } catch {
            throw DerivedImageError.derivedCachePersistenceFailed
        }
    }

    func deleteObject(entryID: UUID, format: DerivedImageStorageFormat, session: DerivedImageAnchoredCacheSession) throws {
        _ = try session.deleteObject(entryID: entryID, format: format)
    }

    func removeInvalidEntryArtifacts(entry: DerivedImageCacheEntryRow, session: DerivedImageAnchoredCacheSession) throws -> UInt64? {
        let bytes = try session.objectByteSize(entryID: entry.id, format: entry.storageFormat)
        guard try session.deleteObject(entryID: entry.id, format: entry.storageFormat) else {
            return nil
        }
        return bytes
    }

    func listReferencedObjectPaths(entries: [DerivedImageCacheEntryRow]) -> Set<String> {
        Set(entries.map {
            DerivedImageCachePathLayout.objectRelativePath(entryID: $0.id, format: $0.storageFormat)
        })
    }
}
