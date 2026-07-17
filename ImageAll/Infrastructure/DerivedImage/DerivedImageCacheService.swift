import Foundation
import ImageIO
import os

actor DerivedImageInFlightCoordinator {
    private var tasks: [DerivedImageCacheKey: Task<DerivedImagePayload, Error>] = [:]

    struct DerivedImageCacheKey: Hashable, Sendable {
        let assetID: UUID
        let contentRevision: Int
        let representationVersion: Int
        let variant: DerivedImageVariant
        let persistence: DerivedImagePersistence
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

final class DerivedImageOperationGate: @unchecked Sendable {
    private struct GateState {
        var maintenanceRunning = false
        var activeGenerations = 0
        var protectedStagingNames: Set<String> = []
    }

    private let state = OSAllocatedUnfairLock(initialState: GateState())

    func beginGeneration(stagingName: String) {
        while true {
            let blocked = state.withLock { gate -> Bool in
                if gate.maintenanceRunning {
                    return true
                }
                gate.activeGenerations += 1
                gate.protectedStagingNames.insert(stagingName)
                return false
            }
            if !blocked {
                return
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
    }

    func beginAccess() {
        while true {
            let blocked = state.withLock { gate -> Bool in
                if gate.maintenanceRunning {
                    return true
                }
                gate.activeGenerations += 1
                return false
            }
            if !blocked { return }
            Thread.sleep(forTimeInterval: 0.001)
        }
    }

    func endAccess() {
        state.withLock { gate in
            gate.activeGenerations = max(0, gate.activeGenerations - 1)
        }
    }

    func endGeneration(stagingName: String) {
        state.withLock { gate in
            gate.protectedStagingNames.remove(stagingName)
            gate.activeGenerations = max(0, gate.activeGenerations - 1)
        }
    }

    func protectedStagingSnapshot() -> Set<String> {
        state.withLock { $0.protectedStagingNames }
    }

    func withMaintenance<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        while true {
            let acquired = state.withLock { gate -> Bool in
                if gate.activeGenerations == 0 && !gate.maintenanceRunning {
                    gate.maintenanceRunning = true
                    return true
                }
                return false
            }
            if acquired {
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        defer {
            state.withLock { $0.maintenanceRunning = false }
        }
        return try await body()
    }
}

final class DerivedImageCacheService: DerivedImageCachePort, DownloadedPreviewCachePort,
    PhotoThumbnailCachePort, @unchecked Sendable
{
    private enum HitValidationResult {
        case valid(DerivedImagePayload)
        case invalid(candidate: DerivedImageCacheEntryRow)
    }

    private let database: CatalogDatabase
    private let repository: GRDBDerivedImageCacheRepository
    private let sourceAccess: FolderReconcileSourceAccessService
    private let sourceReader: DerivedImageSourceReader
    private let renderer: DerivedImageRenderer
    private let volumeReader: any DerivedImageVolumeCapacityReading
    private let clock: any JobClock
    private let store: DerivedImageCacheStore
    private let faultInjector: any DerivedImageCacheStoreFaultInjecting
    private let finalPublishCheckpoint: any DerivedImageFinalPublishCheckpointing
    private let maintenanceCheckpoint: any DerivedImageMaintenanceCheckpointing
    private let downloadedPreviewQuotaBytes: UInt64
    private let inFlight = DerivedImageInFlightCoordinator()
    private let operationGate = DerivedImageOperationGate()

    init(
        database: CatalogDatabase,
        cachesDirectory: URL,
        sourceAccess: FolderReconcileSourceAccessService,
        sourceReader: DerivedImageSourceReader = DerivedImageSourceReader(),
        renderer: DerivedImageRenderer = DerivedImageRenderer(),
        volumeReader: any DerivedImageVolumeCapacityReading = FoundationDerivedImageVolumeCapacityReader(),
        clock: any JobClock = SystemJobClock(),
        faultInjector: any DerivedImageCacheStoreFaultInjecting = NoDerivedImageCacheStoreFaultInjector(),
        repositoryFaultInjector: any DerivedImageRepositoryFaultInjecting = NoDerivedImageRepositoryFaultInjector(),
        publishCheckpoint: any DerivedImagePublishCheckpointing = NoDerivedImagePublishCheckpoint(),
        finalPublishCheckpoint: any DerivedImageFinalPublishCheckpointing = NoDerivedImageFinalPublishCheckpoint(),
        maintenanceCheckpoint: any DerivedImageMaintenanceCheckpointing = NoDerivedImageMaintenanceCheckpoint(),
        downloadedPreviewQuotaBytes: UInt64 = DownloadedPreviewCachePolicy.publishedQuotaBytes
    ) {
        self.database = database
        self.repository = GRDBDerivedImageCacheRepository(
            database: database,
            faultInjector: repositoryFaultInjector
        )
        self.sourceAccess = sourceAccess
        self.sourceReader = sourceReader
        self.renderer = renderer
        self.volumeReader = volumeReader
        self.clock = clock
        self.faultInjector = faultInjector
        self.finalPublishCheckpoint = finalPublishCheckpoint
        self.maintenanceCheckpoint = maintenanceCheckpoint
        self.downloadedPreviewQuotaBytes = downloadedPreviewQuotaBytes
        self.store = DerivedImageCacheStore(
            cachesDirectory: cachesDirectory,
            faultInjector: faultInjector,
            publishCheckpoint: publishCheckpoint
        )
    }

    func loadOrGenerate(_ request: DerivedImageRequest) async throws -> DerivedImagePayload {
        operationGate.beginAccess()
        defer { operationGate.endAccess() }
        do {
            if try repository.assetExists(assetID: request.assetID) == false {
                throw DerivedImageError.derivedAssetNotFound
            }
            guard let lookup = try repository.fetchCacheLookupContext(assetID: request.assetID) else {
                throw DerivedImageError.derivedAssetNotFound
            }

            let key = DerivedImageInFlightCoordinator.DerivedImageCacheKey(
                assetID: request.assetID,
                contentRevision: lookup.contentRevision,
                representationVersion: DerivedImageRepresentationVersion.production,
                variant: request.variant,
                persistence: request.persistence
            )

            return try await inFlight.run(key: key) { [self] in
                try await self.loadOrGenerateInternal(request: request, lookup: lookup)
            }
        } catch let error as DerivedImageError {
            throw error
        } catch DerivedImageSecureIOError.unsafePath {
            throw DerivedImageError.derivedCacheUnsafePath
        } catch {
            throw DerivedImageError.derivedCachePersistenceFailed
        }
    }

    func loadDownloadedPreview(assetID: UUID) throws -> Data? {
        try loadCachedPhotoImage(assetID: assetID, variant: .preview)
    }

    func loadPhotoThumbnail(assetID: UUID) throws -> Data? {
        try loadCachedPhotoImage(assetID: assetID, variant: .gridRegular)
    }

    private func loadCachedPhotoImage(
        assetID: UUID,
        variant: DerivedImageVariant
    ) throws -> Data? {
        operationGate.beginAccess()
        defer { operationGate.endAccess() }
        do {
            guard let lookup = try repository.fetchCacheLookupContext(assetID: assetID) else {
                return nil
            }
            guard let entry = try repository.fetchEntry(
                assetID: assetID,
                contentRevision: lookup.contentRevision,
                representationVersion: DerivedImageRepresentationVersion.production,
                variant: variant
            ) else {
                return nil
            }
            let session = try store.ensureLayout()
            defer { session.closeHandles() }
            switch try validateHit(entry: entry, session: session) {
            case let .valid(payload):
                return payload.encodedBytes
            case let .invalid(candidate):
                try repository.deleteEntry(id: candidate.id)
                _ = try? store.deleteObjectDuringEviction(
                    entryID: candidate.id,
                    format: candidate.storageFormat,
                    session: session
                )
                return nil
            }
        } catch let error as DerivedImageError {
            throw error
        } catch DerivedImageSecureIOError.unsafePath {
            throw DerivedImageError.derivedCacheUnsafePath
        } catch {
            throw DerivedImageError.derivedCachePersistenceFailed
        }
    }

    func storeDownloadedPreview(assetID: UUID, sourceBytes: Data) async throws -> Data {
        try await storePhotoImage(
            assetID: assetID,
            sourceBytes: sourceBytes,
            variant: .preview,
            usesDownloadedPreviewQuota: true
        )
    }

    func storePhotoThumbnail(assetID: UUID, sourceBytes: Data) async throws -> Data {
        try await storePhotoImage(
            assetID: assetID,
            sourceBytes: sourceBytes,
            variant: .gridRegular,
            usesDownloadedPreviewQuota: false
        )
    }

    private func storePhotoImage(
        assetID: UUID,
        sourceBytes: Data,
        variant: DerivedImageVariant,
        usesDownloadedPreviewQuota: Bool
    ) async throws -> Data {
        operationGate.beginAccess()
        defer { operationGate.endAccess() }
        do {
            guard let lookup = try repository.fetchCacheLookupContext(assetID: assetID) else {
                throw DerivedImageError.derivedAssetNotFound
            }
            guard lookup.isEligibleForDownloadedPreview else {
                throw DerivedImageError.derivedAssetIneligible
            }
            return try await storePhotoImageInternal(
                sourceBytes: sourceBytes,
                lookup: lookup,
                variant: variant,
                usesDownloadedPreviewQuota: usesDownloadedPreviewQuota
            )
        } catch let error as DerivedImageError {
            throw error
        } catch DerivedImageSecureIOError.unsafePath {
            throw DerivedImageError.derivedCacheUnsafePath
        } catch {
            throw DerivedImageError.derivedCachePersistenceFailed
        }
    }

    func performMaintenance() async throws -> DerivedImageMaintenanceResult {
        try await operationGate.withMaintenance {
            try self.performMaintenanceInternal()
        }
    }

    func cacheUsage() throws -> DerivedImageCacheUsage {
        do {
            return try repository.registeredUsage()
        } catch let error as DerivedImageError {
            throw error
        } catch {
            throw DerivedImageError.derivedCachePersistenceFailed
        }
    }

    func clearCache() async throws -> DerivedImageCacheClearResult {
        try await operationGate.withMaintenance {
            try self.clearCacheInternal()
        }
    }

    private func loadOrGenerateInternal(
        request: DerivedImageRequest,
        lookup: DerivedImageCacheLookupContext
    ) async throws -> DerivedImagePayload {
        let session = try store.ensureLayout()
        defer { session.closeHandles() }

        var replacementCandidate: DerivedImageCacheEntryRow?
        if let entry = try repository.fetchEntry(
            assetID: lookup.assetID,
            contentRevision: lookup.contentRevision,
            representationVersion: DerivedImageRepresentationVersion.production,
            variant: request.variant
        ) {
            switch try validateHit(entry: entry, session: session) {
            case let .valid(payload):
                return payload
            case let .invalid(candidate):
                replacementCandidate = candidate
            }
        }

        guard let context = try repository.fetchGenerationContext(assetID: request.assetID) else {
            throw DerivedImageError.derivedAssetIneligible
        }
        guard context.isEligibleForGeneration else {
            throw DerivedImageError.derivedAssetIneligible
        }

        return try await generateFresh(
            request: request,
            context: context,
            session: session,
            replacementCandidate: replacementCandidate
        )
    }

    private func storePhotoImageInternal(
        sourceBytes: Data,
        lookup: DerivedImageCacheLookupContext,
        variant: DerivedImageVariant,
        usesDownloadedPreviewQuota: Bool
    ) async throws -> Data {
        let session = try store.ensureLayout()
        defer { session.closeHandles() }

        var replacementCandidate: DerivedImageCacheEntryRow?
        if let entry = try repository.fetchEntry(
            assetID: lookup.assetID,
            contentRevision: lookup.contentRevision,
            representationVersion: DerivedImageRepresentationVersion.production,
            variant: variant
        ) {
            switch try validateHit(entry: entry, session: session) {
            case let .valid(payload):
                return payload.encodedBytes
            case let .invalid(candidate):
                replacementCandidate = candidate
            }
        }

        let artifact = try renderer.render(sourceBytes: sourceBytes, variant: variant)
        guard artifact.byteSize > 0 else {
            throw DerivedImageError.derivedEncodeFailed
        }
        guard let incomingBytes = UInt64(exactly: artifact.byteSize) else {
            return artifact.bytes
        }
        guard !usesDownloadedPreviewQuota || incomingBytes <= downloadedPreviewQuotaBytes else {
            return artifact.bytes
        }

        do {
            if usesDownloadedPreviewQuota {
                try evictDownloadedPreviewsIfNeeded(incomingBytes: incomingBytes, session: session)
            }
            try await evictIfNeeded(incomingBytes: incomingBytes, session: session)
        } catch DerivedImageError.derivedInsufficientSpace {
            return artifact.bytes
        }

        return try publishPhotoImage(
            artifact: artifact,
            lookup: lookup,
            variant: variant,
            session: session,
            replacementCandidate: replacementCandidate
        )
    }

    private func publishPhotoImage(
        artifact: DerivedImageEncodedArtifact,
        lookup: DerivedImageCacheLookupContext,
        variant: DerivedImageVariant,
        session: DerivedImageAnchoredCacheSession,
        replacementCandidate: DerivedImageCacheEntryRow?
    ) throws -> Data {
        let stagingName = DerivedImageCachePathLayout.stagingFileName()
        operationGate.beginGeneration(stagingName: stagingName)
        defer { operationGate.endGeneration(stagingName: stagingName) }

        if faultInjector.shouldFault(at: .dbPublish) {
            throw DerivedImageError.derivedCachePersistenceFailed
        }
        let entryID = UUID()
        _ = try store.publish(
            artifact: artifact,
            entryID: entryID,
            format: artifact.storageFormat,
            stagingName: stagingName,
            session: session
        )
        finalPublishCheckpoint.blockAfterFinalObjectPublished(
            entryID: entryID,
            storageFormat: artifact.storageFormat,
            stagingName: stagingName
        )

        let nowMs = clock.nowMs
        let entry = DerivedImageCacheEntryRow(
            id: entryID,
            assetID: lookup.assetID,
            contentRevision: lookup.contentRevision,
            representationVersion: DerivedImageRepresentationVersion.production,
            variant: variant,
            storageFormat: artifact.storageFormat,
            pixelWidth: artifact.pixelWidth,
            pixelHeight: artifact.pixelHeight,
            byteSize: artifact.byteSize,
            encodedSHA256: artifact.sha256,
            createdAtMs: nowMs,
            lastAccessedAtMs: nowMs
        )
        let outcome = try repository.publishEntryReplacingKey(
            entry: entry,
            expected: lookup,
            replacementCandidateID: replacementCandidate?.id
        )
        switch outcome {
        case .sourceChanged:
            _ = try? store.deleteObjectDuringEviction(
                entryID: entryID,
                format: artifact.storageFormat,
                session: session
            )
            throw DerivedImageError.derivedSourceChanged
        case let .lostRaceToExisting(winner):
            _ = try? store.deleteObjectDuringEviction(
                entryID: entryID,
                format: artifact.storageFormat,
                session: session
            )
            switch try validateHit(entry: winner, session: session) {
            case let .valid(payload):
                return payload.encodedBytes
            case let .invalid(candidate):
                return try publishPhotoImage(
                    artifact: artifact,
                    lookup: lookup,
                    variant: variant,
                    session: session,
                    replacementCandidate: candidate
                )
            }
        case let .published(replacedEntry):
            if let replacedEntry,
               !faultInjector.shouldFault(at: .oldObjectDelete)
            {
                _ = try? session.deleteObject(entryID: replacedEntry.id, format: replacedEntry.storageFormat)
            }
            return artifact.bytes
        }
    }

    private func validateHit(
        entry: DerivedImageCacheEntryRow,
        session: DerivedImageAnchoredCacheSession
    ) throws -> HitValidationResult {
        guard let bytes = try store.readObjectBytes(entry: entry, session: session) else {
            return .invalid(candidate: entry)
        }
        guard try renderer.validateStoredBytes(bytes, entry: entry) else {
            return .invalid(candidate: entry)
        }
        let nowMs = clock.nowMs
        try repository.touchEntry(id: entry.id, accessedAtMs: nowMs)
        return .valid(
            DerivedImagePayload(
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
        )
    }

    private func generateFresh(
        request: DerivedImageRequest,
        context: DerivedImageAssetGenerationContext,
        session: DerivedImageAnchoredCacheSession,
        replacementCandidate: DerivedImageCacheEntryRow? = nil
    ) async throws -> DerivedImagePayload {
        let stagingName = DerivedImageCachePathLayout.stagingFileName()
        operationGate.beginGeneration(stagingName: stagingName)
        defer { operationGate.endGeneration(stagingName: stagingName) }

        let artifact: DerivedImageEncodedArtifact
        do {
            artifact = try sourceAccess.withActiveSourceRootURL(sourceID: context.sourceID) { rootURL in
                let initial = try self.sourceReader.readSourceBytes(rootURL: rootURL, relativePath: context.relativePath)
                guard context.matchesHandleFacts(initial.initialFingerprint) else {
                    throw DerivedImageError.derivedSourceChanged
                }
                guard initial.preHandleFstat.sizeBytes == initial.postHandleFstat.sizeBytes,
                      initial.preHandleFstat.modifiedAtNs == initial.postHandleFstat.modifiedAtNs,
                      initial.initialFingerprint.resourceID == initial.postResourceID
                else {
                    throw DerivedImageError.derivedSourceChanged
                }
                if let source = CGImageSourceCreateWithData(initial.bytes as CFData, nil),
                   let actualUTI = CGImageSourceGetType(source) as String?,
                   actualUTI != context.mediaType
                {
                    throw DerivedImageError.derivedSourceChanged
                }
                let rendered = try self.renderer.render(sourceBytes: initial.bytes, variant: request.variant)
                let reopened = try self.sourceReader.reopenedLocatorFingerprint(
                    rootURL: rootURL,
                    relativePath: context.relativePath
                )
                guard context.matches(reopened) else {
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
        } catch DerivedImageSecureIOError.ioFailure {
            throw DerivedImageError.derivedSourceUnavailable
        } catch DerivedImageSecureIOError.unsafePath {
            throw DerivedImageError.derivedSourceChanged
        } catch let error as DerivedImageError {
            throw error
        } catch {
            throw DerivedImageError.derivedCachePersistenceFailed
        }

        guard artifact.byteSize > 0 else {
            throw DerivedImageError.derivedEncodeFailed
        }
        guard let incomingBytes = UInt64(exactly: artifact.byteSize) else {
            throw DerivedImageError.derivedInsufficientSpace
        }
        if incomingBytes > DerivedImageQuotaPolicy.publishedQuotaBytes {
            throw DerivedImageError.derivedInsufficientSpace
        }

        do {
            try await evictIfNeeded(incomingBytes: incomingBytes, session: session)
        } catch DerivedImageError.derivedInsufficientSpace
            where request.persistence == .memoryFallbackAllowed
        {
            return DerivedImagePayload(
                entryID: UUID(),
                assetID: context.assetID,
                contentRevision: context.contentRevision,
                representationVersion: DerivedImageRepresentationVersion.production,
                variant: request.variant,
                storageFormat: artifact.storageFormat,
                pixelWidth: artifact.pixelWidth,
                pixelHeight: artifact.pixelHeight,
                encodedBytes: artifact.bytes,
                origin: .memoryOnly
            )
        }

        if faultInjector.shouldFault(at: .dbPublish) {
            throw DerivedImageError.derivedCachePersistenceFailed
        }

        let entryID = UUID()
        _ = try store.publish(
            artifact: artifact,
            entryID: entryID,
            format: artifact.storageFormat,
            stagingName: stagingName,
            session: session
        )

        finalPublishCheckpoint.blockAfterFinalObjectPublished(
            entryID: entryID,
            storageFormat: artifact.storageFormat,
            stagingName: stagingName
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

        let outcome = try repository.publishEntryReplacingKey(
            entry: entry,
            expected: context,
            replacementCandidateID: replacementCandidate?.id
        )
        switch outcome {
        case .sourceChanged:
            try? store.deleteObjectDuringEviction(entryID: entryID, format: artifact.storageFormat, session: session)
            throw DerivedImageError.derivedSourceChanged
        case let .lostRaceToExisting(winner):
            try? store.deleteObjectDuringEviction(entryID: entryID, format: artifact.storageFormat, session: session)
            switch try validateHit(entry: winner, session: session) {
            case let .valid(payload):
                return payload
            case let .invalid(candidate):
                return try await generateFresh(
                    request: request,
                    context: context,
                    session: session,
                    replacementCandidate: candidate
                )
            }
        case let .published(replacedEntry):
            if let replacedEntry {
                let shouldFaultOldDelete = faultInjector.shouldFault(at: .oldObjectDelete)
                if !shouldFaultOldDelete {
                    try? session.deleteObject(entryID: replacedEntry.id, format: replacedEntry.storageFormat)
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

    private func evictIfNeeded(incomingBytes: UInt64, session: DerivedImageAnchoredCacheSession) async throws {
        let facts = try requireVolumeFacts(at: store.versionRoot)
        guard let reserve = DerivedImageQuotaPolicy.reserveBytes(totalVolumeBytes: facts.totalBytes) else {
            throw DerivedImageError.derivedCapacityUnavailable
        }

        var published = try repository.publishedByteTotal()
        var available = facts.availableBytes
        var lastAvailableAfterSuccessfulDelete = available

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
            if let victimBytes = UInt64(exactly: victim.byteSize),
               let reduced = DerivedImageQuotaPolicy.subtracting(published, victimBytes)
            {
                published = reduced
            }

            let objectDeleted = (try? store.deleteObjectDuringEviction(
                entryID: victim.id,
                format: victim.storageFormat,
                session: session
            )) ?? false

            if objectDeleted {
                let refreshed = try requireVolumeFacts(at: store.versionRoot)
                available = refreshed.availableBytes
                lastAvailableAfterSuccessfulDelete = available
            } else {
                available = lastAvailableAfterSuccessfulDelete
            }
        }
    }

    private func evictDownloadedPreviewsIfNeeded(
        incomingBytes: UInt64,
        session: DerivedImageAnchoredCacheSession
    ) throws {
        var published = try repository.downloadedPreviewByteTotal()
        while true {
            guard let combined = DerivedImageQuotaPolicy.adding(published, incomingBytes) else {
                throw DerivedImageError.derivedInsufficientSpace
            }
            if combined <= downloadedPreviewQuotaBytes {
                return
            }
            guard let victim = try repository.downloadedPreviewLRUEntries().first else {
                throw DerivedImageError.derivedInsufficientSpace
            }
            try repository.deleteEntry(id: victim.id)
            if let victimBytes = UInt64(exactly: victim.byteSize),
               let reduced = DerivedImageQuotaPolicy.subtracting(published, victimBytes)
            {
                published = reduced
            }
            _ = try? store.deleteObjectDuringEviction(
                entryID: victim.id,
                format: victim.storageFormat,
                session: session
            )
        }
    }

    private func requireVolumeFacts(at url: URL) throws -> DerivedImageVolumeFacts {
        do {
            guard let facts = try volumeReader.volumeFacts(at: url) else {
                throw DerivedImageError.derivedCapacityUnavailable
            }
            return facts
        } catch let error as DerivedImageError {
            throw error
        } catch {
            throw DerivedImageError.derivedCapacityUnavailable
        }
    }

    private func performMaintenanceInternal() throws -> DerivedImageMaintenanceResult {
        do {
            return try performMaintenanceInternalBody()
        } catch let error as DerivedImageError {
            throw error
        } catch DerivedImageSecureIOError.unsafePath {
            throw DerivedImageError.derivedCacheUnsafePath
        } catch {
            throw DerivedImageError.derivedCachePersistenceFailed
        }
    }

    private func clearCacheInternal() throws -> DerivedImageCacheClearResult {
        do {
            maintenanceCheckpoint.blockWhileMaintenanceHeld()
            let session = try store.ensureLayout()
            defer { session.closeHandles() }
            try session.preflightForClear()

            let invalidated = try repository.invalidateAllEntries()
            let entries = invalidated.entries

            var removedObjects = 0
            var removedBytes: UInt64 = 0
            var partialReclaim = false
            for entry in entries {
                do {
                    let byteSize = try session.objectByteSize(
                        entryID: entry.id,
                        format: entry.storageFormat
                    ) ?? 0
                    if try store.deleteObjectDuringEviction(
                        entryID: entry.id,
                        format: entry.storageFormat,
                        session: session
                    ) {
                        removedObjects += 1
                        removedBytes = DerivedImageQuotaPolicy.adding(removedBytes, byteSize)
                            ?? UInt64.max
                    }
                } catch {
                    partialReclaim = true
                }
            }

            if !partialReclaim {
                do {
                    var unsafeObjects = 0
                    removedObjects += try session.sweepUnreferencedObjects(
                        referenced: [],
                        protectedStagingNames: [],
                        removedBytes: &removedBytes,
                        unsafeObjects: &unsafeObjects
                    )
                    removedObjects += try session.sweepStaging(
                        excluding: [],
                        removedBytes: &removedBytes,
                        unsafeObjects: &unsafeObjects
                    )
                    partialReclaim = unsafeObjects > 0
                } catch {
                    partialReclaim = true
                }
            }

            return DerivedImageCacheClearResult(
                removedEntries: entries.count,
                registeredBytesInvalidated: invalidated.registeredBytes,
                removedObjects: removedObjects,
                removedBytes: removedBytes,
                partialReclaim: partialReclaim
            )
        } catch let error as DerivedImageError {
            throw error
        } catch DerivedImageSecureIOError.unsafePath {
            throw DerivedImageError.derivedCacheUnsafePath
        } catch {
            throw DerivedImageError.derivedCachePersistenceFailed
        }
    }

    private func performMaintenanceInternalBody() throws -> DerivedImageMaintenanceResult {
        maintenanceCheckpoint.blockWhileMaintenanceHeld()

        let session = try store.ensureLayout()
        defer { session.closeHandles() }

        var removedEntries = 0
        var removedObjects = 0
        var removedBytes: UInt64 = 0
        var unsafeObjects = 0

        let entries = try repository.allEntries()
        var validEntries: [DerivedImageCacheEntryRow] = []
        for entry in entries {
            guard let bytes = try store.readObjectBytes(entry: entry, session: session),
                  try renderer.validateStoredBytes(bytes, entry: entry)
            else {
                try repository.deleteEntry(id: entry.id)
                if let deletedBytes = try store.removeInvalidEntryArtifacts(entry: entry, session: session) {
                    removedObjects += 1
                    removedBytes &+= deletedBytes
                }
                removedEntries += 1
                continue
            }
            validEntries.append(entry)
            _ = bytes
        }

        let referenced = store.listReferencedObjectPaths(entries: validEntries)
        let protected = operationGate.protectedStagingSnapshot()
        removedObjects += try session.sweepUnreferencedObjects(
            referenced: referenced,
            protectedStagingNames: protected,
            removedBytes: &removedBytes,
            unsafeObjects: &unsafeObjects
        )
        removedObjects += try session.sweepStaging(
            excluding: protected,
            removedBytes: &removedBytes,
            unsafeObjects: &unsafeObjects
        )
        return DerivedImageMaintenanceResult(
            removedEntries: removedEntries,
            removedObjects: removedObjects,
            removedBytes: removedBytes,
            unsafeObjects: unsafeObjects
        )
    }
}

private extension DerivedImageCacheStore {
    func deleteObjectDuringEviction(
        entryID: UUID,
        format: DerivedImageStorageFormat,
        session: DerivedImageAnchoredCacheSession
    ) throws -> Bool {
        if faultInjector.shouldFault(at: .evictObjectDelete) {
            throw DerivedImageError.derivedCachePersistenceFailed
        }
        return try session.deleteObject(entryID: entryID, format: format)
    }
}
