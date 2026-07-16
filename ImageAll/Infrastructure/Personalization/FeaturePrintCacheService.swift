import CryptoKit
import Darwin
import Foundation
import GRDB
import ImageIO
import Vision

private struct FeaturePrintArtifact: Sendable {
    let vectorData: Data
    let elementCount: Int
    let sha256: Data
}

private struct VisionFeaturePrintGenerator: Sendable {
    func generate(sourceBytes: Data, expectedMediaType: String?) throws -> FeaturePrintArtifact {
        guard let source = CGImageSourceCreateWithData(sourceBytes as CFData, nil),
              CGImageSourceGetCount(source) == 1
        else {
            throw FeaturePrintError.decodeFailed
        }
        if let expectedMediaType,
           CGImageSourceGetType(source) as String? != expectedMediaType
        {
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

private struct PhotosFeaturePrintGenerationContext: Equatable, Sendable {
    let assetID: UUID
    let sourceID: UUID
    let contentRevision: Int
    let localIdentifier: String
    let mediaType: String
    let availability: String
    let locatorState: String
    let locatorKind: String
    let sourceState: String
    let sourceKind: String
    let recordUpdatedAtMs: Int64

    var isEligibleForGeneration: Bool {
        locatorKind == AssetLocatorKind.photos.rawValue
            && locatorState == AssetLocatorState.current.rawValue
            && availability == AssetAvailability.available.rawValue
            && sourceKind == SourceKind.photos.rawValue
            && sourceState == SourceState.active.rawValue
            && !localIdentifier.isEmpty
    }
}

struct LibraryFeaturePrintInputLoader: FeaturePrintInputLoading, Sendable {
    let database: CatalogDatabase
    let sourceAccess: FolderReconcileSourceAccessService
    let photosImages: (any PhotosFeaturePrintImagePort)?
    let downloadedPreviews: (any DownloadedPreviewCachePort)?
    let sourceReader: DerivedImageSourceReader

    private var assetRepository: GRDBDerivedImageCacheRepository {
        GRDBDerivedImageCacheRepository(database: database)
    }

    init(
        database: CatalogDatabase,
        sourceAccess: FolderReconcileSourceAccessService,
        photosImages: (any PhotosFeaturePrintImagePort)? = nil,
        downloadedPreviews: (any DownloadedPreviewCachePort)? = nil,
        sourceReader: DerivedImageSourceReader = DerivedImageSourceReader()
    ) {
        self.database = database
        self.sourceAccess = sourceAccess
        self.photosImages = photosImages
        self.downloadedPreviews = downloadedPreviews
        self.sourceReader = sourceReader
    }

    func resolveIdentity(assetID: UUID) throws -> FeatureIdentity {
        switch try sourceKinds(assetID: assetID) {
        case nil:
            throw FeaturePrintError.assetNotFound
        case let .some((locatorKind, sourceKind))
            where locatorKind == AssetLocatorKind.file.rawValue
                && sourceKind == SourceKind.folder.rawValue:
            guard let context = try assetRepository.fetchGenerationContext(assetID: assetID),
                  context.isEligibleForGeneration
            else {
                throw FeaturePrintError.assetIneligible
            }
            return FeatureIdentity(assetID: assetID, contentRevision: context.contentRevision)
        case let .some((locatorKind, sourceKind))
            where locatorKind == AssetLocatorKind.photos.rawValue
                && sourceKind == SourceKind.photos.rawValue:
            guard photosImages != nil,
                  let context = try fetchPhotosContext(assetID: assetID),
                  context.isEligibleForGeneration
            else {
                throw FeaturePrintError.assetIneligible
            }
            return FeatureIdentity(assetID: assetID, contentRevision: context.contentRevision)
        default:
            throw FeaturePrintError.assetIneligible
        }
    }

    func loadInput(assetID: UUID, expectedIdentity: FeatureIdentity) throws -> FeaturePrintInput {
        switch try sourceKinds(assetID: assetID) {
        case let .some((locatorKind, sourceKind))
            where locatorKind == AssetLocatorKind.file.rawValue
                && sourceKind == SourceKind.folder.rawValue:
            return try loadFolderInput(assetID: assetID, expectedIdentity: expectedIdentity)
        case let .some((locatorKind, sourceKind))
            where locatorKind == AssetLocatorKind.photos.rawValue
                && sourceKind == SourceKind.photos.rawValue:
            return try loadPhotosInput(assetID: assetID, expectedIdentity: expectedIdentity)
        case nil:
            throw FeaturePrintError.assetNotFound
        default:
            throw FeaturePrintError.assetIneligible
        }
    }

    func isCurrent(_ input: FeaturePrintInput) throws -> Bool {
        guard let currentToken = try validationToken(
            assetID: input.identity.assetID,
            expectedIdentity: input.identity
        ) else {
            return false
        }
        return currentToken == input.validationToken
    }

    private func loadFolderInput(
        assetID: UUID,
        expectedIdentity: FeatureIdentity
    ) throws -> FeaturePrintInput {
        guard let context = try assetRepository.fetchGenerationContext(assetID: assetID),
              context.isEligibleForGeneration,
              FeatureIdentity(assetID: assetID, contentRevision: context.contentRevision) == expectedIdentity
        else {
            throw FeaturePrintError.sourceChanged
        }
        let bytes = try sourceAccess.withActiveSourceRootURL(sourceID: context.sourceID) { rootURL in
            let initial = try sourceReader.readSourceBytes(rootURL: rootURL, relativePath: context.relativePath)
            guard context.matchesHandleFacts(initial.initialFingerprint),
                  initial.preHandleFstat.sizeBytes == initial.postHandleFstat.sizeBytes,
                  initial.preHandleFstat.modifiedAtNs == initial.postHandleFstat.modifiedAtNs,
                  initial.initialFingerprint.resourceID == initial.postResourceID
            else {
                throw FeaturePrintError.sourceChanged
            }
            return initial.bytes
        }
        return FeaturePrintInput(
            identity: expectedIdentity,
            sourceBytes: bytes,
            expectedMediaType: context.mediaType,
            validationToken: fileValidationToken(context)
        )
    }

    private func loadPhotosInput(
        assetID: UUID,
        expectedIdentity: FeatureIdentity
    ) throws -> FeaturePrintInput {
        guard let photosImages,
              let context = try fetchPhotosContext(assetID: assetID),
              context.isEligibleForGeneration,
              FeatureIdentity(assetID: assetID, contentRevision: context.contentRevision) == expectedIdentity
        else {
            throw FeaturePrintError.sourceChanged
        }
        let bytes: Data
        do {
            if let downloaded = try downloadedPreviews?.loadDownloadedPreview(assetID: assetID) {
                bytes = downloaded
            } else {
                bytes = try photosImages.requestLocalFeatureImage(localIdentifier: context.localIdentifier)
            }
        } catch let error as PhotosLibraryError {
            switch error {
            case .authorizationDenied, .authorizationRestricted:
                throw FeaturePrintError.authorizationRequired
            case .libraryUnavailable, .cloudOnly, .changeTokenInvalid, .persistenceFailure:
                throw FeaturePrintError.sourceUnavailable
            }
        } catch {
            throw FeaturePrintError.sourceUnavailable
        }
        guard try fetchPhotosContext(assetID: assetID) == context else {
            throw FeaturePrintError.sourceChanged
        }
        return FeaturePrintInput(
            identity: expectedIdentity,
            sourceBytes: bytes,
            expectedMediaType: nil,
            validationToken: photosValidationToken(context)
        )
    }

    private func validationToken(
        assetID: UUID,
        expectedIdentity: FeatureIdentity
    ) throws -> Data? {
        switch try sourceKinds(assetID: assetID) {
        case let .some((locatorKind, sourceKind))
            where locatorKind == AssetLocatorKind.file.rawValue
                && sourceKind == SourceKind.folder.rawValue:
            guard let context = try assetRepository.fetchGenerationContext(assetID: assetID),
                  context.isEligibleForGeneration,
                  FeatureIdentity(assetID: assetID, contentRevision: context.contentRevision) == expectedIdentity
            else { return nil }
            let sourceMatches = try sourceAccess.withActiveSourceRootURL(sourceID: context.sourceID) { rootURL in
                let reopened = try sourceReader.reopenedLocatorFingerprint(
                    rootURL: rootURL,
                    relativePath: context.relativePath
                )
                return context.matches(reopened)
            }
            guard sourceMatches else { return nil }
            return fileValidationToken(context)
        case let .some((locatorKind, sourceKind))
            where locatorKind == AssetLocatorKind.photos.rawValue
                && sourceKind == SourceKind.photos.rawValue:
            guard let context = try fetchPhotosContext(assetID: assetID),
                  context.isEligibleForGeneration,
                  FeatureIdentity(assetID: assetID, contentRevision: context.contentRevision) == expectedIdentity
            else { return nil }
            return photosValidationToken(context)
        default:
            return nil
        }
    }

    private func sourceKinds(assetID: UUID) throws -> (locatorKind: String, sourceKind: String)? {
        try database.pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT a.locator_kind, s.kind AS source_kind
                FROM asset a
                JOIN source s ON s.id = a.source_id
                WHERE a.id = ?
                """,
                arguments: [assetID.uuidString.lowercased()]
            ) else { return nil }
            return (row["locator_kind"], row["source_kind"])
        }
    }

    private func fetchPhotosContext(assetID: UUID) throws -> PhotosFeaturePrintGenerationContext? {
        try database.pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT a.id, a.source_id, a.content_revision, a.photos_local_identifier,
                    a.media_type, a.availability, a.locator_state, a.locator_kind,
                    a.record_updated_at_ms, s.state AS source_state, s.kind AS source_kind
                FROM asset a
                JOIN source s ON s.id = a.source_id
                WHERE a.id = ?
                """,
                arguments: [assetID.uuidString.lowercased()]
            ),
                let mappedAssetID = UUID(uuidString: row["id"]),
                let sourceID = UUID(uuidString: row["source_id"]),
                let localIdentifier: String = row["photos_local_identifier"]
            else { return nil }
            return PhotosFeaturePrintGenerationContext(
                assetID: mappedAssetID,
                sourceID: sourceID,
                contentRevision: row["content_revision"],
                localIdentifier: localIdentifier,
                mediaType: row["media_type"],
                availability: row["availability"],
                locatorState: row["locator_state"],
                locatorKind: row["locator_kind"],
                sourceState: row["source_state"],
                sourceKind: row["source_kind"],
                recordUpdatedAtMs: row["record_updated_at_ms"]
            )
        }
    }

    private func fileValidationToken(_ context: DerivedImageAssetGenerationContext) -> Data {
        validationToken(fields: [
            context.assetID.uuidString.lowercased(), context.sourceID.uuidString.lowercased(),
            String(context.contentRevision), context.relativePath, context.mediaType,
            context.availability, context.locatorState, context.locatorKind,
            context.sourceState, context.sourceKind, String(context.fingerprintSizeBytes),
            String(context.fingerprintModifiedAtNs), context.fingerprintResourceID?.base64EncodedString() ?? "",
        ])
    }

    private func photosValidationToken(_ context: PhotosFeaturePrintGenerationContext) -> Data {
        validationToken(fields: [
            context.assetID.uuidString.lowercased(), context.sourceID.uuidString.lowercased(),
            String(context.contentRevision), context.localIdentifier, context.mediaType,
            context.availability, context.locatorState, context.locatorKind,
            context.sourceState, context.sourceKind, String(context.recordUpdatedAtMs),
        ])
    }

    private func validationToken(fields: [String]) -> Data {
        var canonical = Data()
        for field in fields {
            let bytes = Data(field.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { canonical.append(contentsOf: $0) }
            canonical.append(bytes)
        }
        return Data(SHA256.hash(data: canonical))
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

final class FeaturePrintCacheService: FeatureVectorLoading, SyncFeatureVectorLoading, @unchecked Sendable {
    private let repository: GRDBPersonalizationRepository
    private let inputLoader: any FeaturePrintInputLoading
    private let generator = VisionFeaturePrintGenerator()
    private let store: FeaturePrintCacheStore
    private let clock: any JobClock

    init(
        database: CatalogDatabase,
        cachesDirectory: URL,
        inputLoader: any FeaturePrintInputLoading,
        clock: any JobClock = SystemJobClock()
    ) {
        repository = GRDBPersonalizationRepository(database: database)
        self.inputLoader = inputLoader
        store = FeaturePrintCacheStore(cachesDirectory: cachesDirectory)
        self.clock = clock
    }

    convenience init(
        database: CatalogDatabase,
        cachesDirectory: URL,
        sourceAccess: FolderReconcileSourceAccessService,
        photosImages: (any PhotosFeaturePrintImagePort)? = nil,
        downloadedPreviews: (any DownloadedPreviewCachePort)? = nil,
        sourceReader: DerivedImageSourceReader = DerivedImageSourceReader(),
        clock: any JobClock = SystemJobClock()
    ) {
        self.init(
            database: database,
            cachesDirectory: cachesDirectory,
            inputLoader: LibraryFeaturePrintInputLoader(
                database: database,
                sourceAccess: sourceAccess,
                photosImages: photosImages,
                downloadedPreviews: downloadedPreviews,
                sourceReader: sourceReader
            ),
            clock: clock
        )
    }

    func loadOrGenerate(assetID: UUID) async throws -> FeatureVectorPayload {
        try loadOrGenerateSync(assetID: assetID)
    }

    func loadOrGenerateSync(assetID: UUID) throws -> FeatureVectorPayload {
        try loadOrGenerateSyncThrowing(assetID: assetID)
    }

    private func loadOrGenerateSyncThrowing(assetID: UUID) throws -> FeatureVectorPayload {
        do {
            let identity = try inputLoader.resolveIdentity(assetID: assetID)
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

            let input = try inputLoader.loadInput(assetID: assetID, expectedIdentity: identity)
            let artifact = try generator.generate(
                sourceBytes: input.sourceBytes,
                expectedMediaType: input.expectedMediaType
            )
            guard try inputLoader.isCurrent(input) else {
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

}
