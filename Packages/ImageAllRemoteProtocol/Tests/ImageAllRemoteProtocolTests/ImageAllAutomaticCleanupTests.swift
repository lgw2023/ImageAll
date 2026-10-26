import Foundation
import XCTest
@testable import ImageAllRemoteProtocol

final class ImageAllAutomaticCleanupTests: XCTestCase {
    func testFailureDefersAcrossRestartAndRequiresFreshAttempt() throws {
        var state = ImageAllAutomaticCleanup()
        let first = try XCTUnwrap(state.begin(nowMs: 1000, connected: true, ready: true))
        state.deferAttempt(first, reason: .busy, nowMs: 1000)
        XCTAssertEqual(state.phase, .deferred)
        XCTAssertEqual(state.reason, .busy)
        state = try JSONDecoder().decode(ImageAllAutomaticCleanup.self, from: JSONEncoder().encode(state)).restored()
        XCTAssertNil(state.begin(nowMs: 2000, connected: true, ready: true))
        XCTAssertNil(state.begin(nowMs: 31000, connected: false, ready: true))
        let second = try XCTUnwrap(state.begin(nowMs: 31000, connected: true, ready: true))
        XCTAssertNotEqual(first, second)
        state.complete(first)
        XCTAssertEqual(state.phase, .running)
        state.complete(second)
        XCTAssertEqual(state.phase, .complete)
        state = try JSONDecoder().decode(ImageAllAutomaticCleanup.self, from: JSONEncoder().encode(state)).restored()
        XCTAssertNil(state.begin(nowMs: 600000, connected: true, ready: true))
    }
}
