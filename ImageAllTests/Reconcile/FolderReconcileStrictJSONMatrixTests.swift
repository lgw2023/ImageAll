import XCTest
@testable import ImageAll

/// Handoff 10.1 strict JSON field-family matrix.
final class FolderReconcileStrictJSONMatrixTests: XCTestCase {
    private let sourceID = UUID()

    func testPayloadRejectsBooleanContractVersion() {
        assertPayloadInvalid(#"{"contract_version":true,"source_id":"\(sourceID.uuidString.lowercased())"}"#)
    }

    func testPayloadRejectsFloatContractVersion() {
        assertPayloadInvalid(#"{"contract_version":1.0,"source_id":"\(sourceID.uuidString.lowercased())"}"#)
    }

    func testPayloadRejectsStringContractVersion() {
        assertPayloadInvalid(#"{"contract_version":"1","source_id":"\(sourceID.uuidString.lowercased())"}"#)
    }

    func testPayloadRejectsArrayContractVersion() {
        assertPayloadInvalid(#"{"contract_version":[1],"source_id":"\(sourceID.uuidString.lowercased())"}"#)
    }

    func testPayloadRejectsNegativeContractVersion() {
        assertPayloadInvalid(#"{"contract_version":-1,"source_id":"\(sourceID.uuidString.lowercased())"}"#)
    }

    func testPayloadRejectsNullSourceID() {
        assertPayloadInvalid(#"{"contract_version":1,"source_id":null}"#)
    }

    func testPayloadRejectsExtraField() {
        assertPayloadInvalid(#"{"contract_version":1,"source_id":"\(sourceID.uuidString.lowercased())","extra":1}"#)
    }

    func testCheckpointRejectsBooleanGeneration() {
        assertCheckpointInvalid(
            """
            {"contract_version":1,"generation":true,"started_dirty_epoch":0,"attempt":1,
            "enumerated_entries":0,"candidate_files":0,"committed_assets":0,"ignored_entries":0,
            "unsupported_assets":0,"unreadable_assets":0,"identity_conflicts":0}
            """
        )
    }

    func testCheckpointRejectsFloatAttempt() {
        assertCheckpointInvalid(
            """
            {"contract_version":1,"generation":1,"started_dirty_epoch":0,"attempt":1.0,
            "enumerated_entries":0,"candidate_files":0,"committed_assets":0,"ignored_entries":0,
            "unsupported_assets":0,"unreadable_assets":0,"identity_conflicts":0}
            """
        )
    }

    func testCheckpointRejectsNegativeCandidateFiles() {
        assertCheckpointInvalid(
            """
            {"contract_version":1,"generation":1,"started_dirty_epoch":0,"attempt":1,
            "enumerated_entries":0,"candidate_files":-1,"committed_assets":0,"ignored_entries":0,
            "unsupported_assets":0,"unreadable_assets":0,"identity_conflicts":0}
            """
        )
    }

    func testCheckpointRejectsStringEnumeratedEntries() {
        assertCheckpointInvalid(
            """
            {"contract_version":1,"generation":1,"started_dirty_epoch":0,"attempt":1,
            "enumerated_entries":"0","candidate_files":0,"committed_assets":0,"ignored_entries":0,
            "unsupported_assets":0,"unreadable_assets":0,"identity_conflicts":0}
            """
        )
    }

    func testCheckpointRejectsOverflowGeneration() {
        let overflow = String(Int.max) + "9"
        assertCheckpointInvalid(
            """
            {"contract_version":1,"generation":\(overflow),"started_dirty_epoch":0,"attempt":1,
            "enumerated_entries":0,"candidate_files":0,"committed_assets":0,"ignored_entries":0,
            "unsupported_assets":0,"unreadable_assets":0,"identity_conflicts":0}
            """
        )
    }

    private func assertPayloadInvalid(_ json: String) {
        let result = FolderReconcilePayloadValidation.validate(
            payloadVersion: 1,
            payload: Data(json.utf8),
            jobSourceID: sourceID
        )
        XCTAssertEqual(result, .failure(.invalid(.folderPayloadInvalid)))
    }

    private func assertCheckpointInvalid(_ json: String) {
        XCTAssertThrowsError(try FolderReconcileCheckpointCodec.decode(Data(json.utf8)))
    }
}
