import XCTest
@testable import ImageAll

final class AssetCatalogQueryTests: XCTestCase {
    func testGalleryOverviewExecutesAsOneAggregateStatement() throws {
        let fixture = try CatalogQueryTestSupport.openGalleryOverviewDatabase()
        let counter = CatalogSQLStatementCounter()
        try fixture.database.pool.read { db in
            db.trace { event in
                guard case let .statement(statement) = event else { return }
                let sql = statement.sql.uppercased()
                if sql.hasPrefix("SELECT") || sql.hasPrefix("WITH") {
                    counter.increment()
                }
            }
        }
        defer {
            try? fixture.database.pool.read { db in
                db.trace(options: [])
            }
        }

        _ = try fixture.query.fetchGalleryOverview()

        XCTAssertEqual(counter.value, 1)
    }

    func testGalleryOverviewAggregatesExactUniqueSourcesPositiveTagsAndYears() throws {
        let fixture = try CatalogQueryTestSupport.openGalleryOverviewDatabase()

        let overview = try fixture.query.fetchGalleryOverview()

        XCTAssertEqual(overview.totalCount, 6)
        XCTAssertEqual(
            overview.summary(for: .image),
            GalleryOverviewMediaSummary(
                mediaKind: .image,
                totalCount: 4,
                exactUniqueCount: 3,
                exactRedundantCount: 1,
                exactFingerprintCount: 3
            )
        )
        XCTAssertEqual(
            overview.summary(for: .video),
            GalleryOverviewMediaSummary(
                mediaKind: .video,
                totalCount: 2,
                exactUniqueCount: 2,
                exactRedundantCount: 0,
                exactFingerprintCount: 0
            )
        )
        XCTAssertEqual(overview.exactUniqueCount, 5)
        XCTAssertEqual(overview.exactRedundantCount, 1)
        XCTAssertEqual(overview.exactFingerprintCount, 3)

        XCTAssertEqual(overview.sources.map(\.displayName), ["相机归档", "Apple Photos"])
        XCTAssertEqual(overview.sources.map(\.imageCount), [3, 1])
        XCTAssertEqual(overview.sources.map(\.videoCount), [1, 1])

        XCTAssertEqual(overview.positiveTags.map(\.displayName), ["家人", "旅行"])
        XCTAssertEqual(overview.positiveTags.map(\.imageCount), [2, 1])
        XCTAssertEqual(overview.positiveTags.map(\.videoCount), [1, 1])
        XCTAssertEqual(overview.positiveLabeledAssetCount, 5)
        XCTAssertEqual(overview.acceptedDecisionCount, 5)

        XCTAssertEqual(
            overview.years,
            [
                GalleryOverviewYearSummary(year: 2023, imageCount: 1, videoCount: 0),
                GalleryOverviewYearSummary(year: 2024, imageCount: 2, videoCount: 2),
            ]
        )
        XCTAssertEqual(overview.undatedCount, 1)
        XCTAssertEqual(
            overview.availability,
            [
                GalleryOverviewAvailabilitySummary(
                    availability: .available,
                    imageCount: 3,
                    videoCount: 2
                ),
                GalleryOverviewAvailabilitySummary(
                    availability: .missing,
                    imageCount: 1,
                    videoCount: 0
                ),
            ]
        )
    }

    func testGalleryOverviewKeepsHundredThousandAssetTotalsAndEvidenceCoverageExact() throws {
        let databaseURL = try DatabaseTestSupport.makeTempDatabaseURL()
        let fixture = try CatalogQueryTestSupport.openScaleDatabase(
            at: databaseURL,
            assetCount: 100_000
        )

        let overview = try fixture.query.fetchGalleryOverview()

        XCTAssertEqual(overview.totalCount, 100_000)
        XCTAssertEqual(overview.summary(for: .image).totalCount, 100_000)
        XCTAssertEqual(overview.summary(for: .image).exactUniqueCount, 100_000)
        XCTAssertEqual(overview.exactFingerprintCount, 0)
        XCTAssertEqual(overview.exactRedundantCount, 0)
        XCTAssertEqual(overview.sources.count, 2)
        XCTAssertEqual(overview.sources.map(\.totalCount).sorted(), [50_000, 50_000])
        XCTAssertEqual(
            overview.positiveLabeledAssetCount,
            CatalogQueryTestSupport.scaleDecisionCount(assetCount: 100_000)
        )
        XCTAssertEqual(overview.positiveTags.map(\.totalCount), [10_000])
    }

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

