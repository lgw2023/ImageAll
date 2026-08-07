import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

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
    let isPersisted: Bool

    init(
        identity: AppCoreMLModelIdentity,
        values: [Float],
        vectorSHA256: String,
        origin: AppCoreMLEmbeddingOrigin,
        isPersisted: Bool = true
    ) {
        self.identity = identity
        self.values = values
        self.vectorSHA256 = vectorSHA256
        self.origin = origin
        self.isPersisted = isPersisted
    }
}

final class AppCoreMLEmbeddingCache: @unchecked Sendable {
    private static let processLock = NSLock()
    // Access is serialized by processLock and the cross-process lifecycle lock.
    nonisolated(unsafe) private static var capacityStates: [CapacityStateKey: CapacityState] = [:]
    private static let defaultMaximumCacheBytes = 256 * 1024 * 1024
    private static let recordSchemaRevision = 2

    private let cachesDirectory: URL
    private let service: AppCoreMLEmbeddingService
    private let maximumCacheBytes: Int64

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
        try embedding(for: image, key: key, isPreparedModelInput: false)
    }

    func embedding(
        forPreparedModelInput image: CGImage,
        key: AppCoreMLEmbeddingCacheKey
    ) throws -> AppCoreMLCachedEmbedding {
        try embedding(for: image, key: key, isPreparedModelInput: true)
    }

    private func embedding(
        for image: CGImage,
        key: AppCoreMLEmbeddingCacheKey,
        isPreparedModelInput: Bool
    ) throws -> AppCoreMLCachedEmbedding {
        guard case .ready = service.availability else {
            throw AppCoreMLEmbeddingError.unavailable
        }
        guard key.contentRevision >= 0 else {
            return try generatedEmbedding(
                for: image,
                isPreparedModelInput: isPreparedModelInput
            )
        }
        return try Self.processLock.withLock {
            let lockDescriptor: Int32
            do {
                lockDescriptor = try acquireLifecycleLock()
            } catch {
                return try generatedEmbedding(
                    for: image,
                    isPreparedModelInput: isPreparedModelInput
                )
            }
            defer {
                _ = Darwin.lockf(lockDescriptor, F_ULOCK, 0)
                Darwin.close(lockDescriptor)
            }
            // Cache addresses include the complete model identity, and reads
            // validate the record schema. A lookup therefore cannot consume an
            // older model's object. Avoid opening and decoding every cache object
            // on this latency-sensitive path; capacity enforcement after a
            // publish reclaims older objects.
            return try embeddingLocked(
                for: image,
                key: key,
                isPreparedModelInput: isPreparedModelInput
            )
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
        key: AppCoreMLEmbeddingCacheKey,
        isPreparedModelInput: Bool
    ) throws -> AppCoreMLCachedEmbedding {
        guard case let .ready(identity) = service.availability else {
            throw AppCoreMLEmbeddingError.unavailable
        }
        let address = CacheAddress(key: key, identity: identity)
        if let cached = try? read(address: address, identity: identity) {
            return cached
        }

        let result = try generatedEmbedding(
            for: image,
            isPreparedModelInput: isPreparedModelInput
        )
        let vectorData = Self.vectorData(result.values)
        if let published = try? publish(
            Record(
                schemaRevision: Self.recordSchemaRevision,
                address: address,
                vectorData: vectorData,
                vectorSHA256: result.vectorSHA256
            ),
            address: address
        ) {
            let retained = (try? enforceCapacity(afterPublishing: published)) ?? true
            return AppCoreMLCachedEmbedding(
                identity: result.identity,
                values: result.values,
                vectorSHA256: result.vectorSHA256,
                origin: result.origin,
                isPersisted: retained
            )
        }
        return result
    }

    private func generatedEmbedding(
        for image: CGImage,
        isPreparedModelInput: Bool
    ) throws -> AppCoreMLCachedEmbedding {
        let generated = isPreparedModelInput
            ? try service.embedding(forPreparedModelInput: image)
            : try service.embedding(for: image)
        let vectorData = Self.vectorData(generated.values)
        return AppCoreMLCachedEmbedding(
            identity: generated.identity,
            values: generated.values,
            vectorSHA256: Self.sha256(vectorData),
            origin: .generated,
            isPersisted: false
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

    private func publish(_ record: Record, address: CacheAddress) throws -> CacheObject {
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
        var status = stat()
        guard lstat(destination.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG
        else {
            throw DerivedImageSecureIOError.unsafePath
        }
        return CacheObject(
            url: Self.canonicalFileURL(destination),
            sizeBytes: Int64(status.st_size),
            modifiedAtNs: Int64(status.st_mtimespec.tv_sec) * 1_000_000_000
                + Int64(status.st_mtimespec.tv_nsec)
        )
    }

    private func enforceCapacity(afterPublishing published: CacheObject) throws -> Bool {
        let key = CapacityStateKey(
            rootPath: Self.canonicalFileURL(
                Self.versionRoot(under: cachesDirectory)
            ).path,
            maximumCacheBytes: maximumCacheBytes
        )
        var state: CapacityState
        if let existing = Self.capacityStates[key] {
            state = existing
        } else {
            let objects = try ownedObjects()
            state = CapacityState(
                totalBytes: objects.reduce(Int64(0)) { $0 + $1.sizeBytes },
                objectsByPath: Dictionary(
                    uniqueKeysWithValues: objects.map { ($0.url.path, $0) }
                ),
                evictionQueue: Self.oldestFirst(objects),
                nextEvictionIndex: 0
            )
        }
        if let replaced = state.objectsByPath.updateValue(published, forKey: published.url.path) {
            state.totalBytes -= replaced.sizeBytes
        }
        state.totalBytes += published.sizeBytes
        state.evictionQueue.append(published)
        guard state.totalBytes > maximumCacheBytes else {
            Self.capacityStates[key] = state
            return true
        }
        while state.totalBytes > maximumCacheBytes,
              state.nextEvictionIndex < state.evictionQueue.count
        {
            let candidate = state.evictionQueue[state.nextEvictionIndex]
            state.nextEvictionIndex += 1
            guard let current = state.objectsByPath[candidate.url.path],
                  current.sizeBytes == candidate.sizeBytes,
                  current.modifiedAtNs == candidate.modifiedAtNs
            else {
                continue
            }
            if removeOwnedObject(at: current.url) {
                state.totalBytes -= current.sizeBytes
                state.objectsByPath[current.url.path] = nil
            }
        }
        state.compactEvictionQueueIfNeeded()
        let retained = state.objectsByPath[published.url.path] != nil
        Self.capacityStates[key] = state
        return retained
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
                    url: Self.canonicalFileURL(url),
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

    /// FileManager enumerators canonicalize macOS' `/var` alias to
    /// `/private/var`, while a caller-provided cache URL may keep `/var`.
    /// Capacity accounting must use one spelling or it can count and evict the
    /// just-published object as if it were a different file.
    private static func canonicalFileURL(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func oldestFirst(_ objects: [CacheObject]) -> [CacheObject] {
        objects.sorted {
            if $0.modifiedAtNs == $1.modifiedAtNs {
                return $0.url.path < $1.url.path
            }
            return $0.modifiedAtNs < $1.modifiedAtNs
        }
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

    private struct CapacityStateKey: Hashable {
        let rootPath: String
        let maximumCacheBytes: Int64
    }

    private struct CapacityState {
        var totalBytes: Int64
        var objectsByPath: [String: CacheObject]
        var evictionQueue: [CacheObject]
        var nextEvictionIndex: Int

        mutating func compactEvictionQueueIfNeeded() {
            guard nextEvictionIndex >= 1_024,
                  nextEvictionIndex * 2 >= evictionQueue.count
            else { return }
            evictionQueue.removeFirst(nextEvictionIndex)
            nextEvictionIndex = 0
        }
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

    }
}

/// Lossless cache of the exact 224 x 224 image produced by the encoder's
/// existing preview preprocessing path. It is deliberately separate from the
/// embedding cache so a future model artifact with the same preprocessing can
/// reuse the expensive decode/resize result without changing personal-head
/// compatibility.
final class AppCoreMLModelInputCache: @unchecked Sendable {
    private static let processLock = NSLock()
    private static let recordSchemaRevision = 1
    private static let pipelineRevision = "legacy-preview-preprocess-v1"
    private static let defaultMaximumCacheBytes: Int64 = 512 * 1024 * 1024

    private let cachesDirectory: URL
    private let maximumCacheBytes: Int64
    private var capacityState: CapacityState?

    init(
        cachesDirectory: URL,
        maximumCacheBytes: Int64 = defaultMaximumCacheBytes
    ) {
        self.cachesDirectory = cachesDirectory
        self.maximumCacheBytes = max(0, maximumCacheBytes)
    }

    func cachedImage(
        for key: AppCoreMLEmbeddingCacheKey,
        preprocessingRevision: String
    ) -> CGImage? {
        Self.processLock.withLock {
            try? read(address: Address(key: key, preprocessingRevision: preprocessingRevision))
        }
    }

    func publish(
        _ image: CGImage,
        for key: AppCoreMLEmbeddingCacheKey,
        preprocessingRevision: String
    ) throws {
        guard image.width == 224, image.height == 224 else {
            throw AppSelectedAssetEmbeddingCacheError.invalidImage
        }
        try Self.processLock.withLock {
            let address = Address(key: key, preprocessingRevision: preprocessingRevision)
            let destination = try objectURL(address: address)
            let versionRoot = Self.versionRoot(under: cachesDirectory)
            let objects = versionRoot.appendingPathComponent("objects", isDirectory: true)
            let shard = destination.deletingLastPathComponent()
            for directory in [
                cachesDirectory,
                versionRoot.deletingLastPathComponent(),
                versionRoot,
                objects,
                shard,
            ] {
                try DerivedImageSecureIO.ensureDirectory(at: directory)
                guard !DerivedImageSecureIO.isSymlink(at: directory) else {
                    throw DerivedImageSecureIOError.unsafePath
                }
            }
            let pngData = try Self.pngData(image)
            let record = Record(
                schemaRevision: Self.recordSchemaRevision,
                address: address,
                pngData: pngData,
                pngSHA256: Self.sha256(pngData)
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(record).write(to: destination, options: .atomic)
            guard let object = Self.cacheObject(at: destination) else {
                throw DerivedImageSecureIOError.unsafePath
            }
            try enforceCapacity(preserving: object)
        }
    }

    private func read(address: Address) throws -> CGImage? {
        let url = try objectURL(address: address)
        guard FileManager.default.fileExists(atPath: url.path),
              DerivedImageSecureIO.isRegularFile(at: url)
        else {
            return nil
        }
        let descriptor = try DerivedImageSecureIO.openReadOnlyNoFollow(at: url)
        defer { Darwin.close(descriptor) }
        let data = try DerivedImageSecureIO.readAllBytes(from: descriptor)
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard record.schemaRevision == Self.recordSchemaRevision,
              record.address == address,
              record.pngSHA256 == Self.sha256(record.pngData),
              let source = CGImageSourceCreateWithData(record.pngData as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == 224,
              image.height == 224
        else {
            return nil
        }
        return image
    }

    private func enforceCapacity(preserving published: CacheObject) throws {
        if capacityState == nil {
            let objects = try ownedObjects()
            capacityState = CapacityState(
                totalBytes: objects.reduce(Int64(0)) { $0 + $1.sizeBytes },
                objectsByPath: Dictionary(
                    uniqueKeysWithValues: objects.map { ($0.url.path, $0) }
                ),
                evictionQueue: Self.oldestFirst(objects),
                nextEvictionIndex: 0
            )
        }
        guard var state = capacityState else { return }
        if let replaced = state.objectsByPath.updateValue(published, forKey: published.url.path) {
            state.totalBytes -= replaced.sizeBytes
        }
        state.totalBytes += published.sizeBytes
        state.evictionQueue.append(published)
        while state.totalBytes > maximumCacheBytes,
              state.nextEvictionIndex < state.evictionQueue.count
        {
            let candidate = state.evictionQueue[state.nextEvictionIndex]
            state.nextEvictionIndex += 1
            guard let current = state.objectsByPath[candidate.url.path],
                  current.sizeBytes == candidate.sizeBytes,
                  current.modifiedAtNs == candidate.modifiedAtNs
            else {
                continue
            }
            if Darwin.unlink(current.url.path) == 0 || errno == ENOENT {
                state.totalBytes -= current.sizeBytes
                state.objectsByPath[current.url.path] = nil
            }
        }
        state.compactEvictionQueueIfNeeded()
        capacityState = state
    }

    private func ownedObjects() throws -> [CacheObject] {
        let directory = Self.versionRoot(under: cachesDirectory)
            .appendingPathComponent("objects", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory)
        else { return [] }
        guard isDirectory.boolValue,
              !DerivedImageSecureIO.isSymlink(at: directory),
              let enumerator = FileManager.default.enumerator(
                  at: directory,
                  includingPropertiesForKeys: nil,
                  options: [.skipsPackageDescendants]
              )
        else {
            throw DerivedImageSecureIOError.unsafePath
        }
        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "model-input" else { return nil }
            return Self.cacheObject(at: url)
        }
    }

    private func objectURL(address: Address) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let digest = Self.sha256(try encoder.encode(address))
        return Self.versionRoot(under: cachesDirectory)
            .appendingPathComponent("objects", isDirectory: true)
            .appendingPathComponent(String(digest.prefix(2)), isDirectory: true)
            .appendingPathComponent("\(digest).model-input")
    }

    private static func versionRoot(under cachesDirectory: URL) -> URL {
        cachesDirectory
            .appendingPathComponent("ModelInputs", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
    }

    private static func oldestFirst(_ objects: [CacheObject]) -> [CacheObject] {
        objects.sorted {
            if $0.modifiedAtNs == $1.modifiedAtNs { return $0.url.path < $1.url.path }
            return $0.modifiedAtNs < $1.modifiedAtNs
        }
    }

    private static func pngData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw AppSelectedAssetEmbeddingCacheError.persistenceFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw AppSelectedAssetEmbeddingCacheError.persistenceFailed
        }
        return data as Data
    }

    private static func cacheObject(at url: URL) -> CacheObject? {
        var status = stat()
        guard lstat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
            return nil
        }
        return CacheObject(
            url: url.resolvingSymlinksInPath().standardizedFileURL,
            sizeBytes: Int64(status.st_size),
            modifiedAtNs: Int64(status.st_mtimespec.tv_sec) * 1_000_000_000
                + Int64(status.st_mtimespec.tv_nsec)
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct Address: Codable, Equatable {
        let catalogScopeID: String
        let assetID: String
        let contentRevision: Int64
        let preprocessingRevision: String
        let pipelineRevision: String

        init(key: AppCoreMLEmbeddingCacheKey, preprocessingRevision: String) {
            catalogScopeID = key.catalogScopeID.uuidString.lowercased()
            assetID = key.assetID.uuidString.lowercased()
            contentRevision = key.contentRevision
            self.preprocessingRevision = preprocessingRevision
            pipelineRevision = AppCoreMLModelInputCache.pipelineRevision
        }
    }

    private struct Record: Codable {
        let schemaRevision: Int
        let address: Address
        let pngData: Data
        let pngSHA256: String
    }

    private struct CacheObject {
        let url: URL
        let sizeBytes: Int64
        let modifiedAtNs: Int64
    }

    private struct CapacityState {
        var totalBytes: Int64
        var objectsByPath: [String: CacheObject]
        var evictionQueue: [CacheObject]
        var nextEvictionIndex: Int

        mutating func compactEvictionQueueIfNeeded() {
            guard nextEvictionIndex >= 1_024,
                  nextEvictionIndex * 2 >= evictionQueue.count
            else { return }
            evictionQueue.removeFirst(nextEvictionIndex)
            nextEvictionIndex = 0
        }
    }
}

actor AppSelectedAssetEmbeddingCacheRuntime: AppSelectedAssetEmbeddingCaching {
    private let catalogScopeID: UUID
    private let activationCoordinator: AppModelActivationCoordinator
    private let cachesDirectory: URL
    private let modelInputCache: AppCoreMLModelInputCache
    private var activeEmbeddingCache: AppCoreMLEmbeddingCache?
    private var activeIdentity: AppCoreMLModelIdentity?

    init(
        catalogScopeID: UUID,
        activationCoordinator: AppModelActivationCoordinator,
        cachesDirectory: URL
    ) {
        self.catalogScopeID = catalogScopeID
        self.activationCoordinator = activationCoordinator
        self.cachesDirectory = cachesDirectory
        modelInputCache = AppCoreMLModelInputCache(cachesDirectory: cachesDirectory)
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
        let cache = embeddingCache(service: service)
        if let hit = try cache.cachedEmbedding(for: key) {
            return hit
        }
        let prepared: CGImage
        if case let .ready(identity) = service.availability,
           let cached = modelInputCache.cachedImage(
               for: key,
               preprocessingRevision: identity.preprocessingRevision
           )
        {
            prepared = cached
        } else {
            let data = try await imageData()
            let image = try Self.decodeSingleImage(data)
            prepared = try service.preparedModelInputImage(for: image)
            if case let .ready(identity) = service.availability {
                try? modelInputCache.publish(
                    prepared,
                    for: key,
                    preprocessingRevision: identity.preprocessingRevision
                )
            }
        }
        let result = try cache.embedding(forPreparedModelInput: prepared, key: key)
        guard result.isPersisted else {
            throw AppSelectedAssetEmbeddingCacheError.persistenceFailed
        }
        return result
    }

    func cacheSelectedAssets(
        _ requests: [AppSelectedAssetEmbeddingRequest],
        maximumConcurrentImageLoads: Int
    ) async throws -> [AppCoreMLCachedEmbedding?] {
        guard let service = await activationCoordinator.readyService(),
              case let .ready(identity) = service.availability
        else {
            throw AppSelectedAssetEmbeddingCacheError.modelUnavailable
        }
        let cache = embeddingCache(service: service)
        let concurrency = max(1, min(4, maximumConcurrentImageLoads))
        var results = Array<AppCoreMLCachedEmbedding?>(repeating: nil, count: requests.count)
        var resolved = Set<Int>()
        var preparedImages: [Int: CGImage] = [:]
        var loadTasks: [Int: Task<Data, Error>] = [:]
        var nextToSchedule = 0

        func scheduleMore() {
            while loadTasks.count + preparedImages.count < concurrency,
                  nextToSchedule < requests.count
            {
                let index = nextToSchedule
                nextToSchedule += 1
                let request = requests[index]
                guard request.contentRevision > 0 else {
                    resolved.insert(index)
                    continue
                }
                let key = AppCoreMLEmbeddingCacheKey(
                    catalogScopeID: catalogScopeID,
                    assetID: request.assetID,
                    contentRevision: Int64(request.contentRevision)
                )
                if let hit = try? cache.cachedEmbedding(for: key) {
                    results[index] = hit
                    resolved.insert(index)
                    continue
                }
                if let prepared = modelInputCache.cachedImage(
                    for: key,
                    preprocessingRevision: identity.preprocessingRevision
                ) {
                    preparedImages[index] = prepared
                    continue
                }
                loadTasks[index] = Task.detached(priority: .utility) {
                    try await request.imageData()
                }
            }
        }

        scheduleMore()
        defer { loadTasks.values.forEach { $0.cancel() } }
        for index in requests.indices {
            try Task.checkCancellation()
            if resolved.contains(index) {
                scheduleMore()
                continue
            }
            let request = requests[index]
            let key = AppCoreMLEmbeddingCacheKey(
                catalogScopeID: catalogScopeID,
                assetID: request.assetID,
                contentRevision: Int64(request.contentRevision)
            )
            do {
                let prepared: CGImage
                if let cached = preparedImages.removeValue(forKey: index) {
                    prepared = cached
                } else if let task = loadTasks.removeValue(forKey: index) {
                    let data = try await task.value
                    // Refill before inference so two source reads remain in flight
                    // while the single Core ML lane processes this candidate.
                    scheduleMore()
                    let image = try Self.decodeSingleImage(data)
                    prepared = try service.preparedModelInputImage(for: image)
                    try? modelInputCache.publish(
                        prepared,
                        for: key,
                        preprocessingRevision: identity.preprocessingRevision
                    )
                } else {
                    scheduleMore()
                    guard let task = loadTasks.removeValue(forKey: index) else {
                        resolved.insert(index)
                        continue
                    }
                    let data = try await task.value
                    scheduleMore()
                    let image = try Self.decodeSingleImage(data)
                    prepared = try service.preparedModelInputImage(for: image)
                    try? modelInputCache.publish(
                        prepared,
                        for: key,
                        preprocessingRevision: identity.preprocessingRevision
                    )
                }
                let result = try cache.embedding(forPreparedModelInput: prepared, key: key)
                if result.isPersisted {
                    results[index] = result
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                results[index] = nil
            }
            resolved.insert(index)
            scheduleMore()
        }
        return results
    }

    private func embeddingCache(service: AppCoreMLEmbeddingService) -> AppCoreMLEmbeddingCache {
        let identity: AppCoreMLModelIdentity? = if case let .ready(value) = service.availability {
            value
        } else {
            nil
        }
        if let activeEmbeddingCache, activeIdentity == identity {
            return activeEmbeddingCache
        }
        let cache = AppCoreMLEmbeddingCache(
            cachesDirectory: cachesDirectory,
            service: service
        )
        activeEmbeddingCache = cache
        activeIdentity = identity
        return cache
    }

    private static func decodeSingleImage(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw AppSelectedAssetEmbeddingCacheError.invalidImage
        }
        return image
    }
}
