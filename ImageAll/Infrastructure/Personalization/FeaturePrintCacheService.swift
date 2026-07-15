import CryptoKit
import Darwin
import Foundation
import ImageIO
import Vision

private struct FeaturePrintArtifact: Sendable {
    let vectorData: Data
    let elementCount: Int
    let sha256: Data
}

private struct VisionFeaturePrintGenerator: Sendable {
    func generate(sourceBytes: Data, expectedMediaType: String) throws -> FeaturePrintArtifact {
        guard let source = CGImageSourceCreateWithData(sourceBytes as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetType(source) as String? == expectedMediaType
        else {
            throw FeaturePrintError.decodeFailed
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1_024,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw FeaturePrintError.decodeFailed
        }

        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = PersonalizationConstants.requestRevision
        request.imageCropAndScaleOption = .scaleFill
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            throw FeaturePrintError.generationFailed
        }
        guard let observation = request.results?.first as? VNFeaturePrintObservation,
              observation.elementType == .float,
              observation.elementCount > 0,
              observation.data.count == observation.elementCount * MemoryLayout<Float>.size
        else {
            throw FeaturePrintError.generationFailed
        }
        return FeaturePrintArtifact(
            vectorData: observation.data,
            elementCount: observation.elementCount,
            sha256: Data(SHA256.hash(data: observation.data))
        )
    }
}

private enum FeaturePrintCachePathLayout {
    static let rootComponent = "Features"
    static let versionComponent = "v1"
    static let objectsComponent = "objects"

    static func versionRoot(under cachesDirectory: URL) -> URL {
        cachesDirectory
            .appendingPathComponent(rootComponent, isDirectory: true)
            .appendingPathComponent(versionComponent, isDirectory: true)
    }

    static func cacheKey(identity: FeatureIdentity) -> String {
        let canonical = identity.assetID.uuidString.lowercased()
        let shard = String(canonical.replacingOccurrences(of: "-", with: "").prefix(2))
        return "\(objectsComponent)/\(shard)/\(canonical)-c\(identity.contentRevision).fprint"
    }
}

private struct FeaturePrintCacheStore: Sendable {
    let cachesDirectory: URL

    func read(registration: FeatureRegistration) throws -> Data? {
        let url = try objectURL(cacheKey: registration.cacheKey)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard DerivedImageSecureIO.isRegularFile(at: url) else {
            throw FeaturePrintError.cacheUnsafePath
        }
        do {
            let fd = try DerivedImageSecureIO.openReadOnlyNoFollow(at: url)
            defer { Darwin.close(fd) }
            let stats = try DerivedImageSecureIO.fstatRegularFile(fd: fd)
            guard stats.sizeBytes == registration.byteCount else { return nil }
            let data = try DerivedImageSecureIO.readAllBytes(from: fd)
            guard data.count == registration.byteCount,
                  Data(SHA256.hash(data: data)) == registration.vectorSHA256
            else { return nil }
            return data
        } catch DerivedImageSecureIOError.unsafePath {
            throw FeaturePrintError.cacheUnsafePath
        } catch {
            throw FeaturePrintError.cachePersistenceFailed
        }
    }

    func publish(_ data: Data, cacheKey: String) throws {
        let destination = try objectURL(cacheKey: cacheKey)
        let versionRoot = FeaturePrintCachePathLayout.versionRoot(under: cachesDirectory)
        let objects = versionRoot.appendingPathComponent(FeaturePrintCachePathLayout.objectsComponent, isDirectory: true)
        let shard = destination.deletingLastPathComponent()
        do {
            try ensureTrustedDirectory(cachesDirectory)
            try ensureTrustedDirectory(versionRoot.deletingLastPathComponent())
            try ensureTrustedDirectory(versionRoot)
            try ensureTrustedDirectory(objects)
            try ensureTrustedDirectory(shard)
            if FileManager.default.fileExists(atPath: destination.path),
               !DerivedImageSecureIO.isRegularFile(at: destination)
            {
                throw FeaturePrintError.cacheUnsafePath
            }
            try data.write(to: destination, options: .atomic)
            guard DerivedImageSecureIO.isRegularFile(at: destination) else {
                throw FeaturePrintError.cacheUnsafePath
            }
        } catch let error as FeaturePrintError {
            throw error
        } catch {
            throw FeaturePrintError.cachePersistenceFailed
        }
    }

    private func objectURL(cacheKey: String) throws -> URL {
        guard case let .success(validated) = RelativePathRules.validate(cacheKey),
              validated == cacheKey,
              cacheKey.hasPrefix("objects/"),
              cacheKey.hasSuffix(".fprint")
        else {
            throw FeaturePrintError.cacheUnsafePath
        }
        let components = cacheKey.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 3,
              components[1].count == 2,
              components[1].allSatisfy({ "0123456789abcdef".contains($0) })
        else {
            throw FeaturePrintError.cacheUnsafePath
        }
        return FeaturePrintCachePathLayout.versionRoot(under: cachesDirectory)
            .appendingPathComponent(cacheKey)
    }

