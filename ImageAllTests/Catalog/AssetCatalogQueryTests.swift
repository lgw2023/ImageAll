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

    func testAllSourceStatesReturnCurrentAssets() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()
        let page = try fixture.query.fetchAssetPage(
            AssetPageRequest(filter: AssetPageFilter(), sort: .newest, cursor: nil, limit: 200)
        )
        XCTAssertTrue(page.items.contains { $0.sourceID == fixture.ids.sourceA && $0.sourceState == .disabled })
        XCTAssertTrue(page.items.contains { $0.sourceID == fixture.ids.sourceB && $0.sourceState == .unavailable })
        XCTAssertTrue(page.items.contains { $0.sourceID == fixture.ids.sourceC && $0.sourceState == .active })
        XCTAssertTrue(page.items.contains { $0.sourceID == fixture.ids.sourceD && $0.sourceState == .authorizationRequired })
    }

    func testDisabledAndUnavailableSourcesStillReturnCurrentAssets() throws {
        try testAllSourceStatesReturnCurrentAssets()
    }

    func testSourceFilterUsesORSemanticsAndExcludesUnselectedSources() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()
        let both = try fixture.query.fetchAssetPage(
            AssetPageRequest(
                filter: AssetPageFilter(sourceIDs: [fixture.ids.sourceA, fixture.ids.sourceB]),
                sort: .newest,
                cursor: nil,
                limit: 200
            )
        )
        XCTAssertTrue(both.items.allSatisfy { $0.sourceID == fixture.ids.sourceA || $0.sourceID == fixture.ids.sourceB })
        XCTAssertTrue(both.items.contains { $0.sourceID == fixture.ids.sourceA })
        XCTAssertTrue(both.items.contains { $0.sourceID == fixture.ids.sourceB })

        let onlyA = try fixture.query.fetchAssetPage(
            AssetPageRequest(
                filter: AssetPageFilter(sourceIDs: [fixture.ids.sourceA]),
                sort: .newest,
                cursor: nil,
                limit: 200
            )
        )
        XCTAssertTrue(onlyA.items.allSatisfy { $0.sourceID == fixture.ids.sourceA })
        XCTAssertFalse(onlyA.items.contains { $0.sourceID == fixture.ids.sourceB })
    }

    func testSourceFilterUsesORSemantics() throws {
        try testSourceFilterUsesORSemanticsAndExcludesUnselectedSources()
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
        XCTAssertEqual(byFileName.items.map(\.assetID), [fixture.ids.assetMiddle])

        let byPath = try fixture.query.fetchAssetPage(
            AssetPageRequest(filter: AssetPageFilter(searchText: "2024/beach"), sort: .newest, cursor: nil, limit: 50)
        )
        XCTAssertTrue(byPath.items.contains { $0.assetID == fixture.ids.assetNewest })

        let bySource = try fixture.query.fetchAssetPage(
            AssetPageRequest(filter: AssetPageFilter(searchText: "vacation"), sort: .newest, cursor: nil, limit: 50)
        )
        XCTAssertTrue(bySource.items.contains { $0.sourceID == fixture.ids.sourceA })

        let byTag = try fixture.query.fetchAssetPage(
            AssetPageRequest(filter: AssetPageFilter(searchText: "Family"), sort: .newest, cursor: nil, limit: 50)
        )
        XCTAssertEqual(byTag.items.map(\.assetID).sorted { $0.uuidString < $1.uuidString }, [
            fixture.ids.assetMiddle,
            fixture.ids.assetNewest,
        ].sorted { $0.uuidString < $1.uuidString })

        let literalPercentUnderscore = try fixture.query.fetchAssetPage(
            AssetPageRequest(filter: AssetPageFilter(searchText: "100%_complete"), sort: .newest, cursor: nil, limit: 50)
        )
        XCTAssertEqual(literalPercentUnderscore.items.map(\.assetID), [fixture.ids.assetLiteralWildcard])

        let literalBackslash = try fixture.query.fetchAssetPage(
            AssetPageRequest(filter: AssetPageFilter(searchText: "weird\\segment"), sort: .newest, cursor: nil, limit: 50)
        )
        XCTAssertEqual(literalBackslash.items.map(\.assetID), [fixture.ids.assetLiteralBackslash])
    }

    func testSearchInjectionDoesNotExpandResults() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()
        let baseline = try fixture.query.fetchAssetPage(
            AssetPageRequest(filter: AssetPageFilter(searchText: "no-such-term"), sort: .newest, cursor: nil, limit: 200)
        )
        let injection = try fixture.query.fetchAssetPage(
            AssetPageRequest(filter: AssetPageFilter(searchText: "' OR '1'='1"), sort: .newest, cursor: nil, limit: 200)
        )
        XCTAssertTrue(baseline.items.isEmpty)
        XCTAssertTrue(injection.items.isEmpty)
    }

    func testWhitespaceOnlySearchMatchesUnfiltered() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()
        let unfiltered = try fixture.query.fetchAssetPage(
            AssetPageRequest(filter: AssetPageFilter(), sort: .newest, cursor: nil, limit: 200)
        )
        let whitespace = try fixture.query.fetchAssetPage(
            AssetPageRequest(
                filter: AssetPageFilter(searchText: "\u{2003}\u{3000}\u{00A0}"),
                sort: .newest,
                cursor: nil,
                limit: 200
            )
        )
        XCTAssertEqual(whitespace.items.map(\.assetID), unfiltered.items.map(\.assetID))
    }

    func testNewestOldestAndFileNameSortOrdersAreStable() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()

        let newest = try fixture.query.fetchAssetPage(
            AssetPageRequest(filter: AssetPageFilter(), sort: .newest, cursor: nil, limit: 200)
        )
        XCTAssertEqual(newest.items.first?.assetID, fixture.ids.assetNewest)
        XCTAssertEqual(newest.items.last?.assetID, fixture.ids.assetNoTime)

        let duplicateIDs = newest.items
            .filter { $0.assetID == fixture.ids.assetDuplicateTimeA || $0.assetID == fixture.ids.assetDuplicateTimeB }
            .map(\.assetID)
        XCTAssertEqual(
            duplicateIDs,
            [fixture.ids.assetDuplicateTimeA, fixture.ids.assetDuplicateTimeB].sorted { $0.uuidString > $1.uuidString }
        )

        let oldest = try fixture.query.fetchAssetPage(
            AssetPageRequest(filter: AssetPageFilter(), sort: .oldest, cursor: nil, limit: 200)
        )
        XCTAssertEqual(oldest.items.first?.assetID, fixture.ids.assetOldest)

        let byName = try fixture.query.fetchAssetPage(
            AssetPageRequest(filter: AssetPageFilter(), sort: .fileNameAscending, cursor: nil, limit: 200)
        )
        let names = byName.items.compactMap(\.fileName)
        XCTAssertEqual(names, names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })

        let nocaseIndexA = byName.items.firstIndex { $0.assetID == fixture.ids.assetNocaseLower }
        let nocaseIndexB = byName.items.firstIndex { $0.assetID == fixture.ids.assetNocaseUpper }
        guard let nocaseIndexA, let nocaseIndexB else {
            return XCTFail("Expected NOCASE collision assets")
        }
        if fixture.ids.assetNocaseLower.uuidString < fixture.ids.assetNocaseUpper.uuidString {
            XCTAssertLessThan(nocaseIndexA, nocaseIndexB)
        } else {
            XCTAssertLessThan(nocaseIndexB, nocaseIndexA)
        }
    }

    func testAllSortModesPaginateIdenticallyToFullFetch() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()
        for sort in [AssetPageSort.newest, .oldest, .fileNameAscending] {
            var seen: [UUID] = []
            var cursor: AssetPageCursor?
            repeat {
                let page = try fixture.query.fetchAssetPage(
                    AssetPageRequest(filter: AssetPageFilter(), sort: sort, cursor: cursor, limit: 2)
                )
                for item in page.items {
                    XCTAssertFalse(seen.contains(item.assetID), "Duplicate at sort \(sort)")
                    seen.append(item.assetID)
                }
                cursor = page.nextCursor
            } while cursor != nil

            let full = try fixture.query.fetchAssetPage(
                AssetPageRequest(filter: AssetPageFilter(), sort: sort, cursor: nil, limit: 200)
            )
            XCTAssertEqual(seen, full.items.map(\.assetID), "Pagination mismatch for \(sort)")
        }
    }

    func testKeysetPaginationTraversesFullSetWithoutDuplicatesOrGaps() throws {
        try testAllSortModesPaginateIdenticallyToFullFetch()
    }

    func testPaginationSurvivesInsertBeforeCursor() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()
        let firstPage = try fixture.query.fetchAssetPage(
            AssetPageRequest(filter: AssetPageFilter(), sort: .newest, cursor: nil, limit: 2)
        )
        guard let cursor = firstPage.nextCursor else {
            return XCTFail("Expected cursor")
        }

        let inserted = UUID()
        try fixture.database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO asset (
                    id, source_id, locator_kind, relative_path, photos_local_identifier,
                    locator_state, media_type, media_created_at_ms, media_modified_at_ms,
                    file_name, content_revision, availability, record_created_at_ms, record_updated_at_ms
                ) VALUES (?, ?, 'file', ?, NULL, 'current', 'public.jpeg', ?, ?, 'inserted.jpg', 1, 'available', ?, ?)
                """,
                arguments: [
                    inserted.uuidString.lowercased(),
                    fixture.ids.sourceA.uuidString.lowercased(),
                    "2024/beach/inserted.jpg",
                    1_800_000_000_000,
                    1_800_000_000_000,
                    DatabaseTestSupport.timestampMs,
                    DatabaseTestSupport.timestampMs,
                ]
            )
        }

        var seen = firstPage.items.map(\.assetID)
        var nextCursor: AssetPageCursor? = cursor
        while let current = nextCursor {
            let page = try fixture.query.fetchAssetPage(
                AssetPageRequest(filter: AssetPageFilter(), sort: .newest, cursor: current, limit: 2)
            )
            for item in page.items {
                XCTAssertFalse(seen.contains(item.assetID))
                seen.append(item.assetID)
            }
            nextCursor = page.nextCursor
        }
        XCTAssertFalse(seen.contains(inserted))
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

    func testClosedPoolQuerySurfacesPersistenceFailure() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        _ = try CatalogQueryTestSupport.seedCatalogFixture(database: database, repository: CatalogRepository(database: database))
        let query = GRDBAssetCatalogQueryRepository(database: database)
        try CatalogDatabase.closePool(database.pool)

        XCTAssertThrowsError(
            try query.fetchAssetPage(
                AssetPageRequest(filter: AssetPageFilter(searchText: "secret-path"), sort: .newest, cursor: nil, limit: 10)
            )
        ) { error in
            XCTAssertEqual(error as? CatalogQueryError, .persistenceFailure)
            let description = String(describing: error)
            XCTAssertFalse(description.contains("SELECT"))
            XCTAssertFalse(description.contains("secret-path"))
        }
    }
}
