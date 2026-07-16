import AppKit
import Foundation
import Photos

final class PhotoKitPhotosLibraryAdapter: NSObject, PhotosLibraryAccessPort, PhotosChangeHistoryPort,
    PhotosChangeObserverPort, PhotosCloudPreviewPort, PhotosFeaturePrintImagePort, PHPhotoLibraryChangeObserver,
    @unchecked Sendable
{
    private let imageManager = PHCachingImageManager()
    private let observerLock = NSLock()
    private var onLibraryChange: (@Sendable () -> Void)?
    private var isObservingChanges = false
    private static let supportedTypes: Set<String> = [
        "public.jpeg",
        "public.png",
        "public.heic",
        "public.heif",
        "public.tiff",
        "org.webmproject.webp",
    ]
    static let cloudPreviewTargetSize = NSSize(width: 2_048, height: 2_048)

    func authorizationState() -> PhotosAuthorizationState {
        mapAuthorization(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestAuthorization() async -> PhotosAuthorizationState {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return mapAuthorization(status)
    }

    func enumerateStaticImages(
        startingAt startOffset: Int,
        batchSize: Int,
        onBatch: (PhotosAssetEnumerationBatch) throws -> Void
    ) throws {
        guard authorizationState() == .authorized else {
            throw PhotosLibraryError.authorizationDenied
        }
        guard batchSize > 0 else { throw PhotosLibraryError.libraryUnavailable }

        let options = PHFetchOptions()
        options.sortDescriptors = [
            NSSortDescriptor(key: "creationDate", ascending: true),
        ]
        let result = PHAsset.fetchAssets(with: .image, options: options)
        let totalCount = result.count
        let effectiveStart = min(max(0, startOffset), totalCount)
        guard effectiveStart < totalCount else {
            try onBatch(
                PhotosAssetEnumerationBatch(
                    assets: [],
                    completedCount: max(startOffset, totalCount),
                    totalCount: max(startOffset, totalCount)
                )
            )
            return
        }

        for batchStart in stride(from: effectiveStart, to: totalCount, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, totalCount)
            let fetchedAssets = result.objects(at: IndexSet(integersIn: batchStart ..< batchEnd))
            var metadataBatch: [PhotosAssetMetadata] = []
            metadataBatch.reserveCapacity(fetchedAssets.count)
            for asset in fetchedAssets {
                if let metadata = metadata(for: asset) {
                    metadataBatch.append(metadata)
                }
            }
            try onBatch(
                PhotosAssetEnumerationBatch(
                    assets: metadataBatch,
                    completedCount: batchEnd,
                    totalCount: totalCount
                )
            )
        }
    }

    func currentChangeToken() throws -> Data {
        guard authorizationState() == .authorized else {
            throw PhotosLibraryError.authorizationDenied
        }
        guard PHPhotoLibrary.shared().unavailabilityReason == nil else {
            throw PhotosLibraryError.libraryUnavailable
        }
        return try archiveChangeToken(PHPhotoLibrary.shared().currentChangeToken)
    }

    func enumeratePersistentChanges(
        since changeToken: Data,
        onBatch: (PhotosPersistentChangeBatch) throws -> Void
    ) throws {
        guard authorizationState() == .authorized else {
            throw PhotosLibraryError.authorizationDenied
        }
        guard PHPhotoLibrary.shared().unavailabilityReason == nil else {
            throw PhotosLibraryError.libraryUnavailable
        }
        let decodedToken: PHPersistentChangeToken
        do {
            guard let token = try NSKeyedUnarchiver.unarchivedObject(
                ofClass: PHPersistentChangeToken.self,
                from: changeToken
            ) else {
                throw PhotosLibraryError.changeTokenInvalid
            }
            decodedToken = token
        } catch let error as PhotosLibraryError {
            throw error
        } catch {
            throw PhotosLibraryError.changeTokenInvalid
        }

        let changes: PHPersistentChangeFetchResult
        do {
            changes = try PHPhotoLibrary.shared().fetchPersistentChanges(since: decodedToken)
        } catch let error as PhotosLibraryError {
            throw error
        } catch {
            throw PhotosLibraryError.changeTokenInvalid
        }

        do {
            for change in changes {
                let details = try change.changeDetails(for: .asset)
                let changedIdentifiers = details.insertedLocalIdentifiers
                    .union(details.updatedLocalIdentifiers)
                let upsertedAssets = metadata(localIdentifiers: changedIdentifiers)
                let resolvedIdentifiers = Set(upsertedAssets.map { $0.localIdentifier })
                let deletedIdentifiers = details.deletedLocalIdentifiers
                    .union(changedIdentifiers.subtracting(resolvedIdentifiers))
                    .sorted()
                try onBatch(
                    PhotosPersistentChangeBatch(
                        upsertedAssets: upsertedAssets,
                        deletedLocalIdentifiers: deletedIdentifiers,
                        changeToken: try archiveChangeToken(change.changeToken)
                    )
                )
            }
        } catch let error as PhotosLibraryError {
            throw error
        } catch {
            throw PhotosLibraryError.changeTokenInvalid
        }
    }

    func startObservingChanges(_ onChange: @escaping @Sendable () -> Void) {
        let shouldRegister = observerLock.withLock {
            onLibraryChange = onChange
            guard !isObservingChanges else { return false }
            isObservingChanges = true
            return true
        }
        if shouldRegister {
            PHPhotoLibrary.shared().register(self)
        }
    }

    func photoLibraryDidChange(_: PHChange) {
        let callback = observerLock.withLock { onLibraryChange }
        callback?()
    }

    deinit {
        let shouldUnregister = observerLock.withLock { isObservingChanges }
        if shouldUnregister {
            PHPhotoLibrary.shared().unregisterChangeObserver(self)
        }
    }

    func requestLocalImage(
        localIdentifier: String,
        variant: PhotosImageVariant
    ) async throws -> Data {
        guard authorizationState() == .authorized else {
            throw PhotosLibraryError.authorizationDenied
        }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = fetch.firstObject else {
            throw PhotosLibraryError.libraryUnavailable
        }

        let options = Self.makeLocalOnlyImageRequestOptions()
        let targetSize: NSSize = switch variant {
        case .grid: NSSize(width: 512, height: 512)
        case .preview: NSSize(width: 2_048, height: 2_048)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let completion = OneShotImageContinuation(continuation)
            imageManager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                if let image, let data = image.tiffRepresentation {
                    completion.resume(returning: data)
                    return
                }
                if (info?[PHImageResultIsInCloudKey] as? Bool) == true {
                    completion.resume(throwing: PhotosLibraryError.cloudOnly)
                    return
                }
                if let error = info?[PHImageErrorKey] as? Error {
                    completion.resume(throwing: error)
                    return
                }
                if (info?[PHImageCancelledKey] as? Bool) == true {
                    completion.resume(throwing: PhotosLibraryError.libraryUnavailable)
                    return
                }
                completion.resume(throwing: PhotosLibraryError.libraryUnavailable)
            }
        }
    }

    func requestCloudPreview(
        localIdentifier: String,
        grant _: PhotosCloudDownloadGrant,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> Data {
        guard authorizationState() == .authorized else {
            throw PhotosLibraryError.authorizationDenied
        }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = fetch.firstObject else {
            throw PhotosLibraryError.libraryUnavailable
        }

        let cancellation = PhotoKitImageRequestCancellation(manager: imageManager)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let completion = OneShotImageContinuation(continuation)
                let requestID = imageManager.requestImage(
                    for: asset,
                    targetSize: Self.cloudPreviewTargetSize,
                    contentMode: .aspectFit,
                    options: Self.makeCloudPreviewRequestOptions(onProgress: onProgress)
                ) { image, info in
                    if (info?[PHImageResultIsDegradedKey] as? Bool) == true {
                        return
                    }
                    if let image, let data = image.tiffRepresentation {
                        onProgress(1.0)
                        completion.resume(returning: data)
                        return
                    }
                    if (info?[PHImageCancelledKey] as? Bool) == true {
                        completion.resume(throwing: CancellationError())
                        return
                    }
                    if let error = info?[PHImageErrorKey] as? Error {
                        completion.resume(throwing: error)
                        return
                    }
                    completion.resume(throwing: PhotosLibraryError.libraryUnavailable)
                }
                cancellation.install(requestID: requestID, completion: completion)
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    func requestLocalFeatureImage(localIdentifier: String) throws -> Data {
        guard authorizationState() == .authorized else {
            throw PhotosLibraryError.authorizationDenied
        }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = fetch.firstObject else {
            throw PhotosLibraryError.libraryUnavailable
        }

        let result = SynchronousImageResult()
        imageManager.requestImage(
            for: asset,
            targetSize: NSSize(width: 1_024, height: 1_024),
            contentMode: .aspectFit,
            options: Self.makeLocalOnlyFeaturePrintRequestOptions()
        ) { image, info in
            if let image, let data = image.tiffRepresentation {
                result.set(.success(data))
            } else if (info?[PHImageResultIsInCloudKey] as? Bool) == true {
                result.set(.failure(PhotosLibraryError.cloudOnly))
            } else {
                result.set(.failure(PhotosLibraryError.libraryUnavailable))
            }
        }
        guard let value = result.value else {
            throw PhotosLibraryError.libraryUnavailable
        }
        return try value.get()
    }

    private func mapAuthorization(_ status: PHAuthorizationStatus) -> PhotosAuthorizationState {
        switch status {
        case .authorized, .limited:
            return .authorized
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .restricted
        }
    }

    static func isSupportedStaticImage(
        mediaType: PHAssetMediaType,
        mediaSubtypes _: PHAssetMediaSubtype,
        uniformTypeIdentifier: String
    ) -> Bool {
        mediaType == .image
            && supportedTypes.contains(uniformTypeIdentifier.lowercased())
    }

    static func makeLocalOnlyImageRequestOptions() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isSynchronous = false
        options.isNetworkAccessAllowed = false
        return options
    }

    static func makeLocalOnlyFeaturePrintRequestOptions() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isSynchronous = true
        options.isNetworkAccessAllowed = false
        return options
    }

    static func makeCloudPreviewRequestOptions(
        onProgress: @escaping @Sendable (Double) -> Void
    ) -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isSynchronous = false
        options.isNetworkAccessAllowed = true
        options.progressHandler = { progress, _, _, _ in
            onProgress(min(max(progress, 0), 1))
        }
        return options
    }

    private func preferredStillResource(for asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        return resources.first(where: { $0.type == .fullSizePhoto })
            ?? resources.first(where: { $0.type == .photo })
            ?? resources.first(where: { $0.type == .alternatePhoto })
    }

    private func metadata(localIdentifiers: Set<String>) -> [PhotosAssetMetadata] {
        guard !localIdentifiers.isEmpty else { return [] }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers.sorted(), options: nil)
        var assets: [PhotosAssetMetadata] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            if let metadata = self.metadata(for: asset) {
                assets.append(metadata)
            }
        }
        return assets.sorted { $0.localIdentifier < $1.localIdentifier }
    }

    private func metadata(for asset: PHAsset) -> PhotosAssetMetadata? {
        guard let resource = preferredStillResource(for: asset) else { return nil }
        let type = resource.uniformTypeIdentifier.lowercased()
        guard Self.isSupportedStaticImage(
            mediaType: asset.mediaType,
            mediaSubtypes: asset.mediaSubtypes,
            uniformTypeIdentifier: type
        ) else { return nil }
        return PhotosAssetMetadata(
            localIdentifier: asset.localIdentifier,
            fileName: safeFileName(resource.originalFilename),
            mediaType: type,
            width: asset.pixelWidth,
            height: asset.pixelHeight,
            createdAtMs: milliseconds(asset.creationDate),
            modifiedAtMs: milliseconds(asset.modificationDate)
        )
    }

    private func archiveChangeToken(_ token: PHPersistentChangeToken) throws -> Data {
        do {
            return try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
        } catch {
            throw PhotosLibraryError.persistenceFailure
        }
    }

    private func safeFileName(_ raw: String) -> String? {
        let name = (raw as NSString).lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("\0") else { return nil }
        return name
    }

    private func milliseconds(_ date: Date?) -> Int64? {
        date.map { Int64($0.timeIntervalSince1970 * 1_000) }
    }
}

