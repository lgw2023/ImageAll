import XCTest
@testable import ImageAll

final class AssetCatalogQueryTests: XCTestCase {
    func testInvalidPageLimitIsRejected() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()
        for invalid in [0, 201] {
            XCTAssertThrowsError(
                try fixture.query.fetchAssetPage(
                    AssetPageRequest(
                        filter: AssetPageFilter(),
                        sort: .newest,
                        cursor: nil,
                        limit: invalid
                    )
                )
            ) { error in
                XCTAssertEqual(error as? CatalogQueryError, .invalidPageLimit)
            }
        }
    }

    func testHistoricalAssetsAreExcludedFromGrid() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()
        let page = try fixture.query.fetchAssetPage(
            AssetPageRequest(filter: AssetPageFilter(), sort: .newest, cursor: nil, limit: 50)
        )
        XCTAssertFalse(page.items.contains { $0.assetID == fixture.ids.assetHistorical })
    }

    func testDisabledAndUnavailableSourcesStillReturnCurrentAssets() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()
        let page = try fixture.query.fetchAssetPage(
            AssetPageRequest(filter: AssetPageFilter(), sort: .newest, cursor: nil, limit: 50)
        )
        XCTAssertTrue(page.items.contains { $0.sourceID == fixture.ids.sourceA && $0.sourceState == .disabled })
        XCTAssertTrue(page.items.contains { $0.sourceID == fixture.ids.sourceB && $0.sourceState == .unavailable })
    }

    func testSourceFilterUsesORSemantics() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()
        let page = try fixture.query.fetchAssetPage(
            AssetPageRequest(
                filter: AssetPageFilter(sourceIDs: [fixture.ids.sourceA, fixture.ids.sourceB]),
                sort: .newest,
                cursor: nil,
                limit: 50
            )
        )
        XCTAssertTrue(page.items.allSatisfy { $0.sourceID == fixture.ids.sourceA || $0.sourceID == fixture.ids.sourceB })
        XCTAssertGreaterThan(page.items.count, 1)
    }

    func testAvailabilityAndMediaTypeFilters() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()
        let availabilityPage = try fixture.query.fetchAssetPage(
            AssetPageRequest(
                filter: AssetPageFilter(availabilities: [.missing]),
                sort: .newest,
                cursor: nil,
                limit: 50
            )
        )
        XCTAssertEqual(availabilityPage.items.count, 1)
        XCTAssertEqual(availabilityPage.items[0].assetID, fixture.ids.assetOldest)

        let utiPage = try fixture.query.fetchAssetPage(
            AssetPageRequest(
                filter: AssetPageFilter(mediaTypes: ["public.tiff"]),
                sort: .newest,
                cursor: nil,
                limit: 50
            )
        )
        XCTAssertEqual(utiPage.items.count, 1)
        XCTAssertEqual(utiPage.items[0].assetID, fixture.ids.assetNoTime)
    }

    func testTagDecisionAllAndAnyFilters() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()
        let allPage = try fixture.query.fetchAssetPage(
            AssetPageRequest(
                filter: AssetPageFilter(
                    tagDecisionFilters: [
                        TagDecisionFilter(tagID: fixture.ids.tagFamily, decision: .accepted),
                        TagDecisionFilter(tagID: fixture.ids.tagWork, decision: .rejected),
                    ],
                    tagMatchMode: .all
                ),
                sort: .newest,
                cursor: nil,
                limit: 50
            )
        )
        XCTAssertEqual(allPage.items.map(\.assetID), [fixture.ids.assetNewest])

        let anyPage = try fixture.query.fetchAssetPage(
            AssetPageRequest(
                filter: AssetPageFilter(
                    tagDecisionFilters: [
                        TagDecisionFilter(tagID: fixture.ids.tagFamily, decision: .accepted),
                        TagDecisionFilter(tagID: fixture.ids.tagWork, decision: .accepted),
                    ],
                    tagMatchMode: .any
                ),
                sort: .newest,
                cursor: nil,
                limit: 50
            )
        )
        let anyIDs = Set(anyPage.items.map(\.assetID))
        XCTAssertTrue(anyIDs.contains(fixture.ids.assetNewest))
        XCTAssertTrue(anyIDs.contains(fixture.ids.assetMiddle))
        XCTAssertFalse(anyIDs.contains(fixture.ids.assetOldest))
    }

    func testTaggedAndUntaggedPresenceFilters() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()
        let tagged = try fixture.query.fetchAssetPage(
            AssetPageRequest(
                filter: AssetPageFilter(tagPresence: .tagged),
                sort: .newest,
                cursor: nil,
                limit: 50
            )
        )
        XCTAssertTrue(tagged.items.allSatisfy { $0.acceptedTagCount > 0 })

        let untagged = try fixture.query.fetchAssetPage(
            AssetPageRequest(
                filter: AssetPageFilter(tagPresence: .untagged),
                sort: .newest,
                cursor: nil,
                limit: 50
            )
        )
        XCTAssertTrue(untagged.items.allSatisfy { $0.acceptedTagCount == 0 })
        XCTAssertTrue(untagged.items.contains { $0.assetID == fixture.ids.assetOldest })
    }

    func testSearchMatchesFourFieldsAndEscapesWildcards() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()

        let byFileName = try fixture.query.fetchAssetPage(
            AssetPageRequest(filter: AssetPageFilter(searchText: "img_002"), sort: .newest, cursor: nil, limit: 50)
        )
        XCTAssertEqual(byFileName.items.count, 1)
        XCTAssertEqual(byFileName.items[0].assetID, fixture.ids.assetMiddle)

        let byPath = try fixture.query.fetchAssetPage(
            AssetPageRequest(filter: AssetPageFilter(searchText: "2024/beach"), sort: .newest, cursor: nil, limit: 50)
        )
        XCTAssertFalse(byPath.items.isEmpty)

        let bySource = try fixture.query.fetchAssetPage(
            AssetPageRequest(filter: AssetPageFilter(searchText: "vacation"), sort: .newest, cursor: nil, limit: 50)
        )
        XCTAssertFalse(bySource.items.isEmpty)

        let byTag = try fixture.query.fetchAssetPage(
            AssetPageRequest(filter: AssetPageFilter(searchText: "Family"), sort: .newest, cursor: nil, limit: 50)
        )
        XCTAssertFalse(byTag.items.isEmpty)

        let literal = try fixture.query.fetchAssetPage(
            AssetPageRequest(filter: AssetPageFilter(searchText: "100%_complete"), sort: .newest, cursor: nil, limit: 50)
        )
        XCTAssertTrue(literal.items.isEmpty)
    }

    func testNewestOldestAndFileNameSortOrdersAreStable() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()

        let newest = try fixture.query.fetchAssetPage(
            AssetPageRequest(filter: AssetPageFilter(), sort: .newest, cursor: nil, limit: 50)
        )
        XCTAssertEqual(newest.items.first?.assetID, fixture.ids.assetNewest)
        XCTAssertEqual(newest.items.last?.assetID, fixture.ids.assetNoTime)

        let oldest = try fixture.query.fetchAssetPage(
            AssetPageRequest(filter: AssetPageFilter(), sort: .oldest, cursor: nil, limit: 50)
        )
        XCTAssertEqual(oldest.items.first?.assetID, fixture.ids.assetOldest)

        let byName = try fixture.query.fetchAssetPage(
            AssetPageRequest(filter: AssetPageFilter(), sort: .fileNameAscending, cursor: nil, limit: 50)
        )
        let names = byName.items.compactMap(\.fileName)
        XCTAssertEqual(names, names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }

    func testKeysetPaginationTraversesFullSetWithoutDuplicatesOrGaps() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()
        var seen: [UUID] = []
        var cursor: AssetPageCursor?
        repeat {
            let page = try fixture.query.fetchAssetPage(
                AssetPageRequest(filter: AssetPageFilter(), sort: .newest, cursor: cursor, limit: 2)
            )
            for item in page.items {
                XCTAssertFalse(seen.contains(item.assetID))
                seen.append(item.assetID)
            }
            cursor = page.nextCursor
        } while cursor != nil

        let full = try fixture.query.fetchAssetPage(
            AssetPageRequest(filter: AssetPageFilter(), sort: .newest, cursor: nil, limit: 50)
        )
        XCTAssertEqual(seen, full.items.map(\.assetID))
    }

    func testCursorSortMismatchIsRejected() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()
        let first = try fixture.query.fetchAssetPage(
            AssetPageRequest(filter: AssetPageFilter(), sort: .newest, cursor: nil, limit: 1)
        )
        guard let cursor = first.nextCursor else {
            return XCTFail("Expected cursor")
        }
        XCTAssertThrowsError(
            try fixture.query.fetchAssetPage(
                AssetPageRequest(filter: AssetPageFilter(), sort: .oldest, cursor: cursor, limit: 1)
            )
        ) { error in
            XCTAssertEqual(error as? CatalogQueryError, .cursorSortMismatch)
        }
    }

    func testGridProjectionIncludesDecisionCounts() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()
        let page = try fixture.query.fetchAssetPage(
            AssetPageRequest(filter: AssetPageFilter(), sort: .newest, cursor: nil, limit: 50)
        )
        let newest = page.items.first { $0.assetID == fixture.ids.assetNewest }
        XCTAssertEqual(newest?.acceptedTagCount, 1)
        XCTAssertEqual(newest?.rejectedTagCount, 1)
    }

    func testInspectorNotFoundDoesNotLeakDetails() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()
        XCTAssertThrowsError(try fixture.query.fetchInspectorDetail(assetID: UUID())) { error in
            XCTAssertEqual(error as? CatalogQueryError, .notFound)
            XCTAssertFalse(String(describing: error).contains("SELECT"))
        }
    }

    func testInspectorDetailIncludesFingerprintAndTagStates() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()
        let detail = try fixture.query.fetchInspectorDetail(assetID: fixture.ids.assetNewest)
        XCTAssertEqual(detail.fingerprintSizeBytes, 12_345)
        XCTAssertEqual(detail.fingerprintModifiedAtNs, 9_876_543_210)
        let family = detail.tags.first { $0.tagID == fixture.ids.tagFamily }
        XCTAssertEqual(family?.decision, .accepted)
        let work = detail.tags.first { $0.tagID == fixture.ids.tagWork }
        XCTAssertEqual(work?.decision, .rejected)
    }
}
