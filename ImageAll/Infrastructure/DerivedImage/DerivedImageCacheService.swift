import Foundation

actor DerivedImageInFlightCoordinator {
    private var tasks: [DerivedImageCacheKey: Task<DerivedImagePayload, Error>] = [:]

    struct DerivedImageCacheKey: Hashable, Sendable {
        let assetID: UUID
        let contentRevision: Int
        let representationVersion: Int
        let variant: DerivedImageVariant
    }

    func run(
        key: DerivedImageCacheKey,
        operation: @Sendable @escaping () async throws -> DerivedImagePayload
    ) async throws -> DerivedImagePayload {
        if let existing = tasks[key] {
            return try await existing.value
        }
        let task = Task {
            try await operation()
        }
        tasks[key] = task
        defer { tasks[key] = nil }
        return try await task.value
    }
}

actor DerivedImageMaintenanceGate {
    private var running = false

    func withExclusive<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        while running {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        running = true
        defer { running = false }
        return try await body()
    }
}

final class DerivedImageCacheService: DerivedImageCachePort, @unchecked Sendable {
    private let database: CatalogDatabase
    private let repository: GRDBDerivedImageCacheRepository
    private let sourceAccess: FolderReconcileSourceAccessService
    private let sourceReader: DerivedImageSourceReader
    private let renderer: DerivedImageRenderer
    private let volumeReader: any DerivedImageVolumeCapacityReading
    private let clock: any JobClock
    private let cachesDirectory: URL
    private let store: DerivedImageCacheStore
    private let faultInjector: any DerivedImageCacheStoreFaultInjecting
    private let inFlight = DerivedImageInFlightCoordinator()
    private let maintenanceGate = DerivedImageMaintenanceGate()

    init(
        database: CatalogDatabase,
        cachesDirectory: URL,
        sourceAccess: FolderReconcileSourceAccessService,
        sourceReader: DerivedImageSourceReader = DerivedImageSourceReader(),
        renderer: DerivedImageRenderer = DerivedImageRenderer(),
        volumeReader: any DerivedImageVolumeCapacityReading = FoundationDerivedImageVolumeCapacityReader(),
        clock: any JobClock = SystemJobClock(),
        faultInjector: any DerivedImageCacheStoreFaultInjecting = NoDerivedImageCacheStoreFaultInjector()
    ) {
        self.database = database
        self.repository = GRDBDerivedImageCacheRepository(database: database)
        self.sourceAccess = sourceAccess
        self.sourceReader = sourceReader
        self.renderer = renderer
        self.volumeReader = volumeReader
        self.clock = clock
        self.cachesDirectory = cachesDirectory
        self.faultInjector = faultInjector
        let versionRoot = DerivedImageCachePathLayout.versionRoot(under: cachesDirectory)
        self.store = DerivedImageCacheStore(versionRoot: versionRoot, faultInjector: faultInjector)
    }

    func loadOrGenerate(_ request: DerivedImageRequest) async throws -> DerivedImagePayload {
        if try repository.assetExists(assetID: request.assetID) == false {
            throw DerivedImageError.derivedAssetNotFound
        }
        guard let context = try repository.fetchGenerationContext(assetID: request.assetID) else {
            throw DerivedImageError.derivedAssetIneligible
        }
        guard context.isEligibleForGeneration else {
            throw DerivedImageError.derivedAssetIneligible
        }

        let key = DerivedImageInFlightCoordinator.DerivedImageCacheKey(
            assetID: request.assetID,
            contentRevision: context.contentRevision,
            representationVersion: DerivedImageRepresentationVersion.production,
            variant: request.variant
        )

        return try await inFlight.run(key: key) { [self] in
            try await self.loadOrGenerateInternal(request: request, context: context)
        }
    }

    func performMaintenance() async throws -> DerivedImageMaintenanceResult {
        try await maintenanceGate.withExclusive {
            try self.performMaintenanceInternal()
        }
    }

    private func loadOrGenerateInternal(
        request: DerivedImageRequest,
        context: DerivedImageAssetGenerationContext
    ) async throws -> DerivedImagePayload {
        try store.ensureLayout()

        if let entry = try repository.fetchEntry(
            assetID: context.assetID,
            contentRevision: context.contentRevision,
            representationVersion: DerivedImageRepresentationVersion.production,
            variant: request.variant
        ), let payload = try validateHit(entry: entry, context: context) {
            return payload
        }

        return try await generateFresh(request: request, context: context)
    }

