import CryptoKit
import Foundation
import ImageAllRemoteProtocol
import XCTest

final class ImageAllMigrationArchiveTests: XCTestCase {
    func testFactSnapshotRoundTripRejectsDuplicateMediaIdentity() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("facts.imageallfacts")
        let item = ImageAllMigrationFactItem(
            mediaID: UUID(), observedFavorite: true, favoriteTarget: false,
            tagDecisions: [.init(tagID: UUID(), tagName: "风景", decision: .accepted)],
            collections: [.init(collectionID: UUID(), collectionName: "旅行", included: true)]
        )
        let snapshot = ImageAllMigrationFactSnapshot(
            sourceDeviceID: UUID(), sourceEpoch: UUID(), scopeRevision: 2,
            snapshotSequence: 4, factWatermark: 7, items: [item],
            syncCheckpoint: .init(
                hostID: UUID(), deviceID: UUID(),
                acknowledgedScopeRevision: 2,
                acknowledgedSnapshotSequence: 3,
                tagChangeCursor: 4, collectionChangeCursor: 5,
                favoriteChangeCursor: 6,
                archiveManifestSHA256: String(repeating: "a", count: 64),
                sourceVerifiedAtMs: 1_000
            ),
            auditRecords: [.init(operationID: UUID(), sequence: 7, mediaID: item.mediaID,
                                 field: "favorite.target", value: "0", createdAtMs: 100, origin: "remoteSync")]
        )
        try ImageAllMigrationFacts.write(snapshot, to: url)
        XCTAssertEqual(try ImageAllMigrationFacts.read(at: url), snapshot)
        let legacyEvent = Data("""
            {"operationID":"\(UUID().uuidString)","sequence":1,"mediaID":"\(item.mediaID.uuidString)",
             "field":"favorite.target","value":"1","createdAtMs":100}
            """.utf8)
        let legacy = try JSONDecoder().decode(ImageAllMigrationAuditRecord.self, from: legacyEvent)
        XCTAssertNil(legacy.origin)
        XCTAssertNil(legacy.referenceName)
        let named = ImageAllMigrationAuditRecord(operationID: UUID(), sequence: 1,
            mediaID: item.mediaID, field: "tag.\(UUID().uuidString)", value: "accepted",
            createdAtMs: 100, origin: "localEdit", referenceName: "操作时名称")
        XCTAssertEqual(try JSONDecoder().decode(ImageAllMigrationAuditRecord.self,
            from: JSONEncoder().encode(named)), named)
        for records in [
            snapshot.auditRecords! + snapshot.auditRecords!,
            [.init(operationID: UUID(), sequence: 7, mediaID: item.mediaID,
                   field: "favorite.target", value: "1", createdAtMs: 101, origin: "invented")],
            [.init(operationID: UUID(), sequence: 7, mediaID: item.mediaID,
                   field: "tag.example", value: "accepted", createdAtMs: 101, referenceName: "")],
            [.init(operationID: UUID(), sequence: 8, mediaID: item.mediaID,
                   field: "favorite.target", value: "1", createdAtMs: 101)],
            [.init(operationID: UUID(), sequence: 7, mediaID: UUID(),
                   field: "favorite.target", value: "1", createdAtMs: 101)]
        ] {
            let invalidAudit = ImageAllMigrationFactSnapshot(
                sourceDeviceID: snapshot.sourceDeviceID, sourceEpoch: snapshot.sourceEpoch,
                scopeRevision: 2, snapshotSequence: 4, factWatermark: 7, items: [item], auditRecords: records
            )
            XCTAssertThrowsError(try ImageAllMigrationFacts.validate(invalidAudit))
        }
        let duplicate = ImageAllMigrationFactSnapshot(
            sourceDeviceID: snapshot.sourceDeviceID, sourceEpoch: snapshot.sourceEpoch,
            scopeRevision: 2, snapshotSequence: 4, factWatermark: 7,
            items: [item, item]
        )
        XCTAssertThrowsError(try ImageAllMigrationFacts.write(duplicate, to: url)) {
            XCTAssertEqual($0 as? ImageAllMigrationFactsError, .invalidSnapshot)
        }
        let invalidCursor = ImageAllMigrationFactSnapshot(
            sourceDeviceID: snapshot.sourceDeviceID, sourceEpoch: snapshot.sourceEpoch,
            scopeRevision: 2, snapshotSequence: 5, factWatermark: 7,
            items: [item], syncCheckpoint: .init(
                hostID: UUID(), deviceID: UUID(),
                acknowledgedScopeRevision: 2, acknowledgedSnapshotSequence: 3,
                tagChangeCursor: -1, collectionChangeCursor: 0,
                favoriteChangeCursor: 0
            )
        )
        XCTAssertThrowsError(try ImageAllMigrationFacts.write(invalidCursor, to: url)) {
            XCTAssertEqual($0 as? ImageAllMigrationFactsError, .invalidSnapshot)
        }
        let unpairedSourceProof = ImageAllMigrationFactSnapshot(
            sourceDeviceID: snapshot.sourceDeviceID, sourceEpoch: snapshot.sourceEpoch,
            scopeRevision: 2, snapshotSequence: 5, factWatermark: 7,
            items: [item], syncCheckpoint: .init(
                hostID: UUID(), deviceID: UUID(),
                acknowledgedScopeRevision: 2, acknowledgedSnapshotSequence: 3,
                tagChangeCursor: 0, collectionChangeCursor: 0,
                favoriteChangeCursor: 0,
                archiveManifestSHA256: String(repeating: "b", count: 64)
            )
        )
        XCTAssertThrowsError(try ImageAllMigrationFacts.write(unpairedSourceProof, to: url)) {
            XCTAssertEqual($0 as? ImageAllMigrationFactsError, .invalidSnapshot)
        }
    }

    func testCheckpointTagAliasesRoundTripAndRejectAmbiguousIdentity() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("tag-alias-facts.imageallfacts")
        let localID = UUID(), remoteID = UUID()
        let item = ImageAllMigrationFactItem(
            mediaID: UUID(), observedFavorite: false, favoriteTarget: nil,
            tagDecisions: [.init(tagID: localID, tagName: "Café", decision: .accepted)],
            collections: []
        )
        let alias = ImageAllMigrationTagAlias(
            localTagID: localID, localTagName: "Café",
            remoteTagID: remoteID, remoteTagName: "Cafe\u{301}"
        )
        func snapshot(_ aliases: [ImageAllMigrationTagAlias]) -> ImageAllMigrationFactSnapshot {
            .init(
                sourceDeviceID: UUID(), sourceEpoch: UUID(),
                scopeRevision: 1, snapshotSequence: 2, factWatermark: 1,
                items: [item], syncCheckpoint: .init(
                    hostID: UUID(), deviceID: UUID(),
                    acknowledgedScopeRevision: 1, acknowledgedSnapshotSequence: 1,
                    tagChangeCursor: 0, collectionChangeCursor: 0,
                    favoriteChangeCursor: 0, tagAliases: aliases
                )
            )
        }
        let valid = snapshot([alias])
        try ImageAllMigrationFacts.write(valid, to: file)
        XCTAssertEqual(try ImageAllMigrationFacts.read(at: file), valid)
        XCTAssertThrowsError(try ImageAllMigrationFacts.write(snapshot([alias, alias]), to: file)) {
            XCTAssertEqual($0 as? ImageAllMigrationFactsError, .invalidSnapshot)
        }
    }

    func testCheckpointCollectionAliasesRoundTripAndRejectAmbiguousIdentity() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("collection-alias-facts.imageallfacts")
        let localID = UUID(), remoteID = UUID()
        let item = ImageAllMigrationFactItem(
            mediaID: UUID(), observedFavorite: false, favoriteTarget: nil,
            tagDecisions: [],
            collections: [.init(collectionID: localID, collectionName: "Café", included: true)]
        )
        let alias = ImageAllMigrationCollectionAlias(
            localCollectionID: localID, localCollectionName: "Café",
            remoteCollectionID: remoteID, remoteCollectionName: "Cafe\u{301}"
        )
        func snapshot(_ aliases: [ImageAllMigrationCollectionAlias]) -> ImageAllMigrationFactSnapshot {
            .init(
                sourceDeviceID: UUID(), sourceEpoch: UUID(),
                scopeRevision: 1, snapshotSequence: 2, factWatermark: 1,
                items: [item], syncCheckpoint: .init(
                    hostID: UUID(), deviceID: UUID(),
                    acknowledgedScopeRevision: 1, acknowledgedSnapshotSequence: 1,
                    tagChangeCursor: 0, collectionChangeCursor: 0,
                    favoriteChangeCursor: 0, collectionAliases: aliases
                )
            )
        }
        let valid = snapshot([alias])
        try ImageAllMigrationFacts.write(valid, to: file)
        XCTAssertEqual(try ImageAllMigrationFacts.read(at: file), valid)
        XCTAssertThrowsError(try ImageAllMigrationFacts.write(snapshot([alias, alias]), to: file)) {
            XCTAssertEqual($0 as? ImageAllMigrationFactsError, .invalidSnapshot)
        }
    }

    func testPublishedFactSidecarIsPartOfIndependentArchiveVerification() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.deletingLastPathComponent().appendingPathComponent(
            "ImageAll-facts-\(UUID().uuidString).imageallfacts"
        )
        defer { try? FileManager.default.removeItem(at: source) }
        let item = try makeItem(
            root: root, resourceID: UUID(), bytes: Data("original-with-facts".utf8)
        )
        let migrationHeader = header(migrationID: UUID(), count: 1)
        try ImageAllMigrationArchive.write(header: migrationHeader, items: [item], to: root)
        let facts = ImageAllMigrationFactSnapshot(
            sourceDeviceID: migrationHeader.sourceDeviceID,
            sourceEpoch: migrationHeader.sourceEpoch,
            scopeRevision: migrationHeader.scopeRevision,
            snapshotSequence: migrationHeader.inventoryWatermark + 1,
            factWatermark: item.factRevision + 1,
            items: [.init(
                mediaID: item.mediaID, observedFavorite: true, favoriteTarget: false,
                tagDecisions: [], collections: []
            )]
        )
        try ImageAllMigrationFacts.write(facts, to: source)
        let originalMedia = try ImageAllMigrationArchive.verify(at: root)
        let published = try ImageAllMigrationFacts.publish(from: source, into: root)
        XCTAssertEqual(try ImageAllMigrationFacts.publish(from: source, into: root), published)
        let withFacts = try ImageAllMigrationArchive.verify(at: root)
        XCTAssertTrue(withFacts.hasSameMedia(as: originalMedia))
        XCTAssertNotNil(withFacts.factsSHA256)
        try Data("tampered".utf8).write(to: published)
        XCTAssertThrowsError(try ImageAllMigrationArchive.verify(at: root))
    }

    func testRejectsDuplicateSourceAlbumMembership() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try makeItem(
            root: root, resourceID: UUID(), bytes: Data("album-original".utf8)
        )
        let album = ImageAllMigrationAppleAlbumMembership(
            albumLocalIdentifier: "album-1", albumTitle: "Travel",
            folderPath: [.init(localIdentifier: "folder-1", title: "Trips")],
            sourceOrdinal: 2
        )
        let item = ImageAllMigrationItem(
            mediaID: original.mediaID,
            sourceLocalIdentifier: original.sourceLocalIdentifier,
            mediaKind: original.mediaKind, createdAtMs: original.createdAtMs,
            favoriteTarget: original.favoriteTarget,
            observedFavorite: original.observedFavorite,
            factRevision: original.factRevision,
            tagDecisions: original.tagDecisions, collections: original.collections,
            resources: original.resources, appleAlbums: [album, album]
        )
        try ImageAllMigrationArchive.write(
            header: .init(
                migrationID: UUID(), sourceDeviceID: UUID(), sourceEpoch: UUID(),
                scopeRevision: 1, inventoryWatermark: 9, declaredItemCount: 1,
                appleAlbumCoverage: .selectedAssetsOnly
            ), items: [item], to: root
        )
        XCTAssertThrowsError(try ImageAllMigrationArchive.verify(at: root)) { error in
            XCTAssertEqual(error as? ImageAllMigrationArchiveError, .duplicateIdentity)
        }
    }

    func testDanglingFactsSymlinkDoesNotPassArchiveVerification() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try makeItem(root: root, resourceID: UUID(), bytes: Data("original".utf8))
        try ImageAllMigrationArchive.write(
            header: header(migrationID: UUID(), count: 1), items: [item], to: root
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("facts"),
            withDestinationURL: root.appendingPathComponent("missing-facts")
        )
        XCTAssertThrowsError(try ImageAllMigrationArchive.verify(at: root))
    }

    func testIndependentVerifierChecksOriginalBytesAndHumanFacts() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let resourceID = UUID()
        let bytes = Data("synthetic-original-image".utf8)
        let item = try makeItem(root: root, resourceID: resourceID, bytes: bytes)
        let migrationID = UUID()
        try ImageAllMigrationArchive.write(
            header: header(migrationID: migrationID, count: 1),
            items: [item], to: root
        )

        let result = try ImageAllMigrationArchive.verify(at: root)
        XCTAssertEqual(result.migrationID, migrationID)
        XCTAssertEqual(result.itemCount, 1)
        XCTAssertEqual(result.resourceCount, 1)
        XCTAssertEqual(result.verifiedBytes, Int64(bytes.count))
        XCTAssertEqual(result.manifestSHA256.count, 64)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(item.tagDecisions.first?.decision, .rejected)
        XCTAssertEqual(item.collections.first?.included, true)

        try Data("synthetic-original-changed".utf8).write(
            to: root.appendingPathComponent("resources/\(resourceID.uuidString.lowercased()).jpg")
        )
        XCTAssertThrowsError(try ImageAllMigrationArchive.verify(at: root)) { error in
            XCTAssertEqual(error as? ImageAllMigrationArchiveError, .resourceChanged)
        }
    }

    func testMissingRequiredResourceIsReportedWithoutClaimingCompletion() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let mediaID = UUID()
        let resourceID = UUID()
        let item = ImageAllMigrationItem(
            mediaID: mediaID, sourceLocalIdentifier: "fixture-local",
            mediaKind: .image, createdAtMs: nil,
            favoriteTarget: true, observedFavorite: false, factRevision: 2,
            tagDecisions: [], collections: [], resources: [
                .init(id: resourceID, role: "original", version: 1,
                      uniformTypeIdentifier: "public.jpeg",
                      required: true, status: .notLocal,
                      relativePath: nil, byteCount: nil, sha256: nil)
            ]
        )
        try ImageAllMigrationArchive.write(
            header: header(migrationID: UUID(), count: 1), items: [item], to: root
        )
        let result = try ImageAllMigrationArchive.verify(at: root)
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(result.incompleteMediaIDs, [mediaID])
        XCTAssertEqual(result.verifiedBytes, 0)
        XCTAssertEqual(result.unavailableResources.count, 1)
        XCTAssertEqual(result.unavailableResources.first?.mediaID, mediaID)
        XCTAssertEqual(result.unavailableResources.first?.resourceID, resourceID)
        XCTAssertEqual(result.unavailableResources.first?.role, "original")
        XCTAssertEqual(result.unavailableResources.first?.status, .notLocal)
        XCTAssertEqual(result.unavailableResources.first?.required, true)
    }

    func testMissingLivePhotoPairKeepsArchiveIncompleteEvenWithOriginalPhoto() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try makeItem(
            root: root, resourceID: UUID(), bytes: Data("synthetic-live-photo".utf8)
        )
        let item = ImageAllMigrationItem(
            mediaID: original.mediaID,
            sourceLocalIdentifier: original.sourceLocalIdentifier,
            mediaKind: .image, createdAtMs: original.createdAtMs,
            favoriteTarget: original.favoriteTarget,
            observedFavorite: original.observedFavorite,
            factRevision: original.factRevision,
            tagDecisions: original.tagDecisions, collections: original.collections,
            resources: original.resources + [.init(
                id: UUID(), role: "pairedVideo", version: 1,
                uniformTypeIdentifier: "com.apple.quicktime-movie",
                required: true, status: .notLocal,
                relativePath: nil, byteCount: nil, sha256: nil
            )]
        )
        try ImageAllMigrationArchive.write(
            header: header(migrationID: UUID(), count: 1), items: [item], to: root
        )
        let verification = try ImageAllMigrationArchive.verify(at: root)
        XCTAssertFalse(verification.isComplete)
        XCTAssertEqual(verification.resourceCount, 1)
        XCTAssertEqual(verification.incompleteMediaIDs, [item.mediaID])
        XCTAssertEqual(verification.unavailableResources.map(\.role), ["pairedVideo"])
    }

    func testUnavailableOptionalResourceAlsoBlocksCurrentMacImport() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try makeItem(
            root: root, resourceID: UUID(), bytes: Data("synthetic-original".utf8)
        )
        let item = ImageAllMigrationItem(
            mediaID: original.mediaID,
            sourceLocalIdentifier: original.sourceLocalIdentifier,
            mediaKind: original.mediaKind, createdAtMs: original.createdAtMs,
            favoriteTarget: original.favoriteTarget,
            observedFavorite: original.observedFavorite,
            factRevision: original.factRevision,
            tagDecisions: original.tagDecisions,
            collections: original.collections,
            resources: original.resources + [.init(
                id: UUID(), role: "adjustmentData", version: 1,
                uniformTypeIdentifier: "public.data", required: false,
                status: .unsupported, relativePath: nil,
                byteCount: nil, sha256: nil
            )]
        )
        try ImageAllMigrationArchive.write(
            header: header(migrationID: UUID(), count: 1), items: [item], to: root
        )
        let verification = try ImageAllMigrationArchive.verify(at: root)
        XCTAssertFalse(verification.isComplete)
        XCTAssertTrue(verification.incompleteMediaIDs.isEmpty)
        XCTAssertEqual(verification.unavailableResources.map(\.status), [.unsupported])
        XCTAssertEqual(verification.unavailableResources.map(\.required), [false])
    }

    func testVerifiedVisitorStreamsRecordsAndDetectsSourceChangingDuringImport() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("stable original".utf8)
        let item = try makeItem(root: root, resourceID: UUID(), bytes: bytes)
        let header = header(migrationID: UUID(), count: 1)
        try ImageAllMigrationArchive.write(header: header, items: [item], to: root)
        let (readHeader, expected) = try ImageAllMigrationArchive.readVerifiedHeader(at: root)
        XCTAssertEqual(readHeader, header)
        var visited: [UUID] = []
        let result = try ImageAllMigrationArchive.visitVerifiedRecords(
            at: root,
            onHeader: { XCTAssertEqual($0, header) },
            onItem: { visited.append($0.mediaID) }
        )
        XCTAssertEqual(result, expected)
        XCTAssertEqual(visited, [item.mediaID])

        XCTAssertThrowsError(try ImageAllMigrationArchive.visitVerifiedRecords(
            at: root,
            onHeader: { _ in },
            onItem: { record in
                try Data("changed during import".utf8).write(
                    to: root.appendingPathComponent(record.resources[0].relativePath!)
                )
            }
        )) { error in
            XCTAssertEqual(error as? ImageAllMigrationArchiveError, .resourceChanged)
        }
    }

    func testRejectsSymlinkAndUnfinishedOrDuplicateManifest() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let resourceID = UUID()
        let bytes = Data("fixture".utf8)
        let item = try makeItem(root: root, resourceID: resourceID, bytes: bytes)
        try ImageAllMigrationArchive.write(
            header: header(migrationID: UUID(), count: 2), items: [item], to: root
        )
        XCTAssertThrowsError(try ImageAllMigrationArchive.verify(at: root)) { error in
            XCTAssertEqual(error as? ImageAllMigrationArchiveError, .invalidManifest)
        }

        let manifest = root.appendingPathComponent(ImageAllMigrationArchive.manifestFilename)
        try FileManager.default.removeItem(at: manifest)
        try ImageAllMigrationArchive.write(
            header: header(migrationID: UUID(), count: 2), items: [item, item], to: root
        )
        XCTAssertThrowsError(try ImageAllMigrationArchive.verify(at: root)) { error in
            XCTAssertEqual(error as? ImageAllMigrationArchiveError, .duplicateIdentity)
        }

        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.removeItem(at: root.appendingPathComponent("resources"))
        let external = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: external) }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("resources"), withDestinationURL: external
        )
        try ImageAllMigrationArchive.write(
            header: header(migrationID: UUID(), count: 1), items: [item], to: root
        )
        XCTAssertThrowsError(try ImageAllMigrationArchive.verify(at: root)) { error in
            XCTAssertEqual(error as? ImageAllMigrationArchiveError, .unsafeResourcePath)
        }
    }

    func testPublishesIndependentVerifiedCopyWithoutChangingSource() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let targetParent = makeRoot()
        defer { try? FileManager.default.removeItem(at: targetParent) }
        let resourceID = UUID()
        let bytes = Data("independent synthetic original".utf8)
        let item = try makeItem(root: root, resourceID: resourceID, bytes: bytes)
        try ImageAllMigrationArchive.write(
            header: header(migrationID: UUID(), count: 1), items: [item], to: root
        )
        let sourceVerification = try ImageAllMigrationArchive.verify(at: root)
        let copy = try ImageAllMigrationArchive.publishVerifiedCopy(
            from: root, to: targetParent
        )
        XCTAssertNotEqual(copy.path, root.path)
        XCTAssertEqual(try ImageAllMigrationArchive.verify(at: copy), sourceVerification)
        XCTAssertEqual(try ImageAllMigrationArchive.verify(at: root), sourceVerification)
        XCTAssertThrowsError(try ImageAllMigrationArchive.publishVerifiedCopy(
            from: root, to: targetParent
        )) { error in
            XCTAssertEqual(error as? ImageAllMigrationArchiveError, .destinationCollision)
        }
        XCTAssertThrowsError(try ImageAllMigrationArchive.publishVerifiedCopy(
            from: root, to: root
        )) { error in
            XCTAssertEqual(error as? ImageAllMigrationArchiveError, .destinationOverlap)
        }
    }

    func testRejectsResourcePathThatDoesNotUseReceiverGeneratedName() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let resourceID = UUID()
        let bytes = Data("fixture".utf8)
        let original = try makeItem(root: root, resourceID: resourceID, bytes: bytes)
        let resource = try XCTUnwrap(original.resources.first)
        let item = ImageAllMigrationItem(
            mediaID: original.mediaID,
            sourceLocalIdentifier: original.sourceLocalIdentifier,
            mediaKind: original.mediaKind,
            createdAtMs: original.createdAtMs,
            favoriteTarget: original.favoriteTarget,
            observedFavorite: original.observedFavorite,
            factRevision: original.factRevision,
            tagDecisions: original.tagDecisions,
            collections: original.collections,
            resources: [.init(
                id: resource.id, role: resource.role, version: resource.version,
                uniformTypeIdentifier: resource.uniformTypeIdentifier,
                required: true, status: .present,
                relativePath: "resources/../escape.jpg",
                byteCount: resource.byteCount, sha256: resource.sha256
            )]
        )
        try ImageAllMigrationArchive.write(
            header: header(migrationID: UUID(), count: 1), items: [item], to: root
        )
        XCTAssertThrowsError(try ImageAllMigrationArchive.verify(at: root)) { error in
            XCTAssertEqual(error as? ImageAllMigrationArchiveError, .unsafeResourcePath)
        }
    }

    func testSourceMetadataPreservesUnknownsAndRejectsInvalidObservations() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = try makeItem(root: root, resourceID: UUID(), bytes: Data("metadata-fixture".utf8))
        let metadata = ImageAllMigrationSourceMetadata(pixelWidth: 4032, pixelHeight: 3024,
            durationSeconds: 1.25, modifiedAtMs: -1_000,
            location: .init(latitude: 0, longitude: 0, horizontalAccuracyMeters: 12.5,
                            altitudeMeters: -20, verticalAccuracyMeters: 3, observedAtMs: 100))
        let item = ImageAllMigrationItem(mediaID: base.mediaID, sourceLocalIdentifier: base.sourceLocalIdentifier,
            mediaKind: base.mediaKind, createdAtMs: base.createdAtMs, favoriteTarget: base.favoriteTarget,
            observedFavorite: base.observedFavorite, factRevision: base.factRevision,
            tagDecisions: base.tagDecisions, collections: base.collections, resources: base.resources,
            sourceMetadata: metadata)
        try ImageAllMigrationArchive.write(header: header(migrationID: UUID(), count: 1), items: [item], to: root)
        var restored: ImageAllMigrationSourceMetadata?
        _ = try ImageAllMigrationArchive.visitVerifiedRecords(at: root, onHeader: { _ in },
            onItem: { restored = $0.sourceMetadata })
        XCTAssertEqual(restored, metadata)
        let old = try JSONDecoder().decode(ImageAllMigrationItem.self, from: JSONEncoder().encode(base))
        XCTAssertNil(old.sourceMetadata)
        XCTAssertNoThrow(try ImageAllMigrationSourceMetadata().validate())
        for invalid in [
            ImageAllMigrationSourceMetadata(pixelWidth: 0),
            .init(durationSeconds: -.infinity),
            .init(location: .init(latitude: 91, longitude: 0, horizontalAccuracyMeters: 1)),
            .init(location: .init(latitude: 0, longitude: 0, horizontalAccuracyMeters: -1)),
            .init(location: .init(latitude: 0, longitude: 0, horizontalAccuracyMeters: 1, altitudeMeters: 0))
        ] { XCTAssertThrowsError(try invalid.validate()) }
        let manifest = root.appendingPathComponent(ImageAllMigrationArchive.manifestFilename)
        var lines = try String(contentsOf: manifest, encoding: .utf8).split(separator: "\n").map(String.init)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
        object["sourceMetadata"] = ["pixelWidth": -1]
        lines[1] = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: manifest)
        XCTAssertThrowsError(try ImageAllMigrationArchive.verify(at: root))
    }

    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageAllArchive-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func header(migrationID: UUID, count: Int) -> ImageAllMigrationHeader {
        .init(migrationID: migrationID, sourceDeviceID: UUID(), sourceEpoch: UUID(),
              scopeRevision: 1, inventoryWatermark: 9, declaredItemCount: count)
    }

    private func makeItem(root: URL, resourceID: UUID, bytes: Data) throws -> ImageAllMigrationItem {
        let directory = root.appendingPathComponent("resources", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "\(resourceID.uuidString.lowercased()).jpg"
        try bytes.write(to: directory.appendingPathComponent(name))
        let hash = Data(SHA256.hash(data: bytes)).map { String(format: "%02x", $0) }.joined()
        return ImageAllMigrationItem(
            mediaID: UUID(), sourceLocalIdentifier: "fixture-local",
            mediaKind: .image, createdAtMs: 1_000,
            favoriteTarget: true, observedFavorite: false, factRevision: 3,
            tagDecisions: [.init(tagID: UUID(), tagName: "family", decision: .rejected)],
            collections: [.init(collectionID: UUID(), collectionName: "trip", included: true)],
            resources: [
                .init(id: resourceID, role: "original", version: 1,
                      uniformTypeIdentifier: "public.jpeg",
                      required: true, status: .present,
                      relativePath: "resources/\(name)",
                      byteCount: Int64(bytes.count), sha256: hash)
            ]
        )
    }
}
