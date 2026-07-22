import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO

struct AppCoreMLEmbeddingCacheKey: Equatable, Sendable {
    let catalogScopeID: UUID
    let assetID: UUID
    let contentRevision: Int64
}

enum AppCoreMLEmbeddingOrigin: Equatable, Sendable {
    case generated
    case cacheHit
}

struct AppCoreMLCachedEmbedding: Equatable, Sendable {
    let identity: AppCoreMLModelIdentity
    let values: [Float]
    let vectorSHA256: String
    let origin: AppCoreMLEmbeddingOrigin
}

final class AppCoreMLEmbeddingCache: @unchecked Sendable {
    private static let processLock = NSLock()
    private static let defaultMaximumCacheBytes = 256 * 1024 * 1024
    private static let recordSchemaRevision = 2

    private let cachesDirectory: URL
    private let service: AppCoreMLEmbeddingService
    private let maximumCacheBytes: Int64
    private var requiresMaintenance = true

    init(
        cachesDirectory: URL,
        service: AppCoreMLEmbeddingService,
        maximumCacheBytes: Int = defaultMaximumCacheBytes
    ) {
        self.cachesDirectory = cachesDirectory
        self.service = service
        self.maximumCacheBytes = Int64(max(0, maximumCacheBytes))
    }

    func embedding(
        for image: CGImage,
        key: AppCoreMLEmbeddingCacheKey
    ) throws -> AppCoreMLCachedEmbedding {
        guard case .ready = service.availability else {
            throw AppCoreMLEmbeddingError.unavailable
        }
        guard key.contentRevision >= 0 else {
            return try generatedEmbedding(for: image)
        }
        return try Self.processLock.withLock {
            let lockDescriptor: Int32
            do {
                lockDescriptor = try acquireLifecycleLock()
            } catch {
                return try generatedEmbedding(for: image)
            }
            defer {
                _ = Darwin.lockf(lockDescriptor, F_ULOCK, 0)
                Darwin.close(lockDescriptor)
            }
            if requiresMaintenance,
               case let .ready(identity) = service.availability
            {
                do {
                    try maintain(identity: identity)
                    requiresMaintenance = false
                } catch {
                    // Cache maintenance is best-effort; inference remains available.
                }
            }
            return try embeddingLocked(for: image, key: key)
        }
    }

    func cachedEmbedding(
        for key: AppCoreMLEmbeddingCacheKey
    ) throws -> AppCoreMLCachedEmbedding? {
        guard case let .ready(identity) = service.availability else {
            throw AppCoreMLEmbeddingError.unavailable
        }
        guard key.contentRevision >= 0 else { return nil }
        let address = CacheAddress(key: key, identity: identity)
        return Self.processLock.withLock {
            try? read(address: address, identity: identity)
        }
    }

    private func embeddingLocked(
        for image: CGImage,
        key: AppCoreMLEmbeddingCacheKey
    ) throws -> AppCoreMLCachedEmbedding {
        guard case let .ready(identity) = service.availability else {
            throw AppCoreMLEmbeddingError.unavailable
        }
        let address = CacheAddress(key: key, identity: identity)
        if let cached = try? read(address: address, identity: identity) {
            return cached
        }

        let result = try generatedEmbedding(for: image)
        let vectorData = Self.vectorData(result.values)
        if let destination = try? publish(
            Record(
                schemaRevision: Self.recordSchemaRevision,
                address: address,
                vectorData: vectorData,
                vectorSHA256: result.vectorSHA256
            ),
            address: address
        ) {
            try? enforceCapacity(preserving: destination)
        }
        return result
    }

    private func generatedEmbedding(for image: CGImage) throws -> AppCoreMLCachedEmbedding {
        let generated = try service.embedding(for: image)
        let vectorData = Self.vectorData(generated.values)
        return AppCoreMLCachedEmbedding(
            identity: generated.identity,
            values: generated.values,
            vectorSHA256: Self.sha256(vectorData),
            origin: .generated
        )
    }

