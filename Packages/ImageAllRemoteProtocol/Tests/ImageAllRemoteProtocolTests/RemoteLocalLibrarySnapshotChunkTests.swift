import Foundation
import XCTest
@testable import ImageAllRemoteProtocol

final class RemoteLocalLibrarySnapshotChunkTests: XCTestCase {
    func testStagingRejectsChangedRetryAndSymlinkAfterRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = (0..<1_100).map { _ in UUID() }
        let request = RemoteLocalLibrarySnapshotRequest(
            hostID: UUID(), installID: UUID(), sourceEpoch: UUID(), scopeRevision: 1, snapshotSequence: 1,
            selectedAssetIDs: ids, assets: ids.map { .init(id: $0, localIdentifier: String(repeating: "x", count: 200),
                mediaKind: .image, createdAtMs: nil, observedFavorite: false, favoriteTarget: nil,
                tagDecisions: [], collections: []) }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(request)
        XCTAssertGreaterThan(bytes.count, 200 * 1_024)
        let identity = try RemoteLocalLibrarySnapshotReceiptLookup(request: request)
        let deviceID = UUID(), size = RemoteLocalLibrarySnapshotChunk.maximumChunkBytes
        let first = RemoteLocalLibrarySnapshotChunk(snapshot: identity, totalBytes: bytes.count, offset: 0,
                                                    bytes: bytes.subdata(in: 0..<size))
        XCTAssertLessThan(try encoder.encode(first).count, 200 * 1_024)
        let stagingRoot = root.appendingPathComponent("staging")
        let firstResult = try RemoteLocalLibrarySnapshotChunkStaging(root: stagingRoot).receive(first, deviceID: deviceID)
        XCTAssertEqual(firstResult.receivedBytes, size)
        XCTAssertNil(firstResult.complete)
        let reopened = RemoteLocalLibrarySnapshotChunkStaging(root: stagingRoot)
        var changed = first.bytes
        changed[0] ^= 1
        XCTAssertThrowsError(try reopened.receive(.init(snapshot: identity, totalBytes: bytes.count, offset: 0,
                                                        bytes: changed), deviceID: deviceID))
        let protectedFixture = root.appendingPathComponent("unchanged.bin")
        let sentinel = Data("synthetic sentinel".utf8)
        try sentinel.write(to: protectedFixture)
        let session = stagingRoot.appendingPathComponent(deviceID.uuidString).appendingPathComponent(identity.requestSHA256)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.path), "retry must retain its session")
        try FileManager.default.createSymbolicLink(at: session.appendingPathComponent("chunk-\(size).bin"),
                                                   withDestinationURL: protectedFixture)
        XCTAssertThrowsError(try reopened.receive(.init(snapshot: identity, totalBytes: bytes.count, offset: size,
                                                        bytes: bytes.subdata(in: size..<(size * 2))), deviceID: deviceID))
        XCTAssertEqual(try Data(contentsOf: protectedFixture), sentinel)
    }
}
