import Foundation
import XCTest
@testable import ImageAll

final class LibraryThumbnailByteBudgetTests: XCTestCase {
    func testByteBudgetEvictsLeastRecentlyUsedAndAccountsForReplacement() {
        let a = UUID(), b = UUID(), c = UUID()
        var cache = LibraryThumbnailMemoryCache(capacity: 3, byteCapacity: 10)
        cache.store(Data(repeating: 1, count: 4), for: a)
        cache.store(Data(repeating: 2, count: 4), for: b)
        XCTAssertNotNil(cache.data(for: a))
        cache.store(Data(repeating: 3, count: 4), for: c)
        XCTAssertNil(cache.data(for: b))
        XCTAssertEqual(cache.totalBytes, 8)
        cache.store(Data(repeating: 4, count: 6), for: a)
        XCTAssertEqual(cache.totalBytes, 10)
        XCTAssertEqual(cache.version(for: a), 2)
        cache.store(Data([5]), for: a)
        XCTAssertEqual(cache.totalBytes, 5)
        XCTAssertFalse(cache.store(Data([5]), for: a))
        cache.store(Data(repeating: 6, count: 11), for: a)
        XCTAssertNil(cache.data(for: a))
        XCTAssertNotNil(cache.data(for: c))
        XCTAssertEqual(cache.totalBytes, 4)
        cache.removeAll()
        XCTAssertEqual(cache.totalBytes, 0)
        XCTAssertEqual(cache.count, 0)
    }

    func testDefaultBudgetBoundsLargeBatchBelowItemLimit() {
        var cache = LibraryThumbnailMemoryCache(capacity: 3_000)
        for index in 0..<2_889 {
            cache.store(Data(repeating: UInt8(index % 251), count: 128 * 1_024), for: UUID())
            XCTAssertLessThanOrEqual(cache.totalBytes, 64 * 1_024 * 1_024)
        }
        XCTAssertEqual(cache.count, 512)
    }
}
