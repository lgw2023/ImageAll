import Foundation
import ImageAllRemoteProtocol
import XCTest

final class RemoteProtocolRoundTripTests: XCTestCase {
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private let decoder = JSONDecoder()

    func testCapabilitiesRoundTrip() throws {
        let original = RemoteCapabilities(
            hostAppVersion: "1.0.0-test",
            capabilities: [.sources, .assetPages, .thumbnails, .tagDecisions],
            listenPort: 8787
        )
        try assertRoundTrip(original)
    }

    func testSourceSummaryRoundTrip() throws {
        let original = RemoteSourceSummary(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            kind: .folder,
            displayName: "Archive",
            state: .active
        )
        try assertRoundTrip(original)
    }

    func testAssetPageRoundTrip() throws {
        let item = RemoteAssetSummary(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            sourceID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            sourceName: "Archive",
            fileName: "a.jpg",
            mediaType: "image",
            availability: .available,
            contentRevision: 3,
            acceptedTagCount: 1,
            rejectedTagCount: 0,
            mediaCreatedAtMs: 1_700_000_000_000,
            width: 4000,
            height: 3000
        )
        let original = RemoteAssetPage(items: [item], nextCursor: "cursor-1")
        try assertRoundTrip(original)
    }

    func testBatchTagDecisionRoundTrip() throws {
        let request = RemoteBatchTagDecisionRequest(
            operationID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            tagID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            assetIDs: [UUID(uuidString: "22222222-2222-2222-2222-222222222222")!],
            action: .accept
        )
        try assertRoundTrip(request)

        let response = RemoteBatchTagDecisionResponse(
            operationID: request.operationID,
            appliedAssetCount: 1,
            replayed: false
        )
        try assertRoundTrip(response)
    }

    func testAPIErrorRoundTrip() throws {
        let original = RemoteAPIError(code: .unauthorized, message: "missing token")
        try assertRoundTrip(original)
    }

    private func assertRoundTrip<T: Codable & Equatable>(_ value: T) throws {
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(T.self, from: data)
        XCTAssertEqual(decoded, value)
    }
}
