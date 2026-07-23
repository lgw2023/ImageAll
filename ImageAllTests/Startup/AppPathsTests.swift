import XCTest
@testable import ImageAll

final class AppPathsTests: XCTestCase {
    func testExternalAppStorageSelectionMigratesApplicationSupportAndAllCachesAcrossRestart() throws {
        let root = try StartupTestSupport.makeTempRoot(testCase: self)
        let internalSupport = root
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("ImageAll", isDirectory: true)
        let internalCaches = root
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("ImageAll", isDirectory: true)
        let externalRoot = root.appendingPathComponent("SSD1", isDirectory: true)
        try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: internalSupport.appendingPathComponent("Catalog", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: internalSupport.appendingPathComponent("PersonalModels", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: internalCaches.appendingPathComponent("Features", isDirectory: true),
            withIntermediateDirectories: true
        )
        let existingExternalThumbnail = UserDefaultsAppStorageLocationStore
            .cacheDirectory(under: externalRoot)
            .appendingPathComponent("DerivedImages/thumbnail.bin")
        try FileManager.default.createDirectory(
            at: existingExternalThumbnail.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("catalog".utf8).write(
            to: internalSupport.appendingPathComponent("Catalog/ImageAll.sqlite")
        )
        try Data("model".utf8).write(
            to: internalSupport.appendingPathComponent("PersonalModels/model.bin")
        )
        try Data("feature".utf8).write(
            to: internalCaches.appendingPathComponent("Features/feature.bin")
        )
        try Data("thumbnail".utf8).write(to: existingExternalThumbnail)

        let suiteName = "AppPathsTests.external-storage.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let bookmarks = FakeAppStorageBookmarkPort()
        let store = UserDefaultsAppStorageLocationStore(
            defaults: defaults,
            bookmarks: bookmarks
        )

        let preference = try store.prepareExternalRoot(externalRoot)
        store.commit(preference)
        let resolution = try store.resolve(
            internalApplicationSupportDirectory: internalSupport,
            internalCachesDirectory: internalCaches
        )

        XCTAssertEqual(
            resolution.applicationSupportDirectory.standardizedFileURL,
            externalRoot
                .appendingPathComponent("Application Support/ImageAll", isDirectory: true)
                .standardizedFileURL
        )
        XCTAssertEqual(
            resolution.cachesDirectory.standardizedFileURL,
            externalRoot
                .appendingPathComponent("Caches/ImageAll", isDirectory: true)
                .standardizedFileURL
        )
        XCTAssertTrue(resolution.status.usesExternalStorage)
        XCTAssertFalse(resolution.status.requiresRestart)
        XCTAssertEqual(
            try Data(contentsOf: resolution.applicationSupportDirectory
                .appendingPathComponent("Catalog/ImageAll.sqlite")),
            Data("catalog".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: resolution.applicationSupportDirectory
                .appendingPathComponent("PersonalModels/model.bin")),
            Data("model".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: resolution.cachesDirectory
                .appendingPathComponent("Features/feature.bin")),
            Data("feature".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: resolution.cachesDirectory
                .appendingPathComponent("DerivedImages/thumbnail.bin")),
            Data("thumbnail".utf8)
        )
        XCTAssertEqual(bookmarks.createdURLs, [externalRoot.standardizedFileURL])
        XCTAssertEqual(bookmarks.startedURLs.count, 2)
        XCTAssertEqual(bookmarks.stoppedURLs.count, 1)
        XCTAssertNotNil(resolution.accessLease)
    }

    func testUnavailableExternalAppStorageFailsClosedInsteadOfOpeningEmptyInternalCatalog() throws {
        let root = try StartupTestSupport.makeTempRoot(testCase: self)
        let internalSupport = root
            .appendingPathComponent("Library/Application Support/ImageAll", isDirectory: true)
        let internalCaches = root
            .appendingPathComponent("Library/Caches/ImageAll", isDirectory: true)
        let externalRoot = root.appendingPathComponent("SSD1", isDirectory: true)
        try FileManager.default.createDirectory(
            at: externalRoot,
            withIntermediateDirectories: true
        )
        let suiteName = "AppPathsTests.external-storage-fail-closed.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let bookmarks = FakeAppStorageBookmarkPort(
            startResults: [true, false]
        )
        let store = UserDefaultsAppStorageLocationStore(
            defaults: defaults,
            bookmarks: bookmarks
        )

        store.commit(try store.prepareExternalRoot(externalRoot))
        XCTAssertThrowsError(
            try store.resolve(
                internalApplicationSupportDirectory: internalSupport,
                internalCachesDirectory: internalCaches
            )
        ) { error in
            XCTAssertEqual(error as? AppStorageLocationError, .authorizationUnavailable)
        }
    }

    func testLegacyPreviewCachePreferenceIsPromotedToUnifiedAppStoragePreference() throws {
        let root = try StartupTestSupport.makeTempRoot(testCase: self)
        let internalSupport = root
            .appendingPathComponent("Library/Application Support/ImageAll", isDirectory: true)
        let internalCaches = root
            .appendingPathComponent("Library/Caches/ImageAll", isDirectory: true)
        let externalRoot = root.appendingPathComponent("SSD1", isDirectory: true)
        try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)
        let suiteName = "AppPathsTests.legacy-storage-promotion.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let bookmark = Data(externalRoot.standardizedFileURL.path.utf8)
        defaults.set(bookmark, forKey: "derived-image-cache.external-bookmark.v1")
        defaults.set(
            externalRoot.standardizedFileURL.path,
            forKey: "derived-image-cache.external-root-path.v1"
        )
        let store = UserDefaultsAppStorageLocationStore(
            defaults: defaults,
            bookmarks: FakeAppStorageBookmarkPort()
        )

        _ = try store.resolve(
            internalApplicationSupportDirectory: internalSupport,
            internalCachesDirectory: internalCaches
        )

        XCTAssertEqual(
            defaults.data(forKey: "app-storage.external-bookmark.v1"),
            bookmark
        )
        XCTAssertEqual(
            defaults.string(forKey: "app-storage.external-root-path.v1"),
            externalRoot.standardizedFileURL.path
        )
    }

