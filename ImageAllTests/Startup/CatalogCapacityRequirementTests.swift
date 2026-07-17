import XCTest
@testable import ImageAll

final class CatalogCapacityRequirementTests: XCTestCase {
    private let oneMiB: UInt64 = 1024 * 1024
    private let margin: UInt64 = 64 * 1024 * 1024

    func testFootprintZeroUsesOneMiBMinimumBeforeTripling() {
        XCTAssertEqual(
            CatalogCapacityRequirement.requiredAdditionalBytes(sourceFootprint: 0),
            3 * oneMiB + margin
        )
    }

    func testFootprintExactlyOneMiB() {
        XCTAssertEqual(
            CatalogCapacityRequirement.requiredAdditionalBytes(sourceFootprint: oneMiB),
            3 * oneMiB + margin
        )
    }

    func testFootprintAboveOneMiBUsesActualFootprint() {
        let footprint: UInt64 = oneMiB + 512
        XCTAssertEqual(
            CatalogCapacityRequirement.requiredAdditionalBytes(sourceFootprint: footprint),
            3 * footprint + margin
        )
    }

    func testExactlyEnoughCapacityPasses() throws {
        let root = try StartupTestSupport.makeTempRoot(testCase: self)
        let paths = try StartupTestSupport.resolvedPaths(root: root)
        try StartupTestSupport.seedEmptySQLite(at: paths.catalogDatabaseURL)

        let footprint = try CatalogCapacityChecker().databaseFootprintBytes(at: paths.catalogDatabaseURL)
        guard let required = CatalogCapacityRequirement.requiredAdditionalBytes(sourceFootprint: footprint) else {
            return XCTFail("Expected requirement")
        }

        let checker = CatalogCapacityChecker(provider: FixedCapacityProvider(bytes: required))
        XCTAssertNoThrow(try checker.assertSufficientSpace(for: paths.catalogDatabaseURL, at: paths.catalogDirectory))
    }

    func testOneByteShortCapacityFails() throws {
        let root = try StartupTestSupport.makeTempRoot(testCase: self)
        let paths = try StartupTestSupport.resolvedPaths(root: root)
        try StartupTestSupport.seedEmptySQLite(at: paths.catalogDatabaseURL)

        let footprint = try CatalogCapacityChecker().databaseFootprintBytes(at: paths.catalogDatabaseURL)
        guard let required = CatalogCapacityRequirement.requiredAdditionalBytes(sourceFootprint: footprint) else {
            return XCTFail("Expected requirement")
        }

        let checker = CatalogCapacityChecker(provider: FixedCapacityProvider(bytes: required - 1))
        XCTAssertThrowsError(
            try checker.assertSufficientSpace(for: paths.catalogDatabaseURL, at: paths.catalogDirectory)
        ) { error in
            guard case let CatalogCapacityError.insufficientSpace(bytes) = error else {
                return XCTFail("Expected insufficientSpace, got \(error)")
            }
            XCTAssertEqual(bytes, required)
        }
    }

    func testOverflowReturnsNil() {
        XCTAssertNil(
            CatalogCapacityRequirement.requiredAdditionalBytes(sourceFootprint: .max)
        )
    }
}
