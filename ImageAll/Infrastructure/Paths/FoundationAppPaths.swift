import Foundation

struct FoundationAppPathsResolver: AppPathsResolving {
    private let storageLocationStore: UserDefaultsAppStorageLocationStore
    private let onMigrationProgress: (@Sendable (ExternalAppStorageMigrationProgress) -> Void)?
    private let isMigrationCancelled: (@Sendable () -> Bool)?

    init(
        storageLocationStore: UserDefaultsAppStorageLocationStore =
            UserDefaultsAppStorageLocationStore(
                bookmarks: FoundationAppStorageBookmarkAdapter()
            ),
        onMigrationProgress: (@Sendable (ExternalAppStorageMigrationProgress) -> Void)? = nil,
        isMigrationCancelled: (@Sendable () -> Bool)? = nil
    ) {
        self.storageLocationStore = storageLocationStore
        self.onMigrationProgress = onMigrationProgress
        self.isMigrationCancelled = isMigrationCancelled
    }

    func resolvingWithMigrationHooks(
        onProgress: (@Sendable (ExternalAppStorageMigrationProgress) -> Void)?,
        isCancelled: (@Sendable () -> Bool)?
    ) -> any AppPathsResolving {
        FoundationAppPathsResolver(
            storageLocationStore: storageLocationStore,
            onMigrationProgress: onProgress,
            isMigrationCancelled: isCancelled
        )
    }

    func resolve() throws -> AppPaths {
        let internalApplicationSupportDirectory = try resolveDirectory(
            for: .applicationSupportDirectory,
            appendingPath: "ImageAll",
            create: false
        )
        let internalCachesDirectory = try resolveDirectory(
            for: .cachesDirectory,
            appendingPath: "ImageAll",
            create: false
        )
        let storage = try storageLocationStore.resolve(
            internalApplicationSupportDirectory: internalApplicationSupportDirectory,
            internalCachesDirectory: internalCachesDirectory,
            onProgress: onMigrationProgress,
            isCancelled: isMigrationCancelled
        )

        let applicationSupportDirectory = storage.applicationSupportDirectory
        let catalogDirectory = applicationSupportDirectory
            .appendingPathComponent("Catalog", isDirectory: true)
        let backupsDirectory = applicationSupportDirectory
            .appendingPathComponent("Backups", isDirectory: true)
        let runtimeDirectory = applicationSupportDirectory
            .appendingPathComponent("Runtime", isDirectory: true)

        return AppPaths(
            applicationSupportDirectory: applicationSupportDirectory,
            catalogDirectory: catalogDirectory,
            catalogDatabaseURL: catalogDirectory.appendingPathComponent(
                CatalogSnapshotConstants.databaseFilename
            ),
            backupsDirectory: backupsDirectory,
            runtimeDirectory: runtimeDirectory,
            catalogLockFileURL: runtimeDirectory.appendingPathComponent("catalog.lock"),
            cachesDirectory: storage.cachesDirectory,
            storageLocationStatus: storage.status,
            storageAccessLease: storage.accessLease
        )
    }

    func ensureRequiredDirectories(for paths: AppPaths) throws {
        try ensureDirectory(at: paths.catalogDirectory)
        try ensureDirectory(at: paths.backupsDirectory)
        try ensureDirectory(at: paths.runtimeDirectory)
        try assertSameVolume(
            paths.catalogDirectory,
            paths.backupsDirectory,
            paths.runtimeDirectory
        )
    }

    private func resolveDirectory(
        for searchPath: FileManager.SearchPathDirectory,
        appendingPath: String,
        create: Bool
    ) throws -> URL {
        do {
            let base = try FileManager.default.url(
                for: searchPath,
                in: .userDomainMask,
                appropriateFor: nil,
                create: create
            )
            return base.appendingPathComponent(appendingPath, isDirectory: true)
        } catch {
            throw AppPathsError.resolutionFailed
        }
    }