    func testCompletedExternalMigrationDoesNotRescanLegacyInternalCacheOnLaterLaunch() throws {
        let root = try StartupTestSupport.makeTempRoot(testCase: self)
        let internalSupport = root
            .appendingPathComponent("Library/Application Support/ImageAll", isDirectory: true)
        let internalCaches = root
            .appendingPathComponent("Library/Caches/ImageAll", isDirectory: true)
        let externalRoot = root.appendingPathComponent("SSD1", isDirectory: true)
        try FileManager.default.createDirectory(
            at: internalSupport.appendingPathComponent("Catalog", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: internalCaches.appendingPathComponent("Features", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)
        try Data("catalog".utf8).write(
            to: internalSupport.appendingPathComponent("Catalog/ImageAll.sqlite")
        )
        try Data("first".utf8).write(
            to: internalCaches.appendingPathComponent("Features/first.bin")
        )
        let suiteName = "AppPathsTests.completed-storage.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = UserDefaultsAppStorageLocationStore(
            defaults: defaults,
            bookmarks: FakeAppStorageBookmarkPort()
        )
        store.commit(try store.prepareExternalRoot(externalRoot))

        let firstResolution = try store.resolve(
            internalApplicationSupportDirectory: internalSupport,
            internalCachesDirectory: internalCaches
        )
        firstResolution.accessLease?.stop()
        try Data("late".utf8).write(
            to: internalCaches.appendingPathComponent("Features/late.bin")
        )

        let secondResolution = try store.resolve(
            internalApplicationSupportDirectory: internalSupport,
            internalCachesDirectory: internalCaches
        )

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: secondResolution.cachesDirectory
                    .appendingPathComponent("Features/late.bin")
                    .path
            )
        )
    }

    func testExternalMigrationConvergesCopiedCatalogBeforeFirstOpen() throws {
        let root = try StartupTestSupport.makeTempRoot(testCase: self)
        let internalSupport = root
            .appendingPathComponent("Library/Application Support/ImageAll", isDirectory: true)
        let internalCaches = root
            .appendingPathComponent("Library/Caches/ImageAll", isDirectory: true)
        let internalDatabaseURL = internalSupport
            .appendingPathComponent("Catalog/ImageAll.sqlite")
        let externalRoot = root.appendingPathComponent("SSD1", isDirectory: true)
        try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)
        let database = try SnapshotTestSupport.openLiveDatabase(at: internalDatabaseURL)
        defer { try? database.pool.close() }
        _ = try SnapshotTestSupport.seedRepresentativeFacts(in: database)
        let suiteName = "AppPathsTests.catalog-convergence.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = UserDefaultsAppStorageLocationStore(
            defaults: defaults,
            bookmarks: FakeAppStorageBookmarkPort()
        )
        store.commit(try store.prepareExternalRoot(externalRoot))

        let resolution = try store.resolve(
            internalApplicationSupportDirectory: internalSupport,
            internalCachesDirectory: internalCaches
        )
        let externalDatabaseURL = resolution.applicationSupportDirectory
            .appendingPathComponent("Catalog/ImageAll.sqlite")

        XCTAssertEqual(
            try CatalogDatabase.inspectFormalDatabase(at: externalDatabaseURL),
            .currentSchema
        )
        XCTAssertFalse(
            CatalogDatabaseSidecarHelpers.hasSidecars(at: externalDatabaseURL)
        )
        XCTAssertEqual(
            try SnapshotTestSupport.factCounts(at: externalDatabaseURL),
            try SnapshotTestSupport.factCounts(in: database)
        )
    }

    @MainActor
    func testAppStorageLocationControllerCommitsSelectionWithoutClearingExistingCache() async throws {
        let root = try StartupTestSupport.makeTempRoot(testCase: self)
        let internalSupport = root
            .appendingPathComponent("Library/Application Support/ImageAll", isDirectory: true)
        let internalCaches = root
            .appendingPathComponent("Library/Caches/ImageAll", isDirectory: true)
        let externalRoot = root.appendingPathComponent("SSD1", isDirectory: true)
        try FileManager.default.createDirectory(
            at: externalRoot,
            withIntermediateDirectories: true
        )
        let suiteName = "AppPathsTests.external-storage-controller.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let bookmarks = FakeAppStorageBookmarkPort()
        let store = UserDefaultsAppStorageLocationStore(
            defaults: defaults,
            bookmarks: bookmarks
        )
        let controller = AppStorageLocationController(
            picker: FakeAppStorageRootPicker(selectedURL: externalRoot),
            store: store,
            activeStatus: AppStorageLocationStatus(
                applicationSupportDirectoryURL: internalSupport,
                cachesDirectoryURL: internalCaches,
                preferredExternalRootURL: nil,
                usesExternalStorage: false,
                requiresRestart: false
            )
        )

        let result = try await controller.chooseExternalLocation()

        guard case let .restartRequired(status) = result else {
            return XCTFail("expected restart requirement")
        }
        XCTAssertEqual(status.preferredExternalRootURL, externalRoot.standardizedFileURL)
        XCTAssertTrue(status.requiresRestart)
        let restartResolution = try store.resolve(
            internalApplicationSupportDirectory: internalSupport,
            internalCachesDirectory: internalCaches
        )
        XCTAssertEqual(
            restartResolution.cachesDirectory,
            UserDefaultsAppStorageLocationStore.cacheDirectory(
                under: externalRoot
            )
        )
        XCTAssertEqual(
            restartResolution.applicationSupportDirectory,
            UserDefaultsAppStorageLocationStore.applicationSupportDirectory(
                under: externalRoot
            )
        )
    }

    func testTemporaryRootProducesExactLayoutAndRequiredDirectories() throws {
        let root = try StartupTestSupport.makeTempRoot(testCase: self)
        let resolver = StartupTestSupport.makePathsResolver(root: root)
        let paths = try resolver.resolve()

        XCTAssertEqual(
            paths.catalogDatabaseURL.lastPathComponent,
            CatalogSnapshotConstants.databaseFilename
        )
        XCTAssertEqual(paths.catalogDirectory.lastPathComponent, "Catalog")
        XCTAssertEqual(paths.backupsDirectory.lastPathComponent, "Backups")
        XCTAssertEqual(paths.runtimeDirectory.lastPathComponent, "Runtime")
        XCTAssertEqual(paths.catalogLockFileURL.lastPathComponent, "catalog.lock")
        XCTAssertTrue(paths.cachesDirectory.path.contains("Caches/ImageAll"))

        try resolver.ensureRequiredDirectories(for: paths)

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.catalogDirectory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.backupsDirectory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.runtimeDirectory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.cachesDirectory.path))
    }

    func testFileOccupyingDirectoryLocationIsRejected() throws {
        let root = try StartupTestSupport.makeTempRoot(testCase: self)
        let resolver = StartupTestSupport.makePathsResolver(root: root)
        var paths = try resolver.resolve()

        try FileManager.default.createDirectory(
            at: paths.applicationSupportDirectory,
            withIntermediateDirectories: true
        )
        try Data("blocker".utf8).write(to: paths.catalogDirectory)
        paths = AppPaths(
            applicationSupportDirectory: paths.applicationSupportDirectory,
            catalogDirectory: paths.catalogDirectory,
            catalogDatabaseURL: paths.catalogDatabaseURL,
            backupsDirectory: paths.backupsDirectory,
            runtimeDirectory: paths.runtimeDirectory,
            catalogLockFileURL: paths.catalogLockFileURL,
            cachesDirectory: paths.cachesDirectory
        )

        XCTAssertThrowsError(try resolver.ensureRequiredDirectories(for: paths)) { error in
            XCTAssertEqual(error as? AppPathsError, .pathNotDirectory)
        }
    }
}

