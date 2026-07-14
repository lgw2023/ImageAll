import XCTest
@testable import ImageAll

final class AppPathsTests: XCTestCase {
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
