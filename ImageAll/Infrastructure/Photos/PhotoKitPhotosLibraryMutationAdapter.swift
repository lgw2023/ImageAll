import AppKit
import Foundation
import Photos

/// The only production module allowed to call PhotoKit mutation APIs
/// (`PHAssetChangeRequest` / `performChanges` / `deleteAssets`).
final class PhotoKitPhotosLibraryMutationAdapter: PhotosLibraryMutationPort, @unchecked Sendable {
    func authorizationState() -> PhotosAuthorizationState {
        Self.mapAuthorizationForMutation(
            PHPhotoLibrary.authorizationStatus(for: .readWrite)
        )
    }

    func requestAuthorization() async -> PhotosAuthorizationState {
        await MainActor.run {
            NSApp?.activate(ignoringOtherApps: true)
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return Self.mapAuthorizationForMutation(status)
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
        // Bring ImageAll forward so the system delete confirmation is visible.
        // Use async activate when off the main thread to avoid nested sync deadlocks.
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                NSApp?.activate(ignoringOtherApps: true)
            }
        } else {
            DispatchQueue.main.async {
                NSApp?.activate(ignoringOtherApps: true)
            }
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
        let identifier = localIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else { return .missing }
        return try presences(localIdentifiers: [identifier])[identifier] ?? .missing
    }

    func presences(
        localIdentifiers: [String]
    ) throws -> [String: PhotosAssetPresence] {
        try requireAuthorized()
        let identifiers = normalized(localIdentifiers)
        guard !identifiers.isEmpty else { return [:] }
        let live = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var availableIdentifiers = Set<String>()
        availableIdentifiers.reserveCapacity(live.count)
        live.enumerateObjects { asset, _, _ in
            availableIdentifiers.insert(asset.localIdentifier)
        }
        return Dictionary(
            uniqueKeysWithValues: identifiers.map { identifier in
                (
                    identifier,
                    availableIdentifiers.contains(identifier) ? .available : .missing
                )
            }
        )
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

    static func mapAuthorizationForMutation(
        _ status: PHAuthorizationStatus
    ) -> PhotosAuthorizationState {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .restricted:
            return .restricted
        case .denied:
            return .denied
        case .authorized:
            return .authorized
        case .limited:
            // Limited library access is readable for catalog, but mutation
            // (move to Recently Deleted) requires full read-write authorization.
            // It is already a determined state, so retrying the system request
            // cannot upgrade it; the UI must direct the user to System Settings.
            return .denied
        @unknown default:
            return .denied
        }
    }
}
