import Foundation
import GRDB

struct LibraryAssetImageLoadLimits: Equatable, Sendable {
    var maximumConcurrentGridLoads: Int
    var maximumConcurrentPreviewLoads: Int

    init(maximumConcurrentGridLoads: Int, maximumConcurrentPreviewLoads: Int) {
        precondition(maximumConcurrentGridLoads > 0)
        precondition(maximumConcurrentPreviewLoads > 0)
        self.maximumConcurrentGridLoads = maximumConcurrentGridLoads
        self.maximumConcurrentPreviewLoads = maximumConcurrentPreviewLoads
    }

    /// Backward-compatible single-pool initializer used by older call sites and tests.
    init(maximumConcurrentLoads: Int) {
        self.init(
            maximumConcurrentGridLoads: maximumConcurrentLoads,
            maximumConcurrentPreviewLoads: max(1, maximumConcurrentLoads / 2)
        )
    }
}

struct LibraryAssetImageLoader: Sendable {
    let database: CatalogDatabase
    let fileImages: any DerivedImageCachePort
    let photosImages: any PhotosLibraryAccessPort
    let cloudPreviews: (any PhotosCloudPreviewPort)?
    let downloadedPreviews: (any DownloadedPreviewCachePort)?
    let photoThumbnails: (any PhotoThumbnailCachePort)?
    private let loadCoordinator: LibraryAssetImageLoadCoordinator?
    private let inFlight: LibraryAssetImageInFlightCoordinator

    init(
        database: CatalogDatabase,
        fileImages: any DerivedImageCachePort,
        photosImages: any PhotosLibraryAccessPort,
        cloudPreviews: (any PhotosCloudPreviewPort)? = nil,
        downloadedPreviews: (any DownloadedPreviewCachePort)? = nil,
        photoThumbnails: (any PhotoThumbnailCachePort)? = nil,
        maximumConcurrentLoads: Int? = nil,
        limits: LibraryAssetImageLoadLimits? = nil
    ) {
        self.database = database
        self.fileImages = fileImages
        self.photosImages = photosImages
        self.cloudPreviews = cloudPreviews
        self.downloadedPreviews = downloadedPreviews
        self.photoThumbnails = photoThumbnails
        let resolvedLimits = limits ?? maximumConcurrentLoads.map {
            LibraryAssetImageLoadLimits(maximumConcurrentLoads: $0)
        }
        loadCoordinator = resolvedLimits.map { LibraryAssetImageLoadCoordinator(limits: $0) }
        inFlight = LibraryAssetImageInFlightCoordinator()
    }

    func load(assetID: UUID, variant: PhotosImageVariant) async throws -> Data {
        try await load(
            assetID: assetID,
            variant: variant,
            filePersistence: nil
        )
    }

    /// The app-model pipeline persists its exact 224-pixel input separately.
    /// File-backed sources therefore keep the legacy preview rendering contract
    /// without also publishing a much larger 2048-pixel intermediate preview.
    func loadModelSuggestionPreview(assetID: UUID) async throws -> Data {
        try await load(
            assetID: assetID,
            variant: .preview,
            filePersistence: .memoryOnly
        )
    }

    private func load(
        assetID: UUID,
        variant: PhotosImageVariant,
        filePersistence: DerivedImagePersistence?
    ) async throws -> Data {
        // Coalesce remounted cells before starting I/O. Production leaves unique
        // requests to Swift's executor and the underlying frameworks instead of
        // imposing an app-level concurrency ceiling. A bounded coordinator is
        // retained only as an injectable test seam.
        try await inFlight.run(
            assetID: assetID,
            variant: variant,
            filePersistence: filePersistence
        ) { [self] in
            if let loadCoordinator {
                return try await loadCoordinator.run(lane: .lane(for: variant)) { [self] in
                    try await loadWithoutConcurrencyLimit(
                        assetID: assetID,
                        variant: variant,
                        filePersistence: filePersistence
                    )
                }
            }
            return try await loadWithoutConcurrencyLimit(
                assetID: assetID,
                variant: variant,
                filePersistence: filePersistence
            )
        }
    }

    func loadOriginalAspectThumbnailIfCached(assetID: UUID) async throws -> Data? {
        let locator = try await locator(assetID: assetID)
        if locator.kind == AssetLocatorKind.photos.rawValue {
            return try photoThumbnails?.loadPhotoOriginalAspectThumbnail(assetID: assetID)
        }
        return try await fileImages.loadCached(
            DerivedImageRequest(
                assetID: assetID,
                variant: .gridOriginal,
                persistence: .required
            )
        )?.encodedBytes
    }

    func loadThumbnailIfCached(assetID: UUID) async throws -> Data? {
        let locator = try await locator(assetID: assetID)
        if locator.kind == AssetLocatorKind.photos.rawValue {
            return try photoThumbnails?.loadPhotoThumbnail(assetID: assetID)
        }
        return try await fileImages.loadCached(
            DerivedImageRequest(
                assetID: assetID,
                variant: .gridRegular,
                persistence: .required
            )
        )?.encodedBytes
    }