    private func validateHit(
        entry: DerivedImageCacheEntryRow,
        context: DerivedImageAssetGenerationContext
    ) throws -> DerivedImagePayload? {
        guard let bytes = try store.readObjectBytes(entry: entry) else {
            try repository.deleteEntry(id: entry.id)
            store.removeInvalidEntryArtifacts(entry: entry)
            return nil
        }
        guard try renderer.validateStoredBytes(bytes, entry: entry) else {
            try repository.deleteEntry(id: entry.id)
            store.removeInvalidEntryArtifacts(entry: entry)
            return nil
        }
        let nowMs = clock.nowMs
        try repository.touchEntry(id: entry.id, accessedAtMs: nowMs)
        return DerivedImagePayload(
            entryID: entry.id,
            assetID: entry.assetID,
            contentRevision: entry.contentRevision,
            representationVersion: entry.representationVersion,
            variant: entry.variant,
            storageFormat: entry.storageFormat,
            pixelWidth: entry.pixelWidth,
            pixelHeight: entry.pixelHeight,
            encodedBytes: bytes,
            origin: .cacheHit
        )
    }

    private func generateFresh(
        request: DerivedImageRequest,
        context: DerivedImageAssetGenerationContext
    ) async throws -> DerivedImagePayload {
        let incomingBytes: UInt64
        let artifact: DerivedImageEncodedArtifact
        let entryID = UUID()

        let generated: DerivedImageEncodedArtifact
        do {
            generated = try sourceAccess.withActiveSourceRootURL(sourceID: context.sourceID) { rootURL in
                let initial = try self.sourceReader.readSourceBytes(rootURL: rootURL, relativePath: context.relativePath)
                guard context.matches(initial.fingerprint) else {
                    throw DerivedImageError.derivedSourceChanged
                }
                let rendered = try self.renderer.render(sourceBytes: initial.bytes, variant: request.variant)
                let postOpen = try self.sourceReader.openedFingerprint(rootURL: rootURL, relativePath: context.relativePath)
                guard context.matches(postOpen) else {
                    throw DerivedImageError.derivedSourceChanged
                }
                return rendered
            }
        } catch let error as FolderReconcileHandlerError {
            switch error {
            case .authorizationRequired:
                throw DerivedImageError.derivedAuthorizationRequired
            case .sourceUnavailable, .enumerationIncomplete:
                throw DerivedImageError.derivedSourceUnavailable
            }
        } catch let error as DerivedImageError {
            throw error
        }

        artifact = generated
        guard artifact.byteSize > 0 else {
            throw DerivedImageError.derivedEncodeFailed
        }
        guard let incoming = UInt64(exactly: artifact.byteSize) else {
            throw DerivedImageError.derivedInsufficientSpace
        }
        incomingBytes = incoming

        if incomingBytes > DerivedImageQuotaPolicy.publishedQuotaBytes {
            throw DerivedImageError.derivedInsufficientSpace
        }

        try await evictIfNeeded(incomingBytes: incomingBytes)

        if faultInjector.shouldFault(at: .dbPublish) {
            throw DerivedImageError.derivedCachePersistenceFailed
        }

        _ = try store.publish(
            artifact: artifact,
            entryID: entryID,
            format: artifact.storageFormat
        )

        let nowMs = clock.nowMs
        let entry = DerivedImageCacheEntryRow(
            id: entryID,
            assetID: context.assetID,
            contentRevision: context.contentRevision,
            representationVersion: DerivedImageRepresentationVersion.production,
            variant: request.variant,
            storageFormat: artifact.storageFormat,
            pixelWidth: artifact.pixelWidth,
            pixelHeight: artifact.pixelHeight,
            byteSize: artifact.byteSize,
            encodedSHA256: artifact.sha256,
            createdAtMs: nowMs,
            lastAccessedAtMs: nowMs
        )

        let outcome = try repository.publishEntryReplacingKey(entry: entry, expected: context)
        switch outcome {
        case .sourceChanged:
            store.deleteObject(entryID: entryID, format: artifact.storageFormat)
            throw DerivedImageError.derivedSourceChanged
        case let .lostRaceToExisting(winner):
            store.deleteObject(entryID: entryID, format: artifact.storageFormat)
            guard let payload = try validateHit(entry: winner, context: context) else {
                throw DerivedImageError.derivedCachePersistenceFailed
            }
            return payload
        case let .published(replacedEntry):
            if let replacedEntry {
                if !faultInjector.shouldFault(at: .oldObjectDelete) {
                    store.deleteObject(entryID: replacedEntry.id, format: replacedEntry.storageFormat)
                }
            }
            return DerivedImagePayload(
                entryID: entry.id,
                assetID: entry.assetID,
                contentRevision: entry.contentRevision,
                representationVersion: entry.representationVersion,
                variant: entry.variant,
                storageFormat: entry.storageFormat,
                pixelWidth: entry.pixelWidth,
                pixelHeight: entry.pixelHeight,
                encodedBytes: artifact.bytes,
                origin: .generated
            )
        }
    }

