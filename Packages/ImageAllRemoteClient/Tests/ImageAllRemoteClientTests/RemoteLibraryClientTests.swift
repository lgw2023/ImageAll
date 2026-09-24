import Foundation
import ImageAllRemoteClient
import ImageAllRemoteProtocol
import XCTest

final class RemoteLibraryClientTests: XCTestCase {
    func testPostsCollectionMembershipWithStableOperationID() async throws {
        let request = RemoteLocalLibraryCollectionMembershipRequest(
            hostID: UUID(), installID: UUID(), sourceEpoch: UUID(),
            scopeRevision: 2, operationID: UUID(), deviceSequence: 19,
            assetID: UUID(), collectionID: UUID(), collectionName: "旅行",
            included: false, baseRevision: 1
        )
        let transport = MockTransport { outgoing in
            XCTAssertEqual(outgoing.httpMethod, "POST")
            XCTAssertEqual(outgoing.url?.path, RemoteHTTPPaths.localLibraryCollectionMembership)
            XCTAssertEqual(outgoing.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            XCTAssertEqual(try JSONDecoder().decode(
                RemoteLocalLibraryCollectionMembershipRequest.self,
                from: XCTUnwrap(outgoing.httpBody)
            ), request)
            let response = RemoteLocalLibraryCollectionMembershipReceipt(
                hostID: request.hostID, deviceID: UUID(),
                operationID: request.operationID, disposition: .applied,
                fieldRevision: 2, currentIncluded: false, replayed: false
            )
            return (
                try JSONEncoder().encode(response),
                HTTPURLResponse(url: outgoing.url!, statusCode: 200,
                                httpVersion: "HTTP/1.1", headerFields: nil)!
            )
        }
        let client = RemoteLibraryClient(
            endpoint: try RemoteHostEndpoint(host: "127.0.0.1", port: 8787, accessToken: "secret"),
            transport: transport
        )
        let receipt = try await client.submitLocalLibraryCollectionMembership(request)
        XCTAssertEqual(receipt.operationID, request.operationID)
        XCTAssertEqual(receipt.currentIncluded, false)
    }

    func testFetchesScopedMacTagChangesWithBearerToken() async throws {
        let hostID = UUID()
        let deviceID = UUID()
        let epoch = UUID()
        let change = RemoteLocalLibraryTagChange(
            sequence: 8, scopeRevision: 2, assetID: UUID(), tagID: UUID(),
            tagName: "family", decision: .rejected, fieldRevision: 3
        )
        let transport = MockTransport { outgoing in
            XCTAssertEqual(outgoing.httpMethod, "GET")
            XCTAssertEqual(outgoing.url?.path, RemoteHTTPPaths.localLibraryTagChanges)
            XCTAssertEqual(outgoing.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            let query = URLComponents(url: try XCTUnwrap(outgoing.url), resolvingAgainstBaseURL: false)?
                .queryItems ?? []
            XCTAssertEqual(query.first(where: { $0.name == "sourceEpoch" })?.value, epoch.uuidString)
            XCTAssertEqual(query.first(where: { $0.name == "scopeRevision" })?.value, "2")
            XCTAssertEqual(query.first(where: { $0.name == "afterCursor" })?.value, "7")
            let page = RemoteLocalLibraryTagChangesPage(
                hostID: hostID, deviceID: deviceID, sourceEpoch: epoch,
                scopeRevision: 2, changes: [change], nextCursor: 8, hasMore: false
            )
            return (
                try JSONEncoder().encode(page),
                HTTPURLResponse(url: outgoing.url!, statusCode: 200,
                                httpVersion: "HTTP/1.1", headerFields: nil)!
            )
        }
        let client = RemoteLibraryClient(
            endpoint: try RemoteHostEndpoint(host: "127.0.0.1", port: 8787, accessToken: "secret"),
            transport: transport
        )
        let page = try await client.fetchLocalLibraryTagChanges(
            sourceEpoch: epoch, scopeRevision: 2, afterCursor: 7
        )
        XCTAssertEqual(page.changes, [change])
        XCTAssertEqual(page.nextCursor, 8)
    }

    func testPostsVersionedPhoneTagDecisionWithStableOperationID() async throws {
        let request = RemoteLocalLibraryTagDecisionRequest(
            hostID: UUID(), installID: UUID(), sourceEpoch: UUID(),
            scopeRevision: 2, operationID: UUID(), deviceSequence: 18,
            assetID: UUID(), tagID: UUID(), tagName: "家庭",
            decision: .rejected, baseRevision: 3
        )
        let transport = MockTransport { outgoing in
            XCTAssertEqual(outgoing.httpMethod, "POST")
            XCTAssertEqual(outgoing.url?.path, RemoteHTTPPaths.localLibraryTagDecision)
            XCTAssertEqual(outgoing.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            XCTAssertEqual(try JSONDecoder().decode(
                RemoteLocalLibraryTagDecisionRequest.self,
                from: XCTUnwrap(outgoing.httpBody)
            ), request)
            let response = RemoteLocalLibraryTagDecisionReceipt(
                hostID: request.hostID, deviceID: UUID(),
                operationID: request.operationID, disposition: .applied,
                fieldRevision: 4, currentDecision: .rejected, replayed: false
            )
            return (
                try JSONEncoder().encode(response),
                HTTPURLResponse(url: outgoing.url!, statusCode: 200,
                                httpVersion: "HTTP/1.1", headerFields: nil)!
            )
        }
        let client = RemoteLibraryClient(
            endpoint: try RemoteHostEndpoint(host: "127.0.0.1", port: 8787, accessToken: "secret"),
            transport: transport
        )
        let receipt = try await client.submitLocalLibraryTagDecision(request)
        XCTAssertEqual(receipt.operationID, request.operationID)
        XCTAssertEqual(receipt.fieldRevision, 4)
        XCTAssertNil(receipt.conflictReason)
    }

    func testPostsExplicitLocalLibrarySnapshotWithBearerToken() async throws {
        let hostID = UUID()
        let assetID = UUID()
        let request = RemoteLocalLibrarySnapshotRequest(
            hostID: hostID, installID: UUID(), sourceEpoch: UUID(),
            scopeRevision: 1, snapshotSequence: 2, selectedAssetIDs: [assetID],
            assets: [RemoteLocalLibraryAsset(
                id: assetID, localIdentifier: "local-only-identifier", mediaKind: .image,
                createdAtMs: nil, observedFavorite: false, favoriteTarget: true,
                tagDecisions: [], collections: []
            )]
        )
        let transport = MockTransport { outgoing in
            XCTAssertEqual(outgoing.httpMethod, "POST")
            XCTAssertEqual(outgoing.url?.path, RemoteHTTPPaths.localLibrarySnapshot)
            XCTAssertEqual(outgoing.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            XCTAssertEqual(try JSONDecoder().decode(
                RemoteLocalLibrarySnapshotRequest.self,
                from: XCTUnwrap(outgoing.httpBody)
            ), request)
            let response = RemoteLocalLibrarySnapshotReceipt(
                hostID: hostID, deviceID: UUID(), sourceEpoch: request.sourceEpoch,
                snapshotSequence: request.snapshotSequence, acceptedAssetCount: 1,
                replayed: false
            )
            return (
                try JSONEncoder().encode(response),
                HTTPURLResponse(url: outgoing.url!, statusCode: 200,
                                httpVersion: "HTTP/1.1", headerFields: nil)!
            )
        }
        let client = RemoteLibraryClient(
            endpoint: try RemoteHostEndpoint(host: "127.0.0.1", port: 8787, accessToken: "secret"),
            transport: transport
        )
        let receipt = try await client.submitLocalLibrarySnapshot(request)
        XCTAssertEqual(receipt.hostID, hostID)
        XCTAssertEqual(receipt.acceptedAssetCount, 1)
    }

    func testFetchesCapabilitiesAndSourcesWithBearerToken() async throws {
        let transport = MockTransport { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            XCTAssertEqual(request.url?.path, "/v1/capabilities")
            let payload = try JSONEncoder().encode(
                RemoteCapabilities(hostAppVersion: "1.2.3", listenPort: 8787)
            )
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (payload, response)
        }
        let client = RemoteLibraryClient(
            endpoint: try RemoteHostEndpoint(host: "127.0.0.1", port: 8787, accessToken: "secret"),
            transport: transport
        )
        let capabilities = try await client.fetchCapabilities()
        XCTAssertEqual(capabilities.hostAppVersion, "1.2.3")
        XCTAssertEqual(capabilities.listenPort, 8787)
    }

    func testBuildsAssetPageQuery() async throws {
        let sourceID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let acceptedTagID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        let excludedTagID = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
        let transport = MockTransport { request in
            XCTAssertEqual(request.url?.path, "/v1/assets")
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let map = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(map["sourceIDs"], sourceID.uuidString)
            XCTAssertEqual(map["sort"], "newest")
            XCTAssertEqual(map["limit"], "40")
            XCTAssertEqual(map["q"], "beach")
            XCTAssertEqual(map["cursor"], "abc")
            XCTAssertEqual(map["acceptedTagIDs"], acceptedTagID.uuidString)
            XCTAssertEqual(map["excludedTagIDs"], excludedTagID.uuidString)
            XCTAssertEqual(map["tagMatchMode"], "any")
            XCTAssertEqual(map["availabilities"], "available")
            XCTAssertEqual(map["mediaKinds"], "video")
            XCTAssertEqual(map["tagPresence"], "tagged")
            let payload = try JSONEncoder().encode(RemoteAssetPage(items: [], nextCursor: nil))
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (payload, response)
        }
        let client = RemoteLibraryClient(
            endpoint: try RemoteHostEndpoint(host: "127.0.0.1", port: 8787, accessToken: "secret"),
            transport: transport
        )
        _ = try await client.fetchAssets(
            RemoteAssetPageRequest(
                sourceIDs: [sourceID],
                searchText: "beach",
                sort: .newest,
                limit: 40,
                cursor: "abc",
                tagDecisionFilters: [
                    RemoteAssetTagDecisionFilter(tagID: acceptedTagID, decision: .accepted)
                ],
                excludedTagIDs: [excludedTagID],
                tagMatchMode: .any,
                availabilities: [.available],
                mediaKinds: [.video],
                tagPresence: .tagged
            )
        )
    }

    func testMapsUnauthorizedAPIError() async throws {
        let transport = MockTransport { request in
            let payload = try JSONEncoder().encode(
                RemoteAPIError(code: .unauthorized, message: "invalid or missing bearer token")
            )
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (payload, response)
        }
        let client = RemoteLibraryClient(
            endpoint: try RemoteHostEndpoint(host: "127.0.0.1", port: 8787, accessToken: "bad"),
            transport: transport
        )
        do {
            _ = try await client.fetchSources()
            XCTFail("expected unauthorized")
        } catch let error as RemoteAPIError {
            XCTAssertEqual(error.code, .unauthorized)
        }
    }

    func testPostsTagDecisionBody() async throws {
        let operationID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let tagID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let assetID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let transport = MockTransport { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/tag-decisions/batch")
            let body = try XCTUnwrap(request.httpBody)
            let decoded = try JSONDecoder().decode(RemoteBatchTagDecisionRequest.self, from: body)
            XCTAssertEqual(decoded.operationID, operationID)
            XCTAssertEqual(decoded.tagID, tagID)
            XCTAssertEqual(decoded.assetIDs, [assetID])
            XCTAssertEqual(decoded.action, .accept)
            let payload = try JSONEncoder().encode(
                RemoteBatchTagDecisionResponse(
                    operationID: operationID,
                    appliedAssetCount: 1,
                    replayed: false
                )
            )
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (payload, response)
        }
        let client = RemoteLibraryClient(
            endpoint: try RemoteHostEndpoint(host: "127.0.0.1", port: 8787, accessToken: "secret"),
            transport: transport
        )
        let response = try await client.applyTagDecision(
            RemoteBatchTagDecisionRequest(
                operationID: operationID,
                tagID: tagID,
                assetIDs: [assetID],
                action: .accept
            )
        )
        XCTAssertEqual(response.appliedAssetCount, 1)
        XCTAssertFalse(response.replayed)
    }

    func testPostsPresetTagInstallation() async throws {
        let operationID = UUID()
        let tag = RemoteTagSummary(
            id: UUID(),
            displayName: "风景",
            state: .active,
            groupID: UUID()
        )
        let transport = MockTransport { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/tags/install-presets")
            let decoded = try JSONDecoder().decode(
                RemoteInstallPresetTagsRequest.self,
                from: try XCTUnwrap(request.httpBody)
            )
            XCTAssertEqual(decoded.operationID, operationID)
            return try Self.jsonResponse(
                RemoteInstallPresetTagsResponse(
                    operationID: operationID,
                    createdTags: [tag],
                    replayed: false
                ),
                for: request
            )
        }
        let client = RemoteLibraryClient(
            endpoint: try RemoteHostEndpoint(
                host: "127.0.0.1",
                port: 8787,
                accessToken: "secret"
            ),
            transport: transport
        )

        let response = try await client.installPresetTags(
            RemoteInstallPresetTagsRequest(operationID: operationID)
        )
        XCTAssertEqual(response.createdTags, [tag])
        XCTAssertFalse(response.replayed)
    }

    func testCreatesTagAndAppliesItToSelectedAssets() async throws {
        let operationID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let tagID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let assetIDs = [
            UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
        ]
        let transport = MockTransport { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, RemoteHTTPPaths.tagsCreateAndApply)
            let body = try XCTUnwrap(request.httpBody)
            let decoded = try JSONDecoder().decode(RemoteCreateTagAndApplyRequest.self, from: body)
            XCTAssertEqual(decoded.operationID, operationID)
            XCTAssertEqual(decoded.name, "旅行")
            XCTAssertEqual(decoded.assetIDs, assetIDs)
            return try Self.jsonResponse(
                RemoteCreateTagAndApplyResponse(
                    operationID: operationID,
                    tagID: tagID,
                    displayName: "旅行",
                    appliedAssetCount: 2,
                    replayed: false
                ),
                for: request
            )
        }
        let client = RemoteLibraryClient(
            endpoint: try RemoteHostEndpoint(
                host: "127.0.0.1",
                port: 8787,
                accessToken: "secret"
            ),
            transport: transport
        )

        let response = try await client.createTagAndApply(
            RemoteCreateTagAndApplyRequest(
                operationID: operationID,
                name: "旅行",
                assetIDs: assetIDs
            )
        )

        XCTAssertEqual(response.tagID, tagID)
        XCTAssertEqual(response.appliedAssetCount, 2)
    }

    func testFetchesReviewOverviewAndUndoesLatestTagDecision() async throws {
        let sourceID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let undoID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        let operationID = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
        let transport = MockTransport { request in
            if request.httpMethod == "GET" {
                XCTAssertEqual(request.url?.path, RemoteHTTPPaths.reviewOverview)
                let items = URLComponents(
                    url: request.url!,
                    resolvingAgainstBaseURL: false
                )?.queryItems ?? []
                let map = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
                XCTAssertEqual(map["mediaKind"], "video")
                XCTAssertEqual(map["sourceIDs"], sourceID.uuidString)
                return try Self.jsonResponse(
                    RemoteReviewOverview(totalPendingSuggestionCount: 3, tags: []),
                    for: request
                )
            }

            XCTAssertEqual(request.url?.path, RemoteHTTPPaths.tagDecisionsUndo)
            let body = try XCTUnwrap(request.httpBody)
            let decoded = try JSONDecoder().decode(RemoteUndoTagDecisionRequest.self, from: body)
            XCTAssertEqual(decoded.operationID, operationID)
            XCTAssertEqual(decoded.undoID, undoID)
            return try Self.jsonResponse(
                RemoteUndoTagDecisionResponse(
                    operationID: operationID,
                    restoredAssetCount: 2,
                    replayed: false
                ),
                for: request
            )
        }
        let client = RemoteLibraryClient(
            endpoint: try RemoteHostEndpoint(
                host: "127.0.0.1",
                port: 8787,
                accessToken: "secret"
            ),
            transport: transport
        )

        let overview = try await client.fetchReviewOverview(
            mediaKind: .video,
            sourceIDs: [sourceID]
        )
        let undo = try await client.undoTagDecision(
            RemoteUndoTagDecisionRequest(operationID: operationID, undoID: undoID)
        )

        XCTAssertEqual(overview.totalPendingSuggestionCount, 3)
        XCTAssertEqual(undo.restoredAssetCount, 2)
    }

    func testManagesTagsAndTagGroupsThroughNarrowRoutes() async throws {
        let tagID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let groupID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let operationID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let tag = RemoteTagSummary(
            id: tagID,
            displayName: "旅行",
            state: .active,
            groupID: groupID
        )
        let group = RemoteTagGroupSummary(
            id: groupID,
            displayName: "主题",
            sortOrder: 1,
            isSystem: false
        )
        let transport = MockTransport { request in
            switch request.url?.path {
            case RemoteHTTPPaths.tagGroups where request.httpMethod == "GET":
                return try Self.jsonResponse([group], for: request)
            case RemoteHTTPPaths.tagRename(tagID: tagID):
                let body = try XCTUnwrap(request.httpBody)
                XCTAssertEqual(
                    try JSONDecoder().decode(RemoteRenameTagRequest.self, from: body).name,
                    "新旅行"
                )
                return try Self.jsonResponse(
                    RemoteTagMutationResponse(operationID: operationID, tag: tag, replayed: false),
                    for: request
                )
            case RemoteHTTPPaths.tagMove(tagID: tagID):
                let body = try XCTUnwrap(request.httpBody)
                XCTAssertEqual(
                    try JSONDecoder().decode(RemoteMoveTagRequest.self, from: body).groupID,
                    groupID
                )
                return try Self.jsonResponse(
                    RemoteTagMutationResponse(operationID: operationID, tag: tag, replayed: false),
                    for: request
                )
            case RemoteHTTPPaths.tagArchive(tagID: tagID):
                return try Self.jsonResponse(
                    RemoteTagMutationResponse(operationID: operationID, tag: nil, replayed: false),
                    for: request
                )
            case RemoteHTTPPaths.tagGroups where request.httpMethod == "POST":
                return try Self.jsonResponse(
                    RemoteTagGroupMutationResponse(
                        operationID: operationID,
                        group: group,
                        replayed: false
                    ),
                    for: request
                )
            case RemoteHTTPPaths.tagGroupRename(groupID: groupID):
                return try Self.jsonResponse(
                    RemoteTagGroupMutationResponse(
                        operationID: operationID,
                        group: group,
                        replayed: false
                    ),
                    for: request
                )
            case RemoteHTTPPaths.tagGroupDelete(groupID: groupID):
                return try Self.jsonResponse(
                    RemoteTagGroupMutationResponse(
                        operationID: operationID,
                        group: nil,
                        replayed: false
                    ),
                    for: request
                )
            default:
                XCTFail("unexpected route \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }
        let client = RemoteLibraryClient(
            endpoint: try RemoteHostEndpoint(
                host: "127.0.0.1",
                port: 8787,
                accessToken: "secret"
            ),
            transport: transport
        )

        let groups = try await client.fetchTagGroups()
        XCTAssertEqual(groups, [group])
        _ = try await client.renameTag(
            tagID: tagID,
            request: RemoteRenameTagRequest(operationID: operationID, name: "新旅行")
        )
        _ = try await client.moveTag(
            tagID: tagID,
            request: RemoteMoveTagRequest(operationID: operationID, groupID: groupID)
        )
        _ = try await client.archiveTag(
            tagID: tagID,
            request: RemoteArchiveTagRequest(operationID: operationID)
        )
        _ = try await client.createTagGroup(
            RemoteCreateTagGroupRequest(operationID: operationID, name: "主题")
        )
        _ = try await client.renameTagGroup(
            groupID: groupID,
            request: RemoteRenameTagGroupRequest(operationID: operationID, name: "新主题")
        )
        _ = try await client.deleteTagGroup(
            groupID: groupID,
            request: RemoteDeleteTagGroupRequest(operationID: operationID)
        )
    }

    func testLoadsAssetDetailAndPreviewAtRequestedWidth() async throws {
        let assetID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let transport = MockTransport { request in
            if request.url?.path == "/v1/assets/\(assetID.uuidString)" {
                let detail = RemoteAssetDetail(
                    assetID: assetID,
                    sourceID: UUID(),
                    sourceName: "Fixture",
                    fileName: "sample.jpg",
                    relativePath: "sample.jpg",
                    mediaType: "image",
                    availability: .available,
                    contentRevision: 1,
                    acceptedTagCount: 0,
                    rejectedTagCount: 0,
                    mediaCreatedAtMs: nil,
                    mediaModifiedAtMs: nil,
                    width: 1200,
                    height: 800,
                    tags: []
                )
                return try Self.jsonResponse(detail, for: request)
            }
            XCTAssertEqual(request.url?.path, "/v1/assets/\(assetID.uuidString)/preview")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query?.first(where: { $0.name == "w" })?.value, "1440")
            return (
                Data([0xFF, 0xD8, 0xFF]),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "image/jpeg"]
                )!
            )
        }
        let client = RemoteLibraryClient(
            endpoint: try RemoteHostEndpoint(host: "127.0.0.1", port: 8787, accessToken: "secret"),
            transport: transport
        )

        let detail = try await client.fetchAssetDetail(assetID: assetID)
        let preview = try await client.loadPreview(assetID: assetID, targetPixelWidth: 1440)

        XCTAssertEqual(detail.assetID, assetID)
        XCTAssertEqual(preview, Data([0xFF, 0xD8, 0xFF]))
    }

    func testDownloadsCloudPreviewOnlyThroughExplicitPost() async throws {
        let assetID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let transport = MockTransport { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(
                request.url?.path,
                "/v1/assets/\(assetID.uuidString)/cloud-preview"
            )
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            return (
                Data([0x89, 0x50, 0x4E, 0x47]),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "image/png"]
                )!
            )
        }
        let client = RemoteLibraryClient(
            endpoint: try RemoteHostEndpoint(
                host: "127.0.0.1",
                port: 8787,
                accessToken: "secret"
            ),
            transport: transport
        )

        let preview = try await client.downloadCloudPreview(assetID: assetID)
        XCTAssertEqual(preview, Data([0x89, 0x50, 0x4E, 0x47]))
    }

    func testBuildsReviewQueueQueryAndPostsDecision() async throws {
        let tagID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let sourceID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let assetID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let operationID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let transport = MockTransport { request in
            if request.httpMethod == "GET" {
                XCTAssertEqual(request.url?.path, "/v1/review/queue")
                let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let map = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
                XCTAssertEqual(map["tagID"], tagID.uuidString)
                XCTAssertEqual(map["sourceIDs"], sourceID.uuidString)
                XCTAssertEqual(map["mediaKind"], "video")
                XCTAssertEqual(map["limit"], "20")
                XCTAssertEqual(map["cursor"], "next")
                return try Self.jsonResponse(
                    RemoteReviewQueuePage(items: [], nextCursor: nil),
                    for: request
                )
            }

            XCTAssertEqual(request.url?.path, "/v1/review/decisions/batch")
            let body = try XCTUnwrap(request.httpBody)
            let decoded = try JSONDecoder().decode(RemoteBatchReviewDecisionRequest.self, from: body)
            XCTAssertEqual(decoded.operationID, operationID)
            XCTAssertEqual(decoded.tagID, tagID)
            XCTAssertEqual(decoded.assetIDs, [assetID])
            XCTAssertEqual(decoded.action, .accept)
            return try Self.jsonResponse(
                RemoteBatchReviewDecisionResponse(
                    operationID: operationID,
                    appliedAssetCount: 1,
                    replayed: false
                ),
                for: request
            )
        }
        let client = RemoteLibraryClient(
            endpoint: try RemoteHostEndpoint(host: "127.0.0.1", port: 8787, accessToken: "secret"),
            transport: transport
        )

        _ = try await client.fetchReviewQueue(
            RemoteReviewQueueRequest(
                tagID: tagID,
                sourceIDs: [sourceID],
                mediaKind: .video,
                limit: 20,
                cursor: "next"
            )
        )
        let response = try await client.applyReviewDecision(
            RemoteBatchReviewDecisionRequest(
                operationID: operationID,
                tagID: tagID,
                assetIDs: [assetID],
                action: .accept
            )
        )

        XCTAssertEqual(response.appliedAssetCount, 1)
    }

    func testPostsJobAction() async throws {
        let jobID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let transport = MockTransport { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/jobs/\(jobID.uuidString)/actions")
            let body = try XCTUnwrap(request.httpBody)
            XCTAssertEqual(
                try JSONDecoder().decode(RemoteJobActionRequest.self, from: body).action,
                .pause
            )
            return (
                Data(),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
            )
        }
        let client = RemoteLibraryClient(
            endpoint: try RemoteHostEndpoint(host: "127.0.0.1", port: 8787, accessToken: "secret"),
            transport: transport
        )

        try await client.applyJobAction(jobID: jobID, action: .pause)
    }

    func testHostEndpointBracketsIPv6() throws {
        let endpoint = try RemoteHostEndpoint(
            host: "fe80::1",
            port: 8787,
            accessToken: "secret"
        )
        XCTAssertEqual(endpoint.baseURL.absoluteString, "http://[fe80::1]:8787")
    }

    func testPublicHostEndpointUsesCanonicalSystemTrustedHTTPSURL() throws {
        let endpoint = try RemoteHostEndpoint(
            publicHTTPSBaseURL: " HTTPS://ImageAll.UltraHardcore.Net:443/ ",
            accessToken: "secret"
        )

        XCTAssertEqual(
            endpoint.baseURL.absoluteString,
            "https://imageall.ultrahardcore.net"
        )
        XCTAssertTrue(endpoint.usesTLS)
    }

    private static func jsonResponse<T: Encodable>(
        _ value: T,
        for request: URLRequest
    ) throws -> (Data, URLResponse) {
        (
            try JSONEncoder().encode(value),
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
        )
    }
}

private struct MockTransport: RemoteHTTPTransporting {
    let handler: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await handler(request)
    }
}