    func prewarmOriginalAspectThumbnail(assetID: UUID) async throws -> Data {
        try await load(assetID: assetID, variant: .originalAspectThumbnail)
    }

    func downloadCloudPreview(
        assetID: UUID,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> Data {
        let operation: @Sendable () async throws -> Data = { [self] in
            guard let cloudPreviews, let downloadedPreviews else {
                throw PhotosLibraryError.libraryUnavailable
            }
            let locator = try await locator(assetID: assetID)
            guard locator.kind == AssetLocatorKind.photos.rawValue,
                  let identifier = locator.identifier,
                  locator.sourceState == SourceState.active.rawValue
            else {
                throw PhotosLibraryError.libraryUnavailable
            }
            let sourceBytes = try await cloudPreviews.requestCloudPreview(
                localIdentifier: identifier,
                grant: .issue(),
                onProgress: onProgress
            )
            return try await downloadedPreviews.storeDownloadedPreview(
                assetID: assetID,
                sourceBytes: sourceBytes
            )
        }
        if let loadCoordinator {
            return try await loadCoordinator.run(lane: .preview, operation)
        }
        return try await operation()
    }

    private func loadWithoutConcurrencyLimit(
        assetID: UUID,
        variant: PhotosImageVariant,
        filePersistence: DerivedImagePersistence?
    ) async throws -> Data {
        let locator = try await locator(assetID: assetID)

        if locator.kind == AssetLocatorKind.photos.rawValue {
            guard let identifier = locator.identifier else {
                throw PhotosLibraryError.libraryUnavailable
            }
            if variant == .originalAspectThumbnail {
                guard let photoThumbnails else {
                    throw PhotosLibraryError.libraryUnavailable
                }
                if let cached = try? photoThumbnails.loadPhotoOriginalAspectThumbnail(
                    assetID: assetID
                )
                {
                    return cached
                }
                if let downloadedPreviews,
                   let sourceBytes = try downloadedPreviews.loadDownloadedPreview(assetID: assetID)
                {
                    return try await photoThumbnails.storePhotoOriginalAspectThumbnail(
                        assetID: assetID,
                        sourceBytes: sourceBytes
                    )
                }
            }
            if variant == .grid,
               let photoThumbnails,
               let cached = try? photoThumbnails.loadPhotoThumbnail(assetID: assetID)
            {
                return cached
            }
            if let downloadedPreviews,
               let cached = try downloadedPreviews.loadDownloadedPreview(assetID: assetID)
            {
                if variant == .grid, let photoThumbnails {
                    return (try? await photoThumbnails.storePhotoThumbnail(
                        assetID: assetID,
                        sourceBytes: cached
                    )) ?? cached
                }
                return cached
            }
            guard locator.sourceState == SourceState.active.rawValue else {
                throw PhotosLibraryError.libraryUnavailable
            }
            let sourceBytes = try await photosImages.requestLocalImage(
                localIdentifier: identifier,
                variant: variant
            )
            if variant == .grid, let photoThumbnails {
                return (try? await photoThumbnails.storePhotoThumbnail(
                    assetID: assetID,
                    sourceBytes: sourceBytes
                )) ?? sourceBytes
            }
            if variant == .originalAspectThumbnail {
                guard let photoThumbnails else {
                    throw PhotosLibraryError.libraryUnavailable
                }
                return try await photoThumbnails.storePhotoOriginalAspectThumbnail(
                    assetID: assetID,
                    sourceBytes: sourceBytes
                )
            }
            return sourceBytes
        }

        let derivedVariant: DerivedImageVariant = switch variant {
        case .grid: .gridRegular
        case .originalAspectThumbnail: .gridOriginal
        case .preview: .preview
        }
        return try await fileImages.loadOrGenerate(
            DerivedImageRequest(
                assetID: assetID,
                variant: derivedVariant,
                persistence: filePersistence ?? (variant == .originalAspectThumbnail
                    ? .required
                    : .memoryFallbackAllowed)
            )
        ).encodedBytes
    }

    private func locator(
        assetID: UUID
    ) async throws -> (kind: String, identifier: String?, sourceState: String) {
        try await database.pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT a.locator_kind, a.photos_local_identifier, s.state AS source_state
                FROM asset a
                JOIN source s ON s.id = a.source_id
                WHERE a.id = ? AND a.locator_state = 'current'
                """,
                arguments: [assetID.uuidString.lowercased()]
            ) else {
                throw PhotosLibraryError.libraryUnavailable
            }
            return (row["locator_kind"], row["photos_local_identifier"], row["source_state"])
        }
    }
}

enum LibraryAssetImageLoadLane: Hashable, Sendable {
    case grid
    case preview

    static func lane(for variant: PhotosImageVariant) -> LibraryAssetImageLoadLane {
        switch variant {
        case .grid, .originalAspectThumbnail: .grid
        case .preview: .preview
        }
    }
}

/// Cancellation-safe bounded test seam. Production does not construct it.
actor LibraryAssetImageLoadCoordinator {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let limits: LibraryAssetImageLoadLimits
    private var activeGridLoads = 0
    private var activePreviewLoads = 0
    private var gridWaiters: [Waiter] = []
    private var previewWaiters: [Waiter] = []

    init(limits: LibraryAssetImageLoadLimits) {
        self.limits = limits
    }

    func run<T: Sendable>(
        lane: LibraryAssetImageLoadLane,
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await acquire(lane: lane)
        do {
            try Task.checkCancellation()
            let value = try await operation()
            release(lane: lane)
            return value
        } catch {
            release(lane: lane)
            throw error
        }
    }

    private func acquire(lane: LibraryAssetImageLoadLane) async throws {
        if tryTakeSlot(lane: lane) {
            return
        }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                appendWaiter(Waiter(id: waiterID, continuation: continuation), lane: lane)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID, lane: lane) }
        }
    }

    private func release(lane: LibraryAssetImageLoadLane) {
        switch lane {
        case .grid:
            if let next = gridWaiters.first {
                gridWaiters.removeFirst()
                next.continuation.resume(returning: ())
            } else {
                activeGridLoads = max(0, activeGridLoads - 1)
            }
        case .preview:
            if let next = previewWaiters.first {
                previewWaiters.removeFirst()
                next.continuation.resume(returning: ())
            } else {
                activePreviewLoads = max(0, activePreviewLoads - 1)
            }
        }
    }

    private func tryTakeSlot(lane: LibraryAssetImageLoadLane) -> Bool {
        switch lane {
        case .grid:
            guard activeGridLoads < limits.maximumConcurrentGridLoads else { return false }
            activeGridLoads += 1
            return true
        case .preview:
            guard activePreviewLoads < limits.maximumConcurrentPreviewLoads else { return false }
            activePreviewLoads += 1
            return true
        }
    }

    private func appendWaiter(_ waiter: Waiter, lane: LibraryAssetImageLoadLane) {
        switch lane {
        case .grid: gridWaiters.append(waiter)
        case .preview: previewWaiters.append(waiter)
        }
    }

    private func cancelWaiter(id: UUID, lane: LibraryAssetImageLoadLane) {
        switch lane {
        case .grid:
            guard let index = gridWaiters.firstIndex(where: { $0.id == id }) else { return }
            let waiter = gridWaiters.remove(at: index)
            waiter.continuation.resume(throwing: CancellationError())
        case .preview:
            guard let index = previewWaiters.firstIndex(where: { $0.id == id }) else { return }
            let waiter = previewWaiters.remove(at: index)
            waiter.continuation.resume(throwing: CancellationError())
        }
    }
}

/// Coalesces concurrent loads for the same asset/variant so Lazy grid remounts share one fetch.
actor LibraryAssetImageInFlightCoordinator {
    private struct Key: Hashable, Sendable {
        let assetID: UUID
        let variant: PhotosImageVariant
        let filePersistence: DerivedImagePersistence?
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Data, Error>
    }

    private struct Entry {
        let id: UUID
        var task: Task<Void, Never>?
        var waiters: [Waiter]
    }

    private var entries: [Key: Entry] = [:]

    func run(
        assetID: UUID,
        variant: PhotosImageVariant,
        filePersistence: DerivedImagePersistence?,
        operation: @Sendable @escaping () async throws -> Data
    ) async throws -> Data {
        let key = Key(
            assetID: assetID,
            variant: variant,
            filePersistence: filePersistence
        )
        try Task.checkCancellation()
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                register(
                    waiter: Waiter(id: waiterID, continuation: continuation),
                    key: key,
                    operation: operation
                )
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID, key: key) }
        }
    }

    private func register(
        waiter: Waiter,
        key: Key,
        operation: @Sendable @escaping () async throws -> Data
    ) {
        if entries[key] != nil {
            entries[key]?.waiters.append(waiter)
            return
        }
        let entryID = UUID()
        entries[key] = Entry(id: entryID, task: nil, waiters: [waiter])
        let task = Task { [self] in
            do {
                finish(key: key, entryID: entryID, result: .success(try await operation()))
            } catch {
                finish(key: key, entryID: entryID, result: .failure(error))
            }
        }
        entries[key]?.task = task
    }

    private func cancelWaiter(id: UUID, key: Key) {
        guard var entry = entries[key],
              let index = entry.waiters.firstIndex(where: { $0.id == id })
        else { return }
        let waiter = entry.waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
        if entry.waiters.isEmpty {
            entries.removeValue(forKey: key)
            entry.task?.cancel()
        } else {
            entries[key] = entry
        }
    }

    private func finish(key: Key, entryID: UUID, result: Result<Data, Error>) {
        guard entries[key]?.id == entryID,
              let entry = entries.removeValue(forKey: key)
        else { return }
        for waiter in entry.waiters {
            waiter.continuation.resume(with: result)
        }
    }
}