    private func acquireLifecycleLock() throws -> Int32 {
        let versionRoot = Self.versionRoot(under: cachesDirectory)
        for directory in [cachesDirectory, versionRoot.deletingLastPathComponent(), versionRoot] {
            try DerivedImageSecureIO.ensureDirectory(at: directory)
            guard !DerivedImageSecureIO.isSymlink(at: directory) else {
                throw DerivedImageSecureIOError.unsafePath
            }
        }
        let lockURL = versionRoot.appendingPathComponent("lifecycle.lock")
        let descriptor = Darwin.open(
            lockURL.path,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        do {
            try DerivedImageSecureIO.verifyRegularFileFD(descriptor)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        while Darwin.lockf(descriptor, F_LOCK, 0) != 0 {
            guard errno == EINTR else {
                let code = errno
                Darwin.close(descriptor)
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
        }
        return descriptor
    }

    private func read(
        address: CacheAddress,
        identity: AppCoreMLModelIdentity
    ) throws -> AppCoreMLCachedEmbedding? {
        let url = try objectURL(address: address)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard DerivedImageSecureIO.isRegularFile(at: url) else { return nil }
        let fd = try DerivedImageSecureIO.openReadOnlyNoFollow(at: url)
        defer { Darwin.close(fd) }
        let data = try DerivedImageSecureIO.readAllBytes(from: fd)
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard record.schemaRevision == Self.recordSchemaRevision,
              record.address == address,
              record.vectorSHA256 == Self.sha256(record.vectorData),
              let values = Self.values(record.vectorData),
              values.count == identity.elementCount,
              values.allSatisfy(\.isFinite)
        else {
            return nil
        }
        return AppCoreMLCachedEmbedding(
            identity: identity,
            values: values,
            vectorSHA256: record.vectorSHA256,
            origin: .cacheHit
        )
    }

    private func publish(_ record: Record, address: CacheAddress) throws -> URL {
        let destination = try objectURL(address: address)
        let versionRoot = Self.versionRoot(under: cachesDirectory)
        let objects = versionRoot.appendingPathComponent("objects", isDirectory: true)
        let shard = destination.deletingLastPathComponent()
        for directory in [cachesDirectory, versionRoot.deletingLastPathComponent(), versionRoot, objects, shard] {
            try DerivedImageSecureIO.ensureDirectory(at: directory)
            guard !DerivedImageSecureIO.isSymlink(at: directory) else {
                throw DerivedImageSecureIOError.unsafePath
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        try data.write(to: destination, options: .atomic)
        guard DerivedImageSecureIO.isRegularFile(at: destination) else {
            throw DerivedImageSecureIOError.unsafePath
        }
        return destination
    }

    private func maintain(identity: AppCoreMLModelIdentity) throws {
        for object in try ownedObjects() {
            let isCurrent: Bool
            do {
                let descriptor = try DerivedImageSecureIO.openReadOnlyNoFollow(at: object.url)
                defer { Darwin.close(descriptor) }
                let data = try DerivedImageSecureIO.readAllBytes(from: descriptor)
                let record = try JSONDecoder().decode(Record.self, from: data)
                isCurrent = record.schemaRevision == Self.recordSchemaRevision
                    && record.address.matches(identity: identity)
            } catch {
                isCurrent = false
            }
            if !isCurrent {
                _ = Darwin.unlink(object.url.path)
            }
        }
        try enforceCapacity(preserving: nil)
    }

    private func enforceCapacity(preserving destination: URL?) throws {
        var objects = try ownedObjects()
        var totalBytes = objects.reduce(Int64(0)) { $0 + $1.sizeBytes }
        guard totalBytes > maximumCacheBytes else { return }
        objects.sort {
            if $0.modifiedAtNs == $1.modifiedAtNs {
                return $0.url.path < $1.url.path
            }
            return $0.modifiedAtNs < $1.modifiedAtNs
        }
        for object in objects where object.url != destination {
            guard totalBytes > maximumCacheBytes else { break }
            if removeOwnedObject(at: object.url) {
                totalBytes -= object.sizeBytes
            }
        }
        if let destination,
           totalBytes > maximumCacheBytes,
           objects.contains(where: { $0.url == destination })
        {
            _ = removeOwnedObject(at: destination)
        }
    }

    private func removeOwnedObject(at url: URL) -> Bool {
        Darwin.unlink(url.path) == 0 || errno == ENOENT
    }

    private func ownedObjects() throws -> [CacheObject] {
        let objectsDirectory = Self.versionRoot(under: cachesDirectory)
            .appendingPathComponent("objects", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: objectsDirectory.path,
            isDirectory: &isDirectory
        ) else {
            return []
        }
        guard isDirectory.boolValue,
              !DerivedImageSecureIO.isSymlink(at: objectsDirectory),
              let enumerator = FileManager.default.enumerator(
                  at: objectsDirectory,
                  includingPropertiesForKeys: nil,
                  options: [.skipsPackageDescendants]
              )
        else {
            throw DerivedImageSecureIOError.unsafePath
        }
        var result: [CacheObject] = []
        for case let url as URL in enumerator where url.pathExtension == "embedding" {
            var status = stat()
            guard lstat(url.path, &status) == 0,
                  status.st_mode & S_IFMT == S_IFREG
            else {
                continue
            }
            result.append(
                CacheObject(
                    url: url,
                    sizeBytes: Int64(status.st_size),
                    modifiedAtNs: Int64(status.st_mtimespec.tv_sec) * 1_000_000_000
                        + Int64(status.st_mtimespec.tv_nsec)
                )
            )
        }
        return result
    }

    private func objectURL(address: CacheAddress) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let digest = Self.sha256(try encoder.encode(address))
        return Self.versionRoot(under: cachesDirectory)
            .appendingPathComponent("objects", isDirectory: true)
            .appendingPathComponent(String(digest.prefix(2)), isDirectory: true)
            .appendingPathComponent("\(digest).embedding")
    }

    private static func versionRoot(under cachesDirectory: URL) -> URL {
        cachesDirectory
            .appendingPathComponent("ModelEmbeddings", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
    }

    private static func vectorData(_ values: [Float]) -> Data {
        var data = Data(capacity: values.count * MemoryLayout<UInt32>.size)
        for value in values {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func values(_ data: Data) -> [Float]? {
        guard data.count.isMultiple(of: MemoryLayout<UInt32>.size) else { return nil }
        let bytes = [UInt8](data)
        return stride(from: 0, to: bytes.count, by: 4).map { offset in
            let bits = UInt32(bytes[offset])
                | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16
                | UInt32(bytes[offset + 3]) << 24
            return Float(bitPattern: bits)
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct Record: Codable {
        let schemaRevision: Int
        let address: CacheAddress
        let vectorData: Data
        let vectorSHA256: String
    }

    private struct CacheObject {
        let url: URL
        let sizeBytes: Int64
        let modifiedAtNs: Int64
    }

    private struct CacheAddress: Codable, Equatable {
        let catalogScopeID: String
        let assetID: String
        let contentRevision: Int64
        let provider: String
        let modelID: String
        let modelRevision: String
        let preprocessingRevision: String
        let embeddingSemantics: String
        let postprocessingRevision: String
        let elementType: String
        let elementCount: Int
        let sourceModelSHA256: String
        let artifactSHA256: String
        let manifestSHA256: String
        let licenseID: String
        let licenseSHA256: String

        init(key: AppCoreMLEmbeddingCacheKey, identity: AppCoreMLModelIdentity) {
            catalogScopeID = key.catalogScopeID.uuidString.lowercased()
            assetID = key.assetID.uuidString.lowercased()
            contentRevision = key.contentRevision
            provider = identity.provider
            modelID = identity.modelID
            modelRevision = identity.modelRevision
            preprocessingRevision = identity.preprocessingRevision
            embeddingSemantics = identity.embeddingSemantics
            postprocessingRevision = identity.postprocessingRevision
            elementType = identity.elementType
            elementCount = identity.elementCount
            sourceModelSHA256 = identity.sourceModelSHA256
            artifactSHA256 = identity.artifactSHA256
            manifestSHA256 = identity.manifestSHA256
            licenseID = identity.licenseID
            licenseSHA256 = identity.licenseSHA256
        }

        func matches(identity: AppCoreMLModelIdentity) -> Bool {
            provider == identity.provider
                && modelID == identity.modelID
                && modelRevision == identity.modelRevision
                && preprocessingRevision == identity.preprocessingRevision
                && embeddingSemantics == identity.embeddingSemantics
                && postprocessingRevision == identity.postprocessingRevision
                && elementType == identity.elementType
                && elementCount == identity.elementCount
                && sourceModelSHA256 == identity.sourceModelSHA256
                && artifactSHA256 == identity.artifactSHA256
                && manifestSHA256 == identity.manifestSHA256
                && licenseID == identity.licenseID
                && licenseSHA256 == identity.licenseSHA256
        }
    }
}

actor AppSelectedAssetEmbeddingCacheRuntime: AppSelectedAssetEmbeddingCaching {
    private let catalogScopeID: UUID
    private let activationCoordinator: AppModelActivationCoordinator
    private let cachesDirectory: URL

    init(
        catalogScopeID: UUID,
        activationCoordinator: AppModelActivationCoordinator,
        cachesDirectory: URL
    ) {
        self.catalogScopeID = catalogScopeID
        self.activationCoordinator = activationCoordinator
        self.cachesDirectory = cachesDirectory
    }

    func cacheSelectedAsset(
        assetID: UUID,
        contentRevision: Int,
        imageData: @escaping @Sendable () async throws -> Data
    ) async throws -> AppCoreMLCachedEmbedding {
        guard contentRevision > 0 else {
            throw AppSelectedAssetEmbeddingCacheError.invalidAsset
        }
        guard let service = await activationCoordinator.readyService() else {
            throw AppSelectedAssetEmbeddingCacheError.modelUnavailable
        }
        let key = AppCoreMLEmbeddingCacheKey(
            catalogScopeID: catalogScopeID,
            assetID: assetID,
            contentRevision: Int64(contentRevision)
        )
        let cache = AppCoreMLEmbeddingCache(
            cachesDirectory: cachesDirectory,
            service: service
        )
        if let hit = try cache.cachedEmbedding(for: key) {
            return hit
        }
        let data = try await imageData()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw AppSelectedAssetEmbeddingCacheError.invalidImage
        }
        let result = try cache.embedding(for: image, key: key)
        guard let persisted = try cache.cachedEmbedding(for: key),
              persisted.identity == result.identity,
              persisted.vectorSHA256 == result.vectorSHA256
        else {
            throw AppSelectedAssetEmbeddingCacheError.persistenceFailed
        }
        return result
    }
}