    func testRecycledAssetsAreHiddenByDefaultButRemainExplicitlyQueryable() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()
        try fixture.database.pool.write { db in
            try db.execute(
                sql: "UPDATE asset SET availability = 'recycled' WHERE id = ?",
                arguments: [fixture.ids.assetNewest.uuidString.lowercased()]
            )
        }

        let defaultPage = try fixture.query.fetchAssetPage(
            AssetPageRequest(filter: AssetPageFilter(), sort: .newest, cursor: nil, limit: 200)
        )
        XCTAssertFalse(defaultPage.items.contains { $0.assetID == fixture.ids.assetNewest })

        let recyclePage = try fixture.query.fetchAssetPage(
            AssetPageRequest(
                filter: AssetPageFilter(availabilities: [.recycled]),
                sort: .newest,
                cursor: nil,
                limit: 200
            )
        )
        XCTAssertEqual(recyclePage.items.map(\.assetID), [fixture.ids.assetNewest])
    }

    func testPhotosRecycleEntryRemainsHiddenAfterReconcileMarksAssetMissingAndRepositoryReloads() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()
        let recycleEntryID = UUID(uuidString: "70000000-0000-4000-8000-000000000001")!
        try fixture.database.pool.write { db in
            try db.execute(
                sql: """
                UPDATE asset
                SET availability = 'missing', content_revision = content_revision + 1
                WHERE id = ?
                """,
                arguments: [fixture.ids.assetAuthRequired.uuidString.lowercased()]
            )
            try db.execute(
                sql: """
                INSERT INTO recycle_entry (
                    id, asset_id, source_kind, trashed_at_ms, purge_after_ms, state,
                    quarantine_relative_path, original_relative_path, photos_local_identifier,
                    error_code, created_at_ms, updated_at_ms
                ) VALUES (?, ?, 'photos', 1, 2, 'recycled', NULL, ?, ?, NULL, 1, 1)
                """,
                arguments: [
                    recycleEntryID.uuidString.lowercased(),
                    fixture.ids.assetAuthRequired.uuidString.lowercased(),
                    "AUTH-LOCAL-ID",
                    "AUTH-LOCAL-ID",
                ]
            )
        }

        // A fresh repository models reopening ImageAll after Photos reconciliation.
        let reloadedQuery = GRDBAssetCatalogQueryRepository(database: fixture.database)
        let defaultPage = try reloadedQuery.fetchAssetPage(
            AssetPageRequest(filter: AssetPageFilter(), sort: .newest, cursor: nil, limit: 200)
        )
        XCTAssertFalse(defaultPage.items.contains { $0.assetID == fixture.ids.assetAuthRequired })

        let missingPage = try reloadedQuery.fetchAssetPage(
            AssetPageRequest(
                filter: AssetPageFilter(availabilities: [.missing]),
                sort: .newest,
                cursor: nil,
                limit: 200
            )
        )
        XCTAssertFalse(missingPage.items.contains { $0.assetID == fixture.ids.assetAuthRequired })
        XCTAssertThrowsError(
            try reloadedQuery.fetchInspectorDetail(assetID: fixture.ids.assetAuthRequired)
        ) { error in
            XCTAssertEqual(error as? CatalogQueryError, .notFound)
        }

        try fixture.database.pool.write { db in
            try db.execute(
                sql: "UPDATE recycle_entry SET state = 'restored' WHERE id = ?",
                arguments: [recycleEntryID.uuidString.lowercased()]
            )
            try db.execute(
                sql: "UPDATE asset SET availability = 'available' WHERE id = ?",
                arguments: [fixture.ids.assetAuthRequired.uuidString.lowercased()]
            )
        }

        let restoredPage = try reloadedQuery.fetchAssetPage(
            AssetPageRequest(filter: AssetPageFilter(), sort: .newest, cursor: nil, limit: 200)
        )
        XCTAssertTrue(restoredPage.items.contains { $0.assetID == fixture.ids.assetAuthRequired })
        XCTAssertNoThrow(
            try reloadedQuery.fetchInspectorDetail(assetID: fixture.ids.assetAuthRequired)
        )
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

    func testMediaKindFilterKeepsPhotoAndVideoPagesDisjoint() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()
        try fixture.database.pool.write { db in
            try db.execute(
                sql: """
                UPDATE asset
                SET media_kind = 'video',
                    media_type = 'com.apple.quicktime-movie',
                    duration_ms = 12_345
                WHERE id = ?
                """,
                arguments: [fixture.ids.assetNewest.uuidString.lowercased()]
            )
        }

        let photos = try fixture.query.fetchAssetPage(
            AssetPageRequest(
                filter: AssetPageFilter(mediaKinds: [.image]),
                sort: .newest,
                cursor: nil,
                limit: 200
            )
        )
        let videos = try fixture.query.fetchAssetPage(
            AssetPageRequest(
                filter: AssetPageFilter(mediaKinds: [.video]),
                sort: .newest,
                cursor: nil,
                limit: 200
            )
        )

        XCTAssertFalse(photos.items.contains { $0.assetID == fixture.ids.assetNewest })
        XCTAssertEqual(videos.items.map(\.assetID), [fixture.ids.assetNewest])
        XCTAssertEqual(videos.items.first?.mediaKind, .video)
        XCTAssertEqual(videos.items.first?.durationMs, 12_345)
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

    func testExcludedTagFilters() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()

        let excludeFamilyPage = try fixture.query.fetchAssetPage(
            AssetPageRequest(
                filter: AssetPageFilter(excludedTagIDs: [fixture.ids.tagFamily]),
                sort: .newest,
                cursor: nil,
                limit: 50
            )
        )
        let excludeFamilyIDs = Set(excludeFamilyPage.items.map(\.assetID))
        XCTAssertFalse(excludeFamilyIDs.contains(fixture.ids.assetNewest))
        XCTAssertFalse(excludeFamilyIDs.contains(fixture.ids.assetMiddle))
        XCTAssertTrue(excludeFamilyIDs.contains(fixture.ids.assetOldest))

        let taggedExcludeFamilyPage = try fixture.query.fetchAssetPage(
            AssetPageRequest(
                filter: AssetPageFilter(
                    excludedTagIDs: [fixture.ids.tagFamily],
                    tagPresence: .tagged
                ),
                sort: .newest,
                cursor: nil,
                limit: 50
            )
        )
        XCTAssertTrue(taggedExcludeFamilyPage.items.isEmpty)
    }

    func testIncludeAndExcludeSameTagYieldsEmptyPage() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()
        let page = try fixture.query.fetchAssetPage(
            AssetPageRequest(
                filter: AssetPageFilter(
                    tagDecisionFilters: [
                        TagDecisionFilter(tagID: fixture.ids.tagFamily, decision: .accepted),
                    ],
                    excludedTagIDs: [fixture.ids.tagFamily]
                ),
                sort: .newest,
                cursor: nil,
                limit: 50
            )
        )
        XCTAssertTrue(page.items.isEmpty)
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
        let ids = fixture.ids

        let byFileName = try fixture.query.fetchAssetPage(
            AssetPageRequest(filter: AssetPageFilter(searchText: "img_002"), sort: .newest, cursor: nil, limit: 200)
        )
        XCTAssertEqual(byFileName.items.map(\.assetID), [ids.assetMiddle])

        let byPath = try fixture.query.fetchAssetPage(
            AssetPageRequest(filter: AssetPageFilter(searchText: "2024/beach"), sort: .fileNameAscending, cursor: nil, limit: 200)
        )
        XCTAssertEqual(
            Set(byPath.items.map(\.assetID)),
            Set([
                ids.assetNewest, ids.assetMiddle, ids.assetOldest, ids.assetNoTime,
                ids.assetDuplicateTimeA, ids.assetDuplicateTimeB, ids.assetNocaseLower, ids.assetNocaseUpper,
                ids.assetLiteralWildcard, ids.assetLiteralBackslash, ids.assetDecoyWildcard,
                ids.assetDecoyUnderscore, ids.assetDecoyBackslash,
            ])
        )

        let bySource = try fixture.query.fetchAssetPage(
            AssetPageRequest(filter: AssetPageFilter(searchText: "vacation"), sort: .newest, cursor: nil, limit: 200)
        )
        XCTAssertEqual(
            Set(bySource.items.map(\.assetID)),
            Set([
                ids.assetNewest, ids.assetMiddle, ids.assetOldest, ids.assetNoTime,
                ids.assetDuplicateTimeA, ids.assetDuplicateTimeB, ids.assetNocaseLower, ids.assetNocaseUpper,
                ids.assetLiteralWildcard, ids.assetLiteralBackslash, ids.assetDecoyWildcard,
                ids.assetDecoyUnderscore, ids.assetDecoyBackslash,
            ])
        )

        let byTag = try fixture.query.fetchAssetPage(
            AssetPageRequest(filter: AssetPageFilter(searchText: "Family"), sort: .newest, cursor: nil, limit: 200)
        )
        XCTAssertEqual(byTag.items.map(\.assetID), [ids.assetNewest, ids.assetMiddle])

        let literalPercentUnderscore = try fixture.query.fetchAssetPage(
            AssetPageRequest(filter: AssetPageFilter(searchText: "100%_complete"), sort: .newest, cursor: nil, limit: 200)
        )
        XCTAssertEqual(literalPercentUnderscore.items.map(\.assetID), [ids.assetLiteralWildcard])

        let literalUnderscore = try fixture.query.fetchAssetPage(
            AssetPageRequest(filter: AssetPageFilter(searchText: "img_002"), sort: .newest, cursor: nil, limit: 200)
        )
        XCTAssertEqual(literalUnderscore.items.map(\.assetID), [ids.assetMiddle])

        let literalBackslash = try fixture.query.fetchAssetPage(
            AssetPageRequest(filter: AssetPageFilter(searchText: "weird\\segment"), sort: .newest, cursor: nil, limit: 200)
        )
        XCTAssertEqual(literalBackslash.items.map(\.assetID), [ids.assetLiteralBackslash])
    }

    func testMultiFamilyFilterCombinationHasUniquePositiveAndNegativeHits() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()
        let positive = try fixture.query.fetchAssetPage(
            AssetPageRequest(
                filter: AssetPageFilter(
                    sourceIDs: [fixture.ids.sourceA],
                    tagDecisionFilters: [
                        TagDecisionFilter(tagID: fixture.ids.tagFamily, decision: .accepted),
                    ],
                    tagMatchMode: .all,
                    availabilities: [.available],
                    mediaTypes: ["public.png"],
                    searchText: "img_002"
                ),
                sort: .newest,
                cursor: nil,
                limit: 50
            )
        )
        XCTAssertEqual(positive.items.map(\.assetID), [fixture.ids.assetMiddle])

        let negative = try fixture.query.fetchAssetPage(
            AssetPageRequest(
                filter: AssetPageFilter(
                    sourceIDs: [fixture.ids.sourceA],
                    tagDecisionFilters: [
                        TagDecisionFilter(tagID: fixture.ids.tagFamily, decision: .accepted),
                    ],
                    tagMatchMode: .all,
                    availabilities: [.available],
                    mediaTypes: ["public.jpeg"],
                    searchText: "img_002"
                ),
                sort: .newest,
                cursor: nil,
                limit: 50
            )
        )
        XCTAssertTrue(negative.items.isEmpty)
    }

    func testSearchInjectionDoesNotExpandResults() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()
        let baseline = try fixture.query.fetchAssetPage(
            AssetPageRequest(filter: AssetPageFilter(searchText: "no-such-term"), sort: .newest, cursor: nil, limit: 200)
        )
        let injection = try fixture.query.fetchAssetPage(
            AssetPageRequest(filter: AssetPageFilter(searchText: "' OR '1'='1"), sort: .newest, cursor: nil, limit: 200)
        )
        let quotedPhrase = try fixture.query.fetchAssetPage(
            AssetPageRequest(filter: AssetPageFilter(searchText: "abc\"def"), sort: .newest, cursor: nil, limit: 200)
        )
        XCTAssertTrue(baseline.items.isEmpty)
        XCTAssertTrue(injection.items.isEmpty)
        XCTAssertTrue(quotedPhrase.items.isEmpty)
    }

    func testTwoCharacterAssetSearchKeepsLiteralLikeFallback() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()
        try fixture.database.pool.write { db in
            try db.execute(
                sql: "UPDATE asset SET file_name = 'QZ.jpg' WHERE id = ?",
                arguments: [fixture.ids.assetMiddle.uuidString.lowercased()]
            )
        }

        let page = try fixture.query.fetchAssetPage(
            AssetPageRequest(filter: AssetPageFilter(searchText: "QZ"), sort: .newest, cursor: nil, limit: 200)
        )
        XCTAssertEqual(page.items.map(\.assetID), [fixture.ids.assetMiddle])
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

    func testNewestOldestAndFileNameSortOrdersMatchIndependentExpectations() throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()

        for sort in [AssetPageSort.newest, .oldest, .fileNameAscending] {
            let page = try fixture.query.fetchAssetPage(
                AssetPageRequest(filter: AssetPageFilter(), sort: sort, cursor: nil, limit: 200)
            )
            XCTAssertEqual(
                page.items.map(\.assetID),
                CatalogQuerySortExpectations.expectedOrder(for: sort),
                "Full fetch mismatch for \(sort)"
            )
        }
    }

    func testAllSortModesPaginateIdenticallyToIndependentExpectations() throws {
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

            XCTAssertEqual(
                seen,
                CatalogQuerySortExpectations.expectedOrder(for: sort),
                "Pagination mismatch for \(sort)"
            )
        }
    }

    func testNewestOldestAndFileNameSortOrdersAreStable() throws {
        try testNewestOldestAndFileNameSortOrdersMatchIndependentExpectations()
    }

    func testKeysetPaginationTraversesFullSetWithoutDuplicatesOrGaps() throws {
        try testAllSortModesPaginateIdenticallyToIndependentExpectations()
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

    func testHundredThousandSyntheticAssetsKeepNewestKeysetPagesStable() throws {
        let fixture = try CatalogQueryTestSupport.openScaleDatabase(
            at: makeTempDatabaseURL(),
            assetCount: 100_000
        )
        let startedAt = ContinuousClock.now
        let firstPage = try fixture.query.fetchAssetPage(
            AssetPageRequest(filter: AssetPageFilter(), sort: .newest, cursor: nil, limit: 100)
        )
        let firstExpected = (99_900 ... 99_999).reversed().map(CatalogQueryTestSupport.scaleAssetID)
        XCTAssertEqual(firstPage.items.map(\.assetID), firstExpected)

        let cursor = try XCTUnwrap(firstPage.nextCursor)
        let secondPage = try fixture.query.fetchAssetPage(
            AssetPageRequest(filter: AssetPageFilter(), sort: .newest, cursor: cursor, limit: 100)
        )
        let secondExpected = (99_800 ... 99_899).reversed().map(CatalogQueryTestSupport.scaleAssetID)
        XCTAssertEqual(secondPage.items.map(\.assetID), secondExpected)
        XCTAssertTrue(Set(firstPage.items.map(\.assetID)).isDisjoint(with: secondPage.items.map(\.assetID)))
        XCTAssertLessThan(ContinuousClock.now - startedAt, .seconds(1))
    }

    func testHundredThousandSyntheticAssetsKeepFiltersSortAndSearchCorrect() throws {
        let fixture = try CatalogQueryTestSupport.openScaleDatabase(
            at: makeTempDatabaseURL(),
            assetCount: 100_000
        )
        let startedAt = ContinuousClock.now

        let sourceAndTypePage = try fixture.query.fetchAssetPage(
            AssetPageRequest(
                filter: AssetPageFilter(
                    sourceIDs: [fixture.folderSourceID],
                    mediaTypes: ["public.jpeg"]
                ),
                sort: .newest,
                cursor: nil,
                limit: 5
            )
        )
        XCTAssertEqual(
            sourceAndTypePage.items.map(\.assetID),
            [99_996, 99_990, 99_984, 99_978, 99_972].map(CatalogQueryTestSupport.scaleAssetID)
        )

        let taggedPage = try fixture.query.fetchAssetPage(
            AssetPageRequest(
                filter: AssetPageFilter(
                    tagDecisionFilters: [
                        TagDecisionFilter(tagID: fixture.acceptedTagID, decision: .accepted),
                    ]
                ),
                sort: .newest,
                cursor: nil,
                limit: 5
            )
        )
        XCTAssertEqual(
            taggedPage.items.map(\.assetID),
            [99_990, 99_980, 99_970, 99_960, 99_950].map(CatalogQueryTestSupport.scaleAssetID)
        )

        let fileNamePage = try fixture.query.fetchAssetPage(
            AssetPageRequest(filter: AssetPageFilter(), sort: .fileNameAscending, cursor: nil, limit: 5)
        )
        XCTAssertEqual(
            fileNamePage.items.map(\.assetID),
            [0, 2, 4, 6, 8].map(CatalogQueryTestSupport.scaleAssetID)
        )

        let searchPage = try fixture.query.fetchAssetPage(
            AssetPageRequest(
                filter: AssetPageFilter(searchText: "asset-099998"),
                sort: .newest,
                cursor: nil,
                limit: 5
            )
        )
        XCTAssertEqual(searchPage.items.map(\.assetID), [CatalogQueryTestSupport.scaleAssetID(99_998)])
        XCTAssertLessThan(ContinuousClock.now - startedAt, .seconds(2))
    }

    func testTenThousandAndMillionSyntheticAssetsKeepQueryEnvelopeStable() throws {
        for assetCount in [10_000, 1_000_000] {
            let databaseURL = try makeTempDatabaseURL()
            let fixture = try CatalogQueryTestSupport.openScaleDatabase(
                at: databaseURL,
                assetCount: assetCount
            )
            let lastIndex = assetCount - 1
            let startedAt = ContinuousClock.now
            var queryTimings: [String] = []

            var queryStartedAt = ContinuousClock.now
            let firstPage = try fixture.query.fetchAssetPage(
                AssetPageRequest(filter: AssetPageFilter(), sort: .newest, cursor: nil, limit: 100)
            )
            queryTimings.append("newest_first=\(ContinuousClock.now - queryStartedAt)")
            XCTAssertEqual(firstPage.items.count, 100)
            XCTAssertEqual(
                firstPage.items.map(\.assetID),
                ((lastIndex - 99) ... lastIndex).reversed().map(CatalogQueryTestSupport.scaleAssetID)
            )

            queryStartedAt = ContinuousClock.now
            let secondPage = try fixture.query.fetchAssetPage(
                AssetPageRequest(
                    filter: AssetPageFilter(),
                    sort: .newest,
                    cursor: try XCTUnwrap(firstPage.nextCursor),
                    limit: 100
                )
            )
            queryTimings.append("newest_second=\(ContinuousClock.now - queryStartedAt)")
            XCTAssertEqual(secondPage.items.count, 100)
            XCTAssertEqual(
                secondPage.items.map(\.assetID),
                ((lastIndex - 199) ... (lastIndex - 100)).reversed().map(CatalogQueryTestSupport.scaleAssetID)
            )

            let topFolderJPEG = lastIndex - (lastIndex % 6)
            queryStartedAt = ContinuousClock.now
            let sourceAndTypePage = try fixture.query.fetchAssetPage(
                AssetPageRequest(
                    filter: AssetPageFilter(
                        sourceIDs: [fixture.folderSourceID],
                        mediaTypes: ["public.jpeg"]
                    ),
                    sort: .newest,
                    cursor: nil,
                    limit: 5
                )
            )
            queryTimings.append("source_media=\(ContinuousClock.now - queryStartedAt)")
            XCTAssertEqual(
                sourceAndTypePage.items.map(\.assetID),
                stride(from: topFolderJPEG, through: topFolderJPEG - 24, by: -6)
                    .map(CatalogQueryTestSupport.scaleAssetID)
            )

            let topAccepted = lastIndex - (lastIndex % 10)
            queryStartedAt = ContinuousClock.now
            let taggedPage = try fixture.query.fetchAssetPage(
                AssetPageRequest(
                    filter: AssetPageFilter(
                        tagDecisionFilters: [
                            TagDecisionFilter(tagID: fixture.acceptedTagID, decision: .accepted),
                        ]
                    ),
                    sort: .newest,
                    cursor: nil,
                    limit: 5
                )
            )
            queryTimings.append("tag=\(ContinuousClock.now - queryStartedAt)")
            XCTAssertEqual(
                taggedPage.items.map(\.assetID),
                stride(from: topAccepted, through: topAccepted - 40, by: -10)
                    .map(CatalogQueryTestSupport.scaleAssetID)
            )

            queryStartedAt = ContinuousClock.now
            let fileNamePage = try fixture.query.fetchAssetPage(
                AssetPageRequest(filter: AssetPageFilter(), sort: .fileNameAscending, cursor: nil, limit: 5)
            )
            queryTimings.append("file_name=\(ContinuousClock.now - queryStartedAt)")
            XCTAssertEqual(
                fileNamePage.items.map(\.assetID),
                [0, 2, 4, 6, 8].map(CatalogQueryTestSupport.scaleAssetID)
            )

            let searchIndex = assetCount - 2
            queryStartedAt = ContinuousClock.now
            let searchPage = try fixture.query.fetchAssetPage(
                AssetPageRequest(
                    filter: AssetPageFilter(
                        searchText: CatalogQueryTestSupport.scaleSearchText(index: searchIndex)
                    ),
                    sort: .newest,
                    cursor: nil,
                    limit: 5
                )
            )
            let searchElapsed = ContinuousClock.now - queryStartedAt
            queryTimings.append("search=\(searchElapsed)")
            XCTAssertEqual(searchPage.items.map(\.assetID), [CatalogQueryTestSupport.scaleAssetID(searchIndex)])
            if assetCount == 1_000_000 {
                XCTAssertLessThan(searchElapsed, .seconds(2))
            }

            let elapsed = ContinuousClock.now - startedAt
            let threshold: Duration = assetCount == 10_000 ? .seconds(1) : .seconds(5)
            let databaseBytes = try CatalogQueryTestSupport.scaleDatabaseFootprintBytes(at: databaseURL)
            let metrics = [
                "assets=\(assetCount)",
                "query_seconds=\(elapsed)",
                "database_bytes=\(databaseBytes)",
                queryTimings.joined(separator: " "),
            ].joined(separator: " ")

            let attachment = XCTAttachment(string: metrics)
            attachment.name = "ImageAll \(assetCount) synthetic query baseline"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertLessThan(elapsed, threshold)
            try CatalogDatabase.closePool(fixture.database.pool)
        }
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

private final class CatalogSQLStatementCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int {
        lock.withLock { storedValue }
    }

    func increment() {
        lock.withLock { storedValue += 1 }
    }
}
