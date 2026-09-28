import Foundation
import ImageAllRemoteClient
import ImageAllRemoteProtocol
import XCTest

final class RemoteLibraryClientTests: XCTestCase {
    func testCollectionRenamePreservesCommandAndReceipt() async throws {
        let request = RemoteLocalCollectionRenameRequest(commandID: UUID(), hostID: UUID(), installID: UUID(),
            sourceEpoch: UUID(), scopeRevision: 1, snapshotSequence: 2, expectedChangeCursor: 3,
            collectionID: UUID(), expectedName: "旧名", newName: "新名")
        let expected = RemoteLocalCollectionRenameReceipt(request: request, deviceID: UUID(), resultingChangeCursor: 4)
        let transport = MockTransport { outgoing in
            XCTAssertEqual(outgoing.httpMethod, "POST")
            XCTAssertEqual(outgoing.url?.path, RemoteHTTPPaths.localLibraryCollectionRename)
            XCTAssertEqual(try JSONDecoder().decode(RemoteLocalCollectionRenameRequest.self,
                                                   from: XCTUnwrap(outgoing.httpBody)), request)
            return (try JSONEncoder().encode(expected), HTTPURLResponse(url: outgoing.url!, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
        let client = RemoteLibraryClient(endpoint: try RemoteHostEndpoint(host: "127.0.0.1", port: 8787,
                                                                          accessToken: "secret"), transport: transport)
        let actual = try await client.renameLocalLibraryCollection(request)
        XCTAssertEqual(actual, expected)
        XCTAssertFalse(RemoteCapabilities(hostAppVersion: "test").capabilities.contains(.localLibraryCollectionRename))
    }

    func testSelectedVideoSampleSuggestionsKeepExactIDsAndCannotBecomeWholeLibrary() async throws {
        let operation = UUID(), ids = [UUID(), UUID(), UUID()]
        let transport = MockTransport { outgoing in
            XCTAssertEqual(outgoing.url?.path, RemoteHTTPPaths.sampleSuggestionRequests)
            XCTAssertEqual(outgoing.httpMethod, "POST")
            let request = try JSONDecoder().decode(RemoteSampleSuggestionRequest.self, from: XCTUnwrap(outgoing.httpBody))
            XCTAssertEqual(request.operationID, operation)
            XCTAssertEqual(request.mediaKind, .video)
            XCTAssertEqual(request.assetIDs, ids)
            XCTAssertNil(request.sourceIDs)
            let result = RemoteSampleSuggestionResponse(activity: .init(operationID: operation,
                mediaKind: .video, phase: .running, completedUnitCount: 0, totalUnitCount: 3), replayed: true)
            return (try JSONEncoder().encode(result), HTTPURLResponse(url: outgoing.url!, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
        let endpoint = try RemoteHostEndpoint(host: "127.0.0.1", port: 8787, accessToken: "secret")
        let client = RemoteLibraryClient(endpoint: endpoint, transport: transport)
        let result = try await client.submitSelectedSampleSuggestions(assetIDs: ids, mediaKind: .video, operationID: operation)
        XCTAssertTrue(result.replayed)
        let forbiddenTransport = MockTransport { _ in
            XCTFail("invalid selected IDs must never reach whole-library API")
            throw URLError(.badURL)
        }
        let guarded = RemoteLibraryClient(endpoint: endpoint, transport: forbiddenTransport)
        for invalid in [[], [ids[0], ids[0]]] {
            do {
                _ = try await guarded.submitSelectedSampleSuggestions(assetIDs: invalid, mediaKind: .video, operationID: operation)
                XCTFail("empty or duplicate selection must fail")
            } catch let error as RemoteAPIError { XCTAssertEqual(error.code, .conflict) }
        }
    }

    func testVideoTagSuggestionsQuerySubmitReplayCancelAndIdentityChecks() async throws {
        let operation = UUID(), tag = UUID(), source = UUID()
        for method in [RemoteTagLibrarySuggestionMethod.personalCentroid, .personalAdamW] {
            let activity = RemoteTagLibrarySuggestionActivity(operationID: operation, mediaKind: .video,
                method: method, tagID: tag, phase: .scoring, completedUnitCount: 1,
                totalUnitCount: 2, availableActions: [.cancel])
            let transport = MockTransport { outgoing in
                XCTAssertEqual(outgoing.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
                let bytes: Data
                switch outgoing.url?.path {
                case RemoteHTTPPaths.tagLibrarySuggestions:
                    XCTAssertEqual(outgoing.httpMethod, "GET")
                    XCTAssertEqual(URLComponents(url: outgoing.url!, resolvingAgainstBaseURL: false)?
                        .queryItems?.first(where: { $0.name == "mediaKind" })?.value, "video")
                    bytes = try JSONEncoder().encode(RemoteTagLibrarySuggestionSnapshot(mediaKind: .video,
                        maximumPendingCount: 0, personalCentroidAvailable: true, personalAdamWAvailable: true,
                        activities: [activity]))
                case RemoteHTTPPaths.tagLibrarySuggestionRequests:
                    XCTAssertEqual(outgoing.httpMethod, "POST")
                    let request = try JSONDecoder().decode(RemoteTagLibrarySuggestionRequest.self, from: XCTUnwrap(outgoing.httpBody))
                    XCTAssertEqual(request.operationID, operation)
                    XCTAssertEqual(request.mediaKind, .video)
                    XCTAssertEqual(request.method, method)
                    XCTAssertEqual(request.tagID, tag)
                    XCTAssertEqual(request.sourceIDs, [source])
                    bytes = try JSONEncoder().encode(RemoteTagLibrarySuggestionResponse(activity: activity, replayed: true))
                default:
                    XCTAssertEqual(outgoing.httpMethod, "POST")
                    XCTAssertEqual(outgoing.url?.path, RemoteHTTPPaths.tagLibrarySuggestionAction(operationID: operation))
                    let request = try JSONDecoder().decode(RemoteTagLibrarySuggestionActionRequest.self, from: XCTUnwrap(outgoing.httpBody))
                    XCTAssertEqual(request.action, .cancel)
                    bytes = try JSONEncoder().encode(RemoteTagLibrarySuggestionActionResponse(activity: activity))
                }
                return (bytes, HTTPURLResponse(url: outgoing.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
            }
            let client = RemoteLibraryClient(endpoint: try RemoteHostEndpoint(host: "127.0.0.1", port: 8787, accessToken: "secret"), transport: transport)
            let snapshot = try await client.fetchTagLibrarySuggestions(mediaKind: .video)
            XCTAssertEqual(snapshot.activities, [activity])
            let receipt = try await client.submitTagLibrarySuggestions(.init(operationID: operation, mediaKind: .video,
                method: method, tagID: tag, sourceIDs: [source]))
            XCTAssertTrue(receipt.replayed)
            let cancelled = try await client.cancelTagLibrarySuggestions(activity: activity)
            XCTAssertEqual(cancelled.activity.operationID, operation)
        }
    }

    func testTagSuggestionsRejectWrongMediaTagMethodAndOperation() async throws {
        let operation = UUID(), tag = UUID()
        let expected = RemoteTagLibrarySuggestionActivity(operationID: operation, mediaKind: .video,
            method: .personalCentroid, tagID: tag, phase: .scoring, completedUnitCount: 0, totalUnitCount: 1)
        for mismatch in 0..<4 {
            let wrong = RemoteTagLibrarySuggestionActivity(operationID: mismatch == 0 ? UUID() : operation,
                mediaKind: mismatch == 1 ? .image : .video,
                method: mismatch == 2 ? .personalAdamW : .personalCentroid,
                tagID: mismatch == 3 ? UUID() : tag, phase: .completed, completedUnitCount: 1, totalUnitCount: 1)
            let transport = MockTransport { outgoing in
                let bytes: Data
                if outgoing.url?.path == RemoteHTTPPaths.tagLibrarySuggestionRequests {
                    bytes = try JSONEncoder().encode(RemoteTagLibrarySuggestionResponse(activity: wrong, replayed: false))
                } else if outgoing.httpMethod == "GET" {
                    // Correct envelope with a wrong-media activity must also fail.
                    bytes = try JSONEncoder().encode(RemoteTagLibrarySuggestionSnapshot(mediaKind: .video,
                        maximumPendingCount: 0, personalCentroidAvailable: true, personalAdamWAvailable: true, activities: [wrong]))
                } else {
                    bytes = try JSONEncoder().encode(RemoteTagLibrarySuggestionActionResponse(activity: wrong))
                }
                return (bytes, HTTPURLResponse(url: outgoing.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
            }
            let client = RemoteLibraryClient(endpoint: try RemoteHostEndpoint(host: "127.0.0.1", port: 8787, accessToken: "secret"), transport: transport)
            for action in 0..<(mismatch == 1 ? 3 : 2) {
                do {
                    if action == 0 {
                        _ = try await client.submitTagLibrarySuggestions(.init(operationID: operation, mediaKind: .video,
                            method: .personalCentroid, tagID: tag, sourceIDs: [UUID()]))
                    } else if action == 1 { _ = try await client.cancelTagLibrarySuggestions(activity: expected) }
                    else { _ = try await client.fetchTagLibrarySuggestions(mediaKind: .video) }
                    XCTFail("wrong identity must fail")
                } catch let error as RemoteAPIError { XCTAssertEqual(error.code, .conflict) }
            }
        }
    }

    func testVideoTrainingSetupLaunchPollAndCancelPreserveScope() async throws {
        let operation = UUID(), tag = UUID(), source = UUID()
        let activity = RemoteTrainingActivity(operationID: operation, mediaKind: .video,
            method: .personalCentroid, phase: .preparingEmbeddings,
            completedUnitCount: 1, totalUnitCount: 2, availableActions: [.cancel])
        let transport = MockTransport { outgoing in
            XCTAssertEqual(outgoing.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            let bytes: Data
            switch outgoing.url?.path {
            case RemoteHTTPPaths.trainingSetup, RemoteHTTPPaths.trainingActivities:
                XCTAssertEqual(outgoing.httpMethod, "GET")
                XCTAssertEqual(URLComponents(url: outgoing.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "mediaKind" })?.value, "video")
                if outgoing.url?.path == RemoteHTTPPaths.trainingSetup {
                    bytes = try JSONEncoder().encode(RemoteTrainingSetupSnapshot(mediaKind: .video,
                        tags: [.init(id: tag, displayName: "动作", acceptedSampleCount: 3,
                            rejectedSampleCount: 2, featureMode: .generate, personalEligible: true)],
                        sources: [.init(id: source, displayName: "合成视频")],
                        methods: [.init(method: .personalCentroid, isAvailable: true)]))
                } else { bytes = try JSONEncoder().encode([activity]) }
            case RemoteHTTPPaths.trainingLaunch:
                XCTAssertEqual(outgoing.httpMethod, "POST")
                let request = try JSONDecoder().decode(RemoteTrainingLaunchRequest.self, from: XCTUnwrap(outgoing.httpBody))
                XCTAssertEqual(request.operationID, operation)
                XCTAssertEqual(request.mediaKind, .video)
                XCTAssertEqual(request.tagIDs, [tag])
                XCTAssertEqual(request.sourceIDs, request.method == .featureKnn ? [source] : [])
                XCTAssertTrue(request.assetIDs.isEmpty)
                bytes = try JSONEncoder().encode(RemoteTrainingLaunchResponse(operationID: operation,
                    method: request.method, acceptedAtMs: 1, scheduledTagCount: 1, replayed: true))
            default:
                XCTAssertEqual(outgoing.httpMethod, "POST")
                XCTAssertEqual(outgoing.url?.path, RemoteHTTPPaths.trainingActivityAction(operationID: operation))
                let request = try JSONDecoder().decode(RemoteTrainingActivityActionRequest.self, from: XCTUnwrap(outgoing.httpBody))
                XCTAssertEqual(request.action, .cancel)
                bytes = try JSONEncoder().encode(RemoteTrainingActivityActionResponse(activity: activity))
            }
            return (bytes, HTTPURLResponse(url: outgoing.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
        let client = RemoteLibraryClient(endpoint: try RemoteHostEndpoint(host: "127.0.0.1", port: 8787, accessToken: "secret"), transport: transport)
        let setup = try await client.fetchTrainingSetup(mediaKind: .video)
        XCTAssertTrue(setup.tags[0].personalEligible)
        for method in RemoteTrainingRunMethod.allCases {
            let receipt = try await client.launchTraining(.init(operationID: operation, mediaKind: .video,
                method: method, tagIDs: [tag], sourceIDs: method == .featureKnn ? [source] : []))
            XCTAssertTrue(receipt.replayed)
        }
        let activities = try await client.fetchTrainingActivities(mediaKind: .video)
        XCTAssertEqual(activities, [activity])
        let result = try await client.cancelTraining(operationID: operation, mediaKind: .video)
        XCTAssertEqual(result.activity.operationID, operation)
    }

    func testTrainingRejectsWrongMediaOperationAndMethodResponses() async throws {
        let operation = UUID()
        let wrongActivity = RemoteTrainingActivity(operationID: operation, mediaKind: .image,
            method: .personalCentroid, phase: .completed, completedUnitCount: 1, totalUnitCount: 1)
        for scenario in 0..<5 {
            let transport = MockTransport { outgoing in
                let bytes: Data
                switch scenario {
                case 0:
                    bytes = try JSONEncoder().encode(RemoteTrainingSetupSnapshot(mediaKind: .image, tags: [], sources: [], methods: []))
                case 1: bytes = try JSONEncoder().encode([wrongActivity])
                case 2, 3:
                    bytes = try JSONEncoder().encode(RemoteTrainingLaunchResponse(
                        operationID: scenario == 2 ? UUID() : operation,
                        method: scenario == 3 ? .personalAdamW : .personalCentroid,
                        acceptedAtMs: 1, scheduledTagCount: 1, replayed: false))
                default: bytes = try JSONEncoder().encode(RemoteTrainingActivityActionResponse(activity: wrongActivity))
                }
                return (bytes, HTTPURLResponse(url: outgoing.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
            }
            let client = RemoteLibraryClient(endpoint: try RemoteHostEndpoint(host: "127.0.0.1", port: 8787, accessToken: "secret"), transport: transport)
            do {
                switch scenario {
                case 0: _ = try await client.fetchTrainingSetup(mediaKind: .video)
                case 1: _ = try await client.fetchTrainingActivities(mediaKind: .video)
                case 2, 3: _ = try await client.launchTraining(.init(operationID: operation, mediaKind: .video, method: .personalCentroid, tagIDs: [UUID()]))
                default: _ = try await client.cancelTraining(operationID: operation, mediaKind: .video)
                }
                XCTFail("mismatched response must fail")
            } catch let error as RemoteAPIError { XCTAssertEqual(error.code, .conflict) }
        }
    }

    func testVideoPersonalSampleQuerySubmitAndCancelPreserveScope() async throws {
        let operation = UUID(), asset = UUID()
        let running = RemoteSampleSuggestionActivity(operationID: operation, mediaKind: .video,
            phase: .running, completedUnitCount: 0, totalUnitCount: 1, availableActions: [.cancel])
        let transport = MockTransport { outgoing in
            XCTAssertEqual(outgoing.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            let bytes: Data
            switch outgoing.url?.path {
            case RemoteHTTPPaths.sampleSuggestions:
                XCTAssertEqual(outgoing.httpMethod, "GET")
                XCTAssertNotNil(URLComponents(url: outgoing.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "mediaKind" }))
                bytes = try JSONEncoder().encode(RemoteSampleSuggestionSnapshot(mediaKind: .video,
                    isAvailable: true, maximumSampleCount: 100, activities: [running]))
            case RemoteHTTPPaths.sampleSuggestionRequests:
                let body = try JSONDecoder().decode(RemoteSampleSuggestionRequest.self, from: XCTUnwrap(outgoing.httpBody))
                XCTAssertEqual(body.operationID, operation)
                XCTAssertEqual(body.mediaKind, .video)
                XCTAssertEqual(body.assetIDs, [asset])
                XCTAssertNil(body.sourceIDs)
                bytes = try JSONEncoder().encode(RemoteSampleSuggestionResponse(activity: running, replayed: true))
            default:
                XCTAssertEqual(outgoing.url?.path, RemoteHTTPPaths.sampleSuggestionAction(operationID: operation))
                let body = try JSONDecoder().decode(RemoteSampleSuggestionActionRequest.self, from: XCTUnwrap(outgoing.httpBody))
                XCTAssertEqual(body.action, .cancel)
                bytes = try JSONEncoder().encode(RemoteSampleSuggestionActionResponse(activity: .init(
                    operationID: operation, mediaKind: .video, phase: .cancelled, completedUnitCount: 0, totalUnitCount: 1)))
            }
            return (bytes, HTTPURLResponse(url: outgoing.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
        let client = RemoteLibraryClient(endpoint: try RemoteHostEndpoint(host: "127.0.0.1", port: 8787, accessToken: "secret"), transport: transport)
        let snapshot = try await client.fetchSampleSuggestions(mediaKind: .video)
        XCTAssertTrue(snapshot.isAvailable)
        let result = try await client.submitSampleSuggestions(.init(operationID: operation, mediaKind: .video, assetIDs: [asset]))
        XCTAssertTrue(result.replayed)
        let cancelled = try await client.cancelSampleSuggestions(operationID: operation)
        XCTAssertEqual(cancelled.activity.phase, .cancelled)
        do {
            _ = try await client.fetchSampleSuggestions(mediaKind: .image)
            XCTFail("wrong media response must fail")
        } catch let error as RemoteAPIError { XCTAssertEqual(error.code, .conflict) }
    }

    func testVideoStandardSuggestionRequestsPreserveIdentityAndRejectMismatches() async throws {
        let assetID = UUID(), operationID = UUID()
        for mismatch in [false, true] {
            let transport = MockTransport { outgoing in
                XCTAssertEqual(outgoing.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
                let bytes: Data
                if outgoing.httpMethod == "GET" {
                    XCTAssertEqual(outgoing.url?.path, RemoteHTTPPaths.librarySuggestions)
                    XCTAssertEqual(URLComponents(url: outgoing.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "video")
                    bytes = try JSONEncoder().encode(RemoteLibrarySuggestionSnapshot(
                        mediaKind: mismatch ? .image : .video,
                        service: .init(state: .ready, serviceVersion: "1", provider: "synthetic", modelID: "fixture"),
                        standardAvailable: true, personalMode: .unavailable
                    ))
                } else {
                    XCTAssertEqual(outgoing.url?.path, RemoteHTTPPaths.assetDetail(assetID: assetID) + "/local-suggestions")
                    let request = try JSONDecoder().decode(RemoteAssetLocalSuggestionRequest.self, from: XCTUnwrap(outgoing.httpBody))
                    XCTAssertEqual(request.operationID, operationID)
                    XCTAssertEqual(request.track, .standard)
                    bytes = try JSONEncoder().encode(RemoteAssetLocalSuggestionResponse(
                        operationID: operationID, assetID: mismatch ? UUID() : assetID,
                        track: .standard, state: .results, suggestions: [], replayed: false
                    ))
                }
                return (bytes, HTTPURLResponse(url: outgoing.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
            }
            let client = RemoteLibraryClient(endpoint: try RemoteHostEndpoint(host: "127.0.0.1", port: 8787, accessToken: "secret"), transport: transport)
            do {
                let snapshot = try await client.fetchLibrarySuggestions(mediaKind: .video)
                XCTAssertFalse(mismatch)
                XCTAssertTrue(snapshot.standardAvailable)
            } catch let error as RemoteAPIError {
                XCTAssertTrue(mismatch)
                XCTAssertEqual(error.code, .conflict)
            }
            do {
                let result = try await client.analyzeAssetLocalSuggestions(assetID: assetID,
                    request: .init(operationID: operationID, track: .standard))
                XCTAssertFalse(mismatch)
                XCTAssertEqual(result.assetID, assetID)
            } catch let error as RemoteAPIError {
                XCTAssertTrue(mismatch)
                XCTAssertEqual(error.code, .conflict)
            }
        }
    }

    func testChunkedSnapshotResumesAndStopsWhenScopeValidationFails() async throws {
        let deviceID = UUID(), hostID = UUID()
        let ids = (0..<1_100).map { _ in UUID() }
        let snapshot = RemoteLocalLibrarySnapshotRequest(
            hostID: hostID, installID: UUID(), sourceEpoch: UUID(), scopeRevision: 1, snapshotSequence: 1,
            selectedAssetIDs: ids, assets: ids.map { .init(id: $0, localIdentifier: String(repeating: "x", count: 200),
                mediaKind: .image, createdAtMs: nil, observedFavorite: false, favoriteTarget: nil,
                tagDecisions: [], collections: []) }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(snapshot)
        let size = RemoteLocalLibrarySnapshotChunk.maximumChunkBytes
        actor Receiver {
            var offsets: [Int] = []
            var validations = 0
            func validate(failAt: Int? = nil) throws {
                validations += 1
                if validations == failAt { throw CancellationError() }
            }
            func accept(_ offset: Int) { offsets.append(offset) }
        }
        let receiver = Receiver()
        let transport = MockTransport { outgoing in
            XCTAssertEqual(outgoing.url?.path, RemoteHTTPPaths.localLibrarySnapshotChunk)
            XCTAssertEqual(outgoing.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            let body = try XCTUnwrap(outgoing.httpBody)
            XCTAssertLessThan(body.count, 200 * 1_024)
            let chunk = try JSONDecoder().decode(RemoteLocalLibrarySnapshotChunk.self, from: body)
            await receiver.accept(chunk.offset)
            let end = min(chunk.offset + size, bytes.count)
            XCTAssertEqual(chunk.bytes, bytes.subdata(in: chunk.offset..<end))
            let received = chunk.offset == 0 ? 2 * size : end
            let response = RemoteLocalLibrarySnapshotChunkReceipt(
                hostID: hostID, deviceID: deviceID, requestSHA256: chunk.snapshot.requestSHA256,
                receivedBytes: received, snapshotReceipt: received == bytes.count ? .init(
                    hostID: hostID, deviceID: deviceID, sourceEpoch: snapshot.sourceEpoch,
                    snapshotSequence: 1, acceptedAssetCount: ids.count, replayed: false
                ) : nil
            )
            return (try JSONEncoder().encode(response), HTTPURLResponse(
                url: outgoing.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
        let client = RemoteLibraryClient(
            endpoint: try RemoteHostEndpoint(host: "127.0.0.1", port: 8787, accessToken: "secret"), transport: transport
        )
        let receipt = try await client.submitLocalLibrarySnapshotInChunks(snapshot, deviceID: deviceID) {
            try await receiver.validate()
        }
        XCTAssertEqual(receipt.acceptedAssetCount, ids.count)
        let offsets = await receiver.offsets
        XCTAssertEqual(offsets, [0] + Array(stride(from: size * 2, to: bytes.count, by: size)))
        let stopAt = await receiver.validations + 2
        do {
            _ = try await client.submitLocalLibrarySnapshotInChunks(snapshot, deviceID: deviceID) {
                try await receiver.validate(failAt: stopAt)
            }
            XCTFail("changed scope must stop further chunks")
        } catch is CancellationError { }
        let stoppedOffsets = await receiver.offsets
        XCTAssertEqual(stoppedOffsets, offsets + [0])
    }

    func testLooksUpFrozenSnapshotReceiptWithoutResendingAssetMetadata() async throws {
        let hostID = UUID(), deviceID = UUID(), assetID = UUID()
        let snapshot = RemoteLocalLibrarySnapshotRequest(
            hostID: hostID, installID: UUID(), sourceEpoch: UUID(),
            scopeRevision: 1, snapshotSequence: 7,
            selectedAssetIDs: [assetID], assets: [.init(
                id: assetID, localIdentifier: "private-source-locator",
                mediaKind: .image, createdAtMs: nil,
                observedFavorite: false, favoriteTarget: nil,
                tagDecisions: [], collections: []
            )]
        )
        let lookup = try RemoteLocalLibrarySnapshotReceiptLookup(request: snapshot)
        let receipt = RemoteLocalLibrarySnapshotReceipt(
            hostID: hostID, deviceID: deviceID, sourceEpoch: snapshot.sourceEpoch,
            snapshotSequence: 7, acceptedAssetCount: 1, replayed: true,
            importedAssetIDs: [assetID]
        )
        let transport = MockTransport { outgoing in
            XCTAssertEqual(outgoing.httpMethod, "POST")
            XCTAssertEqual(outgoing.url?.path, RemoteHTTPPaths.localLibrarySnapshotReceipt)
            XCTAssertEqual(outgoing.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            let body = try XCTUnwrap(outgoing.httpBody)
            XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("private-source-locator"))
            XCTAssertEqual(try JSONDecoder().decode(
                RemoteLocalLibrarySnapshotReceiptLookup.self, from: body
            ), lookup)
            return (
                try JSONEncoder().encode(RemoteLocalLibrarySnapshotReceiptLookupResult(
                    receipt: receipt
                )),
                HTTPURLResponse(url: outgoing.url!, statusCode: 200,
                                httpVersion: "HTTP/1.1", headerFields: nil)!
            )
        }
        let client = RemoteLibraryClient(
            endpoint: try RemoteHostEndpoint(host: "127.0.0.1", port: 8787, accessToken: "secret"),
            transport: transport
        )
        let result = try await client.lookupLocalLibrarySnapshotReceipt(lookup)
        XCTAssertEqual(result.receipt, receipt)
    }

    func testFetchesScopedMacFavoriteChangesWithBearerToken() async throws {
        let hostID = UUID()
        let deviceID = UUID()
        let epoch = UUID()
        let change = RemoteLocalLibraryFavoriteChange(
            sequence: 5, scopeRevision: 2, assetID: UUID(),
            target: true, fieldRevision: 3
        )
        let transport = MockTransport { outgoing in
            XCTAssertEqual(outgoing.httpMethod, "GET")
            XCTAssertEqual(outgoing.url?.path, RemoteHTTPPaths.localLibraryFavoriteChanges)
            XCTAssertEqual(outgoing.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            let query = URLComponents(url: try XCTUnwrap(outgoing.url), resolvingAgainstBaseURL: false)?
                .queryItems ?? []
            XCTAssertEqual(query.first(where: { $0.name == "sourceEpoch" })?.value, epoch.uuidString)
            XCTAssertEqual(query.first(where: { $0.name == "scopeRevision" })?.value, "2")
            XCTAssertEqual(query.first(where: { $0.name == "afterCursor" })?.value, "4")
            let page = RemoteLocalLibraryFavoriteChangesPage(
                hostID: hostID, deviceID: deviceID, sourceEpoch: epoch,
                scopeRevision: 2, changes: [change], nextCursor: 5, hasMore: false
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
        let page = try await client.fetchLocalLibraryFavoriteChanges(
            sourceEpoch: epoch, scopeRevision: 2, afterCursor: 4
        )
        XCTAssertEqual(page.changes, [change])
        XCTAssertEqual(page.nextCursor, 5)
    }

    func testPostsFavoriteTargetWithBearerAndStableOperationID() async throws {
        let request = RemoteLocalLibraryFavoriteTargetRequest(
            hostID: UUID(), installID: UUID(), sourceEpoch: UUID(),
            scopeRevision: 2, operationID: UUID(), deviceSequence: 19,
            assetID: UUID(), target: false, baseRevision: 1
        )
        let transport = MockTransport { outgoing in
            XCTAssertEqual(outgoing.httpMethod, "POST")
            XCTAssertEqual(outgoing.url?.path, RemoteHTTPPaths.localLibraryFavoriteTarget)
            XCTAssertEqual(outgoing.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            XCTAssertEqual(try JSONDecoder().decode(
                RemoteLocalLibraryFavoriteTargetRequest.self,
                from: XCTUnwrap(outgoing.httpBody)
            ), request)
            let response = RemoteLocalLibraryFavoriteTargetReceipt(
                hostID: request.hostID, deviceID: UUID(), operationID: request.operationID,
                disposition: .applied, fieldRevision: 2, currentTarget: false, replayed: false
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
        let receipt = try await client.submitLocalLibraryFavoriteTarget(request)
        XCTAssertEqual(receipt.operationID, request.operationID)
        XCTAssertEqual(receipt.currentTarget, false)
    }
    func testFetchesScopedMacCollectionChangesWithBearerToken() async throws {
        let hostID = UUID()
        let deviceID = UUID()
        let epoch = UUID()
        let change = RemoteLocalLibraryCollectionChange(
            sequence: 5, scopeRevision: 2, assetID: UUID(),
            collectionID: UUID(), collectionName: "旅行",
            included: false, fieldRevision: 3
        )
        let transport = MockTransport { outgoing in
            XCTAssertEqual(outgoing.httpMethod, "GET")
            XCTAssertEqual(outgoing.url?.path, RemoteHTTPPaths.localLibraryCollectionChanges)
            XCTAssertEqual(outgoing.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            let query = URLComponents(url: try XCTUnwrap(outgoing.url), resolvingAgainstBaseURL: false)?
                .queryItems ?? []
            XCTAssertEqual(query.first(where: { $0.name == "sourceEpoch" })?.value, epoch.uuidString)
            XCTAssertEqual(query.first(where: { $0.name == "scopeRevision" })?.value, "2")
            XCTAssertEqual(query.first(where: { $0.name == "afterCursor" })?.value, "4")
            let page = RemoteLocalLibraryCollectionChangesPage(
                hostID: hostID, deviceID: deviceID, sourceEpoch: epoch,
                scopeRevision: 2, changes: [change], nextCursor: 5, hasMore: false
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
        let page = try await client.fetchLocalLibraryCollectionChanges(
            sourceEpoch: epoch, scopeRevision: 2, afterCursor: 4
        )
        XCTAssertEqual(page.changes, [change])
        XCTAssertEqual(page.nextCursor, 5)
    }

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
            XCTAssertEqual(map["sort"], "durationLongest")
            XCTAssertEqual(map["limit"], "40")
            XCTAssertEqual(map["q"], "beach")
            XCTAssertEqual(map["cursor"], "abc")
            XCTAssertEqual(map["acceptedTagIDs"], acceptedTagID.uuidString)
            XCTAssertEqual(map["excludedTagIDs"], excludedTagID.uuidString)
            XCTAssertEqual(map["tagMatchMode"], "any")
            XCTAssertEqual(map["availabilities"], "available")
            XCTAssertEqual(map["mediaKinds"], "video")
            XCTAssertEqual(map["videoDuration"], "oneToTenMinutes")
            XCTAssertEqual(map["videoOrientation"], "portrait")
            XCTAssertEqual(map["tagPresence"], "tagged")
            XCTAssertEqual(map["worldMapCellDegrees"], "7.5")
            XCTAssertEqual(map["worldMapLongitudeBucket"], "24")
            XCTAssertEqual(map["worldMapLatitudeBucket"], "12")
            XCTAssertEqual(map["worldMapMediaScope"], "all")
            XCTAssertEqual(map["worldMapWest"], "-180.0")
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
                sort: .durationLongest,
                limit: 40,
                cursor: "abc",
                tagDecisionFilters: [
                    RemoteAssetTagDecisionFilter(tagID: acceptedTagID, decision: .accepted)
                ],
                excludedTagIDs: [excludedTagID],
                tagMatchMode: .any,
                availabilities: [.available],
                mediaKinds: [.video],
                videoDuration: .oneToTenMinutes,
                videoOrientation: .portrait,
                tagPresence: .tagged,
                worldMapSelection: RemoteWorldMapSelectionQuery(cellDegrees: 7.5, longitudeBucket: 24,
                    latitudeBucket: 12, bounds: RemoteWorldMapBounds(west: -180, south: -90, east: 180, north: 90), mediaScope: .all)
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
