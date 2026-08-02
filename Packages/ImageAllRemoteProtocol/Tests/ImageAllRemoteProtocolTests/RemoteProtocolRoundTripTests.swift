import Foundation
import ImageAllRemoteProtocol
import XCTest

final class RemoteProtocolRoundTripTests: XCTestCase {
    func testAssetPageRequestDefaultsToFileNameSort() {
        XCTAssertEqual(
            RemoteAssetPageRequest().sort,
            .fileNameAscending
        )
    }

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private let decoder = JSONDecoder()

    func testCapabilitiesRoundTrip() throws {
        let original = RemoteCapabilities(
            hostAppVersion: "1.0.0-test",
            capabilities: [.sources, .tags, .assetPages, .thumbnails, .tagDecisions, .pairing, .events],
            listenPort: 8787,
            usesTLS: true,
            hostID: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"),
            certificateFingerprintSHA256: "deadbeef"
        )
        try assertRoundTrip(original)
    }

    func testCreateTagAndApplyRoundTrip() throws {
        let operationID = UUID()
        let tagID = UUID()
        let assetIDs = [UUID(), UUID()]

        try assertRoundTrip(
            RemoteCreateTagAndApplyRequest(
                operationID: operationID,
                name: "旅行",
                assetIDs: assetIDs
            )
        )
        try assertRoundTrip(
            RemoteCreateTagAndApplyResponse(
                operationID: operationID,
                tagID: tagID,
                displayName: "旅行",
                appliedAssetCount: 2,
                replayed: false,
                undoID: UUID()
            )
        )
    }

    func testTagManagementAndUndoRoundTrip() throws {
        let operationID = UUID()
        let tagID = UUID()
        let groupID = UUID()
        try assertRoundTrip(
            RemoteTagGroupSummary(
                id: groupID,
                displayName: "旅行",
                sortOrder: 20,
                isSystem: false
            )
        )
        try assertRoundTrip(RemoteRenameTagRequest(operationID: operationID, name: "家人"))
        try assertRoundTrip(RemoteMoveTagRequest(operationID: operationID, groupID: groupID))
        try assertRoundTrip(RemoteArchiveTagRequest(operationID: operationID))
        try assertRoundTrip(
            RemoteTagMutationResponse(
                operationID: operationID,
                tag: RemoteTagSummary(
                    id: tagID,
                    displayName: "家人",
                    state: .active,
                    groupID: groupID
                ),
                replayed: false
            )
        )
        let undoID = UUID()
        try assertRoundTrip(RemoteUndoTagDecisionRequest(operationID: operationID, undoID: undoID))
        try assertRoundTrip(
            RemoteUndoTagDecisionResponse(
                operationID: operationID,
                restoredAssetCount: 2,
                replayed: false
            )
        )
    }

    func testReviewOverviewRoundTrip() throws {
        let overview = RemoteReviewOverview(
            totalPendingSuggestionCount: 7,
            tags: [
                RemoteSuggestionTagOverview(
                    id: UUID(),
                    displayName: "猫",
                    acceptedSampleCount: 8,
                    rejectedSampleCount: 5,
                    pendingSuggestionCount: 7,
                    pendingSuggestionCounts: RemoteSuggestionOriginCounts(
                        featurePrint: 2,
                        standardModel: 1,
                        personalModel: 3,
                        personalAdamW: 1
                    ),
                    taskStatus: .completed,
                    checkedCount: 120,
                    totalCount: 120,
                    skippedCount: 4,
                    missingPositiveCount: 0,
                    missingNegativeCount: 0,
                    canReview: true
                ),
            ]
        )
        try assertRoundTrip(overview)
        try assertRoundTrip(
            RemoteReviewQueueRequest(
                tagID: overview.tags[0].id,
                sourceIDs: [UUID()],
                mediaKind: .video,
                limit: 48,
                cursor: "cursor"
            )
        )
    }

    func testPairingOfferRoundTrip() throws {
        let original = RemotePairingOffer(
            hostID: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            hostDisplayName: "Studio",
            listenPort: 8787,
            usesTLS: true,
            certificateFingerprintSHA256: "abc123",
            pairingToken: "pair-token",
            expiresAtMs: 1_700_000_000_000,
            publicBaseURL: "https://imageall.ultrahardcore.net"
        )
        try assertRoundTrip(original)
    }