    private func evictIfNeeded(incomingBytes: UInt64) async throws {
        guard let facts = try volumeReader.volumeFacts(at: store.versionRoot) else {
            throw DerivedImageError.derivedCapacityUnavailable
        }
        guard let reserve = DerivedImageQuotaPolicy.reserveBytes(totalVolumeBytes: facts.totalBytes) else {
            throw DerivedImageError.derivedCapacityUnavailable
        }

        var published = try repository.publishedByteTotal()
        var available = facts.availableBytes

        while true {
            let needsQuotaEviction: Bool
            if let combined = DerivedImageQuotaPolicy.adding(published, incomingBytes) {
                needsQuotaEviction = combined > DerivedImageQuotaPolicy.publishedQuotaBytes
            } else {
                throw DerivedImageError.derivedCapacityUnavailable
            }

            let needsReserveEviction: Bool
            if let required = DerivedImageQuotaPolicy.adding(reserve, incomingBytes) {
                needsReserveEviction = available < required
            } else {
                throw DerivedImageError.derivedCapacityUnavailable
            }

            if !needsQuotaEviction && !needsReserveEviction {
                return
            }

            let candidates = try repository.lruEntries()
            guard let victim = candidates.first else {
                throw DerivedImageError.derivedInsufficientSpace
            }

            try repository.deleteEntry(id: victim.id)
            store.deleteObject(entryID: victim.id, format: victim.storageFormat)
            if let victimBytes = UInt64(exactly: victim.byteSize),
               let reduced = DerivedImageQuotaPolicy.subtracting(published, victimBytes)
            {
                published = reduced
            }

            guard let refreshed = try volumeReader.volumeFacts(at: store.versionRoot) else {
                throw DerivedImageError.derivedCapacityUnavailable
            }
            available = refreshed.availableBytes
        }
    }

    private func performMaintenanceInternal() throws -> DerivedImageMaintenanceResult {
        try store.ensureLayout()
        var removedEntries = 0
        var removedObjects = 0
        var removedBytes: UInt64 = 0
        var unsafeObjects = 0

        let entries = try repository.allEntries()
        let referenced = store.listReferencedObjectPaths(entries: entries)

        for entry in entries {
            guard let bytes = try store.readObjectBytes(entry: entry),
                  try renderer.validateStoredBytes(bytes, entry: entry)
            else {
                try repository.deleteEntry(id: entry.id)
                store.removeInvalidEntryArtifacts(entry: entry)
                removedEntries += 1
                continue
            }
            _ = bytes
        }

        let objectsRoot = DerivedImageCachePathLayout.objectsDirectory(under: store.versionRoot)
        let stagingRoot = DerivedImageCachePathLayout.stagingDirectory(under: store.versionRoot)
        removedObjects += try sweepUnreferenced(directory: objectsRoot, referenced: referenced, removedBytes: &removedBytes, unsafeObjects: &unsafeObjects)
        removedObjects += try sweepStaging(stagingRoot: stagingRoot, removedBytes: &removedBytes, unsafeObjects: &unsafeObjects)
        return DerivedImageMaintenanceResult(
            removedEntries: removedEntries,
            removedObjects: removedObjects,
            removedBytes: removedBytes,
            unsafeObjects: unsafeObjects
        )
    }

    private func sweepUnreferenced(
        directory: URL,
        referenced: Set<String>,
        removedBytes: inout UInt64,
        unsafeObjects: inout Int
    ) throws -> Int {
        var removedCount = 0
        guard let shardEnumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        let versionRootPath = store.versionRoot.path
        for case let url as URL in shardEnumerator {
            if DerivedImageSecureIO.isSymlink(at: url) {
                unsafeObjects += 1
                continue
            }
            let rel = String(url.path.dropFirst(versionRootPath.count + 1))
            guard rel.hasPrefix("\(DerivedImageCachePathLayout.objectsComponent)/") else {
                unsafeObjects += 1
                continue
            }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
                continue
            }
            if referenced.contains(rel) {
                continue
            }
            if let size = DerivedImageSecureIO.fileSize(at: url) {
                removedBytes &+= UInt64(size)
            }
            DerivedImageSecureIO.removeIfPresent(at: url)
            removedCount += 1
        }
        return removedCount
    }

    private func sweepStaging(
        stagingRoot: URL,
        removedBytes: inout UInt64,
        unsafeObjects: inout Int
    ) throws -> Int {
        var removedCount = 0
        guard let enumerator = FileManager.default.enumerator(at: stagingRoot, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return 0
        }
        for case let url as URL in enumerator {
            if DerivedImageSecureIO.isSymlink(at: url) {
                unsafeObjects += 1
                continue
            }
            guard DerivedImageSecureIO.isRegularFile(at: url) else { continue }
            if let size = DerivedImageSecureIO.fileSize(at: url) {
                removedBytes &+= UInt64(size)
            }
            DerivedImageSecureIO.removeIfPresent(at: url)
            removedCount += 1
        }
        return removedCount
    }
}
