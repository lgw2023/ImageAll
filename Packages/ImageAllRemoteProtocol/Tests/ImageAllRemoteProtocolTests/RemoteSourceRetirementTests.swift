import Foundation
import XCTest
@testable import ImageAllRemoteProtocol

final class RemoteSourceRetirementTests: XCTestCase {
    func testLargeCandidateSetUsesBoundedCanonicalDigest() throws {
        let ids = (0..<10_000).map { _ in UUID() }
        let binding = RemotePhoneSourceRetirementBinding(operationID: UUID(), hostID: UUID(), deviceID: UUID(),
            requestID: UUID(), sourceReportID: UUID(), migrationID: UUID(), sourceInstallID: UUID(),
            sourceEpoch: UUID(), scopeRevision: 1, completionReceiptID: UUID(), backupReceiptID: UUID(),
            manifestSHA256: String(repeating: "a", count: 64), factSnapshotSHA256: String(repeating: "b", count: 64),
            candidateAssetIDs: ids)
        XCTAssertEqual(binding.candidateCount, 10_000)
        XCTAssertEqual(binding.candidateSHA256, RemotePhoneSourceRetirementBinding.candidateDigest(ids.reversed()))
        XCTAssertNotEqual(binding.candidateSHA256, RemotePhoneSourceRetirementBinding.candidateDigest(Array(ids.dropFirst())))
        let report = RemotePhoneSourceRetirement(binding: binding, outcome: .completed, updatedAtMs: 1)
        XCTAssertTrue(report.isValid)
        let bytes = try JSONEncoder().encode(report)
        XCTAssertLessThan(bytes.count, 2048)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(ids[0].uuidString))
        XCTAssertEqual(try JSONDecoder().decode(RemotePhoneSourceRetirement.self, from: bytes), report)
    }
}
