import Foundation
import ImageAllRemoteProtocol
import XCTest

final class RemoteMediaContractTests: XCTestCase {
    func testExplicitDomainAndLegacyFormatsPreserveUnknown() throws {
        for (format, expected) in [("public.mpeg-4", RemoteAssetMediaKind.video),
                                   ("com.apple.quicktime-movie", .video),
                                   ("video/mp4", .video), ("public.heic", .image),
                                   ("image/jpeg", .image)] {
            let summary = try decodeSummary(format: format)
            XCTAssertNil(summary.mediaKind)
            XCTAssertEqual(summary.resolvedMediaKind, expected)
            let detail = try decodeDetail(format: format)
            XCTAssertEqual(detail.resolvedMediaKind, expected)
        }
        XCTAssertNil(try decodeSummary(format: "vendor.unknown").resolvedMediaKind)
        XCTAssertNil(try decodeDetail(format: "application/octet-stream").resolvedMediaKind)
        let explicit = try decodeSummary(format: "vendor.unknown", kind: "video")
        XCTAssertEqual(explicit.mediaKind, .video)
        XCTAssertEqual(explicit.resolvedMediaKind, .video)
        XCTAssertEqual(try JSONDecoder().decode(RemoteAssetSummary.self,
                                               from: JSONEncoder().encode(explicit)), explicit)
        let detail = try decodeDetail(format: "public.jpeg", kind: "video")
        XCTAssertEqual(detail.resolvedMediaKind, .video)
        XCTAssertEqual(try JSONDecoder().decode(RemoteAssetDetail.self,
                                               from: JSONEncoder().encode(detail)), detail)
        XCTAssertThrowsError(try decodeSummary(format: "public.jpeg", kind: "future-domain"))
    }

    func testOptionalVideoTechnicalMetadataRoundTripsAndLegacyRemainsUnknown() throws {
        let legacy = try payload(format: "public.mpeg-4", kind: "video")
        XCTAssertNil(try JSONDecoder().decode(RemoteAssetDetail.self, from: legacy).videoTechnicalMetadata)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
        object["videoTechnicalMetadata"] = ["codec": "avc1", "nominalFrameRate": 29.97, "audioTrackCount": 0]
        let detail = try JSONDecoder().decode(RemoteAssetDetail.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(detail.videoTechnicalMetadata?.codec, "avc1")
        XCTAssertEqual(detail.videoTechnicalMetadata?.audioTrackCount, 0)
        XCTAssertNil(detail.videoTechnicalMetadata?.estimatedDataRate)
        XCTAssertEqual(try JSONDecoder().decode(RemoteAssetDetail.self, from: JSONEncoder().encode(detail)), detail)
    }

    private func payload(format: String, kind: String?) throws -> Data {
        var object: [String: Any] = [
            "id": UUID().uuidString, "assetID": UUID().uuidString,
            "sourceID": UUID().uuidString, "sourceName": "Synthetic",
            "mediaType": format, "availability": "available", "contentRevision": 1,
            "acceptedTagCount": 0, "rejectedTagCount": 0, "tags": []
        ]
        if let kind { object["mediaKind"] = kind }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func decodeSummary(format: String, kind: String? = nil) throws -> RemoteAssetSummary {
        try JSONDecoder().decode(RemoteAssetSummary.self, from: payload(format: format, kind: kind))
    }

    private func decodeDetail(format: String, kind: String? = nil) throws -> RemoteAssetDetail {
        try JSONDecoder().decode(RemoteAssetDetail.self, from: payload(format: format, kind: kind))
    }
}