    private func ensureDirectory(at url: URL) throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw AppPathsError.pathNotDirectory
            }
            return
        }

        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw AppPathsError.directoryCreationFailed
        }
    }

    private func assertSameVolume(_ urls: URL...) throws {
        guard let first = urls.first else { return }
        for url in urls.dropFirst() {
            guard try CatalogDatabaseSidecarHelpers.isSameVolume(first, url) else {
                throw AppPathsError.crossVolumeLayoutRejected
            }
        }
    }
}

struct TemporaryAppPathsResolver: AppPathsResolving {
    let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    func resolve() throws -> AppPaths {
        let applicationSupportDirectory = rootURL
            .appendingPathComponent("Application Support/ImageAll", isDirectory: true)
        let cachesDirectory = rootURL
            .appendingPathComponent("Caches/ImageAll", isDirectory: true)
        let catalogDirectory = applicationSupportDirectory
            .appendingPathComponent("Catalog", isDirectory: true)
        let backupsDirectory = applicationSupportDirectory
            .appendingPathComponent("Backups", isDirectory: true)
        let runtimeDirectory = applicationSupportDirectory
            .appendingPathComponent("Runtime", isDirectory: true)

        return AppPaths(
            applicationSupportDirectory: applicationSupportDirectory,
            catalogDirectory: catalogDirectory,
            catalogDatabaseURL: catalogDirectory.appendingPathComponent(
                CatalogSnapshotConstants.databaseFilename
            ),
            backupsDirectory: backupsDirectory,
            runtimeDirectory: runtimeDirectory,
            catalogLockFileURL: runtimeDirectory.appendingPathComponent("catalog.lock"),
            cachesDirectory: cachesDirectory
        )
    }

    func ensureRequiredDirectories(for paths: AppPaths) throws {
        try FoundationAppPathsResolver().ensureRequiredDirectories(for: paths)
    }
}

enum AppStorageLocationError: Error, Equatable, Sendable {
    case invalidRoot
    case authorizationUnavailable
    case staleBookmark
    case directoryCreationFailed
    case bookmarkCreationFailed
    case migrationFailed
    case conflictingDestination
    case cancelled
}

protocol AppStorageBookmarkPort: Sendable {
    func createWriteBookmark(for url: URL) throws -> Data
    func resolveBookmark(_ bookmark: Data) throws -> BookmarkResolveResult
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

struct FoundationAppStorageBookmarkAdapter: AppStorageBookmarkPort {
    func createWriteBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    func resolveBookmark(_ bookmark: Data) throws -> BookmarkResolveResult {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [
                .withSecurityScope,
                .withoutUI,
                .withoutMounting,
                .withoutImplicitStartAccessing,
            ],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return BookmarkResolveResult(url: url, isStale: isStale)
    }

    func startAccessing(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}

@preconcurrency
@MainActor
protocol AppStorageRootPicking: Sendable {
    func pickCacheRoot() -> URL?
}

struct AppStorageExternalPreference: Equatable, Sendable {
    let rootURL: URL
    let bookmark: Data
}

struct AppStorageLocationResolution: Sendable {
    let applicationSupportDirectory: URL
    let cachesDirectory: URL
    let status: AppStorageLocationStatus
    let accessLease: AppStorageSecurityScopeLease?
}

final class AppStorageSecurityScopeLease: AppStorageAccessLease, @unchecked Sendable {
    private let bookmarks: any AppStorageBookmarkPort
    private let url: URL
    private let lock = NSLock()
    private var isActive = true

    init(bookmarks: any AppStorageBookmarkPort, url: URL) {
        self.bookmarks = bookmarks
        self.url = url
    }

    deinit {
        stop()
    }

    func stop() {
        let shouldStop = lock.withLock {
            guard isActive else { return false }
            isActive = false
            return true
        }
        if shouldStop {
            bookmarks.stopAccessing(url)
        }
    }
}

final class UserDefaultsAppStorageLocationStore: @unchecked Sendable {
    private static let bookmarkKey = "app-storage.external-bookmark.v1"
    private static let rootPathKey = "app-storage.external-root-path.v1"
    private static let legacyBookmarkKey = "derived-image-cache.external-bookmark.v1"
    private static let legacyRootPathKey = "derived-image-cache.external-root-path.v1"