    private func ensureTrustedDirectory(_ url: URL) throws {
        try DerivedImageSecureIO.ensureDirectory(at: url)
        guard !DerivedImageSecureIO.isSymlink(at: url) else {
            throw FeaturePrintError.cacheUnsafePath
        }
    }
}

final class FeaturePrintCacheService: FeatureVectorLoading, @unchecked Sendable {
    private let database: CatalogDatabase
    private let repository: GRDBPersonalizationRepository
    private let assetRepository: GRDBDerivedImageCacheRepository
    private let sourceAccess: FolderReconcileSourceAccessService
    private let sourceReader: DerivedImageSourceReader
    private let generator = VisionFeaturePrintGenerator()
    private let store: FeaturePrintCacheStore
    private let clock: any JobClock

    init(
        database: CatalogDatabase,
        cachesDirectory: URL,
        sourceAccess: FolderReconcileSourceAccessService,
        sourceReader: DerivedImageSourceReader = DerivedImageSourceReader(),
        clock: any JobClock = SystemJobClock()
    ) {
        self.database = database
        repository = GRDBPersonalizationRepository(database: database)
        assetRepository = GRDBDerivedImageCacheRepository(database: database)
        self.sourceAccess = sourceAccess
        self.sourceReader = sourceReader
        store = FeaturePrintCacheStore(cachesDirectory: cachesDirectory)
        self.clock = clock
    }

    func loadOrGenerate(assetID: UUID) async throws -> FeatureVectorPayload {
        do {
            guard let context = try assetRepository.fetchGenerationContext(assetID: assetID) else {
                throw FeaturePrintError.assetNotFound
            }
            guard context.isEligibleForGeneration else {
                throw FeaturePrintError.assetIneligible
            }
            let identity = FeatureIdentity(assetID: assetID, contentRevision: context.contentRevision)
            if let registration = try repository.featureRegistration(identity: identity),
               let vectorData = try store.read(registration: registration)
            {
                return FeatureVectorPayload(
                    identity: identity,
                    elementCount: registration.elementCount,
                    vectorData: vectorData,
                    vectorSHA256: registration.vectorSHA256,
                    origin: .cacheHit
                )
            }

            let artifact = try generate(context: context)
            let isStillCurrent = try await database.pool.read { db in
                try assetRepository.revalidate(db: db, expected: context)
            }
            guard isStillCurrent else {
                throw FeaturePrintError.sourceChanged
            }
            let cacheKey = FeaturePrintCachePathLayout.cacheKey(identity: identity)
            try store.publish(artifact.vectorData, cacheKey: cacheKey)
            let registration = FeatureRegistration(
                identity: identity,
                elementCount: artifact.elementCount,
                byteCount: artifact.vectorData.count,
                vectorSHA256: artifact.sha256,
                cacheKey: cacheKey,
                createdAtMs: clock.nowMs
            )
            try repository.registerFeature(registration)
            return FeatureVectorPayload(
                identity: identity,
                elementCount: artifact.elementCount,
                vectorData: artifact.vectorData,
                vectorSHA256: artifact.sha256,
                origin: .generated
            )
        } catch let error as FeaturePrintError {
            throw error
        } catch let error as FolderReconcileHandlerError {
            switch error {
            case .authorizationRequired:
                throw FeaturePrintError.authorizationRequired
            case .sourceUnavailable, .enumerationIncomplete:
                throw FeaturePrintError.sourceUnavailable
            }
        } catch DerivedImageSecureIOError.unsafePath {
            throw FeaturePrintError.sourceChanged
        } catch {
            throw FeaturePrintError.cachePersistenceFailed
        }
    }

    private func generate(context: DerivedImageAssetGenerationContext) throws -> FeaturePrintArtifact {
        try sourceAccess.withActiveSourceRootURL(sourceID: context.sourceID) { rootURL in
            let initial = try sourceReader.readSourceBytes(rootURL: rootURL, relativePath: context.relativePath)
            guard context.matchesHandleFacts(initial.initialFingerprint),
                  initial.preHandleFstat.sizeBytes == initial.postHandleFstat.sizeBytes,
                  initial.preHandleFstat.modifiedAtNs == initial.postHandleFstat.modifiedAtNs,
                  initial.initialFingerprint.resourceID == initial.postResourceID
            else {
                throw FeaturePrintError.sourceChanged
            }
            let artifact = try generator.generate(
                sourceBytes: initial.bytes,
                expectedMediaType: context.mediaType
            )
            let reopened = try sourceReader.reopenedLocatorFingerprint(
                rootURL: rootURL,
                relativePath: context.relativePath
            )
            guard context.matches(reopened) else {
                throw FeaturePrintError.sourceChanged
            }
            return artifact
        }
    }
}
