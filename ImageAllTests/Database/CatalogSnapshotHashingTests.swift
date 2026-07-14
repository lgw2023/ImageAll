import XCTest
@testable import ImageAll

final class CatalogSnapshotHashingTests: XCTestCase {
    func testSha256HexOnMissingFileMapsToInvalidDatabaseChecksum() {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageAllSnapshotHashingTests-missing-\(UUID().uuidString).sqlite")

        XCTAssertThrowsError(try CatalogSnapshotHashing.sha256Hex(of: missingURL)) { error in
            XCTAssertEqual(error as? CatalogSnapshotError, .invalidDatabaseChecksum)
            XCTAssertFalse(error is CocoaError)
        }
    }

    func testFileSizeOnMissingFileMapsToInvalidDatabaseBytes() {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageAllSnapshotHashingTests-missing-\(UUID().uuidString).sqlite")

        XCTAssertThrowsError(try CatalogSnapshotHashing.fileSize(of: missingURL)) { error in
            XCTAssertEqual(error as? CatalogSnapshotError, .invalidDatabaseBytes)
            XCTAssertFalse(error is CocoaError)
        }
    }
}