@MainActor
private struct FakeAppStorageRootPicker: AppStorageRootPicking {
    let selectedURL: URL?

    func pickCacheRoot() -> URL? {
        selectedURL
    }
}

private final class FakeAppStorageBookmarkPort:
    AppStorageBookmarkPort,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storedCreatedURLs: [URL] = []
    private var storedStartedURLs: [URL] = []
    private var storedStoppedURLs: [URL] = []
    private var storedStartResults: [Bool]

    init(startResults: [Bool] = []) {
        storedStartResults = startResults
    }

    var createdURLs: [URL] {
        lock.withLock { storedCreatedURLs }
    }

    var startedURLs: [URL] {
        lock.withLock { storedStartedURLs }
    }

    var stoppedURLs: [URL] {
        lock.withLock { storedStoppedURLs }
    }

    func createWriteBookmark(for url: URL) throws -> Data {
        lock.withLock {
            storedCreatedURLs.append(url.standardizedFileURL)
        }
        return Data(url.standardizedFileURL.path.utf8)
    }

    func resolveBookmark(_ bookmark: Data) throws -> BookmarkResolveResult {
        let path = try XCTUnwrap(String(data: bookmark, encoding: .utf8))
        return BookmarkResolveResult(
            url: URL(fileURLWithPath: path, isDirectory: true),
            isStale: false
        )
    }

    func startAccessing(_ url: URL) -> Bool {
        lock.withLock {
            storedStartedURLs.append(url.standardizedFileURL)
            return storedStartResults.isEmpty
                ? true
                : storedStartResults.removeFirst()
        }
    }

    func stopAccessing(_ url: URL) {
        lock.withLock {
            storedStoppedURLs.append(url.standardizedFileURL)
        }
    }
}
