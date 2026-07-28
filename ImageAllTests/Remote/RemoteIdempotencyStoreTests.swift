import Foundation
import XCTest
@testable import ImageAll

final class RemoteIdempotencyStoreTests: XCTestCase {
    private func tempStorageURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteIdempotencyStoreTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("idempotency.json")
    }

    private func makeKey(tagID: UUID, assetIDs: [UUID], action: String = "accept") -> RemoteIdempotencyStore.MutationKey {
        RemoteIdempotencyStore.MutationKey(kind: "tagDecision", tagID: tagID, assetIDs: assetIDs, action: action)
    }

    func testReplaysResponseForSameOperationIDAndKey() async throws {
        let store = RemoteIdempotencyStore(storageURL: tempStorageURL())
        let tagID = UUID()
        let assetID = UUID()
        let operationID = UUID()
        nonisolated(unsafe) var mutateCallCount = 0

        let first = try await store.perform(operationID: operationID, key: makeKey(tagID: tagID, assetIDs: [assetID])) {
            mutateCallCount += 1
            return 1
        }
        let second = try await store.perform(operationID: operationID, key: makeKey(tagID: tagID, assetIDs: [assetID])) {
            mutateCallCount += 1
            return 1
        }

        XCTAssertEqual(first.response, 1)
        XCTAssertFalse(first.replayed)
        XCTAssertEqual(second.response, 1)
        XCTAssertTrue(second.replayed)
        XCTAssertEqual(mutateCallCount, 1)
    }

    func testConflictWhenSameOperationIDUsedForDifferentMutation() async throws {
        let store = RemoteIdempotencyStore(storageURL: tempStorageURL())
        let tagID = UUID()
        let operationID = UUID()

        _ = try await store.perform(operationID: operationID, key: makeKey(tagID: tagID, assetIDs: [UUID()])) { 1 }

        do {
            _ = try await store.perform(operationID: operationID, key: makeKey(tagID: tagID, assetIDs: [UUID()])) { 1 }
            XCTFail("expected conflict")
        } catch let error as RemoteIdempotencyStore.IdempotencyError {
            XCTAssertEqual(error, .conflict)
        }
    }

    func testMutationKeyNormalizesUnorderedAssetIDs() {
        let tagID = UUID()
        let assetA = UUID()
        let assetB = UUID()
        let keyOne = makeKey(tagID: tagID, assetIDs: [assetA, assetB])
        let keyTwo = makeKey(tagID: tagID, assetIDs: [assetB, assetA])
        XCTAssertEqual(keyOne, keyTwo)
    }

    func testTagDecisionAndReviewDecisionWithSameOperationIDDoNotCollide() async throws {
        let store = RemoteIdempotencyStore(storageURL: tempStorageURL())
        let tagID = UUID()
        let assetID = UUID()
        let operationID = UUID()

        let tagKey = RemoteIdempotencyStore.MutationKey(kind: "tagDecision", tagID: tagID, assetIDs: [assetID], action: "accept")
        let reviewKey = RemoteIdempotencyStore.MutationKey(kind: "reviewDecision", tagID: tagID, assetIDs: [assetID], action: "accept")

        let tagResult = try await store.perform(operationID: operationID, key: tagKey) { 1 }
        let reviewResult = try await store.perform(operationID: operationID, key: reviewKey) { 2 }

        XCTAssertFalse(tagResult.replayed)
        XCTAssertFalse(reviewResult.replayed)
        XCTAssertEqual(reviewResult.response, 2)
    }

    func testPersistsOperationsAcrossStoreInstances() async throws {
        let storageURL = tempStorageURL()
        let tagID = UUID()
        let assetID = UUID()
        let operationID = UUID()

        let firstStore = RemoteIdempotencyStore(storageURL: storageURL)
        _ = try await firstStore.perform(operationID: operationID, key: makeKey(tagID: tagID, assetIDs: [assetID])) { 7 }

        // Simulates a Mac Host process restart: a fresh store instance reloads persisted operations.
        let secondStore = RemoteIdempotencyStore(storageURL: storageURL)
        nonisolated(unsafe) var mutateCalledAgain = false
        let replayed = try await secondStore.perform(operationID: operationID, key: makeKey(tagID: tagID, assetIDs: [assetID])) {
            mutateCalledAgain = true
            return 999
        }

        XCTAssertTrue(replayed.replayed)
        XCTAssertEqual(replayed.response, 7)
        XCTAssertFalse(mutateCalledAgain)
    }
}
