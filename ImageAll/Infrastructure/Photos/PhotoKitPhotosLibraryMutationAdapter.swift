import Foundation
import Photos

/// The only production module allowed to call PhotoKit mutation APIs
/// (`PHAssetChangeRequest` / `performChanges` / `deleteAssets`).
final class PhotoKitPhotosLibraryMutationAdapter: PhotosLibraryMutationPort, @unchecked Sendable {
    func authorizationState() -> PhotosAuthorizationState {
        mapAuthorization(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestAuthorization() async -> PhotosAuthorizationState {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return mapAuthorization(status)
    }

    func moveToRecentlyDeleted(localIdentifiers: [String]) throws {
        try requireAuthorized()
        let identifiers = normalized(localIdentifiers)
        guard !identifiers.isEmpty else { return }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        guard fetch.count > 0 else {
            throw PhotosLibraryMutationError.assetNotFound
        }
        var assets: [PHAsset] = []
        assets.reserveCapacity(fetch.count)
        fetch.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        do {
            try PHPhotoLibrary.shared().performChangesAndWait {
                PHAssetChangeRequest.deleteAssets(assets as NSArray)
            }
        } catch {
            throw PhotosLibraryMutationError.changeFailed
        }
    }

    func presence(localIdentifier: String) throws -> PhotosAssetPresence {
        try requireAuthorized()
        let identifier = localIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else {
            return .missing
        }
        let live = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        if live.count > 0 {
            return .available
        }
        if recentlyDeletedAsset(localIdentifier: identifier) != nil {
            return .recentlyDeleted
        }
        return .missing
    }

    func permanentlyDeleteFromRecentlyDeleted(localIdentifiers: [String]) throws {
        try requireAuthorized()
        let identifiers = normalized(localIdentifiers)
        guard !identifiers.isEmpty else { return }
        var assets: [PHAsset] = []
        for identifier in identifiers {
            if let asset = recentlyDeletedAsset(localIdentifier: identifier) {
                assets.append(asset)
            }
        }
        guard !assets.isEmpty else {
            throw PhotosLibraryMutationError.assetNotFound
        }
        do {
            try PHPhotoLibrary.shared().performChangesAndWait {
                PHAssetChangeRequest.deleteAssets(assets as NSArray)
            }
        } catch {
            throw PhotosLibraryMutationError.changeFailed
        }
    }

    private func requireAuthorized() throws {
        switch authorizationState() {
        case .authorized:
            return
        case .denied:
            throw PhotosLibraryMutationError.authorizationDenied
        case .restricted:
            throw PhotosLibraryMutationError.authorizationRestricted
        case .notDetermined:
            throw PhotosLibraryMutationError.notDetermined
        }
    }

    private func normalized(_ localIdentifiers: [String]) -> [String] {
        localIdentifiers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func recentlyDeletedAsset(localIdentifier: String) -> PHAsset? {
        // macOS PhotoKit does not expose `.smartAlbumRecentlyDeleted`; use the
        // documented-adjacent raw subtype used by the system Recently Deleted album.
        guard let recentlyDeletedSubtype = PHAssetCollectionSubtype(rawValue: 1_000_000_201) else {
            return nil
        }
        let collections = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum,
            subtype: recentlyDeletedSubtype,
            options: nil
        )
        guard let album = collections.firstObject else {
            return nil
        }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "localIdentifier == %@", localIdentifier)
        let fetch = PHAsset.fetchAssets(in: album, options: options)
        return fetch.firstObject
    }

    private func mapAuthorization(_ status: PHAuthorizationStatus) -> PhotosAuthorizationState {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .restricted:
            return .restricted
        case .denied:
            return .denied
        case .authorized, .limited:
            return .authorized
        @unknown default:
            return .denied
        }
    }
}
