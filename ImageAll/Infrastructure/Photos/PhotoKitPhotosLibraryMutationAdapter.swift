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

    func moveToRecentlyDeleted(localIdentifiers: [String]) throws -> [String] {
        try requireAuthorized()
        let identifiers = normalized(localIdentifiers)
        guard !identifiers.isEmpty else { return [] }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var assets: [PHAsset] = []
        assets.reserveCapacity(fetch.count)
        fetch.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        let fetchedIdentifiers = Set(assets.map(\.localIdentifier))
        guard fetchedIdentifiers == Set(identifiers) else {
            throw PhotosLibraryMutationError.assetNotFound
        }
        do {
            try PHPhotoLibrary.shared().performChangesAndWait {
                PHAssetChangeRequest.deleteAssets(assets as NSArray)
            }
        } catch {
            throw PhotosLibraryMutationError.changeFailed
        }
        return identifiers
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
        return .missing
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
        Array(Set(localIdentifiers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }))
            .sorted()
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