    private let defaults: UserDefaults
    private let bookmarks: any AppStorageBookmarkPort
    private let fileManager: FileManager
    private let operationIDProvider: @Sendable () -> UUID

    init(
        defaults: UserDefaults = .standard,
        bookmarks: any AppStorageBookmarkPort,
        fileManager: FileManager = .default,
        operationIDProvider: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.defaults = defaults
        self.bookmarks = bookmarks
        self.fileManager = fileManager
        self.operationIDProvider = operationIDProvider
    }

    func prepareExternalRoot(_ rootURL: URL) throws -> AppStorageExternalPreference {
        let root = rootURL.standardizedFileURL
        try validateDirectory(root)
        guard bookmarks.startAccessing(root) else {
            throw AppStorageLocationError.authorizationUnavailable
        }
        defer { bookmarks.stopAccessing(root) }

        do {
            let probe = root.appendingPathComponent(
                ".imageall-write-probe-\(operationIDProvider().uuidString.lowercased())"
            )
            try Data().write(to: probe, options: .atomic)
            try fileManager.removeItem(at: probe)
        } catch {
            throw AppStorageLocationError.directoryCreationFailed
        }

        do {
            return AppStorageExternalPreference(
                rootURL: root,
                bookmark: try bookmarks.createWriteBookmark(for: root)
            )
        } catch {
            throw AppStorageLocationError.bookmarkCreationFailed
        }
    }

    func commit(_ preference: AppStorageExternalPreference) {
        defaults.set(preference.bookmark, forKey: Self.bookmarkKey)
        defaults.set(preference.rootURL.path, forKey: Self.rootPathKey)
        // Keep the previous preview-cache setting readable by an older local build.
        defaults.set(preference.bookmark, forKey: Self.legacyBookmarkKey)
        defaults.set(preference.rootURL.path, forKey: Self.legacyRootPathKey)
    }

    func resolve(
        internalApplicationSupportDirectory: URL,
        internalCachesDirectory: URL,
        onProgress: (@Sendable (ExternalAppStorageMigrationProgress) -> Void)? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) throws -> AppStorageLocationResolution {
        guard let bookmark = savedBookmark else {
            return internalResolution(
                applicationSupportDirectory: internalApplicationSupportDirectory,
                cachesDirectory: internalCachesDirectory
            )
        }

        let resolved: BookmarkResolveResult
        do {
            resolved = try bookmarks.resolveBookmark(bookmark)
        } catch {
            throw AppStorageLocationError.authorizationUnavailable
        }
        guard !resolved.isStale else {
            throw AppStorageLocationError.staleBookmark
        }

        let root = resolved.url.standardizedFileURL
        try validateDirectory(root)
        guard bookmarks.startAccessing(root) else {
            throw AppStorageLocationError.authorizationUnavailable
        }

        do {
            let migrator = ExternalAppStorageMigrator(
                fileManager: fileManager,
                operationIDProvider: operationIDProvider
            )
            let layout = try migrator.prepare(
                internalApplicationSupportDirectory:
                    internalApplicationSupportDirectory.standardizedFileURL,
                internalCachesDirectory: internalCachesDirectory.standardizedFileURL,
                externalRoot: root,
                onProgress: onProgress,
                isCancelled: isCancelled
            )
            promoteLegacyPreferenceIfNeeded(bookmark: bookmark, resolvedRoot: root)
            let lease = AppStorageSecurityScopeLease(bookmarks: bookmarks, url: root)
            return AppStorageLocationResolution(
                applicationSupportDirectory: layout.applicationSupportDirectory,
                cachesDirectory: layout.cachesDirectory,
                status: AppStorageLocationStatus(
                    applicationSupportDirectoryURL: layout.applicationSupportDirectory,
                    cachesDirectoryURL: layout.cachesDirectory,
                    preferredExternalRootURL: root,
                    usesExternalStorage: true,
                    requiresRestart: false
                ),
                accessLease: lease
            )
        } catch let error as AppStorageLocationError {
            bookmarks.stopAccessing(root)
            throw error
        } catch {
            bookmarks.stopAccessing(root)
            throw AppStorageLocationError.migrationFailed
        }
    }

