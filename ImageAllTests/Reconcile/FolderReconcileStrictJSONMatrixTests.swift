import XCTest
@testable import ImageAll

/// Handoff 10.1 strict JSON field-family matrix via canonical JSON mutation.
final class FolderReconcileStrictJSONMatrixTests: XCTestCase {
    private let sourceID = UUID()

    func testPayloadFieldMutationsRejectInvalidTypes() {
        let canonical = ReconcileStrictJSONMutation.payloadJSON(sourceID: sourceID)
        let fields = ["contract_version", "source_id"]
        let badTypes = ["true", "1.0", "\"1\"", "null", "[1]", "{}", "-1"]
        for field in fields {
            for bad in badTypes {
                let mutated = mutateJSONField(canonical, field: field, valueLiteral: bad)
                assertPayloadInvalid(mutated, field: field, bad: bad)
            }
        }
        assertPayloadInvalid(#"{"contract_version":1}"#, field: "missing source_id")
        assertPayloadInvalid(#"{"source_id":"\(sourceID.uuidString.lowercased())"}"#, field: "missing contract_version")
        assertPayloadInvalid(
            #"{"contract_version":1,"source_id":"\(sourceID.uuidString.lowercased())","extra":1}"#,
            field: "extra"
        )
        assertPayloadInvalid(
            #"{"contract_version":1,"source_id":"\(sourceID.uuidString.uppercased())"}"#,
            field: "uppercase uuid"
        )
        assertPayloadInvalid(#"{"contract_version":1,"source_id":"not-a-uuid"}"#, field: "bad uuid")
    }

    func testCheckpointIntegerFieldMutationsRejectInvalidTypes() {
        let integerFields = [
            "contract_version", "generation", "started_dirty_epoch", "attempt",
            "enumerated_entries", "candidate_files", "committed_assets", "ignored_entries",
            "unsupported_assets", "unreadable_assets", "identity_conflicts",
        ]
        let badTypes = ["true", "1.0", "\"1\"", "null", "[1]", "{}"]
        for field in integerFields {
            for bad in badTypes {
                let mutated = mutateJSONField(ReconcileStrictJSONMutation.canonicalCheckpointJSON, field: field, valueLiteral: bad)
                assertCheckpointInvalid(mutated, field: field, bad: bad)
            }
        }
        for field in integerFields where field != "contract_version" {
            let negative = mutateJSONField(ReconcileStrictJSONMutation.canonicalCheckpointJSON, field: field, valueLiteral: "-1")
            assertCheckpointInvalid(negative, field: field, bad: "negative")
        }
        let overflow = mutateJSONField(
            ReconcileStrictJSONMutation.canonicalCheckpointJSON,
            field: "generation",
            valueLiteral: String(Int.max) + "9"
        )
        assertCheckpointInvalid(overflow, field: "generation", bad: "overflow")
        assertCheckpointInvalid(#"{"contract_version":1}"#, field: "missing fields")
        assertCheckpointInvalid(
            ReconcileStrictJSONMutation.canonicalCheckpointJSON + #" ,"extra":1"#,
            field: "extra"
        )
    }

    private func mutateJSONField(_ json: String, field: String, valueLiteral: String) -> String {
        let pattern = "\"\(field)\":[^,}\\]]+"
        guard let range = json.range(of: pattern, options: .regularExpression) else {
            return json
        }
        return json.replacingCharacters(in: range, with: "\"\(field)\":\(valueLiteral)")
    }

    private func assertPayloadInvalid(_ json: String, field: String, bad: String = "") {
        let result = FolderReconcilePayloadValidation.validate(
            payloadVersion: 1,
            payload: Data(json.utf8),
            jobSourceID: sourceID
        )
        XCTAssertEqual(result, .failure(.invalid(.folderPayloadInvalid)), "field \(field) bad \(bad)")
    }

    private func assertCheckpointInvalid(_ json: String, field: String, bad: String = "") {
        XCTAssertThrowsError(try FolderReconcileCheckpointCodec.decode(Data(json.utf8)), "field \(field) bad \(bad)")
    }
}