private final class SynchronousImageResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Result<Data, Error>?

    var value: Result<Data, Error>? {
        lock.withLock { storedValue }
    }

    func set(_ value: Result<Data, Error>) {
        lock.withLock {
            guard storedValue == nil else { return }
            storedValue = value
        }
    }
}

private final class OneShotImageContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?

    init(_ continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
    }

    func resume(returning data: Data) {
        take()?.resume(returning: data)
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<Data, Error>? {
        lock.withLock {
            defer { continuation = nil }
            return continuation
        }
    }
}

private final class PhotoKitImageRequestCancellation: @unchecked Sendable {
    private struct State {
        var requestID: PHImageRequestID?
        var completion: OneShotImageContinuation?
        var isCancelled = false
    }

    private let manager: PHImageManager
    private let lock = NSLock()
    private var state = State()

    init(manager: PHImageManager) {
        self.manager = manager
    }

    func install(requestID: PHImageRequestID, completion: OneShotImageContinuation) {
        let shouldCancel = lock.withLock { () -> Bool in
            state.requestID = requestID
            state.completion = completion
            return state.isCancelled
        }
        if shouldCancel {
            manager.cancelImageRequest(requestID)
            completion.resume(throwing: CancellationError())
        }
    }

    func cancel() {
        let current = lock.withLock { () -> (PHImageRequestID?, OneShotImageContinuation?) in
            state.isCancelled = true
            return (state.requestID, state.completion)
        }
        if let requestID = current.0 {
            manager.cancelImageRequest(requestID)
        }
        current.1?.resume(throwing: CancellationError())
    }
}
