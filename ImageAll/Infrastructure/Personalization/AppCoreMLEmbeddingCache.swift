import CoreGraphics
import CryptoKit
import Darwin
import Foundation

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
    private let cachesDirectory: URL
    private let service: AppCoreMLEmbeddingService
    private let lock = NSLock()

    init(cachesDirectory: URL, service: AppCoreMLEmbeddingService) {
        self.cachesDirectory = cachesDirectory
        self.service = service
    }

    func embedding(
        for image: CGImage,
        key: AppCoreMLEmbeddingCacheKey
    ) throws -> AppCoreMLCachedEmbedding {
        try lock.withLock {
            try embeddingLocked(for: image, key: key)
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
        if key.contentRevision >= 0,
           let cached = try? read(address: address, identity: identity)
        {
            return cached
        }

        let generated = try service.embedding(for: image)
        let vectorData = Self.vectorData(generated.values)
        let vectorSHA256 = Self.sha256(vectorData)
        let result = AppCoreMLCachedEmbedding(
            identity: generated.identity,
            values: generated.values,
            vectorSHA256: vectorSHA256,
            origin: .generated
        )
        guard key.contentRevision >= 0 else { return result }
        try? publish(
            Record(
                schemaRevision: 1,
                address: address,
                vectorData: vectorData,
                vectorSHA256: vectorSHA256
            ),
            address: address
        )
        return result
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
        guard record.schemaRevision == 1,
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

    private func publish(_ record: Record, address: CacheAddress) throws {
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