    func pendingStatus(
        active: AppStorageLocationStatus,
        preference: AppStorageExternalPreference
    ) -> AppStorageLocationStatus {
        let pendingApplicationSupport = Self.applicationSupportDirectory(
            under: preference.rootURL
        )
        let pendingCaches = Self.cacheDirectory(under: preference.rootURL)
        let alreadyActive =
            active.applicationSupportDirectoryURL.standardizedFileURL
                == pendingApplicationSupport.standardizedFileURL
            && active.cachesDirectoryURL.standardizedFileURL
                == pendingCaches.standardizedFileURL
        return AppStorageLocationStatus(
            applicationSupportDirectoryURL: active.applicationSupportDirectoryURL,
            cachesDirectoryURL: active.cachesDirectoryURL,
            preferredExternalRootURL: preference.rootURL,
            usesExternalStorage: active.usesExternalStorage,
            requiresRestart: !alreadyActive
        )
    }

    static func applicationSupportDirectory(under rootURL: URL) -> URL {
        rootURL
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("ImageAll", isDirectory: true)
            .standardizedFileURL
    }

    static func cacheDirectory(under rootURL: URL) -> URL {
        rootURL
            .appendingPathComponent(
                DerivedImageCachePathLayout.cachesParentComponent,
                isDirectory: true
            )
            .appendingPathComponent(
                DerivedImageCachePathLayout.cachesLeafComponent,
                isDirectory: true
            )
            .standardizedFileURL
    }

    private var savedBookmark: Data? {
        defaults.data(forKey: Self.bookmarkKey)
            ?? defaults.data(forKey: Self.legacyBookmarkKey)
    }

    private func promoteLegacyPreferenceIfNeeded(bookmark: Data, resolvedRoot: URL) {
        guard defaults.data(forKey: Self.bookmarkKey) == nil else { return }
        defaults.set(bookmark, forKey: Self.bookmarkKey)
        defaults.set(resolvedRoot.path, forKey: Self.rootPathKey)
    }

    private func internalResolution(
        applicationSupportDirectory: URL,
        cachesDirectory: URL
    ) -> AppStorageLocationResolution {
        let support = applicationSupportDirectory.standardizedFileURL
        let caches = cachesDirectory.standardizedFileURL
        return AppStorageLocationResolution(
            applicationSupportDirectory: support,
            cachesDirectory: caches,
            status: AppStorageLocationStatus(
                applicationSupportDirectoryURL: support,
                cachesDirectoryURL: caches,
                preferredExternalRootURL: nil,
                usesExternalStorage: false,
                requiresRestart: false
            ),
            accessLease: nil
        )
    }

    private func validateDirectory(_ url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw AppStorageLocationError.invalidRoot
        }
        let values: URLResourceValues
        do {
            values = try url.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                    .isAliasFileKey,
                    .isPackageKey,
                ]
            )
        } catch {
            throw AppStorageLocationError.invalidRoot
        }
        guard values.isDirectory == true,
              values.isSymbolicLink != true,
              values.isAliasFile != true,
              values.isPackage != true
        else {
            throw AppStorageLocationError.invalidRoot
        }
    }
}

private struct ExternalAppStorageLayout {
    let applicationSupportDirectory: URL
    let cachesDirectory: URL
}

private struct ExternalAppStorageMigrator {
    let fileManager: FileManager
    let operationIDProvider: @Sendable () -> UUID