    func testPublicEndpointNormalizationAcceptsOnlyDedicatedHTTPSRoot() {
        XCTAssertEqual(
            RemotePublicEndpoint.normalizedHTTPSBaseURL(
                " HTTPS://ImageAll.UltraHardcore.Net:443/ "
            ),
            "https://imageall.ultrahardcore.net"
        )
        XCTAssertNil(RemotePublicEndpoint.normalizedHTTPSBaseURL("http://imageall.example.com"))
        XCTAssertNil(RemotePublicEndpoint.normalizedHTTPSBaseURL("https://user@example.com"))
        XCTAssertNil(RemotePublicEndpoint.normalizedHTTPSBaseURL("https://example.com/api"))
        XCTAssertNil(RemotePublicEndpoint.normalizedHTTPSBaseURL("https://127.0.0.1"))
        XCTAssertNil(RemotePublicEndpoint.normalizedHTTPSBaseURL("https://[::1]"))
        XCTAssertNil(RemotePublicEndpoint.normalizedHTTPSBaseURL("https://example.com:8443"))
    }

    func testPairingOfferWithoutPublicEndpointRemainsDecodable() throws {
        let payload = Data(
            """
            {
              "hostID":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
              "hostDisplayName":"Legacy Host",
              "listenPort":8787,
              "usesTLS":true,
              "certificateFingerprintSHA256":"abc123",
              "pairingToken":"pair-token",
              "expiresAtMs":1700000000000,
              "protocolVersion":1
            }
            """.utf8
        )

        let offer = try JSONDecoder().decode(RemotePairingOffer.self, from: payload)

        XCTAssertNil(offer.publicBaseURL)
    }

    func testRemoteEventRoundTrip() throws {
        let original = RemoteEvent(
            kind: .jobsChanged,
            emittedAtMs: 1_700_000_000_000,
            jobID: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        )
        try assertRoundTrip(original)
    }

    func testTagSummaryRoundTrip() throws {
        let original = RemoteTagSummary(
            id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            displayName: "风景",
            state: .active,
            groupID: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        )
        try assertRoundTrip(original)
    }

    func testTagSummaryWithoutGroupIDUsesLegacyFallbackGroup() throws {
        let payload = Data(
            """
            {
              "id":"55555555-5555-5555-5555-555555555555",
              "displayName":"风景",
              "state":"active"
            }
            """.utf8
        )

        let summary = try decoder.decode(RemoteTagSummary.self, from: payload)

        XCTAssertEqual(
            summary.groupID,
            UUID(uuidString: "a0000000-0000-4000-8000-000000000007")!
        )
    }

    func testReviewQueueRequestWithoutMediaKindDefaultsToImage() throws {
        let payload = Data(
            """
            {
              "tagID":"55555555-5555-5555-5555-555555555555",
              "sourceIDs":[],
              "limit":40
            }
            """.utf8
        )

        let request = try decoder.decode(RemoteReviewQueueRequest.self, from: payload)

        XCTAssertEqual(request.mediaKind, .image)
    }

    func testBonjourTXTRoundTripHelpers() {
        let hostID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let txt = RemoteBonjour.txtRecord(protocolVersion: 1, hostID: hostID)
        XCTAssertEqual(txt[RemoteBonjour.TXTKey.protocolVersion], "1")
        XCTAssertEqual(txt[RemoteBonjour.TXTKey.hostID], hostID.uuidString)
        XCTAssertEqual(RemoteBonjour.protocolVersion(fromTXT: txt), 1)
        XCTAssertEqual(RemoteBonjour.hostID(fromTXT: txt), hostID)
        XCTAssertEqual(RemoteBonjour.serviceType, "_imageall._tcp")
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

    func testAdvancedAssetPageRequestRoundTrip() throws {
        let tagID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let original = RemoteAssetPageRequest(
            searchText: "sunset",
            sort: .oldest,
            limit: 48,
            tagDecisionFilters: [
                RemoteAssetTagDecisionFilter(tagID: tagID, decision: .accepted),
            ],
            excludedTagIDs: [UUID(uuidString: "55555555-5555-5555-5555-555555555555")!],
            tagMatchMode: .any,
            availabilities: [.available],
            mediaKinds: [.image],
            mediaTypes: ["public.jpeg"],
            tagPresence: .tagged
        )
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
            replayed: false,
            undoID: UUID()
        )
        try assertRoundTrip(response)
    }

    func testAPIErrorRoundTrip() throws {
        let original = RemoteAPIError(code: .unauthorized, message: "missing token")
        try assertRoundTrip(original)
        XCTAssertEqual(original.localizedDescription, "missing token")
    }

    private func assertRoundTrip<T: Codable & Equatable>(_ value: T) throws {
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(T.self, from: data)
        XCTAssertEqual(decoded, value)
    }
}
