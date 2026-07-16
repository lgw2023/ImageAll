import AppKit
import Foundation
import Photos

final class PhotoKitPhotosLibraryAdapter: PhotosLibraryAccessPort, @unchecked Sendable {
    private let imageManager = PHCachingImageManager()
    private static let supportedTypes: Set<String> = [
        "public.jpeg",
        "public.png",
        "public.heic",
        "public.heif",
        "public.tiff",
        "org.webmproject.webp",
    ]

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
                guard let resource = preferredStillResource(for: asset) else { continue }
                let type = resource.uniformTypeIdentifier.lowercased()
                guard Self.isSupportedStaticImage(
                    mediaType: asset.mediaType,
                    mediaSubtypes: asset.mediaSubtypes,
                    uniformTypeIdentifier: type
                ) else { continue }

                metadataBatch.append(
                    PhotosAssetMetadata(
                        localIdentifier: asset.localIdentifier,
                        fileName: safeFileName(resource.originalFilename),
                        mediaType: type,
                        width: asset.pixelWidth,
                        height: asset.pixelHeight,
                        createdAtMs: milliseconds(asset.creationDate),
                        modifiedAtMs: milliseconds(asset.modificationDate)
                    )
                )
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

    private func preferredStillResource(for asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        return resources.first(where: { $0.type == .fullSizePhoto })
            ?? resources.first(where: { $0.type == .photo })
            ?? resources.first(where: { $0.type == .alternatePhoto })
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