    func prepare(
        internalApplicationSupportDirectory: URL,
        internalCachesDirectory: URL,
        externalRoot: URL,
        onProgress: (@Sendable (ExternalAppStorageMigrationProgress) -> Void)? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) throws -> ExternalAppStorageLayout {
        var progress = ExternalAppStorageMigrationProgress.zero
        func report(_ update: (inout ExternalAppStorageMigrationProgress) -> Void) throws {
            if isCancelled?() == true {
                progress.phase = .cancelled
                onProgress?(progress)
                throw AppStorageLocationError.cancelled
            }
            update(&progress)
            onProgress?(progress)
        }

        try report { $0.phase = .preparing }

        let support = UserDefaultsAppStorageLocationStore.applicationSupportDirectory(
            under: externalRoot
        )
        let caches = UserDefaultsAppStorageLocationStore.cacheDirectory(under: externalRoot)

        let supportEstimate = estimateWorkload(at: internalApplicationSupportDirectory)
        let cacheEstimate = estimateWorkload(at: internalCachesDirectory)
        try report {
            $0.totalBytes = supportEstimate.bytes + cacheEstimate.bytes
            $0.totalFiles = supportEstimate.files + cacheEstimate.files
        }

        try ensureDirectory(at: support.deletingLastPathComponent())
        try report { $0.phase = .copyingApplicationSupport }
        try migrateApplicationSupportIfNeeded(
            source: internalApplicationSupportDirectory,
            destination: support,
            estimatedBytes: supportEstimate.bytes,
            estimatedFiles: supportEstimate.files,
            report: report
        )
        try ensureDirectory(at: support)

        try ensureDirectory(at: caches.deletingLastPathComponent())
        try ensureDirectory(at: caches)
        let completionMarker = support
            .appendingPathComponent("Runtime", isDirectory: true)
            .appendingPathComponent("external-storage-v1.complete")
        if !fileManager.fileExists(atPath: completionMarker.path) {
            try report { $0.phase = .convergingSQLite }
            try convergeCopiedSQLiteIfPresent(
                at: support.appendingPathComponent("Catalog/ImageAll.sqlite")
            )
            try report { $0.phase = .mergingCaches }
            try mergeCacheDirectory(
                source: internalCachesDirectory,
                destination: caches,
                report: report
            )
            try report { $0.phase = .writingCompletionMarker }
            try ensureDirectory(at: completionMarker.deletingLastPathComponent())
            do {
                try Data("v1\n".utf8).write(to: completionMarker, options: .atomic)
            } catch {
                try report { $0.phase = .failed }
                throw AppStorageLocationError.migrationFailed
            }
        }

        try report {
            $0.phase = .completed
            $0.bytesCopied = max($0.bytesCopied, $0.totalBytes)
            $0.filesCopied = max($0.filesCopied, $0.totalFiles)
        }

        return ExternalAppStorageLayout(
            applicationSupportDirectory: support,
            cachesDirectory: caches
        )
    }

    private func migrateApplicationSupportIfNeeded(
        source: URL,
        destination: URL,
        estimatedBytes: Int64,
        estimatedFiles: Int,
        report: (@escaping ((inout ExternalAppStorageMigrationProgress) -> Void) throws -> Void)
    ) throws {
        if fileManager.fileExists(atPath: destination.path) {
            try validateDirectory(destination)
            if try !directoryIsEmpty(destination) {
                guard fileManager.fileExists(
                    atPath: destination
                        .appendingPathComponent("Catalog/ImageAll.sqlite")
                        .path
                ) else {
                    throw AppStorageLocationError.conflictingDestination
                }
                try report {
                    $0.bytesCopied += estimatedBytes
                    $0.filesCopied += estimatedFiles
                }
                return
            }
            try fileManager.removeItem(at: destination)
        }

        guard fileManager.fileExists(atPath: source.path) else {
            try ensureDirectory(at: destination)
            return
        }
        try validateDirectory(source)
        try report { _ in }

        let staging = destination.deletingLastPathComponent().appendingPathComponent(
            ".ImageAll.migration-\(operationIDProvider().uuidString.lowercased())",
            isDirectory: true
        )
        guard !fileManager.fileExists(atPath: staging.path) else {
            throw AppStorageLocationError.conflictingDestination
        }

        do {
            try fileManager.copyItem(at: source, to: staging)
            try verifyDirectoryCopy(source: source, destination: staging)
            try fileManager.moveItem(at: staging, to: destination)
            try report {
                $0.bytesCopied += estimatedBytes
                $0.filesCopied += estimatedFiles
            }
        } catch let error as AppStorageLocationError {
            if fileManager.fileExists(atPath: staging.path) {
                try? fileManager.removeItem(at: staging)
            }
            throw error
        } catch {
            if fileManager.fileExists(atPath: staging.path) {
                try? fileManager.removeItem(at: staging)
            }
            throw AppStorageLocationError.migrationFailed
        }
    }

