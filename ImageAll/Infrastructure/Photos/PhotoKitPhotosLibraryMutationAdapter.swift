import AppKit
import Foundation
import OSLog
import Photos

/// The only production module allowed to call PhotoKit mutation APIs
/// (`PHAssetChangeRequest` / `performChanges` / `deleteAssets`).
final class PhotoKitPhotosLibraryMutationAdapter: PhotosLibraryMutationPort, @unchecked Sendable {
    private static let logger = Logger(
        subsystem: "com.gwlee.ImageAll",
        category: "PhotosMutation"
    )

    func authorizationState() -> PhotosAuthorizationState {
        Self.mapAuthorizationForMutation(
            PHPhotoLibrary.authorizationStatus(for: .readWrite)
        )
    }

    func requestAuthorization() async -> PhotosAuthorizationState {
        await MainActor.run {
            Self.activateAppForSystemPrompt()
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
        // PhotoKit owns the confirmation alert. Make the App key before submitting
        // the synchronous background mutation so the alert cannot race an async
        // activation request and end up invisible behind another window.
        activateAppForSystemPromptAndWait()
        do {
            try PHPhotoLibrary.shared().performChangesAndWait {
                PHAssetChangeRequest.deleteAssets(assets as NSArray)
            }
        } catch {
            let diagnostic = Self.mapMutationFailure(error as NSError)
            Self.logger.error(
                "PhotoKit mutation failed category=\(diagnostic.category.rawValue, privacy: .public) domain=\(diagnostic.domain, privacy: .public) code=\(diagnostic.code, privacy: .public)"
            )
            throw PhotosLibraryMutationError.systemChangeFailed(diagnostic)
        }
        return identifiers
    }

    func setFavorite(
        localIdentifiers: [String],
        isFavorite: Bool
    ) throws -> [String: PhotosFavoriteObservation] {
        try requireAuthorized()
        let identifiers = normalized(localIdentifiers)
        guard !identifiers.isEmpty else { return [:] }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var assets: [PHAsset] = []
        assets.reserveCapacity(fetch.count)
        fetch.enumerateObjects { asset, _, _ in assets.append(asset) }
        guard Set(assets.map(\.localIdentifier)) == Set(identifiers) else {
            throw PhotosLibraryMutationError.assetNotFound
        }
        do {
            try PHPhotoLibrary.shared().performChangesAndWait {
                for asset in assets {
                    PHAssetChangeRequest(for: asset).isFavorite = isFavorite
                }
            }
        } catch {
            let diagnostic = Self.mapMutationFailure(error as NSError)
            Self.logger.error(
                "PhotoKit favorite mutation failed category=\(diagnostic.category.rawValue, privacy: .public) domain=\(diagnostic.domain, privacy: .public) code=\(diagnostic.code, privacy: .public)"
            )
            throw PhotosLibraryMutationError.systemChangeFailed(diagnostic)
        }

        let verified = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var observations: [String: PhotosFavoriteObservation] = [:]
        observations.reserveCapacity(verified.count)
        verified.enumerateObjects { asset, _, _ in
            observations[asset.localIdentifier] = PhotosFavoriteObservation(
                isFavorite: asset.isFavorite,
                modifiedAtMs: asset.modificationDate.map {
                    Int64($0.timeIntervalSince1970 * 1_000)
                }
            )
        }
        guard observations.count == identifiers.count,
              observations.values.allSatisfy({ $0.isFavorite == isFavorite })
        else {
            throw PhotosLibraryMutationError.changeFailed
        }
        return observations
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

    private func activateAppForSystemPromptAndWait() {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                Self.activateAppForSystemPrompt()
            }
        } else {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    Self.activateAppForSystemPrompt()
                }
            }
        }
    }

    @MainActor
    private static func activateAppForSystemPrompt() {
        NSApp?.activate(ignoringOtherApps: true)
        NSApp?.mainWindow?.makeKeyAndOrderFront(nil)
    }

    static func mapMutationFailure(
        _ error: NSError
    ) -> PhotosLibraryMutationFailureDiagnostic {
        let category: PhotosLibraryMutationFailureCategory
        if error.domain == PHPhotosError.errorDomain,
           let photosCode = PHPhotosError.Code(rawValue: error.code)
        {
            switch photosCode {
            case .userCancelled:
                category = .userCancelled
            case .accessRestricted, .accessUserDenied:
                category = .authorization
            case .libraryVolumeOffline,
                    .relinquishingLibraryBundleToWriter,
                    .switchingSystemPhotoLibrary:
                category = .libraryUnavailable
            case .changeNotSupported, .requestNotSupportedForAsset:
                category = .unsupported
            default:
                category = .system
            }
        } else {
            category = .system
        }
        return PhotosLibraryMutationFailureDiagnostic(
            category: category,
            domain: error.domain,
            code: error.code
        )
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
