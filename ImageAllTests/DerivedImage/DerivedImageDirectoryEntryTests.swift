import Darwin
import XCTest
@testable import ImageAll

final class DerivedImageDirectoryEntryTests: XCTestCase {
    func testListDirectoryEntryNamesReadsShortShardAndCanonicalUUIDFile() throws {
        let root = try makeTemporaryDirectory()
        defer { cleanup(root) }

        let objectsPath = root.appendingPathComponent("objects")
        let shardPath = objectsPath.appendingPathComponent("77")
        try FileManager.default.createDirectory(at: shardPath, withIntermediateDirectories: true)

        let entryID = UUID(uuidString: "770f1a93-58e8-4f83-9e65-cc9e9cc84812")!
        let objectName = "\(entryID.uuidString.lowercased()).jpg"
        try Data([0x01, 0x02, 0x03]).write(to: shardPath.appendingPathComponent(objectName))

        let objectsFD = try openDirectory(at: objectsPath)
        defer { Darwin.close(objectsFD) }

        let shardNames = try DerivedImageSecureIO.listDirectoryEntryNames(directoryFD: objectsFD)
        XCTAssertEqual(shardNames, ["77"])

        let shardFD = try openDirectory(at: shardPath)
        defer { Darwin.close(shardFD) }

        let objectNames = try DerivedImageSecureIO.listDirectoryEntryNames(directoryFD: shardFD)
        XCTAssertEqual(objectNames, [objectName])
    }

    func testListDirectoryEntryNamesFiltersDotDirectories() throws {
        let root = try makeTemporaryDirectory()
        defer { cleanup(root) }

        let directoryFD = try openDirectory(at: root)
        defer { Darwin.close(directoryFD) }

        XCTAssertTrue(try DerivedImageSecureIO.listDirectoryEntryNames(directoryFD: directoryFD).isEmpty)
    }

    func testListDirectoryEntryNamesReadsValidNonASCIINames() throws {
        let root = try makeTemporaryDirectory()
        defer { cleanup(root) }

        let directoryFD = try openDirectory(at: root)
        defer { Darwin.close(directoryFD) }

        let foreignName = "缓存-rogue"
        try Data([0x01]).write(to: root.appendingPathComponent(foreignName))

        let names = try DerivedImageSecureIO.listDirectoryEntryNames(directoryFD: directoryFD)
        XCTAssertEqual(names, [foreignName])
    }

    func testListDirectoryEntryNamesReturnsEOFWithoutErrorForEmptyDirectory() throws {
        let root = try makeTemporaryDirectory()
        defer { cleanup(root) }

        let directoryFD = try openDirectory(at: root)
        defer { Darwin.close(directoryFD) }

        XCTAssertEqual(try DerivedImageSecureIO.listDirectoryEntryNames(directoryFD: directoryFD), [])
    }

    func testListDirectoryEntryNamesThrowsOnInvalidFileDescriptor() {
        XCTAssertThrowsError(try DerivedImageSecureIO.listDirectoryEntryNames(directoryFD: -1)) { error in
            XCTAssertEqual(error as? DerivedImageSecureIOError, .ioFailure)
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageAllDerivedDirEntry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func openDirectory(at url: URL) throws -> Int32 {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else {
            throw DerivedImageSecureIOError.ioFailure
        }
        return fd
    }
}