    private func mergeCacheDirectory(
        source: URL,
        destination: URL,
        report: (@escaping ((inout ExternalAppStorageMigrationProgress) -> Void) throws -> Void)
    ) throws {
        guard fileManager.fileExists(atPath: source.path) else {
            try ensureDirectory(at: destination)
            return
        }
        try validateDirectory(source)
        try ensureDirectory(at: destination)

        guard let enumerator = fileManager.enumerator(
            at: source,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .isAliasFileKey,
                .fileSizeKey,
            ],
            options: [.skipsHiddenFiles]
        ) else {
            throw AppStorageLocationError.migrationFailed
        }

        for case let sourceItem as URL in enumerator {
            try report { _ in }
            let values = try sourceItem.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .isAliasFileKey,
                    .fileSizeKey,
                ]
            )
            guard values.isSymbolicLink != true, values.isAliasFile != true else {
                throw AppStorageLocationError.migrationFailed
            }
            let relativePath = try relativePath(of: sourceItem, under: source)
            let destinationItem = destination.appendingPathComponent(relativePath)
            if values.isDirectory == true {
                try ensureDirectory(at: destinationItem)
            } else if values.isRegularFile == true {
                try copyCacheFileIfNeeded(
                    source: sourceItem,
                    destination: destinationItem
                )
                let fileBytes = Int64(values.fileSize ?? 0)
                try report {
                    $0.bytesCopied += fileBytes
                    $0.filesCopied += 1
                }
            }
        }
    }

    private func estimateWorkload(at root: URL) -> (bytes: Int64, files: Int) {
        guard fileManager.fileExists(atPath: root.path),
              let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [
                    .isRegularFileKey,
                    .fileSizeKey,
                    .isSymbolicLinkKey,
                    .isAliasFileKey,
                ],
                options: [.skipsHiddenFiles]
              )
        else {
            return (0, 0)
        }
        var bytes: Int64 = 0
        var files = 0
        for case let item as URL in enumerator {
            guard let values = try? item.resourceValues(
                forKeys: [
                    .isRegularFileKey,
                    .fileSizeKey,
                    .isSymbolicLinkKey,
                    .isAliasFileKey,
                ]
            ) else {
                continue
            }
            guard values.isSymbolicLink != true, values.isAliasFile != true else {
                continue
            }
            if values.isRegularFile == true {
                files += 1
                bytes += Int64(values.fileSize ?? 0)
            }
        }
        return (bytes, files)
    }

    private func convergeCopiedSQLiteIfPresent(at databaseURL: URL) throws {
        guard fileManager.fileExists(atPath: databaseURL.path) else { return }
        let header: Data
        do {
            let handle = try FileHandle(forReadingFrom: databaseURL)
            header = try handle.read(upToCount: 16) ?? Data()
            try handle.close()
        } catch {
            throw AppStorageLocationError.migrationFailed
        }
        guard header == Data("SQLite format 3\u{0}".utf8) else { return }

        do {
            let database = try CatalogDatabase.openWithoutMigration(at: databaseURL)
            try database.checkpointAndCloseForReplacement()
            switch try CatalogDatabase.inspectFormalDatabase(at: databaseURL) {
            case .currentSchema, .knownOldPrefix:
                return
            case .missing, .unsupportedSchema, .integrityFailed:
                throw AppStorageLocationError.migrationFailed
            }
        } catch let error as AppStorageLocationError {
            throw error
        } catch {
            throw AppStorageLocationError.migrationFailed
        }
    }

    private func copyCacheFileIfNeeded(source: URL, destination: URL) throws {
        try ensureDirectory(at: destination.deletingLastPathComponent())
        if fileManager.fileExists(atPath: destination.path) {
            guard try filesMatch(source, destination) else {
                throw AppStorageLocationError.conflictingDestination
            }
            return
        }

        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).migration-\(operationIDProvider().uuidString.lowercased())"
        )
        do {
            try fileManager.copyItem(at: source, to: temporary)
            guard try filesMatch(source, temporary) else {
                throw AppStorageLocationError.migrationFailed
            }
            try fileManager.moveItem(at: temporary, to: destination)
        } catch let error as AppStorageLocationError {
            if fileManager.fileExists(atPath: temporary.path) {
                try? fileManager.removeItem(at: temporary)
            }
            throw error
        } catch {
            if fileManager.fileExists(atPath: temporary.path) {
                try? fileManager.removeItem(at: temporary)
            }
            throw AppStorageLocationError.migrationFailed
        }
    }

    private func verifyDirectoryCopy(source: URL, destination: URL) throws {
        guard let enumerator = fileManager.enumerator(
            at: source,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .isAliasFileKey,
            ]
        ) else {
            throw AppStorageLocationError.migrationFailed
        }

        for case let sourceItem as URL in enumerator {
            let values = try sourceItem.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .isAliasFileKey,
                ]
            )
            guard values.isSymbolicLink != true, values.isAliasFile != true else {
                throw AppStorageLocationError.migrationFailed
            }
            let relativePath = try relativePath(of: sourceItem, under: source)
            let destinationItem = destination.appendingPathComponent(relativePath)
            if values.isDirectory == true {
                try validateDirectory(destinationItem)
            } else if values.isRegularFile == true {
                guard fileManager.fileExists(atPath: destinationItem.path),
                      try filesMatch(sourceItem, destinationItem)
                else {
                    throw AppStorageLocationError.migrationFailed
                }
            }
        }
    }

    private func relativePath(of item: URL, under root: URL) throws -> String {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedItem = item.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
        guard resolvedItem.hasPrefix(prefix) else {
            throw AppStorageLocationError.migrationFailed
        }
        let relative = String(resolvedItem.dropFirst(prefix.count))
        guard !relative.isEmpty,
              case .success = RelativePathRules.validate(relative)
        else {
            throw AppStorageLocationError.migrationFailed
        }
        return relative
    }

    private func filesMatch(_ lhs: URL, _ rhs: URL) throws -> Bool {
        try CatalogSnapshotHashing.fileSize(of: lhs)
            == CatalogSnapshotHashing.fileSize(of: rhs)
            && CatalogSnapshotHashing.sha256Hex(of: lhs)
                == CatalogSnapshotHashing.sha256Hex(of: rhs)
    }

    private func directoryIsEmpty(_ url: URL) throws -> Bool {
        try fileManager.contentsOfDirectory(atPath: url.path).isEmpty
    }

    private func ensureDirectory(at url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            try validateDirectory(url)
            return
        }
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            try validateDirectory(url)
        } catch let error as AppStorageLocationError {
            throw error
        } catch {
            throw AppStorageLocationError.directoryCreationFailed
        }
    }

    private func validateDirectory(_ url: URL) throws {
        let values = try url.resourceValues(
            forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .isAliasFileKey,
            ]
        )
        guard values.isDirectory == true,
              values.isSymbolicLink != true,
              values.isAliasFile != true
        else {
            throw AppStorageLocationError.invalidRoot
        }
    }
}

final class AppStorageLocationController: @unchecked Sendable {
    let activeStatus: AppStorageLocationStatus
    private let picker: any AppStorageRootPicking
    private let store: UserDefaultsAppStorageLocationStore

    init(
        picker: any AppStorageRootPicking,
        store: UserDefaultsAppStorageLocationStore,
        activeStatus: AppStorageLocationStatus
    ) {
        self.picker = picker
        self.store = store
        self.activeStatus = activeStatus
    }

    @MainActor
    func chooseExternalLocation() async throws -> AppStorageLocationSelectionResult {
        guard let selectedRoot = picker.pickCacheRoot() else {
            return .cancelled
        }
        let preference = try store.prepareExternalRoot(selectedRoot)
        store.commit(preference)
        return .restartRequired(
            store.pendingStatus(active: activeStatus, preference: preference)
        )
    }
}
