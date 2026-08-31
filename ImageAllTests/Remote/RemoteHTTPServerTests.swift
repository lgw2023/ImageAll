import Darwin
import Foundation
import ImageIO
import ImageAllRemoteProtocol
import Network
import UniformTypeIdentifiers
import XCTest
@testable import ImageAll

final class RemoteHTTPServerTests: XCTestCase {
    private static let legacyDebugToken = "secret-token"

    func testRemoteHostDefaultsEnabledUntilUserTurnsItOff() {
        let suiteName = "RemoteHTTPServerTests.RemoteHostDefaults.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(
            RemoteHostProcessHolder.isEnabled(defaults: defaults, environment: [:])
        )

        defaults.set(false, forKey: RemoteHostProcessHolder.enabledKey)
        XCTAssertFalse(
            RemoteHostProcessHolder.isEnabled(defaults: defaults, environment: [:])
        )

        defaults.set(true, forKey: RemoteHostProcessHolder.enabledKey)
        XCTAssertTrue(
            RemoteHostProcessHolder.isEnabled(defaults: defaults, environment: [:])
        )
    }

    func testRemoteHostEnvironmentProvidesDevelopmentDefaultWithoutOverridingUserSwitch() {
        let suiteName = "RemoteHTTPServerTests.RemoteHostEnvironment.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(
            RemoteHostProcessHolder.isEnabled(
                defaults: defaults,
                environment: ["IMAGEALL_REMOTE_HOST": "1"]
            )
        )
        XCTAssertFalse(
            RemoteHostProcessHolder.isEnabled(
                defaults: defaults,
                environment: ["IMAGEALL_REMOTE_HOST": "0"]
            )
        )

        defaults.set(false, forKey: RemoteHostProcessHolder.enabledKey)
        XCTAssertFalse(
            RemoteHostProcessHolder.isEnabled(
                defaults: defaults,
                environment: ["IMAGEALL_REMOTE_HOST": "1"]
            )
        )
    }

    func testLocalWebURLUsesStableLoopbackOnlyHTTPPort() {
        XCTAssertEqual(
            RemoteHostProcessHolder.localWebURL.absoluteString,
            "http://127.0.0.1:8788"
        )
    }

    func testAssetLocalSuggestionRouteReturnsOnlyRedactedHostProjection() async throws {
        let port = UInt16.random(in: 19_000...29_000)
        let operationID = UUID()
        let assetID = UUID()
        let tagID = UUID()
        let commands = RemoteHTTPTrainingCommandStub(
            setupSnapshot: TrainingCommandSetupSnapshot(
                mediaKind: .image,
                tags: [],
                sources: [],
                supportsPersonalCentroid: false,
                supportsPersonalAdamW: false
            ),
            receipt: TrainingLaunchReceipt(
                operationID: UUID(),
                method: .personalCentroid,
                acceptedAtMs: 0,
                scheduledTagCount: 0,
                jobID: UUID()
            ),
            assetLocalSuggestionSnapshot: AssetLocalSuggestionSnapshot(
                operationID: operationID,
                assetID: assetID,
                track: .personal,
                state: .results,
                suggestions: [
                    AssetLocalSuggestionItem(
                        id: "personal|\(tagID.uuidString.lowercased())",
                        track: .personal,
                        tagID: tagID,
                        displayName: "猫",
                        recommendation: .suggested
                    ),
                ],
                replayed: false
            )
        )
        let (server, _) = makeServer(port: port, trainingCommands: commands)
        try await server.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        defer { Task { await server.stop() } }

        var request = URLRequest(
            url: URL(
                string: "http://127.0.0.1:\(port)/v1/assets/\(assetID.uuidString)/local-suggestions"
            )!
        )
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(RemoteAssetLocalSuggestionRequest(
            operationID: operationID,
            track: .personal
        ))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Bearer \(Self.legacyDebugToken)",
            forHTTPHeaderField: "Authorization"
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        XCTAssertEqual(try XCTUnwrap(response as? HTTPURLResponse).statusCode, 200)
        let payload = try JSONDecoder().decode(RemoteAssetLocalSuggestionResponse.self, from: data)
        XCTAssertEqual(payload.assetID, assetID)
        XCTAssertEqual(payload.suggestions.first?.tagID, tagID)
        XCTAssertEqual(payload.suggestions.first?.displayName, "猫")
        XCTAssertEqual(commands.assetLocalSuggestionCallCount, 1)
        XCTAssertEqual(commands.lastAssetLocalSuggestionCommand?.assetID, assetID)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("score"))
        XCTAssertFalse(json.contains("modelID"))
        XCTAssertFalse(json.contains("weightsSHA256"))
    }

    func testWorkspaceNoticeRoutesPreserveNewerNoticeDuringStaleDismissal() async throws {
        let port = UInt16.random(in: 19_000...29_000)
        let sourceID = UUID()
        let notices = RemoteHTTPWorkspaceNoticePortStub(notice: WorkspaceNoticeProjection(
            id: "7",
            severity: .warning,
            message: "后台扫描未完成，已索引的照片仍可继续浏览。",
            actions: [WorkspaceNoticeActionProjection(
                id: "openRecycleBin",
                kind: .openRecycleBin,
                title: "前往回收站",
                sourceID: sourceID
            )]
        ))
        let (server, _) = makeServer(port: port, workspaceNotices: notices)
        try await server.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        defer { Task { await server.stop() } }

        func request(path: String, method: String = "GET", body: Data? = nil) -> URLRequest {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.httpMethod = method
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(
                "Bearer \(Self.legacyDebugToken)",
                forHTTPHeaderField: "Authorization"
            )
            return request
        }

        let (initialData, initialResponse) = try await URLSession.shared.data(
            for: request(path: RemoteHTTPPaths.workspaceNotice)
        )
        XCTAssertEqual(try XCTUnwrap(initialResponse as? HTTPURLResponse).statusCode, 200)
        let initial = try JSONDecoder().decode(
            RemoteWorkspaceNoticeSnapshot.self,
            from: initialData
        )
        XCTAssertEqual(initial.notice?.id, "7")
        XCTAssertEqual(initial.notice?.severity, .warning)
        XCTAssertEqual(initial.notice?.actions.first?.sourceID, sourceID)

        let actionBody = try JSONEncoder().encode(RemoteWorkspaceNoticeActionRequest(
            noticeID: "7",
            actionID: "openRecycleBin"
        ))
        let (actionData, actionResponse) = try await URLSession.shared.data(for: request(
            path: RemoteHTTPPaths.workspaceNoticeAction,
            method: "POST",
            body: actionBody
        ))
        XCTAssertEqual(try XCTUnwrap(actionResponse as? HTTPURLResponse).statusCode, 200)
        let action = try JSONDecoder().decode(
            RemoteWorkspaceNoticeActionResponse.self,
            from: actionData
        )
        XCTAssertTrue(action.performed)
        XCTAssertEqual(action.notice?.id, "7")

        await notices.replace(with: WorkspaceNoticeProjection(
            id: "8",
            severity: .success,
            message: "已开始增量同步 Apple Photos。",
            actions: []
        ))
        let (staleActionData, _) = try await URLSession.shared.data(for: request(
            path: RemoteHTTPPaths.workspaceNoticeAction,
            method: "POST",
            body: actionBody
        ))
        let staleAction = try JSONDecoder().decode(
            RemoteWorkspaceNoticeActionResponse.self,
            from: staleActionData
        )
        XCTAssertFalse(staleAction.performed)
        XCTAssertEqual(staleAction.notice?.id, "8")
        let staleBody = try JSONEncoder().encode(
            RemoteWorkspaceNoticeDismissRequest(noticeID: "7")
        )
        let (staleData, staleResponse) = try await URLSession.shared.data(for: request(
            path: RemoteHTTPPaths.workspaceNoticeDismiss,
            method: "POST",
            body: staleBody
        ))
        XCTAssertEqual(try XCTUnwrap(staleResponse as? HTTPURLResponse).statusCode, 200)
        let stale = try JSONDecoder().decode(
            RemoteWorkspaceNoticeDismissResponse.self,
            from: staleData
        )
        XCTAssertFalse(stale.dismissed)
        XCTAssertEqual(stale.notice?.id, "8")

        let currentBody = try JSONEncoder().encode(
            RemoteWorkspaceNoticeDismissRequest(noticeID: "8")
        )
        let (currentData, currentResponse) = try await URLSession.shared.data(for: request(
            path: RemoteHTTPPaths.workspaceNoticeDismiss,
            method: "POST",
            body: currentBody
        ))
        XCTAssertEqual(try XCTUnwrap(currentResponse as? HTTPURLResponse).statusCode, 200)
        let current = try JSONDecoder().decode(
            RemoteWorkspaceNoticeDismissResponse.self,
            from: currentData
        )
        XCTAssertTrue(current.dismissed)
        XCTAssertNil(current.notice)
    }

    func testLibrarySlimmingWorkspaceRouteReturnsReadOnlyProjection() async throws {
        let port = UInt16.random(in: 19_000...29_000)
        let analysis = RemoteHTTPServerSlimmingAnalysisStub()
        let (server, _) = makeServer(
            port: port,
            librarySlimmingAnalysis: analysis
        )
        try await server.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        defer { Task { await server.stop() } }

        var request = URLRequest(
            url: URL(
                string: "http://127.0.0.1:\(port)\(RemoteHTTPPaths.librarySlimmingWorkspace)?mediaKind=video"
            )!
        )
        request.setValue(
            "Bearer \(Self.legacyDebugToken)",
            forHTTPHeaderField: "Authorization"
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual(try XCTUnwrap(response as? HTTPURLResponse).statusCode, 200)
        let snapshot = try JSONDecoder().decode(
            RemoteLibrarySlimmingWorkspaceSnapshot.self,
            from: data
        )
        XCTAssertEqual(snapshot.mediaKind, .video)
        XCTAssertTrue(snapshot.jobs.isEmpty)
        XCTAssertEqual(analysis.lastMediaKind, .video)
    }

    func testLibrarySlimmingCommandRoutesExposeSetupAndIdempotentMutations() async throws {
        let port = UInt16.random(in: 19_000...29_000)
        let sourceID = UUID()
        let jobID = UUID()
        let commands = RemoteHTTPSlimmingCommandStub(sourceID: sourceID, jobID: jobID)
        let (server, _) = makeServer(port: port, librarySlimmingCommands: commands)
        try await server.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        defer { Task { await server.stop() } }

        func authorizedRequest(path: String, method: String = "GET") -> URLRequest {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.httpMethod = method
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(
                "Bearer \(Self.legacyDebugToken)",
                forHTTPHeaderField: "Authorization"
            )
            return request
        }

        let (setupData, setupResponse) = try await URLSession.shared.data(
            for: authorizedRequest(path: "\(RemoteHTTPPaths.librarySlimmingSetup)?mediaKind=image")
        )
        XCTAssertEqual(try XCTUnwrap(setupResponse as? HTTPURLResponse).statusCode, 200)
        let setup = try JSONDecoder().decode(RemoteLibrarySlimmingSetupSnapshot.self, from: setupData)
        XCTAssertEqual(setup.sources.map(\.id), [sourceID])
        XCTAssertEqual(setup.sourceSimilarityIndexAvailable, true)

        var maintenance = authorizedRequest(
            path: RemoteHTTPPaths.librarySlimmingSourceMaintenance,
            method: "POST"
        )
        maintenance.httpBody = try JSONEncoder().encode(
            RemoteLibrarySlimmingSourceMaintenanceRequest(
                operationID: UUID(),
                action: .initializeSimilarityIndex,
                mediaKind: .image,
                sourceIDs: [sourceID]
            )
        )
        let (maintenanceData, maintenanceResponse) = try await URLSession.shared.data(
            for: maintenance
        )
        XCTAssertEqual(try XCTUnwrap(maintenanceResponse as? HTTPURLResponse).statusCode, 202)
        let maintenanceResult = try JSONDecoder().decode(
            RemoteLibrarySlimmingSourceMaintenanceResponse.self,
            from: maintenanceData
        )
        XCTAssertEqual(maintenanceResult.action, .initializeSimilarityIndex)
        XCTAssertEqual(maintenanceResult.sourceIDs, [sourceID])
        XCTAssertEqual(commands.sourceMaintenanceCount, 1)

        let operationID = UUID()
        var launch = authorizedRequest(path: RemoteHTTPPaths.librarySlimmingLaunch, method: "POST")
        launch.httpBody = try JSONEncoder().encode(RemoteLibrarySlimmingLaunchRequest(
            operationID: operationID,
            mediaKind: .image,
            mode: .catalog,
            sourceIDs: nil
        ))
        let (firstData, firstResponse) = try await URLSession.shared.data(for: launch)
        let (secondData, secondResponse) = try await URLSession.shared.data(for: launch)
        XCTAssertEqual(try XCTUnwrap(firstResponse as? HTTPURLResponse).statusCode, 202)
        XCTAssertEqual(try XCTUnwrap(secondResponse as? HTTPURLResponse).statusCode, 202)
        XCTAssertFalse(try JSONDecoder().decode(
            RemoteLibrarySlimmingLaunchResponse.self,
            from: firstData
        ).replayed)
        XCTAssertTrue(try JSONDecoder().decode(
            RemoteLibrarySlimmingLaunchResponse.self,
            from: secondData
        ).replayed)
        XCTAssertEqual(commands.launchCount, 1)

        var threshold = authorizedRequest(
            path: RemoteHTTPPaths.librarySlimmingThresholds,
            method: "PUT"
        )
        threshold.httpBody = try JSONEncoder().encode(
            RemoteLibrarySlimmingThresholdUpdateRequest(
                operationID: UUID(),
                thresholds: setup.thresholds
            )
        )
        let (thresholdData, thresholdResponse) = try await URLSession.shared.data(for: threshold)
        XCTAssertEqual(try XCTUnwrap(thresholdResponse as? HTTPURLResponse).statusCode, 200)
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteLibrarySlimmingThresholdUpdateResponse.self,
                from: thresholdData
            ).thresholds,
            setup.thresholds
        )

        var action = authorizedRequest(
            path: RemoteHTTPPaths.librarySlimmingJobAction(jobID: jobID),
            method: "POST"
        )
        action.httpBody = try JSONEncoder().encode(RemoteLibrarySlimmingJobActionRequest(
            operationID: UUID(),
            action: .deleteRecord
        ))
        let (actionData, actionResponse) = try await URLSession.shared.data(for: action)
        XCTAssertEqual(try XCTUnwrap(actionResponse as? HTTPURLResponse).statusCode, 200)
        XCTAssertTrue(try JSONDecoder().decode(
            RemoteLibrarySlimmingJobActionResponse.self,
            from: actionData
        ).deleted)
        XCTAssertEqual(commands.lastAction, .deleteRecord)

        let clusterID = UUID()
        let reviewOperationID = UUID()
        var review = authorizedRequest(
            path: RemoteHTTPPaths.librarySlimmingClusterReview,
            method: "POST"
        )
        review.httpBody = try JSONEncoder().encode(
            RemoteLibrarySlimmingClusterReviewRequest(
                operationID: reviewOperationID,
                jobID: jobID,
                clusterID: clusterID,
                disposition: .confirmed
            )
        )
        let (reviewData, reviewResponse) = try await URLSession.shared.data(for: review)
        XCTAssertEqual(try XCTUnwrap(reviewResponse as? HTTPURLResponse).statusCode, 200)
        let reviewResult = try JSONDecoder().decode(
            RemoteLibrarySlimmingClusterReviewResponse.self,
            from: reviewData
        )
        XCTAssertEqual(reviewResult.operationID, reviewOperationID)
        XCTAssertEqual(reviewResult.clusterID, clusterID)
        XCTAssertEqual(reviewResult.disposition, .confirmed)
        XCTAssertEqual(commands.lastClusterReviewJobID, jobID)
        XCTAssertEqual(commands.lastClusterReviewClusterID, clusterID)
        XCTAssertEqual(commands.lastClusterReviewDisposition, .confirmed)
    }

    func testLibrarySlimmingRecycleRoutesReturnSafeProjectionAndMacApprovalReceipt() async throws {
        let port = UInt16.random(in: 19_000...29_000)
        let commands = RemoteHTTPSlimmingCommandStub(sourceID: UUID(), jobID: UUID())
        let (server, _) = makeServer(port: port, librarySlimmingCommands: commands)
        try await server.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        defer { Task { await server.stop() } }

        func authorizedRequest(path: String, method: String = "GET") -> URLRequest {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.httpMethod = method
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(
                "Bearer \(Self.legacyDebugToken)",
                forHTTPHeaderField: "Authorization"
            )
            return request
        }

        let (snapshotData, snapshotResponse) = try await URLSession.shared.data(
            for: authorizedRequest(
                path: "\(RemoteHTTPPaths.librarySlimmingRecycle)?mediaKind=image&scope=files&limit=60"
            )
        )
        XCTAssertEqual(try XCTUnwrap(snapshotResponse as? HTTPURLResponse).statusCode, 200)
        let snapshot = try JSONDecoder().decode(
            RemoteLibrarySlimmingRecycleSnapshot.self,
            from: snapshotData
        )
        XCTAssertEqual(snapshot.entries.first?.id, commands.recycleEntryID)
        XCTAssertEqual(snapshot.entries.first?.availableActions, [.restore, .purge])
        XCTAssertEqual(snapshot.scopeCounts?.files, 1)
        let json = try XCTUnwrap(String(data: snapshotData, encoding: .utf8))
        XCTAssertFalse(json.contains("private/original"))
        XCTAssertFalse(json.contains("private/quarantine"))

        let operationID = UUID()
        var submit = authorizedRequest(
            path: RemoteHTTPPaths.librarySlimmingRecycleRequests,
            method: "POST"
        )
        submit.httpBody = try JSONEncoder().encode(
            RemoteLibrarySlimmingRecycleSubmitRequest(
                operationID: operationID,
                entryID: commands.recycleEntryID,
                action: .restore
            )
        )
        let (requestData, requestResponse) = try await URLSession.shared.data(for: submit)
        XCTAssertEqual(try XCTUnwrap(requestResponse as? HTTPURLResponse).statusCode, 202)
        let receipt = try JSONDecoder().decode(
            RemoteLibrarySlimmingRecycleRequestSnapshot.self,
            from: requestData
        )
        XCTAssertEqual(receipt.phase, .awaitingMac)
        XCTAssertEqual(commands.lastRecycleCommand?.operationID, operationID)
        XCTAssertEqual(commands.lastRecycleCommand?.action, .restore)
    }

    func testLibrarySlimmingBatchRemovalRoutesFreezeSelectionAndReturnProgress() async throws {
        let port = UInt16.random(in: 19_000...29_000)
        let jobID = UUID()
        let commands = RemoteHTTPSlimmingCommandStub(sourceID: UUID(), jobID: jobID)
        let (server, _) = makeServer(port: port, librarySlimmingCommands: commands)
        try await server.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        defer { Task { await server.stop() } }

        func authorizedRequest(path: String, method: String = "GET") -> URLRequest {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.httpMethod = method
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(
                "Bearer \(Self.legacyDebugToken)",
                forHTTPHeaderField: "Authorization"
            )
            return request
        }

        let (snapshotData, snapshotResponse) = try await URLSession.shared.data(
            for: authorizedRequest(
                path: "\(RemoteHTTPPaths.librarySlimmingRemovals)?mediaKind=image"
            )
        )
        XCTAssertEqual(try XCTUnwrap(snapshotResponse as? HTTPURLResponse).statusCode, 200)
        let snapshot = try JSONDecoder().decode(
            RemoteLibrarySlimmingRemovalSnapshot.self,
            from: snapshotData
        )
        XCTAssertEqual(snapshot.requests.first?.progress?.completedAssetCount, 1)

        let operationID = UUID()
        let clusterID = UUID()
        let assetIDs = [UUID(), UUID()]
        var submit = authorizedRequest(
            path: RemoteHTTPPaths.librarySlimmingRemovals,
            method: "POST"
        )
        submit.httpBody = try JSONEncoder().encode(
            RemoteLibrarySlimmingRemovalSubmitRequest(
                operationID: operationID,
                jobID: jobID,
                clusterID: clusterID,
                mediaKind: .image,
                assetIDs: assetIDs,
                mode: .recoverableRecycle
            )
        )
        let (receiptData, receiptResponse) = try await URLSession.shared.data(for: submit)
        XCTAssertEqual(try XCTUnwrap(receiptResponse as? HTTPURLResponse).statusCode, 202)
        let receipt = try JSONDecoder().decode(
            RemoteLibrarySlimmingRemovalRequestSnapshot.self,
            from: receiptData
        )
        XCTAssertEqual(receipt.assetIDs, assetIDs)
        XCTAssertEqual(commands.lastRemovalCommand?.operationID, operationID)
        XCTAssertEqual(commands.lastRemovalCommand?.clusterID, clusterID)

        let galleryOperationID = UUID()
        var gallerySubmit = authorizedRequest(
            path: RemoteHTTPPaths.librarySlimmingRemovals,
            method: "POST"
        )
        gallerySubmit.httpBody = try JSONEncoder().encode(
            RemoteLibrarySlimmingRemovalSubmitRequest(
                operationID: galleryOperationID,
                jobID: nil,
                clusterID: nil,
                scope: .gallerySelection,
                mediaKind: .image,
                assetIDs: [assetIDs[0]],
                mode: .releaseSourceSpace
            )
        )
        let (galleryData, galleryResponse) = try await URLSession.shared.data(for: gallerySubmit)
        XCTAssertEqual(try XCTUnwrap(galleryResponse as? HTTPURLResponse).statusCode, 202)
        let galleryReceipt = try JSONDecoder().decode(
            RemoteLibrarySlimmingRemovalRequestSnapshot.self,
            from: galleryData
        )
        XCTAssertEqual(galleryReceipt.scope, .gallerySelection)
        XCTAssertNil(galleryReceipt.jobID)
        XCTAssertNil(galleryReceipt.clusterID)
        XCTAssertEqual(commands.lastRemovalCommand?.scope, .gallerySelection)
        XCTAssertEqual(commands.lastRemovalCommand?.mode, .releaseSourceSpace)
    }

    func testLibrarySlimmingIdenticalCleanupRoutesPrepareServerPlanAndSubmitPlanID() async throws {
        let port = UInt16.random(in: 19_000...29_000)
        let jobID = UUID()
        let commands = RemoteHTTPSlimmingCommandStub(sourceID: UUID(), jobID: jobID)
        let (server, _) = makeServer(port: port, librarySlimmingCommands: commands)
        try await server.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        defer { Task { await server.stop() } }

        func authorizedRequest(path: String, method: String = "GET") -> URLRequest {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.httpMethod = method
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(
                "Bearer \(Self.legacyDebugToken)",
                forHTTPHeaderField: "Authorization"
            )
            return request
        }

        var prepare = authorizedRequest(
            path: RemoteHTTPPaths.librarySlimmingIdenticalCleanupPlans,
            method: "POST"
        )
        prepare.httpBody = try JSONEncoder().encode(
            RemoteLibrarySlimmingIdenticalCleanupPlanRequest(jobID: jobID, mediaKind: .image)
        )
        let (planData, planResponse) = try await URLSession.shared.data(for: prepare)
        XCTAssertEqual(try XCTUnwrap(planResponse as? HTTPURLResponse).statusCode, 200)
        let plan = try JSONDecoder().decode(
            RemoteLibrarySlimmingIdenticalCleanupPlanSnapshot.self,
            from: planData
        )
        XCTAssertEqual(plan.groupCount, 2)
        XCTAssertEqual(plan.byteIdenticalGroupCount, 1)
        XCTAssertEqual(plan.perfectVisualGroupCount, 1)
        XCTAssertEqual(plan.favoriteRetainedAssetCount, 1)
        XCTAssertEqual(plan.ordinaryRetainedAssetCount, 1)
        XCTAssertEqual(plan.protectedSkippedAssetCount, 2)
        XCTAssertEqual(plan.removalAssetCount, 3)

        let operationID = UUID()
        var submit = authorizedRequest(
            path: RemoteHTTPPaths.librarySlimmingIdenticalCleanupRequests,
            method: "POST"
        )
        submit.httpBody = try JSONEncoder().encode(
            RemoteLibrarySlimmingIdenticalCleanupSubmitRequest(
                operationID: operationID,
                planID: plan.id,
                mode: .recoverableRecycle
            )
        )
        let (requestData, requestResponse) = try await URLSession.shared.data(for: submit)
        XCTAssertEqual(try XCTUnwrap(requestResponse as? HTTPURLResponse).statusCode, 202)
        let receipt = try JSONDecoder().decode(
            RemoteLibrarySlimmingIdenticalCleanupRequestSnapshot.self,
            from: requestData
        )
        XCTAssertEqual(receipt.planID, plan.id)
        XCTAssertEqual(commands.lastIdenticalCleanupCommand?.operationID, operationID)

        let (statusData, statusResponse) = try await URLSession.shared.data(
            for: authorizedRequest(
                path: "\(RemoteHTTPPaths.librarySlimmingIdenticalCleanupRequests)?mediaKind=image"
            )
        )
        XCTAssertEqual(try XCTUnwrap(statusResponse as? HTTPURLResponse).statusCode, 200)
        let status = try JSONDecoder().decode(
            RemoteLibrarySlimmingIdenticalCleanupSnapshot.self,
            from: statusData
        )
        XCTAssertEqual(status.requests.first?.verification?.verifiedGroupCount, 2)
        XCTAssertEqual(status.requests.first?.verification?.targetRetainedAssetCount, 2)
        XCTAssertEqual(status.requests.first?.verification?.observedAssetCount, 5)
        XCTAssertEqual(status.requests.first?.verification?.currentAvailableAssetCount, 2)
        XCTAssertEqual(status.requests.first?.executionStage, .verifyingResult)
    }

    func testSourceManagementRoutesReturnAsyncMacApprovalReceipt() async throws {
        let port = UInt16.random(in: 19_000...29_000)
        let sourceID = UUID()
        let operationID = UUID()
        let commands = RemoteHTTPSourceManagementCommandStub(
            sourceID: sourceID,
            operationID: operationID
        )
        let (server, _) = makeServer(port: port, sourceManagementCommands: commands)
        try await server.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        defer { Task { await server.stop() } }

        func authorizedRequest(path: String, method: String = "GET") -> URLRequest {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.httpMethod = method
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(
                "Bearer \(Self.legacyDebugToken)",
                forHTTPHeaderField: "Authorization"
            )
            return request
        }

        let (setupData, setupResponse) = try await URLSession.shared.data(
            for: authorizedRequest(path: RemoteHTTPPaths.sourceManagement)
        )
        XCTAssertEqual(try XCTUnwrap(setupResponse as? HTTPURLResponse).statusCode, 200)
        let setup = try JSONDecoder().decode(RemoteSourceManagementSnapshot.self, from: setupData)
        XCTAssertEqual(setup.sources.map(\.id), [sourceID])
        XCTAssertTrue(setup.canConnectPhotos)

        var submit = authorizedRequest(
            path: RemoteHTTPPaths.sourceManagementRequests,
            method: "POST"
        )
        submit.httpBody = try JSONEncoder().encode(RemoteSourceManagementSubmitRequest(
            operationID: operationID,
            action: .reauthorize,
            sourceID: sourceID
        ))
        let (receiptData, receiptResponse) = try await URLSession.shared.data(for: submit)
        XCTAssertEqual(try XCTUnwrap(receiptResponse as? HTTPURLResponse).statusCode, 202)
        let receipt = try JSONDecoder().decode(
            RemoteSourceManagementRequestSnapshot.self,
            from: receiptData
        )
        XCTAssertEqual(receipt.phase, .awaitingMac)
        XCTAssertEqual(commands.lastCommand?.operationID, operationID)
        XCTAssertEqual(commands.lastCommand?.action, .reauthorize)
    }

    func testStorageMaintenanceRoutesReturnRedactedSnapshotAndApprovalReceipt() async throws {
        let port = UInt16.random(in: 19_000...29_000)
        let operationID = UUID()
        let commands = RemoteHTTPStorageMaintenanceCommandStub(operationID: operationID)
        let (server, _) = makeServer(port: port, storageMaintenanceCommands: commands)
        try await server.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        defer { Task { await server.stop() } }

        func authorizedRequest(path: String, method: String = "GET") -> URLRequest {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.httpMethod = method
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(
                "Bearer \(Self.legacyDebugToken)",
                forHTTPHeaderField: "Authorization"
            )
            return request
        }

        let (snapshotData, snapshotResponse) = try await URLSession.shared.data(
            for: authorizedRequest(path: RemoteHTTPPaths.storageMaintenance)
        )
        XCTAssertEqual(try XCTUnwrap(snapshotResponse as? HTTPURLResponse).statusCode, 200)
        let snapshot = try JSONDecoder().decode(
            RemoteStorageMaintenanceSnapshot.self,
            from: snapshotData
        )
        XCTAssertEqual(snapshot.previewCache.registeredBytes, 1_500_000)
        XCTAssertEqual(snapshot.clearPreviewCacheAvailability?.isAvailable, true)
        XCTAssertEqual(snapshot.clearPhotosOriginalsAvailability?.isAvailable, false)
        XCTAssertEqual(
            snapshot.clearPhotosOriginalsAvailability?.reason,
            .librarySlimmingAnalysisInProgress
        )
        XCTAssertEqual(snapshot.appStorage.pendingExternalRootName, "ImageAll-External")
        XCTAssertFalse(String(decoding: snapshotData, as: UTF8.self).contains("/Volumes/"))

        var submit = authorizedRequest(
            path: RemoteHTTPPaths.storageMaintenanceRequests,
            method: "POST"
        )
        submit.httpBody = try JSONEncoder().encode(RemoteStorageMaintenanceSubmitRequest(
            operationID: operationID,
            action: .clearPreviewCache
        ))
        let (receiptData, receiptResponse) = try await URLSession.shared.data(for: submit)
        XCTAssertEqual(try XCTUnwrap(receiptResponse as? HTTPURLResponse).statusCode, 202)
        let receipt = try JSONDecoder().decode(
            RemoteStorageMaintenanceRequestSnapshot.self,
            from: receiptData
        )
        XCTAssertEqual(receipt.phase, .awaitingMac)
        XCTAssertEqual(commands.lastCommand?.action, .clearPreviewCache)
    }

    private func makeIdempotencyStore() -> RemoteIdempotencyStore {
        RemoteIdempotencyStore(storageURL: tempStorageURL(name: "idempotency.json"))
    }

    private func tempStorageURL(name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteHTTPServerTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name)
    }

    private func makePairingStore(
        hostID: UUID = UUID(),
        listenPort: Int,
        usesTLS: Bool = false,
        certificateFingerprintSHA256: String = ""
    ) -> RemotePairingStore {
        RemotePairingStore(
            hostContext: RemotePairingStore.HostContext(
                hostID: hostID,
                hostDisplayName: "Test Host",
                listenPort: listenPort,
                usesTLS: usesTLS,
                certificateFingerprintSHA256: certificateFingerprintSHA256
            ),
            storageURL: tempStorageURL(name: "pairing.json"),
            legacyDebugToken: Self.legacyDebugToken
        )
    }

    private func makeAccessAccountStore() -> RemoteAccessAccountStore {
        RemoteAccessAccountStore(
            storageURL: tempStorageURL(name: "access-accounts.json"),
            passwordHashIterations: 100
        )
    }

    private func makeServer(
        port: UInt16,
        catalog: any RemoteCatalogServing = RemoteHTTPServerTestCatalog(),
        pairingStore: RemotePairingStore? = nil,
        accessAccountStore: RemoteAccessAccountStore? = nil,
        trainingWorkspace: (any TrainingWorkspacePort)? = nil,
        trainingCommands: (any RemoteTrainingCommandPort)? = nil,
        librarySlimmingAnalysis: (any LibrarySlimmingAnalysisJobPort)? = nil,
        librarySlimmingCommands: (any RemoteLibrarySlimmingCommandPort)? = nil,
        sourceManagementCommands: (any RemoteSourceManagementCommandPort)? = nil,
        storageMaintenanceCommands: (any RemoteStorageMaintenanceCommandPort)? = nil,
        workspaceNotices: (any RemoteWorkspaceNoticePort)? = nil,
        hostAppVersion: String = "1.0.0",
        webAssetStore: RemoteWebCompanionAssetStore = RemoteWebCompanionAssetStore(),
        mediaResources: any RemoteMediaResourceProviding = UnavailableRemoteMediaResourceProvider(),
        originalAssetOpener: (any LibraryOriginalAssetOpening)? = nil
    ) -> (RemoteHTTPServer, RemotePairingStore) {
        let store = pairingStore ?? makePairingStore(listenPort: Int(port))
        let facade = RemoteCatalogFacade(
            catalog: catalog,
            review: EmptyPersonalizationReviewPort(),
            trainingWorkspace: trainingWorkspace,
            trainingCommands: trainingCommands,
            librarySlimmingAnalysis: librarySlimmingAnalysis,
            librarySlimmingCommands: librarySlimmingCommands,
            sourceManagementCommands: sourceManagementCommands,
            storageMaintenanceCommands: storageMaintenanceCommands,
            workspaceNotices: workspaceNotices,
            idempotency: makeIdempotencyStore(),
            hostAppVersion: hostAppVersion,
            listenPort: Int(port)
        )
        let server = RemoteHTTPServer(
            facade: facade,
            pairingStore: store,
            accessAccountStore: accessAccountStore ?? makeAccessAccountStore(),
            eventBroker: RemoteEventBroker(),
            mediaResources: mediaResources,
            originalAssetOpener: originalAssetOpener,
            webAssetStore: webAssetStore,
            secIdentity: nil,
            port: port
        )
        return (server, store)
    }

    func testWhitelistedAccountLogsInWithoutPairingTokenOrSessionToken() async throws {
        let port = UInt16.random(in: 19_000...29_000)
        let accountStore = makeAccessAccountStore()
        _ = try await accountStore.upsert(
            username: "web-owner",
            password: "safe-web-password"
        )
        let (server, _) = makeServer(
            port: port,
            accessAccountStore: accountStore,
            hostAppVersion: "2.4.0"
        )
        try await server.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        defer { Task { await server.stop() } }

        let basic = Data("web-owner:safe-web-password".utf8).base64EncodedString()
        var login = URLRequest(
            url: URL(string: "http://127.0.0.1:\(port)/web/account/login")!
        )
        login.httpMethod = "POST"
        login.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        login.setValue(
            "http://127.0.0.1:\(port)",
            forHTTPHeaderField: "Origin"
        )
        login.setValue(
            "127.0.0.1:\(port)",
            forHTTPHeaderField: "Host"
        )
        login.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")

        let (loginData, loginResponse) = try await URLSession.shared.data(for: login)
        let loginHTTP = try XCTUnwrap(loginResponse as? HTTPURLResponse)
        XCTAssertEqual(loginHTTP.statusCode, 200)
        XCTAssertNil(loginHTTP.value(forHTTPHeaderField: "Set-Cookie"))
        let loginText = try XCTUnwrap(String(data: loginData, encoding: .utf8))
        XCTAssertFalse(loginText.contains("token"))
        XCTAssertTrue(loginText.contains("\"authMode\":\"account\""))

        var capabilities = URLRequest(
            url: URL(string: "http://127.0.0.1:\(port)/v1/capabilities")!
        )
        capabilities.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: capabilities)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(
            try JSONDecoder().decode(RemoteCapabilities.self, from: data).hostAppVersion,
            "2.4.0"
        )

        var crossSiteMutation = URLRequest(
            url: URL(string: "http://127.0.0.1:\(port)/v1/tags/selection")!
        )
        crossSiteMutation.httpMethod = "POST"
        crossSiteMutation.httpBody = Data("{}".utf8)
        crossSiteMutation.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        crossSiteMutation.setValue(
            "Basic \(basic)",
            forHTTPHeaderField: "Authorization"
        )
        crossSiteMutation.setValue(
            "https://attacker.example",
            forHTTPHeaderField: "Origin"
        )
        crossSiteMutation.setValue(
            "cross-site",
            forHTTPHeaderField: "Sec-Fetch-Site"
        )
        let (_, crossSiteResponse) = try await URLSession.shared.data(
            for: crossSiteMutation
        )
        XCTAssertEqual(
            try XCTUnwrap(crossSiteResponse as? HTTPURLResponse).statusCode,
            403
        )

        let wrongBasic = Data("web-owner:wrong-password".utf8).base64EncodedString()
        capabilities.setValue("Basic \(wrongBasic)", forHTTPHeaderField: "Authorization")
        let (_, rejectedResponse) = try await URLSession.shared.data(for: capabilities)
        XCTAssertEqual(
            try XCTUnwrap(rejectedResponse as? HTTPURLResponse).statusCode,
            401
        )
    }

    func testParserRejectsNegativeContentLength() {
        let bytes = Data(
            "POST /v1/tag-decisions:batch HTTP/1.1\r\nContent-Length: -1\r\n\r\n".utf8
        )

        guard case let .rejected(status, error) = RemoteHTTPServer.parseRequest(
            buffer: bytes,
            isComplete: false
        ) else {
            return XCTFail("expected rejection")
        }
        XCTAssertEqual(status, 400)
        XCTAssertEqual(error.code, .badRequest)
    }

    func testParserRejectsOversizedDeclaredBodyBeforeAccumulatingIt() {
        let bytes = Data(
            "POST /v1/tag-decisions:batch HTTP/1.1\r\nContent-Length: 999999999\r\n\r\n".utf8
        )

        guard case let .rejected(status, _) = RemoteHTTPServer.parseRequest(
            buffer: bytes,
            isComplete: false
        ) else {
            return XCTFail("expected rejection")
        }
        XCTAssertEqual(status, 413)
    }

    func testParserRejectsDuplicateContentLength() {
        let bytes = Data(
            "POST /v1/tag-decisions/batch HTTP/1.1\r\nContent-Length: 0\r\nContent-Length: 1\r\n\r\n".utf8
        )

        guard case let .rejected(status, _) = RemoteHTTPServer.parseRequest(
            buffer: bytes,
            isComplete: false
        ) else {
            return XCTFail("expected rejection")
        }
        XCTAssertEqual(status, 400)
    }

    func testParserRejectsUnsupportedTransferEncoding() {
        let bytes = Data(
            "POST /v1/tag-decisions/batch HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n".utf8
        )

        guard case let .rejected(status, _) = RemoteHTTPServer.parseRequest(
            buffer: bytes,
            isComplete: false
        ) else {
            return XCTFail("expected rejection")
        }
        XCTAssertEqual(status, 400)
    }

    func testParserRejectsTrailingBytesAfterDeclaredBody() {
        let bytes = Data(
            "POST /v1/tag-decisions:batch HTTP/1.1\r\nContent-Length: 0\r\n\r\nextra".utf8
        )

        guard case let .rejected(status, _) = RemoteHTTPServer.parseRequest(
            buffer: bytes,
            isComplete: false
        ) else {
            return XCTFail("expected rejection")
        }
        XCTAssertEqual(status, 400)
    }

    func testUnauthorizedWithoutBearerToken() async throws {
        let port = UInt16.random(in: 19_000...29_000)
        let (server, _) = makeServer(port: port)
        try await server.start()
        try await Task.sleep(nanoseconds: 150_000_000)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/capabilities")!)
        request.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: request)
        await server.stop()

        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 401)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertEqual(http.value(forHTTPHeaderField: "Pragma"), "no-cache")
        let error = try JSONDecoder().decode(RemoteAPIError.self, from: data)
        XCTAssertEqual(error.code, .unauthorized)
    }

    func testCapabilitiesWithLegacyDebugBearerToken() async throws {
        let port = UInt16.random(in: 19_000...29_000)
        let (server, _) = makeServer(port: port, hostAppVersion: "2.3.4")
        try await server.start()
        try await Task.sleep(nanoseconds: 150_000_000)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/capabilities")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(Self.legacyDebugToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        await server.stop()

        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        let capabilities = try JSONDecoder().decode(RemoteCapabilities.self, from: data)
        XCTAssertEqual(capabilities.hostAppVersion, "2.3.4")
        XCTAssertEqual(capabilities.protocolVersion, RemoteProtocolVersion.current)
    }

    func testFolderHierarchyRoutesParsePairedRelativeScopeWithoutAbsolutePaths() async throws {
        let port = UInt16.random(in: 19_000...29_000)
        let sourceID = UUID()
        let (server, _) = makeServer(port: port)
        try await server.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        defer { Task { await server.stop() } }

        func request(_ path: String) async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.setValue(
                "Bearer \(Self.legacyDebugToken)",
                forHTTPHeaderField: "Authorization"
            )
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, try XCTUnwrap(response as? HTTPURLResponse))
        }

        var folderComponents = URLComponents(string: "/v1/source-folders")!
        folderComponents.queryItems = [
            URLQueryItem(name: "sourceID", value: sourceID.uuidString),
            URLQueryItem(name: "parentRelativePath", value: "Trips/2026"),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "limit", value: "100"),
        ]
        let folderQuery = try XCTUnwrap(folderComponents.string)
        let (folderData, folderResponse) = try await request(folderQuery)
        XCTAssertEqual(folderResponse.statusCode, 200)
        XCTAssertEqual(
            try JSONDecoder().decode(RemoteSourceFolderPage.self, from: folderData).folders,
            []
        )

        var searchComponents = URLComponents(string: "/v1/source-folders")!
        searchComponents.queryItems = [
            URLQueryItem(name: "sourceID", value: sourceID.uuidString),
            URLQueryItem(name: "q", value: "%_"),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "limit", value: "50"),
        ]
        let searchQuery = try XCTUnwrap(searchComponents.string)
        let (searchData, searchResponse) = try await request(searchQuery)
        XCTAssertEqual(searchResponse.statusCode, 200)
        XCTAssertEqual(
            try JSONDecoder().decode(RemoteSourceFolderPage.self, from: searchData).folders,
            []
        )

        var assetsComponents = URLComponents(string: "/v1/assets")!
        assetsComponents.queryItems = [
            URLQueryItem(name: "sourceIDs", value: sourceID.uuidString),
            URLQueryItem(name: "folderSourceID", value: sourceID.uuidString),
            URLQueryItem(name: "folderRelativePath", value: "Trips/2026"),
        ]
        let assetsQuery = try XCTUnwrap(assetsComponents.string)
        let (_, assetsResponse) = try await request(assetsQuery)
        XCTAssertEqual(assetsResponse.statusCode, 200)

        let (_, partialResponse) = try await request(
            "/v1/assets?folderSourceID=\(sourceID.uuidString)"
        )
        XCTAssertEqual(partialResponse.statusCode, 400)
    }

    func testWorldMapRoutesRequireAuthenticationAndReturnCatalogProjection() async throws {
        let port = UInt16.random(in: 19_000...29_000)
        let sourceID = UUID()
        let placeTagID = UUID()
        let placeCandidate = WorldMapPlaceCandidate(
            placeID: "shanghai-cn",
            displayName: "上海市",
            subtitle: "中国上海市",
            latitude: 31.23,
            longitude: 121.47,
            kind: .city,
            countryCode: "CN"
        )
        let unresolvedPlace = WorldMapPlaceTagResolution(
            tagID: placeTagID,
            tagName: "上海",
            groupName: "地点与场景",
            acceptedPhotoCount: 8,
            status: .unresolved,
            confirmedPlaceID: nil,
            candidates: []
        )
        let resolvedPlace = WorldMapPlaceTagResolution(
            tagID: placeTagID,
            tagName: "上海",
            groupName: "地点与场景",
            acceptedPhotoCount: 8,
            status: .resolved,
            confirmedPlaceID: placeCandidate.placeID,
            candidates: [placeCandidate]
        )
        let catalog = RemoteHTTPServerTestCatalog(
            worldMapLocationBackfills: [
                WorldMapLocationBackfillSnapshot(
                    sourceID: sourceID,
                    sourceKind: .folder,
                    sourceDisplayName: "Synthetic Folder",
                    sourceState: .active,
                    phase: .ready,
                    totalPhotoCount: 20,
                    inspectedPhotoCount: 5,
                    locatedPhotoCount: 3,
                    activeJobID: nil,
                    scanProgress: nil
                ),
            ],
            worldMapPlaceResolutions: [unresolvedPlace],
            worldMapPlaceSearchResult: resolvedPlace,
            worldMapPlaceConfirmResult: resolvedPlace
        )
        let (server, _) = makeServer(port: port, catalog: catalog)
        try await server.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        defer { Task { await server.stop() } }

        let (_, unauthorizedOverviewResponse) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(port)\(RemoteHTTPPaths.galleryOverview)")!
        )
        XCTAssertEqual(
            try XCTUnwrap(unauthorizedOverviewResponse as? HTTPURLResponse).statusCode,
            401
        )
        let (_, unauthorizedPlaceResponse) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(port)\(RemoteHTTPPaths.worldMapPlaceTags)")!
        )
        XCTAssertEqual(
            try XCTUnwrap(unauthorizedPlaceResponse as? HTTPURLResponse).statusCode,
            401
        )

        func authorizedRequest(path: String, method: String = "GET") -> URLRequest {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.httpMethod = method
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(
                "Bearer \(Self.legacyDebugToken)",
                forHTTPHeaderField: "Authorization"
            )
            return request
        }

        let (snapshotData, snapshotResponse) = try await URLSession.shared.data(
            for: authorizedRequest(
                path: "\(RemoteHTTPPaths.worldMapSnapshot)?west=118&south=30&east=123&north=33"
            )
        )
        XCTAssertEqual(try XCTUnwrap(snapshotResponse as? HTTPURLResponse).statusCode, 200)
        let snapshot = try JSONDecoder().decode(RemoteWorldMapSnapshot.self, from: snapshotData)
        XCTAssertTrue(snapshot.clusters.isEmpty)

        let (overviewData, overviewResponse) = try await URLSession.shared.data(
            for: authorizedRequest(path: RemoteHTTPPaths.galleryOverview)
        )
        XCTAssertEqual(try XCTUnwrap(overviewResponse as? HTTPURLResponse).statusCode, 200)
        let overview = try JSONDecoder().decode(RemoteGalleryOverviewSnapshot.self, from: overviewData)
        XCTAssertTrue(overview.sources.isEmpty)

        var selectionRequest = authorizedRequest(
            path: RemoteHTTPPaths.worldMapSelection,
            method: "POST"
        )
        selectionRequest.httpBody = try JSONEncoder().encode(RemoteWorldMapSelectionRequest(
            query: RemoteWorldMapSelectionQuery(
                cellDegrees: 7.5,
                longitudeBucket: 24,
                latitudeBucket: 12,
                maximumAssets: 36
            )
        ))
        let (selectionData, selectionResponse) = try await URLSession.shared.data(
            for: selectionRequest
        )
        XCTAssertEqual(try XCTUnwrap(selectionResponse as? HTTPURLResponse).statusCode, 200)
        let selection = try JSONDecoder().decode(RemoteWorldMapSelection.self, from: selectionData)
        XCTAssertTrue(selection.assets.isEmpty)

        let (backfillData, backfillResponse) = try await URLSession.shared.data(
            for: authorizedRequest(path: RemoteHTTPPaths.worldMapLocationBackfill)
        )
        XCTAssertEqual(try XCTUnwrap(backfillResponse as? HTTPURLResponse).statusCode, 200)
        let backfills = try JSONDecoder().decode(
            [RemoteWorldMapLocationBackfillSnapshot].self,
            from: backfillData
        )
        XCTAssertEqual(backfills.first?.sourceDisplayName, "Synthetic Folder")

        var backfillCommand = authorizedRequest(
            path: RemoteHTTPPaths.worldMapLocationBackfillRequests,
            method: "POST"
        )
        backfillCommand.httpBody = try JSONEncoder().encode(
            RemoteWorldMapLocationBackfillCommandRequest(
                operationID: UUID(),
                sourceID: sourceID,
                action: .start
            )
        )
        let (commandData, commandResponse) = try await URLSession.shared.data(for: backfillCommand)
        XCTAssertEqual(try XCTUnwrap(commandResponse as? HTTPURLResponse).statusCode, 202)
        let command = try JSONDecoder().decode(
            RemoteWorldMapLocationBackfillCommandResponse.self,
            from: commandData
        )
        XCTAssertEqual(command.snapshot.sourceID, sourceID)
        XCTAssertEqual(catalog.worldMapLocationBackfillStartCount, 1)

        let (placeData, placeResponse) = try await URLSession.shared.data(
            for: authorizedRequest(path: RemoteHTTPPaths.worldMapPlaceTags)
        )
        XCTAssertEqual(try XCTUnwrap(placeResponse as? HTTPURLResponse).statusCode, 200)
        let placeSnapshot = try JSONDecoder().decode(
            RemoteWorldMapPlaceTagSnapshot.self,
            from: placeData
        )
        XCTAssertEqual(placeSnapshot.items.first?.tagName, "上海")
        XCTAssertEqual(placeSnapshot.maximumQueryLength, 160)

        var placeSearch = authorizedRequest(
            path: RemoteHTTPPaths.worldMapPlaceTagRequests,
            method: "POST"
        )
        placeSearch.httpBody = try JSONEncoder().encode(
            RemoteWorldMapPlaceTagCommandRequest(
                operationID: UUID(),
                tagID: placeTagID,
                action: .search,
                query: "上海 中国"
            )
        )
        let (placeSearchData, placeSearchResponse) = try await URLSession.shared.data(
            for: placeSearch
        )
        XCTAssertEqual(try XCTUnwrap(placeSearchResponse as? HTTPURLResponse).statusCode, 200)
        let placeSearchResult = try JSONDecoder().decode(
            RemoteWorldMapPlaceTagCommandResponse.self,
            from: placeSearchData
        )
        XCTAssertEqual(placeSearchResult.resolution.confirmedPlaceID, placeCandidate.placeID)
        XCTAssertEqual(catalog.worldMapPlaceSearchCount, 1)
    }

    func testTrainingWorkspaceRouteReturnsFilteredHostSnapshot() async throws {
        let port = UInt16.random(in: 19_000...29_000)
        let runID = UUID()
        let training = RemoteHTTPTrainingWorkspaceStub(
            snapshot: TrainingWorkspaceSnapshot(
                runs: [
                    TrainingRunRecord(
                        id: runID,
                        mediaKind: .video,
                        method: .personalCentroid,
                        state: .running,
                        createdAtMs: 1_700_000_000_000,
                        startedAtMs: 1_700_000_001_000,
                        finishedAtMs: nil,
                        catalogScopeID: "allSources",
                        jobID: UUID(),
                        sampleSummaryJSON: "{}",
                        sampleManifestSHA256: nil,
                        configJSON: "{}",
                        metricsJSON: "{}",
                        artifactKind: nil,
                        artifactRef: nil,
                        artifactSHA256: nil,
                        resultSummaryJSON: "{}",
                        errorCode: nil
                    ),
                ],
                slots: []
            )
        )
        let (server, _) = makeServer(
            port: port,
            trainingWorkspace: training
        )
        try await server.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        defer { Task { await server.stop() } }

        var request = URLRequest(
            url: URL(
                string: "http://127.0.0.1:\(port)/v1/training/workspace?mediaKind=video&method=personalCentroid"
            )!
        )
        request.setValue(
            "Bearer \(Self.legacyDebugToken)",
            forHTTPHeaderField: "Authorization"
        )
        let (data, response) = try await URLSession.shared.data(for: request)

        XCTAssertEqual(try XCTUnwrap(response as? HTTPURLResponse).statusCode, 200)
        let payload = try JSONDecoder().decode(
            RemoteTrainingWorkspaceSnapshot.self,
            from: data
        )
        XCTAssertEqual(payload.mediaKind, .video)
        XCTAssertEqual(payload.methodFilter, .personalCentroid)
        XCTAssertEqual(payload.runs.first?.id, runID)
        XCTAssertEqual(training.lastMediaKind, .video)
        XCTAssertEqual(training.lastMethod, .personalCentroid)
    }

    func testTrainingSetupAndLaunchRoutesReuseHostCommandAndReplayOnce() async throws {
        let port = UInt16.random(in: 19_000...29_000)
        let tagID = UUID()
        let sourceID = UUID()
        let jobID = UUID()
        let activityID = UUID()
        let commands = RemoteHTTPTrainingCommandStub(
            setupSnapshot: TrainingCommandSetupSnapshot(
                mediaKind: .image,
                tags: [
                    TrainingCommandTagOption(
                        id: tagID,
                        displayName: "猫",
                        acceptedSampleCount: 18,
                        rejectedSampleCount: 4,
                        featureMode: .generate,
                        personalEligible: true
                    ),
                ],
                sources: [
                    TrainingCommandSourceOption(id: sourceID, displayName: "Apple Photos"),
                ],
                supportsPersonalCentroid: true,
                supportsPersonalAdamW: true
            ),
            receipt: TrainingLaunchReceipt(
                operationID: UUID(),
                method: .featureKnn,
                acceptedAtMs: 1_700_000_000_000,
                scheduledTagCount: 1,
                jobID: jobID
            ),
            trainingActivity: TrainingCommandActivitySnapshot(
                operationID: activityID,
                mediaKind: .image,
                method: .personalCentroid,
                phase: .preparingEmbeddings,
                completedUnitCount: 1,
                totalUnitCount: 3,
                sampleCount: 12,
                errorCode: nil,
                acceptedAtMs: 1_700_000_000_000,
                updatedAtMs: 1_700_000_001_000
            )
        )
        let (server, _) = makeServer(port: port, trainingCommands: commands)
        try await server.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        defer { Task { await server.stop() } }

        var activityRequest = URLRequest(
            url: URL(
                string: "http://127.0.0.1:\(port)"
                    + "\(RemoteHTTPPaths.trainingActivities)?mediaKind=image"
            )!
        )
        activityRequest.setValue(
            "Bearer \(Self.legacyDebugToken)",
            forHTTPHeaderField: "Authorization"
        )
        let (activityData, activityResponse) = try await URLSession.shared.data(
            for: activityRequest
        )
        XCTAssertEqual(try XCTUnwrap(activityResponse as? HTTPURLResponse).statusCode, 200)
        let activities = try JSONDecoder().decode([RemoteTrainingActivity].self, from: activityData)
        XCTAssertEqual(activities.first?.operationID, activityID)
        XCTAssertEqual(activities.first?.method, .personalCentroid)
        XCTAssertEqual(activities.first?.phase, .preparingEmbeddings)

        var setupRequest = URLRequest(
            url: URL(
                string: "http://127.0.0.1:\(port)/v1/training/setup?mediaKind=image"
            )!
        )
        setupRequest.setValue(
            "Bearer \(Self.legacyDebugToken)",
            forHTTPHeaderField: "Authorization"
        )
        let (setupData, setupResponse) = try await URLSession.shared.data(for: setupRequest)

        XCTAssertEqual(try XCTUnwrap(setupResponse as? HTTPURLResponse).statusCode, 200)
        let setup = try JSONDecoder().decode(RemoteTrainingSetupSnapshot.self, from: setupData)
        XCTAssertEqual(setup.tags.first?.displayName, "猫")
        XCTAssertEqual(setup.sources.first?.id, sourceID)

        let operationID = UUID()
        var launchRequest = URLRequest(
            url: URL(string: "http://127.0.0.1:\(port)/v1/training/launch")!
        )
        launchRequest.httpMethod = "POST"
        launchRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        launchRequest.setValue(
            "Bearer \(Self.legacyDebugToken)",
            forHTTPHeaderField: "Authorization"
        )
        launchRequest.httpBody = try JSONEncoder().encode(
            RemoteTrainingLaunchRequest(
                operationID: operationID,
                mediaKind: .image,
                method: .featureKnn,
                tagIDs: [tagID],
                sourceIDs: [sourceID]
            )
        )

        let (firstData, firstResponse) = try await URLSession.shared.data(for: launchRequest)
        let (secondData, secondResponse) = try await URLSession.shared.data(for: launchRequest)

        XCTAssertEqual(try XCTUnwrap(firstResponse as? HTTPURLResponse).statusCode, 202)
        XCTAssertEqual(try XCTUnwrap(secondResponse as? HTTPURLResponse).statusCode, 202)
        let first = try JSONDecoder().decode(RemoteTrainingLaunchResponse.self, from: firstData)
        let second = try JSONDecoder().decode(RemoteTrainingLaunchResponse.self, from: secondData)
        XCTAssertEqual(first.operationID, operationID)
        XCTAssertEqual(first.jobID, jobID)
        XCTAssertFalse(first.replayed)
        XCTAssertTrue(second.replayed)
        XCTAssertEqual(commands.launchCallCount, 1)
        XCTAssertEqual(commands.lastCommand?.tagIDs, Set([tagID]))
        XCTAssertEqual(commands.lastCommand?.sourceIDs, Set([sourceID]))

        var cancelRequest = URLRequest(
            url: URL(
                string: "http://127.0.0.1:\(port)/v1/training/activities/\(operationID.uuidString)/actions"
            )!
        )
        cancelRequest.httpMethod = "POST"
        cancelRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        cancelRequest.setValue(
            "Bearer \(Self.legacyDebugToken)",
            forHTTPHeaderField: "Authorization"
        )
        cancelRequest.httpBody = try JSONEncoder().encode(
            RemoteTrainingActivityActionRequest(action: .cancel)
        )

        let (cancelData, cancelResponse) = try await URLSession.shared.data(for: cancelRequest)
        XCTAssertEqual(try XCTUnwrap(cancelResponse as? HTTPURLResponse).statusCode, 200)
        let cancelled = try JSONDecoder().decode(
            RemoteTrainingActivityActionResponse.self,
            from: cancelData
        )
        XCTAssertEqual(cancelled.activity.operationID, operationID)
        XCTAssertEqual(cancelled.activity.phase, .cancelled)
        XCTAssertEqual(commands.cancelCallCount, 1)
    }

    func testLibrarySuggestionRoutesExposeHostSnapshotAndLaunchScope() async throws {
        let port = UInt16.random(in: 19_000...29_000)
        let sourceID = UUID()
        let jobID = UUID()
        let commands = RemoteHTTPTrainingCommandStub(
            setupSnapshot: TrainingCommandSetupSnapshot(
                mediaKind: .image,
                tags: [],
                sources: [],
                supportsPersonalCentroid: false,
                supportsPersonalAdamW: false
            ),
            receipt: TrainingLaunchReceipt(
                operationID: UUID(),
                method: .featureKnn,
                acceptedAtMs: 0,
                scheduledTagCount: 0,
                jobID: nil
            ),
            librarySuggestionSnapshot: LibrarySuggestionWorkspaceSnapshot(
                mediaKind: .video,
                service: LibrarySuggestionServiceSnapshot(
                    state: .ready,
                    serviceVersion: "1.2.3",
                    provider: "coreml",
                    modelID: "scene-personal-v1"
                ),
                standardAvailable: true,
                personalMode: .fullLibrary,
                standardJob: LibrarySuggestionJobSnapshot(
                    jobID: jobID,
                    state: .running,
                    checkedCount: 12,
                    totalCount: 30,
                    suggestedCount: 4,
                    skippedCount: 1,
                    lastErrorCode: nil,
                    availableActions: [.pause, .cancel]
                ),
                personalJob: nil
            ),
            librarySuggestionReceipt: LibrarySuggestionReceipt(
                operationID: UUID(),
                track: .personal,
                jobID: jobID,
                replayed: false
            )
        )
        let (server, _) = makeServer(port: port, trainingCommands: commands)
        try await server.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        defer { Task { await server.stop() } }

        func authorizedRequest(path: String, method: String = "GET") -> URLRequest {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.httpMethod = method
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(
                "Bearer \(Self.legacyDebugToken)",
                forHTTPHeaderField: "Authorization"
            )
            return request
        }

        let (snapshotData, snapshotResponse) = try await URLSession.shared.data(
            for: authorizedRequest(
                path: "\(RemoteHTTPPaths.librarySuggestions)?mediaKind=video&refreshServiceHealth=1"
            )
        )
        XCTAssertEqual(try XCTUnwrap(snapshotResponse as? HTTPURLResponse).statusCode, 200)
        let snapshot = try JSONDecoder().decode(
            RemoteLibrarySuggestionSnapshot.self,
            from: snapshotData
        )
        XCTAssertEqual(snapshot.mediaKind, .video)
        XCTAssertEqual(snapshot.service.state, .ready)
        XCTAssertEqual(snapshot.standardJob?.availableActions, [.pause, .cancel])
        XCTAssertEqual(commands.librarySuggestionSnapshotCallCount, 1)
        XCTAssertEqual(commands.lastLibrarySuggestionMediaKind, .video)
        XCTAssertTrue(commands.lastLibrarySuggestionRefreshHealth)

        let operationID = UUID()
        var launch = authorizedRequest(
            path: RemoteHTTPPaths.librarySuggestionRequests,
            method: "POST"
        )
        launch.httpBody = try JSONEncoder().encode(
            RemoteLibrarySuggestionRequest(
                operationID: operationID,
                mediaKind: .video,
                track: .personal,
                sourceIDs: [sourceID]
            )
        )
        let (launchData, launchResponse) = try await URLSession.shared.data(for: launch)
        XCTAssertEqual(try XCTUnwrap(launchResponse as? HTTPURLResponse).statusCode, 202)
        let response = try JSONDecoder().decode(
            RemoteLibrarySuggestionResponse.self,
            from: launchData
        )
        XCTAssertEqual(response.operationID, operationID)
        XCTAssertEqual(response.track, .personal)
        XCTAssertEqual(response.jobID, jobID)
        XCTAssertFalse(response.replayed)
        XCTAssertEqual(commands.librarySuggestionLaunchCallCount, 1)
        XCTAssertEqual(commands.lastLibrarySuggestionCommand?.sourceIDs, [sourceID])
    }

    func testEmbeddingPreparationRoutesExposeProgressSubmitAndCancel() async throws {
        let port = UInt16.random(in: 19_000...29_000)
        let operationID = UUID()
        let assetIDs = [UUID(), UUID()]
        let activity = EmbeddingPreparationActivitySnapshot(
            operationID: operationID,
            mediaKind: .image,
            phase: .running,
            completedUnitCount: 1,
            totalUnitCount: 2,
            preparedCount: 1,
            cachedCount: 0,
            cloudOnlyCount: 0,
            failedCount: 0,
            errorCode: nil
        )
        let commands = RemoteHTTPTrainingCommandStub(
            setupSnapshot: TrainingCommandSetupSnapshot(
                mediaKind: .image,
                tags: [],
                sources: [],
                supportsPersonalCentroid: true,
                supportsPersonalAdamW: false
            ),
            receipt: TrainingLaunchReceipt(
                operationID: UUID(),
                method: .personalCentroid,
                acceptedAtMs: 0,
                scheduledTagCount: 0,
                jobID: nil
            ),
            embeddingActivity: activity
        )
        let (server, _) = makeServer(port: port, trainingCommands: commands)
        try await server.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        defer { Task { await server.stop() } }

        var snapshotRequest = URLRequest(
            url: URL(string: "http://127.0.0.1:\(port)/v1/embedding-preparation?mediaKind=image")!
        )
        snapshotRequest.setValue(
            "Bearer \(Self.legacyDebugToken)",
            forHTTPHeaderField: "Authorization"
        )
        let (snapshotData, snapshotResponse) = try await URLSession.shared.data(
            for: snapshotRequest
        )
        XCTAssertEqual(try XCTUnwrap(snapshotResponse as? HTTPURLResponse).statusCode, 200)
        let snapshot = try JSONDecoder().decode(
            RemoteEmbeddingPreparationSnapshot.self,
            from: snapshotData
        )
        XCTAssertTrue(snapshot.isAvailable)
        XCTAssertEqual(snapshot.activities.first?.preparedCount, 1)

        var submitRequest = URLRequest(
            url: URL(string: "http://127.0.0.1:\(port)/v1/embedding-preparation/requests")!
        )
        submitRequest.httpMethod = "POST"
        submitRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        submitRequest.setValue(
            "Bearer \(Self.legacyDebugToken)",
            forHTTPHeaderField: "Authorization"
        )
        submitRequest.httpBody = try JSONEncoder().encode(
            RemoteEmbeddingPreparationRequest(
                operationID: operationID,
                mediaKind: .image,
                assetIDs: assetIDs
            )
        )
        let (submitData, submitResponse) = try await URLSession.shared.data(for: submitRequest)
        XCTAssertEqual(try XCTUnwrap(submitResponse as? HTTPURLResponse).statusCode, 202)
        let submitted = try JSONDecoder().decode(
            RemoteEmbeddingPreparationResponse.self,
            from: submitData
        )
        XCTAssertEqual(submitted.activity.operationID, operationID)
        XCTAssertEqual(commands.embeddingPrepareCallCount, 1)

        var cancelRequest = URLRequest(
            url: URL(
                string: "http://127.0.0.1:\(port)/v1/embedding-preparation/requests/\(operationID.uuidString)/actions"
            )!
        )
        cancelRequest.httpMethod = "POST"
        cancelRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        cancelRequest.setValue(
            "Bearer \(Self.legacyDebugToken)",
            forHTTPHeaderField: "Authorization"
        )
        cancelRequest.httpBody = try JSONEncoder().encode(
            RemoteEmbeddingPreparationActionRequest(action: .cancel)
        )
        let (cancelData, cancelResponse) = try await URLSession.shared.data(for: cancelRequest)
        XCTAssertEqual(try XCTUnwrap(cancelResponse as? HTTPURLResponse).statusCode, 200)
        let cancelled = try JSONDecoder().decode(
            RemoteEmbeddingPreparationActionResponse.self,
            from: cancelData
        )
        XCTAssertEqual(cancelled.activity.phase, .cancelled)
        XCTAssertEqual(commands.embeddingCancelCallCount, 1)
    }

    func testSampleSuggestionRoutesExposeProgressSubmitAndCancel() async throws {
        let port = UInt16.random(in: 19_000...29_000)
        let operationID = UUID()
        let assetIDs = [UUID(), UUID()]
        let activity = SampleSuggestionActivitySnapshot(
            operationID: operationID,
            mediaKind: .image,
            phase: .running,
            completedUnitCount: 0,
            totalUnitCount: 2,
            suggestedCount: 0,
            skippedCount: 0,
            errorCode: nil
        )
        let commands = RemoteHTTPTrainingCommandStub(
            setupSnapshot: TrainingCommandSetupSnapshot(
                mediaKind: .image,
                tags: [],
                sources: [],
                supportsPersonalCentroid: true,
                supportsPersonalAdamW: false
            ),
            receipt: TrainingLaunchReceipt(
                operationID: UUID(),
                method: .personalCentroid,
                acceptedAtMs: 0,
                scheduledTagCount: 0,
                jobID: nil
            ),
            sampleActivity: activity
        )
        let (server, _) = makeServer(port: port, trainingCommands: commands)
        try await server.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        defer { Task { await server.stop() } }

        var snapshotRequest = URLRequest(
            url: URL(string: "http://127.0.0.1:\(port)/v1/sample-suggestions?mediaKind=image")!
        )
        snapshotRequest.setValue(
            "Bearer \(Self.legacyDebugToken)",
            forHTTPHeaderField: "Authorization"
        )
        let (snapshotData, snapshotResponse) = try await URLSession.shared.data(
            for: snapshotRequest
        )
        XCTAssertEqual(try XCTUnwrap(snapshotResponse as? HTTPURLResponse).statusCode, 200)
        let snapshot = try JSONDecoder().decode(
            RemoteSampleSuggestionSnapshot.self,
            from: snapshotData
        )
        XCTAssertTrue(snapshot.isAvailable)
        XCTAssertEqual(snapshot.maximumSampleCount, 500)
        XCTAssertEqual(snapshot.activities.first?.availableActions, [.cancel])

        var submitRequest = URLRequest(
            url: URL(string: "http://127.0.0.1:\(port)/v1/sample-suggestions/requests")!
        )
        submitRequest.httpMethod = "POST"
        submitRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        submitRequest.setValue(
            "Bearer \(Self.legacyDebugToken)",
            forHTTPHeaderField: "Authorization"
        )
        submitRequest.httpBody = try JSONEncoder().encode(
            RemoteSampleSuggestionRequest(
                operationID: operationID,
                mediaKind: .image,
                assetIDs: assetIDs
            )
        )
        let (submitData, submitResponse) = try await URLSession.shared.data(for: submitRequest)
        XCTAssertEqual(try XCTUnwrap(submitResponse as? HTTPURLResponse).statusCode, 202)
        let submitted = try JSONDecoder().decode(
            RemoteSampleSuggestionResponse.self,
            from: submitData
        )
        XCTAssertEqual(submitted.activity.operationID, operationID)
        XCTAssertEqual(commands.sampleSuggestionSubmitCallCount, 1)

        var cancelRequest = URLRequest(
            url: URL(
                string: "http://127.0.0.1:\(port)/v1/sample-suggestions/requests/\(operationID.uuidString)/actions"
            )!
        )
        cancelRequest.httpMethod = "POST"
        cancelRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        cancelRequest.setValue(
            "Bearer \(Self.legacyDebugToken)",
            forHTTPHeaderField: "Authorization"
        )
        cancelRequest.httpBody = try JSONEncoder().encode(
            RemoteSampleSuggestionActionRequest(action: .cancel)
        )
        let (cancelData, cancelResponse) = try await URLSession.shared.data(for: cancelRequest)
        XCTAssertEqual(try XCTUnwrap(cancelResponse as? HTTPURLResponse).statusCode, 200)
        let cancelled = try JSONDecoder().decode(
            RemoteSampleSuggestionActionResponse.self,
            from: cancelData
        )
        XCTAssertEqual(cancelled.activity.phase, .cancelled)
        XCTAssertEqual(commands.sampleSuggestionCancelCallCount, 1)
    }

    func testTagLibrarySuggestionRoutesExposeThresholdProgressSubmitAndCancel() async throws {
        let port = UInt16.random(in: 19_000...29_000)
        let operationID = UUID()
        let tagID = UUID()
        let sourceID = UUID()
        let activity = TagLibrarySuggestionActivitySnapshot(
            operationID: operationID,
            mediaKind: .image,
            method: .personalCentroid,
            tagID: tagID,
            phase: .scoring,
            completedUnitCount: 5,
            totalUnitCount: 20,
            aboveThresholdCount: 3,
            insertedCount: 0,
            skippedCount: 1,
            errorCode: nil
        )
        let commands = RemoteHTTPTrainingCommandStub(
            setupSnapshot: TrainingCommandSetupSnapshot(
                mediaKind: .image,
                tags: [],
                sources: [],
                supportsPersonalCentroid: true,
                supportsPersonalAdamW: false
            ),
            receipt: TrainingLaunchReceipt(
                operationID: UUID(),
                method: .personalCentroid,
                acceptedAtMs: 0,
                scheduledTagCount: 0,
                jobID: nil
            ),
            tagSuggestionActivity: activity,
            tagSuggestionOption: TagLibrarySuggestionTagOption(
                tagID: tagID,
                personalEligible: true,
                personalCentroidMinScore: 0.42,
                personalAdamWMinScore: 0.61
            )
        )
        let (server, _) = makeServer(port: port, trainingCommands: commands)
        try await server.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        defer { Task { await server.stop() } }

        var snapshotRequest = URLRequest(
            url: URL(string: "http://127.0.0.1:\(port)/v1/tag-library-suggestions?mediaKind=image")!
        )
        snapshotRequest.setValue(
            "Bearer \(Self.legacyDebugToken)",
            forHTTPHeaderField: "Authorization"
        )
        let (snapshotData, snapshotResponse) = try await URLSession.shared.data(
            for: snapshotRequest
        )
        XCTAssertEqual(try XCTUnwrap(snapshotResponse as? HTTPURLResponse).statusCode, 200)
        let snapshot = try JSONDecoder().decode(
            RemoteTagLibrarySuggestionSnapshot.self,
            from: snapshotData
        )
        XCTAssertTrue(snapshot.personalCentroidAvailable)
        XCTAssertFalse(snapshot.personalAdamWAvailable)
        XCTAssertEqual(snapshot.tags.first?.personalCentroidMinScore, 0.42)
        XCTAssertEqual(snapshot.activities.first?.availableActions, [.cancel])

        var submitRequest = URLRequest(
            url: URL(string: "http://127.0.0.1:\(port)/v1/tag-library-suggestions/requests")!
        )
        submitRequest.httpMethod = "POST"
        submitRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        submitRequest.setValue(
            "Bearer \(Self.legacyDebugToken)",
            forHTTPHeaderField: "Authorization"
        )
        submitRequest.httpBody = try JSONEncoder().encode(
            RemoteTagLibrarySuggestionRequest(
                operationID: operationID,
                mediaKind: .image,
                method: .personalCentroid,
                tagID: tagID,
                sourceIDs: [sourceID]
            )
        )
        let (submitData, submitResponse) = try await URLSession.shared.data(for: submitRequest)
        XCTAssertEqual(try XCTUnwrap(submitResponse as? HTTPURLResponse).statusCode, 202)
        let submitted = try JSONDecoder().decode(
            RemoteTagLibrarySuggestionResponse.self,
            from: submitData
        )
        XCTAssertEqual(submitted.activity.operationID, operationID)
        XCTAssertEqual(commands.tagSuggestionSubmitCallCount, 1)

        var cancelRequest = URLRequest(
            url: URL(
                string: "http://127.0.0.1:\(port)/v1/tag-library-suggestions/requests/\(operationID.uuidString)/actions"
            )!
        )
        cancelRequest.httpMethod = "POST"
        cancelRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        cancelRequest.setValue(
            "Bearer \(Self.legacyDebugToken)",
            forHTTPHeaderField: "Authorization"
        )
        cancelRequest.httpBody = try JSONEncoder().encode(
            RemoteTagLibrarySuggestionActionRequest(action: .cancel)
        )
        let (cancelData, cancelResponse) = try await URLSession.shared.data(for: cancelRequest)
        XCTAssertEqual(try XCTUnwrap(cancelResponse as? HTTPURLResponse).statusCode, 200)
        let cancelled = try JSONDecoder().decode(
            RemoteTagLibrarySuggestionActionResponse.self,
            from: cancelData
        )
        XCTAssertEqual(cancelled.activity.phase, .cancelled)
        XCTAssertEqual(commands.tagSuggestionCancelCallCount, 1)
    }

    func testCreateTagAndApplyRouteUsesAtomicCatalogMutationOnceAcrossReplay() async throws {
        let port = UInt16.random(in: 19_000...29_000)
        let tagID = UUID()
        let assetIDs = [UUID(), UUID()]
        let catalog = RemoteHTTPServerTestCatalog(
            createTagResult: TagCreateAndApplyResult(
                tagID: tagID,
                displayName: "旅行",
                normalizedName: "旅行",
                priorStates: assetIDs.map {
                    TagMutationPriorState(assetID: $0, priorState: .unknown)
                }
            )
        )
        let (server, _) = makeServer(port: port, catalog: catalog)
        try await server.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        defer { Task { await server.stop() } }

        var request = URLRequest(
            url: URL(string: "http://127.0.0.1:\(port)/v1/tags/create-and-apply")!
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Bearer \(Self.legacyDebugToken)",
            forHTTPHeaderField: "Authorization"
        )
        request.httpBody = try JSONEncoder().encode(
            RemoteCreateTagAndApplyRequest(
                operationID: UUID(),
                name: "  旅行  ",
                assetIDs: assetIDs
            )
        )

        let (firstData, firstResponse) = try await URLSession.shared.data(for: request)
        let (secondData, secondResponse) = try await URLSession.shared.data(for: request)

        XCTAssertEqual(
            try XCTUnwrap(firstResponse as? HTTPURLResponse).statusCode,
            200
        )
        XCTAssertEqual(
            try XCTUnwrap(secondResponse as? HTTPURLResponse).statusCode,
            200
        )
        let first = try JSONDecoder().decode(
            RemoteCreateTagAndApplyResponse.self,
            from: firstData
        )
        let second = try JSONDecoder().decode(
            RemoteCreateTagAndApplyResponse.self,
            from: secondData
        )
        XCTAssertEqual(first.tagID, tagID)
        XCTAssertEqual(first.appliedAssetCount, 2)
        XCTAssertFalse(first.replayed)
        XCTAssertTrue(second.replayed)
        XCTAssertNotNil(first.undoID)
        XCTAssertEqual(catalog.createTagCallCount, 1)
    }

    func testFavoriteRouteUsesCatalogMutationOnceAcrossReplay() async throws {
        let port = UInt16.random(in: 19_000...29_000)
        let assetIDs = [UUID(), UUID()]
        let catalog = RemoteHTTPServerTestCatalog()
        let (server, _) = makeServer(port: port, catalog: catalog)
        try await server.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        defer { Task { await server.stop() } }

        var request = URLRequest(
            url: URL(string: "http://127.0.0.1:\(port)\(RemoteHTTPPaths.favorites)")!
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Bearer \(Self.legacyDebugToken)",
            forHTTPHeaderField: "Authorization"
        )
        request.httpBody = try JSONEncoder().encode(
            RemoteFavoriteMutationRequest(
                operationID: UUID(),
                assetIDs: assetIDs,
                isFavorite: true
            )
        )

        let (firstData, firstResponse) = try await URLSession.shared.data(for: request)
        let (secondData, secondResponse) = try await URLSession.shared.data(for: request)

        XCTAssertEqual(try XCTUnwrap(firstResponse as? HTTPURLResponse).statusCode, 200)
        XCTAssertEqual(try XCTUnwrap(secondResponse as? HTTPURLResponse).statusCode, 200)
        let first = try JSONDecoder().decode(RemoteFavoriteMutationResponse.self, from: firstData)
        let second = try JSONDecoder().decode(RemoteFavoriteMutationResponse.self, from: secondData)
        XCTAssertEqual(first.changedCount, 2)
        XCTAssertEqual(first.localOnlyCount, 2)
        XCTAssertEqual(first.states.map(\.assetID), assetIDs)
        XCTAssertTrue(first.states.allSatisfy(\.isFavorite))
        XCTAssertFalse(first.replayed)
        XCTAssertTrue(second.replayed)
        XCTAssertEqual(catalog.favoriteMutationCallCount, 1)

        var retryRequest = URLRequest(
            url: URL(string: "http://127.0.0.1:\(port)\(RemoteHTTPPaths.favoriteSyncRetry)")!
        )
        retryRequest.httpMethod = "POST"
        retryRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        retryRequest.setValue(
            "Bearer \(Self.legacyDebugToken)",
            forHTTPHeaderField: "Authorization"
        )
        retryRequest.httpBody = try JSONEncoder().encode(
            RemoteFavoriteSyncRetryRequest(operationID: UUID())
        )
        let (retryData, retryResponse) = try await URLSession.shared.data(for: retryRequest)
        let (replayData, replayResponse) = try await URLSession.shared.data(for: retryRequest)
        XCTAssertEqual(try XCTUnwrap(retryResponse as? HTTPURLResponse).statusCode, 200)
        XCTAssertEqual(try XCTUnwrap(replayResponse as? HTTPURLResponse).statusCode, 200)
        XCTAssertFalse(
            try JSONDecoder().decode(RemoteFavoriteSyncRetryResponse.self, from: retryData).replayed
        )
        XCTAssertTrue(
            try JSONDecoder().decode(RemoteFavoriteSyncRetryResponse.self, from: replayData).replayed
        )
        XCTAssertEqual(catalog.favoriteRetryCallCount, 1)
    }

    func testInstallPresetTagsRouteUsesCatalogOnceAcrossReplay() async throws {
        let port = UInt16.random(in: 19_000...29_000)
        let createdTag = TagListItem(
            id: UUID(),
            displayName: "风景",
            state: .active,
            groupID: TagGroupSeed.placesAndScenes.id
        )
        let catalog = RemoteHTTPServerTestCatalog(
            presetInstallResult: TagPresetInstallResult(createdTags: [createdTag])
        )
        let (server, _) = makeServer(port: port, catalog: catalog)
        try await server.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        defer { Task { await server.stop() } }

        var request = URLRequest(
            url: URL(string: "http://127.0.0.1:\(port)/v1/tags/install-presets")!
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Bearer \(Self.legacyDebugToken)",
            forHTTPHeaderField: "Authorization"
        )
        request.httpBody = try JSONEncoder().encode(
            RemoteInstallPresetTagsRequest(operationID: UUID())
        )

        let (firstData, firstResponse) = try await URLSession.shared.data(for: request)
        let (secondData, secondResponse) = try await URLSession.shared.data(for: request)

        XCTAssertEqual(try XCTUnwrap(firstResponse as? HTTPURLResponse).statusCode, 200)
        XCTAssertEqual(try XCTUnwrap(secondResponse as? HTTPURLResponse).statusCode, 200)
        let first = try JSONDecoder().decode(
            RemoteInstallPresetTagsResponse.self,
            from: firstData
        )
        let second = try JSONDecoder().decode(
            RemoteInstallPresetTagsResponse.self,
            from: secondData
        )
        XCTAssertEqual(first.createdTags.map(\.displayName), ["风景"])
        XCTAssertFalse(first.replayed)
        XCTAssertTrue(second.replayed)
        XCTAssertEqual(catalog.presetInstallCallCount, 1)
    }

    func testBonjourServiceIsAdvertisedOnStart() async throws {
        let port = UInt16.random(in: 19_000...29_000)
        let hostID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let facade = RemoteCatalogFacade(
            catalog: RemoteHTTPServerTestCatalog(),
            review: EmptyPersonalizationReviewPort(),
            idempotency: makeIdempotencyStore(),
            hostAppVersion: "1.0.0",
            listenPort: Int(port)
        )
        let server = RemoteHTTPServer(
            facade: facade,
            pairingStore: makePairingStore(listenPort: Int(port)),
            accessAccountStore: makeAccessAccountStore(),
            eventBroker: RemoteEventBroker(),
            secIdentity: nil,
            port: port,
            advertisementName: "ImageAll-Test-Host",
            hostID: hostID
        )
        try await server.start()
        try await Task.sleep(nanoseconds: 100_000_000)
        let serviceType = await server.bonjourServiceType
        await server.stop()
        XCTAssertEqual(serviceType, RemoteBonjour.serviceType)

        let service = RemoteHTTPServer.makeBonjourService(
            name: "ImageAll-Test-Host",
            hostID: hostID
        )
        XCTAssertEqual(service.type, RemoteBonjour.serviceType)
        XCTAssertEqual(service.name, "ImageAll-Test-Host")
        let txtRecord = try XCTUnwrap(service.txtRecordObject)
        XCTAssertEqual(
            txtRecord.dictionary[RemoteBonjour.TXTKey.hostID],
            hostID.uuidString
        )
    }

    func testPairingCompleteRequiresNoBearerTokenAndIssuesSessionTokens() async throws {
        let port = UInt16.random(in: 19_000...29_000)
        let pairingStore = makePairingStore(listenPort: Int(port))
        let (server, store) = makeServer(port: port, pairingStore: pairingStore)
        try await server.start()
        try await Task.sleep(nanoseconds: 150_000_000)

        let offer = await store.issueOffer()

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/pairing/complete")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            RemotePairingCompleteRequest(
                pairingToken: offer.pairingToken,
                deviceName: "iPhone",
                devicePublicKeySPKI_SHA256: "abc123"
            )
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        await server.stop()

        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        let tokens = try JSONDecoder().decode(RemoteSessionTokens.self, from: data)
        XCTAssertFalse(tokens.accessToken.isEmpty)
        XCTAssertFalse(tokens.refreshToken.isEmpty)
    }

    func testWebPairingURLKeepsOneTimeTokenInFragment() throws {
        let offer = RemotePairingOffer(
            hostID: UUID(),
            hostDisplayName: "Test Host",
            listenPort: 8787,
            usesTLS: true,
            certificateFingerprintSHA256: "fingerprint",
            pairingToken: "one-time-secret",
            expiresAtMs: 123,
            publicBaseURL: "https://imageall.example.com"
        )

        let url = try XCTUnwrap(RemoteWebCompanionSession.webPairingURL(for: offer))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "imageall.example.com")
        XCTAssertNil(url.query)
        XCTAssertEqual(url.fragment, "pair=one-time-secret")
    }

    func testWebSessionRequiresMatchingOriginAndHost() {
        XCTAssertTrue(
            RemoteWebCompanionSession.isTrustedSameOrigin(
                headers: [
                    "origin": "https://imageall.example.com",
                    "host": "imageall.example.com",
                    "sec-fetch-site": "same-origin",
                ]
            )
        )
        XCTAssertTrue(
            RemoteWebCompanionSession.isTrustedSameOrigin(
                headers: [
                    "origin": "http://127.0.0.1:8787",
                    "host": "127.0.0.1:8787",
                ]
            )
        )
        XCTAssertFalse(
            RemoteWebCompanionSession.isTrustedSameOrigin(
                headers: [
                    "origin": "https://attacker.example",
                    "host": "imageall.example.com",
                    "sec-fetch-site": "cross-site",
                ]
            )
        )
        XCTAssertFalse(
            RemoteWebCompanionSession.isTrustedSameOrigin(
                headers: ["host": "imageall.example.com"]
            )
        )
    }

    func testWebSessionCookiesAreSecureHttpOnlyAndStrict() {
        let tokens = RemoteSessionTokens(
            deviceID: UUID(),
            hostID: UUID(),
            accessToken: "access-secret",
            accessExpiresAtMs: Int64((Date().timeIntervalSince1970 + 3_600) * 1_000),
            refreshToken: "refresh-secret",
            certificateFingerprintSHA256: "fingerprint",
            usesTLS: true,
            listenPort: 8787
        )

        let values = RemoteWebCompanionSession.sessionCookieHeaders(tokens: tokens)
            .map(\.1)
        XCTAssertEqual(values.count, 3)
        XCTAssertTrue(values.allSatisfy { $0.contains("Secure") })
        XCTAssertTrue(values.allSatisfy { $0.contains("HttpOnly") })
        XCTAssertTrue(values.allSatisfy { $0.contains("SameSite=Strict") })
        XCTAssertTrue(values.contains { $0.hasPrefix("__Host-imageall_access=") })
        XCTAssertTrue(values.contains { $0.hasPrefix("__Secure-imageall_refresh=") })
        XCTAssertTrue(values.contains { $0.hasPrefix("__Secure-imageall_device=") })
    }

    func testWebPairingReturnsSafeSummaryAndSessionCookies() async throws {
        let port = UInt16.random(in: 19_000...29_000)
        let (server, store) = makeServer(port: port)
        try await server.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        let offer = await store.issueOffer()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(
            url: URL(string: "http://127.0.0.1:\(port)/web/session/pair")!
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "http://127.0.0.1:\(port)",
            forHTTPHeaderField: "Origin"
        )
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        request.httpBody = try JSONEncoder().encode(
            RemoteWebCompanionSession.PairingRequest(
                pairingToken: offer.pairingToken,
                deviceName: "Safari",
                clientID: UUID().uuidString
            )
        )

        let (data, response) = try await session.data(for: request)
        await server.stop()

        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        let summary = try JSONDecoder().decode(
            RemoteWebCompanionSession.StatusResponse.self,
            from: data
        )
        XCTAssertTrue(summary.authenticated)
        XCTAssertNotNil(summary.deviceID)
        let responseText = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(responseText.contains("accessToken"))
        XCTAssertFalse(responseText.contains("refreshToken"))
        let cookieHeader = try XCTUnwrap(
            http.value(forHTTPHeaderField: "Set-Cookie")
        )
        XCTAssertTrue(cookieHeader.contains(RemoteWebCompanionSession.accessCookieName))
        XCTAssertTrue(cookieHeader.contains(RemoteWebCompanionSession.refreshCookieName))
        XCTAssertTrue(cookieHeader.contains(RemoteWebCompanionSession.deviceCookieName))
    }

    func testWebAssetStoreServesOnlyFixedPublicRoutes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "RemoteHTTPServerTests-Web-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("<h1>ImageAll</h1>".utf8)
            .write(to: directory.appendingPathComponent("index.html"))

        let worldMapDirectory = directory.appendingPathComponent("WorldMap", isDirectory: true)
        try FileManager.default.createDirectory(
            at: worldMapDirectory,
            withIntermediateDirectories: true
        )
        try Data("<main>Photo Atlas</main>".utf8)
            .write(to: worldMapDirectory.appendingPathComponent("index.html"))

        let store = RemoteWebCompanionAssetStore(
            directoryURL: directory,
            worldMapDirectoryURL: worldMapDirectory
        )
        let root = try XCTUnwrap(store.asset(for: "/"))
        XCTAssertEqual(root.contentType, "text/html; charset=utf-8")
        XCTAssertEqual(String(decoding: root.body, as: UTF8.self), "<h1>ImageAll</h1>")
        XCTAssertFalse(root.allowsSameOriginFraming)
        let worldMap = try XCTUnwrap(store.asset(for: "/world-map/index.html"))
        XCTAssertEqual(String(decoding: worldMap.body, as: UTF8.self), "<main>Photo Atlas</main>")
        XCTAssertTrue(worldMap.allowsSameOriginFraming)
        XCTAssertNil(store.asset(for: "/../pairing.json"))
        XCTAssertNil(store.asset(for: "/world-map/../index.html"))
        XCTAssertNil(store.asset(for: "/v1/capabilities"))
    }

    func testBundledWebCompanionExposesDailyWorkflowSurfaces() throws {
        // Read the checked-in source assets so this contract also works under the
        // protected-data-safe bare xctest runner, where Bundle.main is xctest itself.
        let sourceDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ImageAll/Resources/WebCompanion", isDirectory: true)
        let worldMapDirectory = sourceDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("WorldMap", isDirectory: true)
        let store = RemoteWebCompanionAssetStore(
            directoryURL: sourceDirectory,
            worldMapDirectoryURL: worldMapDirectory
        )
        let html = String(
            decoding: try XCTUnwrap(store.asset(for: "/")?.body),
            as: UTF8.self
        )
        let script = String(
            decoding: try XCTUnwrap(store.asset(for: "/app.js")?.body),
            as: UTF8.self
        )
        let stylesheet = String(
            decoding: try XCTUnwrap(store.asset(for: "/app.css")?.body),
            as: UTF8.self
        )
        let mediaWorker = String(
            decoding: try XCTUnwrap(store.asset(for: "/service-worker.js")?.body),
            as: UTF8.self
        )
        let worldMapScript = String(
            decoding: try XCTUnwrap(store.asset(for: "/world-map/world-map.js")?.body),
            as: UTF8.self
        )

        for controlID in [
            "filterPopover",
            "batchBar",
            "selectionToolActions",
            "reviewWorkspace",
            "reviewQueuePane",
            "reviewMarqueeSelection",
            "reviewSelectionSummary",
            "reviewInspectorSelectionTitle",
            "reviewInspectorFavoriteButton",
            "reviewInspectorUnfavoriteButton",
            "reviewInspectorDeleteButton",
            "reviewInspectorActionStatus",
            "reviewAssetMetadata",
            "reviewViewOriginalButton",
            "reviewOpenOriginalButton",
            "reviewInlineTagForm",
            "reviewInlineTagName",
            "reviewTagSearch",
            "reviewTags",
            "jobsPopover",
            "jobsButtonLabel",
            "refreshJobsButton",
            "currentSourceRefreshButton",
            "currentSourceRefreshLabel",
            "catalogProgressStatusButton",
            "catalogProgressStatusLabel",
            "catalogProgressStatusFill",
            "compactToolbarMenuButton",
            "compactToolbarActivityDot",
            "compactToolbarMenu",
            "compactToolbarConnectionSummary",
            "compactToolbarHostSummary",
            "compactToolbarMenuContent",
            "sidebarVisibilityLabel",
            "commandButtonLabel",
            "undoTagButtonLabel",
            "undoReviewButtonLabel",
            "inspectorVisibilityLabel",
            "toolbarConnectFolderButton",
            "toolbarConnectFolderLabel",
            "toolbarExportPortableDataButton",
            "toolbarExportPortableDataLabel",
            "inspectorLocalModelSection",
            "inspectorStandardModelButton",
            "inspectorPersonalModelButton",
            "inspectorLocalModelBody",
            "lightbox",
            "lightboxBackButton",
            "lightboxStage",
            "lightboxZoomControls",
            "lightboxZoomOutButton",
            "lightboxZoomResetButton",
            "lightboxZoomPercentage",
            "lightboxZoomInButton",
            "lightboxViewOriginalButton",
            "lightboxDeleteButton",
            "accountLoginForm",
            "accountUsername",
            "accountPassword",
            "workspaceNoticeBanner",
            "workspaceNoticeMessage",
            "workspaceNoticeActions",
            "dismissWorkspaceNoticeButton",
            "worldMapBrowseClusterButton",
            "worldMapGalleryBanner",
            "folderBreadcrumb",
            "folderBreadcrumbItems",
            "returnToWorldMapButton",
            "clearWorldMapGalleryButton",
            "sourceRefreshAllButton",
            "sidebarSourceActions",
            "sidebarConnectFolderButton",
            "sidebarConnectPhotosButton",
            "sidebarPhotosConnectedStatus",
            "sourcePrewarmAllButton",
            "sourcePrewarmAllOriginalButton",
            "sourceBatchAuthorizationPanel",
            "sourceReauthorizeAllButton",
            "sourceRefreshAllMutationAuthorizationButton",
            "sourceRequestPhotosWriteAuthorizationButton",
            "newTagDialog",
            "newTagForm",
            "newTagName",
            "newTagRestoreNotice",
            "batchNewTagButton",
            "personalModelToolbarActions",
            "toolbarRebuildPersonalModelButton",
            "toolbarRebuildPersonalAdamWButton",
            "toolbarGeneratePersonalSuggestionsButton",
            "toolbarPrepareSelectedFeaturesButton",
            "toolbarFindSimilarSelectionButton",
            "preparePersonalSelectionButton",
            "findSimilarPersonalSelectionButton",
            "batchPersonalModelActions",
            "selectionFavoriteToolbarActions",
            "toolbarFavoriteSelectedButton",
            "toolbarUnfavoriteSelectedButton",
            "batchFavoriteActions",
            "generatePersonalSuggestionsButton",
            "prepareSelectedFeaturesButton",
            "generateSelectedSuggestionsButton",
            "findSimilarSelectionButton",
            "embeddingPreparationStatus",
            "cancelEmbeddingPreparationButton",
            "selectionInspectorPrepareFeaturesButton",
            "selectionInspectorGenerateSuggestionsButton",
            "selectionInspectorFindSimilarButton",
            "selectionInspectorToolStatus",
            "selectionInspectorCancelPreparationButton",
            "selectionInspectorInlineTagForm",
            "selectionInspectorInlineTagName",
            "selectionInspectorInlineTagError",
            "selectionInspectorNewTagButton",
            "inspectorInlineTagForm",
            "inspectorInlineTagName",
            "inspectorInlineTagError",
            "inspectorNewTagButton",
            "mediaKindTabs",
            "thumbnailRecoveryStatus",
            "gridDensityButton",
            "gridDensityPopover",
            "thumbnailAspectButton",
            "reviewThumbnailLayoutControls",
            "reviewGridDensityButton",
            "reviewGridDensityPopover",
            "reviewThumbnailAspectButton",
            "reviewSelectAllButton",
            "reviewSelectionModeButton",
            "reviewContextMenu",
            "reviewContextMenuTitle",
            "reviewPreviewContextAction",
            "reviewFavoriteContextAction",
            "activeFilterBar",
            "activeFilterSummary",
            "activeFilterRelation",
            "clearActiveFiltersButton",
            "tagNavigation",
            "sidebarInstallPresetTagsButton",
            "emptyStateActions",
            "emptyConnectFolderButton",
            "emptyConnectPhotosButton",
            "emptyInstallPresetTagsButton",
            "commandPalette",
            "commandContextLabel",
            "shortcutDialog",
            "shortcutContextLabel",
            "shortcutList",
            "inspectorPreviousButton",
            "inspectorNextButton",
            "inspectorSelectionHeading",
            "inspectorSelectionTitle",
            "inspectorFavoriteButton",
            "inspectorUnfavoriteButton",
            "inspectorDeleteButton",
            "previewPlaceholderImage",
            "previewVideo",
            "cloudPreviewRecovery",
            "cloudPreviewButton",
            "cloudPreviewProgress",
            "reviewCloudPreviewRecovery",
            "reviewCloudPreviewButton",
            "reviewCloudPreviewProgress",
            "lightboxCloudPreviewRecovery",
            "lightboxCloudPreviewButton",
            "lightboxCloudPreviewProgress",
            "openOriginalButton",
            "viewOriginalButton",
            "openOriginalButtonLabel",
            "openOriginalHint",
            "inspectorTagSearch",
            "assetContextMenu",
            "sidebarVisibilityButton",
            "inspectorVisibilityButton",
            "sidebarResizeHandle",
            "inspectorResizeHandle",
            "reviewOverviewResizeHandle",
            "reviewQueueResizeHandle",
            "tagManagerDialog",
            "tagManagerShell",
            "tagManagerNotice",
            "tagManagerButton",
            "tagActionsPopover",
            "tagActionsSummary",
            "tagActionsNewGroupButton",
            "tagActionsInstallPresetsButton",
            "tagActionsNewTagButton",
            "tagActionsOpenManagerButton",
            "installPresetTagsButton",
            "reviewOverview",
            "reviewOverviewLayout",
            "reviewOverviewGrid",
            "reviewBackButton",
            "generateLibrarySuggestionsButton",
            "cancelSampleSuggestionsButton",
            "sampleSuggestionReviewStatus",
            "reviewLocalModelPanel",
            "reviewLocalModelStatus",
            "standardLibrarySuggestionCard",
            "generateStandardLibrarySuggestionsButton",
            "personalLibrarySuggestionCard",
            "tagSuggestionDialog",
            "tagSuggestionForm",
            "tagSuggestionSourceOptions",
            "tagSuggestionThresholdSummary",
            "tagSuggestionNotice",
            "launchTagSuggestionButton",
            "undoToastButton",
            "trainingWorkspace",
            "newTrainingButton",
            "trainingActivityStrip",
            "trainingMediaKindTabs",
            "trainingMethodFilter",
            "trainingSlotStrip",
            "trainingRunPane",
            "trainingRunList",
            "trainingMetricHighlights",
            "trainingLossChart",
            "trainingMetricEmpty",
            "trainingDetailPane",
            "trainingDetail",
            "trainingDetailActions",
            "trainingSetupDialog",
            "trainingSetupMethods",
            "trainingTagOptions",
            "trainingScopeOptions",
            "launchTrainingButton",
            "slimmingButton",
            "slimmingNavigationButton",
            "slimmingWorkspace",
            "slimmingWorkspaceTabs",
            "slimmingMediaKindTabs",
            "slimmingNavigatorPane",
            "slimmingJobList",
            "slimmingLoadMoreJobsButton",
            "previousSlimmingJobButton",
            "slimmingJobPosition",
            "nextSlimmingJobButton",
            "slimmingJobStatus",
            "slimmingInspector",
            "slimmingInspectorSummary",
            "slimmingInspectorContent",
            "slimmingClusterScopes",
            "slimmingClusterScopeTitle",
            "slimmingClusterList",
            "slimmingSelectedClusterReview",
            "slimmingSelectedClusterReviewStatus",
            "slimmingReprocessClusterButton",
            "slimmingMemberGrid",
            "slimmingThumbnailLayoutControls",
            "slimmingThumbnailAspectButton",
            "slimmingGridDensityButton",
            "slimmingGridDensityPopover",
            "slimmingNavigatorButton",
            "slimmingCatalogAnalyzeButton",
            "slimmingCatalogSourceButton",
            "slimmingCatalogSourcePopover",
            "slimmingCatalogSourceSummary",
            "slimmingCatalogSourceOptions",
            "selectAllSlimmingCatalogSourcesButton",
            "clearSlimmingCatalogSourcesButton",
            "slimmingAnalysisOptionsButton",
            "slimmingCurrentFilterAnalysisButton",
            "slimmingSeedAnalysisButton",
            "openSlimmingSetupButton",
            "slimmingCurrentJobSection",
            "slimmingCurrentJobSummary",
            "slimmingCurrentJobState",
            "slimmingCurrentJobProgress",
            "slimmingCurrentJobActions",
            "openSlimmingThresholdEditorButton",
            "slimmingThresholdDialog",
            "slimmingThresholdForm",
            "slimmingThresholdDialogContent",
            "slimmingThresholdRecallMode",
            "slimmingThresholdRecallTopK",
            "slimmingThresholdRecallTopKSlider",
            "slimmingThresholdL2Mode",
            "slimmingThresholdL2Distance",
            "slimmingThresholdL2DistanceSlider",
            "slimmingThresholdDINOMode",
            "slimmingThresholdDINOSimilarity",
            "slimmingThresholdDINOSimilaritySlider",
            "slimmingThresholdBucketingMode",
            "slimmingThresholdBucketActivationCount",
            "slimmingThresholdBucketActivationCountSlider",
            "resetSlimmingThresholdDialogButton",
            "applySlimmingThresholdDialogButton",
            "slimmingSelectionSummary",
            "slimmingSelectAllButton",
            "slimmingSelectionModeButton",
            "slimmingSelectionBar",
            "slimmingMoveToRecycleButton",
            "slimmingReleaseSpaceButton",
            "slimmingRemovalStatus",
            "slimmingIdenticalCleanupButton",
            "slimmingIdenticalCleanupDialog",
            "slimmingIdenticalCleanupMetrics",
            "slimmingIdenticalCleanupRetentionSummary",
            "slimmingIdenticalCleanupDispositionChart",
            "slimmingIdenticalCleanupGroupHistogram",
            "slimmingIdenticalCleanupSources",
            "slimmingIdenticalCleanupNotice",
            "recoverableSlimmingIdenticalCleanupButton",
            "fastSlimmingIdenticalCleanupButton",
            "identicalCleanupBlockingDialog",
            "identicalCleanupBlockingCard",
            "identicalCleanupBlockingTitle",
            "identicalCleanupBlockingDetail",
            "identicalCleanupBlockingProgressBar",
            "identicalCleanupBlockingProgressLabel",
            "slimmingVerificationDialog",
            "slimmingVerificationScoreSection",
            "slimmingVerificationMetrics",
            "slimmingVerificationResult",
            "slimmingVerificationFootnote",
            "closeSlimmingVerificationButton",
            "slimmingJobActions",
            "slimmingSetupDialog",
            "slimmingModeOptions",
            "slimmingSourceOptions",
            "slimmingRecallMode",
            "slimmingRecallTopKSlider",
            "slimmingL2Mode",
            "slimmingL2DistanceSlider",
            "slimmingDINOMode",
            "slimmingDINOSimilaritySlider",
            "slimmingBucketingMode",
            "slimmingBucketActivationCountSlider",
            "resetSlimmingThresholdsButton",
            "launchSlimmingButton",
            "slimmingRecycleBody",
            "slimmingRecycleSummary",
            "slimmingRecycleMutationStatus",
            "slimmingRecycleSourceBanner",
            "slimmingRecycleSourceBannerName",
            "clearSlimmingRecycleSourceButton",
            "slimmingRecycleScopes",
            "slimmingRecycleSearchInput",
            "slimmingRecycleSearchResultCount",
            "clearSlimmingRecycleSearchButton",
            "slimmingRecycleSourceSelect",
            "slimmingRecycleRequestStatus",
            "slimmingRecycleList",
            "slimmingRecycleLoadMoreButton",
            "slimmingRecycleEmptyTitle",
            "slimmingRecycleEmptyMessage",
            "slimmingRecycleEmptyAction",
            "slimmingRecycleExplanationDialog",
            "slimmingRecycleExplanationTitle",
            "slimmingRecycleExplanationState",
            "slimmingRecycleExplanationPolicy",
            "slimmingRecycleExplanationMessage",
            "closeSlimmingRecycleExplanationButton",
            "slimmingMemberContextMenu",
            "slimmingMemberContextMenuTitle",
            "slimmingMemberContextMenuActions",
            "slimmingRecycleContextMenu",
            "slimmingRecycleContextMenuTitle",
            "slimmingRecycleFavoriteContextAction",
            "slimmingRecycleContextMenuNote",
            "slimmingJobContextMenu",
            "slimmingJobContextMenuTitle",
            "slimmingJobContextMenuActions",
            "sourceManagerButton",
            "sourceSectionHeading",
            "sourceAllActionsButton",
            "sourceActionsPopover",
            "sourceActionsSummary",
            "sourceActionsViewAllButton",
            "sourceActionsRefreshAllButton",
            "sourceActionsPrewarmAllButton",
            "sourceActionsPrewarmAllOriginalButton",
            "sourceActionsReauthorizeAllButton",
            "sourceActionsRefreshMutationButton",
            "sourceActionsPhotosWriteButton",
            "sourceActionsOpenManagerButton",
            "sourceManagerDialog",
            "sourceConnectFolderButton",
            "sourceConnectPhotosButton",
            "sourceAllActionsPanel",
            "sourceAllActionsSummary",
            "sourceBatchAuthorizationSummary",
            "sourceManagerPending",
            "sourceManagerHistoryNotice",
            "sourceManagerListSummary",
            "sourceManagerList",
            "emptySourceRecoveryButton",
            "emptyOpenSourceManagerButton",
            "storageButton",
            "storageStatusLabel",
            "inspectorPlaceholderTagEditor",
            "inspectorPlaceholderTitle",
            "inspectorPlaceholderTags",
            "inspectorWorkspacePlaceholder",
            "inspectorWorkspacePlaceholderSymbol",
            "inspectorWorkspacePlaceholderTitle",
            "inspectorWorkspacePlaceholderText",
            "inspectorTrainingWorkspace",
            "inspectorTrainingWorkspaceTitle",
            "inspectorTrainingWorkspaceTask",
            "inspectorTrainingWorkspaceMethod",
            "inspectorTrainingWorkspaceState",
            "inspectorTrainingWorkspaceCreated",
            "inspectorSlimmingWorkspace",
            "inspectorSlimmingWorkspaceTitle",
            "inspectorSlimmingWorkspaceDescription",
            "inspectorSlimmingWorkspaceContent",
            "inspectorSlimmingWorkspacePending",
            "selectionInspectorPrimary",
            "selectionInspectorPrimaryPreview",
            "selectionInspectorPrimaryMetadata",
            "storageDialog",
            "storagePending",
            "previewCacheSize",
            "photosOriginalsSize",
            "photosOriginalsPolicy",
            "photosOriginalsBlocked",
            "appStorageKind",
            "clearPreviewCacheButton",
            "clearPhotosOriginalsButton",
            "chooseExternalStorageButton",
            "exportPortableDataButton",
            "storageHistory",
            "storageRefreshButton",
            "worldMapButton",
            "worldMapNavigationButton",
            "worldMapWorkspace",
            "worldMapFrame",
            "worldMapClusterMetric",
            "worldMapViewportReadout",
            "worldMapFooterPrompt",
            "worldMapDetail",
            "worldMapPhotoStrip",
            "openWorldMapLocationBackfillButton",
            "worldMapLocationBackfillDialog",
            "worldMapLocationBackfillBody",
            "worldMapLocationBackfillSources",
            "openWorldMapPlaceTagsButton",
            "worldMapPlaceTagDialog",
            "worldMapPlaceTagBody",
            "worldMapPlaceTagItems",
            "galleryOverviewNavigationButton",
            "galleryOverviewWorkspace",
            "galleryOverviewEmpty",
            "galleryOverviewMediaLedger",
            "galleryOverviewSources",
            "galleryOverviewTags",
            "galleryOverviewTimeline",
            "lightboxVideo",
            "lightboxOpenOriginalButton",
            "lightboxFavoriteButton",
            "lightboxReviewActions",
            "undoTagButton",
            "undoReviewButton",
            "reviewUndoButton",
            "confirmDialog",
            "confirmDialogIcon",
            "confirmDialogEyebrow",
            "confirmDialogMessage",
            "cancelConfirmButton",
            "confirmActionButton",
        ] {
            XCTAssertTrue(html.contains("id=\"\(controlID)\""))
        }
        XCTAssertTrue(
            html.contains("id=\"sourceAllActionsButton\" class=\"sidebar-add-button\"")
        )
        for endpoint in [
            "/v1/tags/selection",
            "/v1/tag-decisions/batch",
            "/v1/tag-decisions/undo",
            "/v1/tag-groups",
            "/v1/tags/${tag.id}/rename",
            "/v1/review/queue",
            "/v1/review/overview",
            "/v1/review/decisions/batch",
            "/v1/review/decisions/undo",
            "/v1/training/workspace",
            "/v1/training/setup",
            "/v1/training/launch",
            "/v1/training/activities/${operationID}/actions",
            "/v1/embedding-preparation",
            "/v1/embedding-preparation/requests",
            "/v1/embedding-preparation/requests/${activity.operationID}/actions",
            "/v1/sample-suggestions",
            "/v1/sample-suggestions/requests",
            "/v1/sample-suggestions/requests/${activity.operationID}/actions",
            "/v1/library-suggestions",
            "/v1/library-suggestions/requests",
            "/v1/tag-library-suggestions",
            "/v1/tag-library-suggestions/requests",
            "/v1/tag-library-suggestions/requests/${operationID}/actions",
            "/v1/library-slimming/workspace",
            "/v1/library-slimming/cluster-review",
            "/v1/library-slimming/setup",
            "/v1/library-slimming/launch",
            "/v1/library-slimming/thresholds",
            "/v1/library-slimming/jobs/${jobID}/actions",
            "/v1/library-slimming/recycle",
            "/v1/library-slimming/recycle/requests",
            "/v1/library-slimming/removals",
            "/v1/library-slimming/identical-cleanup/plans",
            "/v1/library-slimming/identical-cleanup/requests",
            "/v1/source-management",
            "/v1/source-management/requests",
            "/v1/storage-maintenance",
            "/v1/storage-maintenance/requests",
            "/v1/workspace-notice",
            "/v1/workspace-notice/dismiss",
            "/v1/workspace-notice/action",
            "/v1/world-map/snapshot",
            "/v1/world-map/selection",
            "/v1/world-map/location-backfill",
            "/v1/world-map/location-backfill/requests",
            "/v1/world-map/place-tags",
            "/v1/world-map/place-tags/requests",
            "/v1/gallery-overview",
            "/v1/jobs/",
            "/web/account/login",
            "/v1/tags/create-and-apply",
            "/v1/assets/${assetID}/media",
            "/v1/assets/${assetID}/open-original",
            "/v1/assets/${assetID}/local-suggestions",
        ] {
            XCTAssertTrue(script.contains(endpoint))
        }
        XCTAssertFalse(script.contains("/v1/review-queue"))
        XCTAssertFalse(script.contains("/v1/review-decisions/batch"))
        XCTAssertTrue(script.contains("function performCreateTagAndApply"))
        XCTAssertTrue(script.contains("function renderSourceActionsMenu"))
        XCTAssertTrue(script.contains("function positionSourceActionsMenu"))
        XCTAssertTrue(stylesheet.contains(".source-actions-popover"))
        XCTAssertTrue(script.contains("function createInlineTagAndApply"))
        XCTAssertTrue(script.contains("function focusInlineTagCreationFromCommand"))
        XCTAssertTrue(script.contains("openGalleryInspectorOverlay({ returnFocus, focus: false })"))
        XCTAssertTrue(script.contains("if (!focusInlineTagCreationFromCommand(commandReturnFocus))"))
        XCTAssertTrue(script.contains("state.inlineTagOperations"))
        XCTAssertTrue(stylesheet.contains(".inspector-inline-tag-form"))
        XCTAssertTrue(stylesheet.contains(".review-workspace.integrated"))
        XCTAssertTrue(script.contains("function syncReviewPresentation"))
        XCTAssertTrue(script.contains("function syncIntegratedReviewFrame"))
        XCTAssertTrue(script.contains("function leaveIntegratedReviewForLibrary"))
        XCTAssertTrue(script.contains("function loadReviewInspectorDetail"))
        XCTAssertTrue(script.contains("function applyReviewTagDecision"))
        XCTAssertTrue(stylesheet.contains(".review-inspector-section"))
        XCTAssertTrue(stylesheet.contains(".slimming-workspace.integrated"))
        XCTAssertTrue(script.contains("function syncSlimmingPresentation"))
        XCTAssertTrue(script.contains("function renderSlimmingInspector"))
        XCTAssertTrue(script.contains("state.contextTagReturnFocus"))
        XCTAssertTrue(script.contains("setInspectorTagData(toggle, \"helpDetail\""))
        XCTAssertTrue(script.contains("setInspectorTagData(chip, \"helpDetail\""))
        XCTAssertTrue(script.contains("button.dataset.helpDetail"))
        XCTAssertTrue(script.contains("Shift+F10 ContextMenu"))
        XCTAssertTrue(stylesheet.contains(".persistent-help[data-kind=\"tag\"]"))
        XCTAssertTrue(
            script.contains(
                "showTagGroupContextMenu(event.clientX, event.clientY, groupID, groupToggle)"
            )
        )
        XCTAssertFalse(
            script.contains(
                "elements.inspectorNewTagButton.addEventListener(\"click\", openNewTagDialog)"
            )
        )
        XCTAssertTrue(script.contains("function handleWorldMapMessage"))
        XCTAssertTrue(script.contains("function renderWorldMapLocationBackfill"))
        XCTAssertTrue(script.contains("function submitWorldMapLocationBackfill"))
        XCTAssertTrue(script.contains("function renderWorldMapPlaceTags"))
        XCTAssertTrue(script.contains("function submitWorldMapPlaceTagSearch"))
        XCTAssertTrue(script.contains("function confirmWorldMapPlaceTag"))
        XCTAssertTrue(script.contains("function syncWorldMapPhotoFavoriteButton"))
        XCTAssertTrue(script.contains("async function toggleWorldMapPhotoFavorite"))
        XCTAssertTrue(script.contains("async function openWorldMapClusterInGallery"))
        XCTAssertTrue(script.contains("function clearWorldMapSelection({ restoreFocus = false } = {})"))
        XCTAssertTrue(script.contains("clearWorldMapSelection({ restoreFocus: true })"))
        XCTAssertTrue(script.contains("function appendWorldMapSelectionQuery"))
        XCTAssertTrue(script.contains("async function clearWorldMapGalleryScope"))
        XCTAssertTrue(script.contains("data-retry-world-map-selection"))
        XCTAssertTrue(script.contains("button.dataset.worldMapPhotoFavorite = \"true\""))
        XCTAssertTrue(stylesheet.contains(".world-map-photo-card"))
        XCTAssertTrue(stylesheet.contains(".world-map-photo-favorite"))
        XCTAssertTrue(stylesheet.contains(".world-map-gallery-banner"))
        XCTAssertTrue(stylesheet.contains(".world-map-browse-cluster"))
        XCTAssertTrue(stylesheet.contains(".world-map-photo-error"))
        XCTAssertTrue(stylesheet.contains("@keyframes world-map-detail-in"))
        XCTAssertTrue(stylesheet.contains(".world-map-detail:not(.hidden) ~ .world-map-footer"))
        XCTAssertTrue(script.contains("function renderGalleryOverview"))
        XCTAssertTrue(script.contains("async function refreshJobs"))
        XCTAssertTrue(script.contains("function jobRowFingerprint("))
        XCTAssertTrue(script.contains("function syncJobRowDiagnostic("))
        XCTAssertTrue(script.contains("function jobActionSemanticKey("))
        XCTAssertTrue(script.contains("function syncJobRowActions("))
        XCTAssertTrue(script.contains("function syncJobRow("))
        XCTAssertTrue(script.contains("row.dataset.jobFingerprint"))
        XCTAssertTrue(script.contains("async function refreshCurrentSource"))
        XCTAssertTrue(script.contains("function syncCatalogProgressStatus"))
        XCTAssertTrue(script.contains("function scheduleCatalogProgressPoll"))
        XCTAssertTrue(script.contains("function catalogJobProgressLabel"))
        XCTAssertTrue(script.contains("function drillDownFromGalleryOverview"))
        XCTAssertTrue(script.contains("function renderActiveFilterBar"))
        XCTAssertTrue(script.contains("function viewOriginalAssetInWeb"))
        XCTAssertTrue(script.contains("function toggleLightboxOriginalView"))
        XCTAssertTrue(script.contains("lightboxOriginalAssetID"))
        XCTAssertTrue(script.contains("original ? \"original\" : \"preview\""))
        XCTAssertTrue(script.contains("lightboxPreviewPrefetches: new Map()"))
        XCTAssertTrue(script.contains("function prefetchAdjacentLightboxPreviews"))
        XCTAssertTrue(script.contains("function clearLightboxPreviewPrefetches"))
        XCTAssertTrue(script.contains("GRID_DOUBLE_CLICK_MAX_DELAY_MS"))
        XCTAssertTrue(script.contains("function rememberGridSelectionBeforeClick"))
        XCTAssertTrue(script.contains("function restoreGridSelectionForDoubleClick"))
        XCTAssertTrue(
            script.contains(
                "const preservesSelection = restoreGridSelectionForDoubleClick(\n      \"library\""
            )
        )
        XCTAssertTrue(
            script.contains(
                "const restoredSelection = restoreGridSelectionForDoubleClick(\n      \"review\",\n      reviewItemKey(item)"
            )
        )
        XCTAssertTrue(script.contains("function captureReviewSelectionSnapshot()"))
        XCTAssertTrue(script.contains("function restoreReviewSelectionSnapshot("))
        XCTAssertTrue(script.contains("selection = captureReviewSelectionSnapshot();"))
        XCTAssertTrue(script.contains("anchorKey: reviewItemKey("))
        XCTAssertTrue(script.contains("const restoredSelectedAssetIDs = new Set("))
        XCTAssertTrue(script.contains("const selectionSnapshot = captureReviewSelectionSnapshot();"))
        XCTAssertTrue(
            script.contains(
                "restoreReviewSelectionSnapshot(selectionSnapshot, { preferredKey: returnReviewKey })"
            )
        )
        XCTAssertTrue(script.contains("reviewScopeKey !== currentReviewScopeKey()"))
        XCTAssertTrue(script.contains("const submittedAssetIDs = new Set(assetIDs);"))
        XCTAssertTrue(script.contains("const selectionStillTargetsSubmission ="))
        XCTAssertTrue(
            script.contains(
                "const queueKeysBeforeReload = state.review.items.map(reviewItemKey);"
            )
        )
        XCTAssertTrue(script.contains("const primaryKeyBeforeReload = reviewItemKey("))
        XCTAssertTrue(script.contains("if (selectionStillTargetsSubmission && state.review.items.length)"))
        XCTAssertTrue(
            script.contains(
                "const continuationKeys = continuedAssetIDs(\n          queueKeysBeforeReload,\n          remainingKeys"
            )
        )
        XCTAssertTrue(script.contains("primaryKeyBeforeReload\n        );"))
        XCTAssertTrue(
            script.contains(
                "const preservesSelection = restoreGridSelectionForDoubleClick(\n      \"slimming\""
            )
        )
        XCTAssertTrue(script.contains("function openLightboxFromContextMenu"))
        XCTAssertTrue(script.contains("function slimmingSelectionPrimaryID"))
        XCTAssertTrue(script.contains("lightboxPreservesSelection: false"))
        XCTAssertTrue(script.contains("preserveSelection: context.preserveSelection === true"))
        XCTAssertTrue(script.contains("preserveSelection: state.lightboxPreservesSelection"))
        XCTAssertTrue(script.contains("function continuesGridSelectionDoubleClick"))
        XCTAssertTrue(
            script.contains(
                "openLightboxFromContextMenu(\"library\", assetID, assetCardFocusTarget(assetID))"
            )
        )
        XCTAssertTrue(
            script.contains(
                "openLightboxFromContextMenu(\"review\", assetID, returnFocus, { reviewKey })"
            )
        )
        XCTAssertTrue(script.contains("contextReviewKey"))
        XCTAssertTrue(script.contains("targetID: reviewKey"))
        XCTAssertTrue(script.contains("reviewCardFocusTarget(reviewKey)"))
        XCTAssertTrue(
            script.contains("openLightboxFromContextMenu(\"slimming\", memberID, returnFocus)")
        )
        XCTAssertTrue(
            script.contains(
                "const assetID = slimmingSelectionPrimaryID();\n        if (assetID)"
            )
        )
        XCTAssertTrue(
            script.contains(
                "preserveSelection: state.slimming.selectedMemberIDs.size > 1"
            )
        )
        XCTAssertTrue(script.contains("returnFocus instanceof HTMLElement"))
        XCTAssertTrue(
            script.contains(
                "preserveSelection: state.slimming.selectedMemberIDs.size > 1,\n"
                    + "            returnFocus,"
            )
        )
        XCTAssertTrue(
            script.contains(
                "state.lightboxContext === \"review\" && !state.lightboxPreservesSelection"
            )
        )
        XCTAssertTrue(
            script.contains(
                "state.lightboxContext === \"library\" && !state.lightboxPreservesSelection"
            )
        )
        XCTAssertFalse(
            script.contains(
                "state.selectedAssetID = assetID;\n      openLightbox(\"library\", assetID)"
            )
        )
        XCTAssertFalse(script.contains("if (state.review.selectionMode) return;"))
        XCTAssertFalse(script.contains("if (state.slimming.selectionMode) return;"))
        XCTAssertFalse(
            script.contains(
                "event.code === \"Space\" && state.slimming.selectedMemberIDs.size === 1"
            )
        )
        XCTAssertTrue(script.contains("priority: \"low\""))
        XCTAssertTrue(script.contains("preserveCurrent: true"))
        XCTAssertTrue(script.contains("const decoder = new Image()"))
        XCTAssertTrue(script.contains("protectedVisiblePath"))
        XCTAssertTrue(script.contains("protected-image-transitioning"))
        XCTAssertTrue(stylesheet.contains(".lightbox-stage img.protected-image-transitioning"))
        XCTAssertTrue(script.contains("async function openLightboxOriginalOnMac"))
        XCTAssertTrue(script.contains("async function requestAssetLocalSuggestions"))
        XCTAssertTrue(script.contains("async function applyAssetLocalSuggestionDecision"))
        XCTAssertTrue(script.contains("function syncLightboxWorkspaceFrame"))
        XCTAssertTrue(script.contains("function trapLibraryLightboxFocus"))
        XCTAssertTrue(script.contains("elements.lightbox.classList.add(\"review-docked\")"))
        XCTAssertTrue(script.contains("function reconcileReviewPreviewAfterGalleryRemoval"))
        XCTAssertTrue(script.contains("function reconcileLibraryPreviewAfterGalleryRemoval"))
        XCTAssertTrue(script.contains("function reconcileLibrarySelectionAfterGalleryRemoval"))
        XCTAssertTrue(script.contains("function reconcileLibraryLightboxAfterFavoriteRemoval"))
        XCTAssertTrue(script.contains("function reconcileLibrarySelectionAfterFavoriteRemoval"))
        XCTAssertTrue(script.contains("function replacementPreviewAssetID"))
        XCTAssertTrue(script.contains("function continuedAssetIDs"))
        XCTAssertTrue(
            script.contains(
                "await reconcileLibraryPreviewAfterGalleryRemoval(context, hidden);"
            )
        )
        XCTAssertTrue(
            script.contains(
                "const continuationIDs = continuedAssetIDs(context.assetIDs || [], remainingIDs);"
            )
        )
        XCTAssertTrue(
            script.contains(
                "context.reviewItemIDs || [],\n    remainingIDs"
            )
        )
        XCTAssertTrue(
            script.contains(
                "renderReviewSelectionState();\n  renderLightbox();\n  checkpointActiveWorkspaceHistory();"
            )
        )
        XCTAssertTrue(
            script.contains(
                "const continuationAssetIDs = continuedAssetIDs("
            )
        )
        XCTAssertTrue(
            script.contains(
                "reconcileLibrarySelectionAfterGalleryRemoval(context, hidden);"
            )
        )
        XCTAssertTrue(
            script.contains(
                "continuationAssetIDs,\n        removed,\n        favoriteRemovalSelectionContext"
            )
        )
        XCTAssertTrue(
            script.contains(
                "favoriteRemovalReconciledLightbox = reconcileLibraryLightboxAfterFavoriteRemoval("
            )
        )
        XCTAssertTrue(
            script.contains(
                "state.nextCursor && removed.has(previousAssetIDs.at(-1))"
            )
        )
        XCTAssertTrue(
            script.contains(
                "await loadAssets({ append: true, preserveSelection: true });"
            )
        )
        XCTAssertTrue(script.contains("favoriteRemovalContinuationPageFailed"))
        XCTAssertTrue(script.contains("下一页载入失败，可刷新重试"))
        XCTAssertFalse(script.contains("const previousSelectedIndex = previousAssets.findIndex("))
        XCTAssertFalse(
            script.contains(
                "state.lightboxContext === \"library\" && hidden.has(state.lightboxAssetID)"
            )
        )
        XCTAssertTrue(script.contains("function bindPersistentHelp"))
        XCTAssertTrue(script.contains("function schedulePersistentHelp"))
        XCTAssertTrue(script.contains("function persistentHelpOwnerKey"))
        XCTAssertTrue(script.contains("function reconcilePersistentHelpTarget"))
        XCTAssertTrue(script.contains("function resetPersistentHelpPointer"))
        XCTAssertTrue(script.contains("owner !== persistentHelpOwner"))
        XCTAssertTrue(script.contains("new MutationObserver((mutations) =>"))
        XCTAssertTrue(script.contains("owner: `review-overview:${overview.id}`"))
        XCTAssertTrue(script.contains("document.addEventListener(\"pointerover\""))
        XCTAssertFalse(script.contains("elements.appView.addEventListener(\"pointerover\""))
        XCTAssertTrue(script.contains("function configurePersistentHelp"))
        XCTAssertTrue(script.contains("kind: \"training\""))
        XCTAssertTrue(script.contains("function configureReviewWorkspacePersistentHelp"))
        XCTAssertTrue(script.contains("kind: \"review\""))
        XCTAssertTrue(script.contains("P 属于、X 不属于、U 稍后"))
        XCTAssertTrue(script.contains("不会替换已载入项目、清空选择或跳回顶部"))
        XCTAssertTrue(script.contains("ArrowUp ArrowDown PageUp PageDown Home End Meta+K"))
        XCTAssertTrue(script.contains("点击查看数据、配置、过程、产物和失败恢复"))
        XCTAssertTrue(script.contains("function visibleListPageStep"))
        XCTAssertTrue(script.contains("function longListNavigationTarget"))
        XCTAssertTrue(script.contains("function moveSidebarTagNavigation(event)"))
        XCTAssertTrue(script.contains("function sidebarTagDirectionalTarget"))
        XCTAssertTrue(script.contains("function sidebarTagPageTarget"))
        XCTAssertTrue(script.contains("function syncSidebarTagRovingTabStop"))
        XCTAssertTrue(script.contains("sidebarTagNavigationID"))
        XCTAssertTrue(
            script.contains(
                "标签按视觉位置、翻页与首尾导航"
            )
        )
        XCTAssertTrue(script.contains("elements.jobsList"))
        XCTAssertTrue(script.contains("elements.trainingRunPane"))
        XCTAssertTrue(script.contains("function navigateSlimmingJobByKey(key, originJobID = null)"))
        XCTAssertTrue(script.contains("async function selectSlimmingJob(jobID, { focus = false } = {})"))
        XCTAssertTrue(script.contains("function navigateSlimmingClusterByKey(key)"))
        XCTAssertTrue(script.contains("function expandSlimmingClusterWindow({ all = false } = {})"))
        XCTAssertTrue(
            script.contains(
                "elements.slimmingClusterList.addEventListener(\"keydown\""
            )
        )
        XCTAssertTrue(
            script.contains(
                "keyShortcuts: \"ArrowLeft ArrowRight ArrowUp ArrowDown PageUp PageDown Home End Shift+F10\""
            )
        )
        XCTAssertTrue(
            script.contains(
                "keyShortcuts: \"ArrowUp ArrowDown PageUp PageDown Home End\""
            )
        )
        XCTAssertTrue(html.contains("ArrowUp ArrowDown PageUp PageDown Home End"))
        XCTAssertTrue(stylesheet.contains("scroll-padding-block: 44px 8px"))
        XCTAssertTrue(script.contains("function assetCardHelpDetail"))
        XCTAssertTrue(script.contains("mainButton.dataset.helpDetail = assetCardHelpDetail(asset)"))
        XCTAssertTrue(script.contains("mainButton.dataset.helpKind = \"asset\""))
        XCTAssertTrue(script.contains("delete mainButton.dataset.helpDetail"))
        XCTAssertTrue(script.contains("async function openSlimmingThresholdEditor"))
        XCTAssertTrue(script.contains("async function saveSlimmingThresholdEditor"))
        XCTAssertTrue(script.contains("function renderSlimmingCurrentJobControls"))
        XCTAssertTrue(script.contains("function reconcileSlimmingJobActionButtons("))
        XCTAssertTrue(script.contains("data-slimming-job-action-key"))
        XCTAssertFalse(script.contains("clearElement(elements.slimmingJobActions)"))
        XCTAssertFalse(script.contains("clearElement(elements.slimmingCurrentJobActions)"))
        XCTAssertTrue(script.contains("function focusSlimmingCurrentJobAction"))
        XCTAssertTrue(script.contains("function focusSlimmingNavigatorJobAction"))
        XCTAssertTrue(script.contains("function reconcileSlimmingJobStatusParts("))
        XCTAssertTrue(script.contains("data-slimming-job-status-part"))
        XCTAssertFalse(script.contains("clearElement(elements.slimmingJobStatus)"))
        XCTAssertTrue(script.contains("function focusSlimmingJobStatusAction"))
        XCTAssertTrue(script.contains("function reconcileSlimmingRemovalStatusParts("))
        XCTAssertTrue(script.contains("data-slimming-removal-status-part"))
        XCTAssertFalse(script.contains("clearElement(elements.slimmingRemovalStatus)"))
        XCTAssertFalse(script.contains("elements.slimmingRemovalStatus.replaceChildren()"))
        XCTAssertTrue(script.contains("function syncIdenticalCleanupMetrics("))
        XCTAssertTrue(script.contains("function syncIdenticalCleanupNotices("))
        XCTAssertTrue(script.contains("data-identical-cleanup-metric-key"))
        XCTAssertTrue(script.contains("data-identical-cleanup-histogram-key"))
        XCTAssertTrue(script.contains("data-identical-cleanup-source-key"))
        XCTAssertTrue(script.contains("data-identical-cleanup-notice-key"))
        XCTAssertTrue(script.contains("function syncIdenticalCleanupChartSelection("))
        XCTAssertTrue(script.contains("function moveIdenticalCleanupChartSelection(event)"))
        XCTAssertTrue(script.contains("function selectIdenticalCleanupChartMark("))
        XCTAssertTrue(script.contains("identicalCleanupChartReading"))
        XCTAssertTrue(html.contains("aria-roledescription=\"可探索图表\""))
        XCTAssertTrue(html.contains("id=\"slimmingIdenticalCleanupHistogramStatus\""))
        XCTAssertTrue(stylesheet.contains("[data-identical-cleanup-chart]:focus-visible"))
        XCTAssertTrue(stylesheet.contains("[data-current=\"true\"]"))
        XCTAssertFalse(script.contains("clearElement(elements.slimmingIdenticalCleanupMetrics)"))
        XCTAssertFalse(script.contains("clearElement(elements.slimmingIdenticalCleanupDispositionChart)"))
        XCTAssertFalse(script.contains("clearElement(elements.slimmingIdenticalCleanupGroupHistogram)"))
        XCTAssertFalse(script.contains("clearElement(elements.slimmingIdenticalCleanupSources)"))
        XCTAssertFalse(script.contains("clearElement(elements.slimmingIdenticalCleanupNotice)"))
        XCTAssertTrue(script.contains("function syncSlimmingVerificationMetrics("))
        XCTAssertTrue(script.contains("function syncSlimmingVerificationResult("))
        XCTAssertTrue(script.contains("data-slimming-verification-metric-key"))
        XCTAssertTrue(script.contains("data-slimming-verification-result-key"))
        XCTAssertFalse(script.contains("clearElement(elements.slimmingVerificationMetrics)"))
        XCTAssertFalse(script.contains("clearElement(elements.slimmingVerificationResult)"))
        XCTAssertTrue(script.contains("function sourceSidebarNodeKey("))
        XCTAssertTrue(script.contains("function reconcileSourceSidebarChildren("))
        XCTAssertFalse(script.contains("clearElement(elements.sourceList)"))
        XCTAssertTrue(script.contains("function reconcileWorldMapPhotoCards("))
        XCTAssertFalse(script.contains("clearElement(elements.worldMapPhotoStrip)"))
        XCTAssertTrue(script.contains("function reconcileWorldMapLocationSourceCards("))
        XCTAssertFalse(script.contains("clearElement(elements.worldMapLocationBackfillSources)"))
        XCTAssertTrue(script.contains("function reconcileWorldMapPlaceCards("))
        XCTAssertTrue(script.contains("function syncWorldMapPlaceCandidateRow("))
        XCTAssertFalse(script.contains("clearElement(elements.worldMapPlaceTagItems)"))
        XCTAssertTrue(script.contains("function currentWorldMapLocationBackfillHistoryContext("))
        XCTAssertTrue(script.contains("function applyWorldMapLocationBackfillHistoryContext("))
        XCTAssertTrue(script.contains("async function restoreWorldMapLocationBackfillLayoutFromHistory("))
        XCTAssertTrue(script.contains("function currentWorldMapPlaceTagsHistoryContext("))
        XCTAssertTrue(script.contains("function applyWorldMapPlaceTagsHistoryContext("))
        XCTAssertTrue(script.contains("async function restoreWorldMapPlaceTagsLayoutFromHistory("))
        XCTAssertTrue(script.contains("...currentWorldMapLocationBackfillHistoryContext()"))
        XCTAssertTrue(script.contains("...currentWorldMapPlaceTagsHistoryContext()"))
        XCTAssertTrue(script.contains("await loadWorldMapLocationBackfill()"))
        XCTAssertTrue(script.contains("await loadWorldMapPlaceTags()"))
        XCTAssertTrue(html.contains("未提交的地点描述也不会写入浏览器历史"))
        XCTAssertTrue(script.contains("function syncFilterChip("))
        XCTAssertFalse(script.contains("clearElement(elements.filterTagChips)"))
        XCTAssertTrue(script.contains("!eventPath.includes(elements.filterPopover)"))
        XCTAssertTrue(script.contains("function syncFolderBreadcrumbButton("))
        XCTAssertTrue(script.contains("function folderBreadcrumbIdentity("))
        XCTAssertFalse(script.contains("clearElement(elements.folderBreadcrumbItems)"))
        XCTAssertTrue(script.contains("function syncReviewSourceFilterOption("))
        XCTAssertTrue(script.contains("function createReviewSourceFilterOption("))
        XCTAssertFalse(script.contains("clearElement(elements.reviewSourceFilterOptions)"))
        XCTAssertTrue(script.contains("function reviewThresholdControlsUnavailable("))
        XCTAssertTrue(script.contains("function syncReviewThresholdControlAvailability("))
        XCTAssertTrue(script.contains("function createTagSuggestionSourceOption("))
        XCTAssertTrue(script.contains("function syncTagSuggestionSourceOption("))
        XCTAssertFalse(script.contains("clearElement(elements.tagSuggestionSourceOptions)"))
        XCTAssertTrue(script.contains("function createTrainingSetupMethodOption("))
        XCTAssertTrue(script.contains("function syncTrainingSetupMethodOption("))
        XCTAssertTrue(script.contains("function createTrainingTagOption("))
        XCTAssertTrue(script.contains("function syncTrainingTagOption("))
        XCTAssertTrue(script.contains("function createTrainingSourceOption("))
        XCTAssertTrue(script.contains("function syncTrainingSourceOption("))
        XCTAssertTrue(script.contains("function createTrainingScopeOption("))
        XCTAssertTrue(script.contains("function syncTrainingScopeOption("))
        XCTAssertFalse(script.contains("clearElement(elements.trainingSetupMethods)"))
        XCTAssertFalse(script.contains("clearElement(elements.trainingTagOptions)"))
        XCTAssertFalse(script.contains("clearElement(elements.trainingScopeOptions)"))
        XCTAssertTrue(script.contains("function createSlimmingSetupModeOption("))
        XCTAssertTrue(script.contains("function syncSlimmingSetupModeOption("))
        XCTAssertTrue(script.contains("function createSlimmingSetupSourceOption("))
        XCTAssertTrue(script.contains("function syncSlimmingSetupSourceOption("))
        XCTAssertTrue(script.contains("function reconcileSlimmingSetupSummary("))
        XCTAssertTrue(script.contains("data-slimming-setup-summary-key"))
        XCTAssertTrue(script.contains("function slimmingSetupThresholdSummary("))
        XCTAssertTrue(script.contains("function slimmingSetupLaunchPresentation("))
        XCTAssertTrue(script.contains("function moveSlimmingSetupModeSelection("))
        XCTAssertFalse(script.contains("clearElement(elements.slimmingModeOptions)"))
        XCTAssertFalse(script.contains("clearElement(elements.slimmingSourceOptions)"))
        XCTAssertFalse(script.contains("clearElement(elements.slimmingLaunchSummary)"))
        XCTAssertTrue(script.contains("function createSlimmingCatalogSourceOption("))
        XCTAssertTrue(script.contains("function syncSlimmingCatalogSourceOption("))
        XCTAssertFalse(script.contains("clearElement(elements.slimmingCatalogSourceOptions)"))
        XCTAssertFalse(
            script.contains(
                "const focusedSourceID = document.activeElement?.dataset.slimmingCatalogSourceId"
            )
        )
        XCTAssertTrue(script.contains("function renderSlimmingCatalogCommands"))
        XCTAssertTrue(script.contains("function renderSlimmingCatalogSourcePicker"))
        XCTAssertTrue(script.contains("async function loadSlimmingCatalogSources"))
        XCTAssertTrue(script.contains("async function launchSlimmingAnalysis"))
        XCTAssertTrue(script.contains("function createSlimmingMaintenanceSourceOption("))
        XCTAssertTrue(script.contains("function syncSlimmingMaintenanceSourceOption("))
        XCTAssertTrue(script.contains("function syncSlimmingIndexSourceOptions("))
        XCTAssertFalse(script.contains("clearElement(elements.slimmingMaintenanceSourceOptions)"))
        XCTAssertFalse(script.contains("clearElement(elements.slimmingIndexSourceSelect)"))
        XCTAssertTrue(script.contains("function renderSlimmingRecycleSourceOptions("))
        XCTAssertTrue(script.contains("async function reconcileSlimmingRecycleSourceProjection("))
        XCTAssertFalse(script.contains("clearElement(elements.slimmingRecycleSourceSelect)"))
        XCTAssertTrue(script.contains("const recycleSourceInvalidated = Boolean("))
        XCTAssertTrue(script.contains("renderSlimmingRecycle({ preserveList: true })"))
        XCTAssertTrue(html.contains("id=\"persistentHelp\""))
        XCTAssertTrue(html.contains("data-help-detail="))
        XCTAssertTrue(stylesheet.contains(".inspector-local-model"))
        XCTAssertTrue(stylesheet.contains(".lightbox.library-docked"))
        XCTAssertTrue(stylesheet.contains(".lightbox.review-docked"))
        XCTAssertTrue(stylesheet.contains(".persistent-help"))
        XCTAssertTrue(stylesheet.contains("white-space: pre-line"))
        XCTAssertTrue(stylesheet.contains(".persistent-help[data-kind=\"asset\"]"))
        XCTAssertTrue(stylesheet.contains(".persistent-help[data-kind=\"training\"]"))
        XCTAssertTrue(stylesheet.contains(".persistent-help[data-kind=\"review\"]"))
        XCTAssertTrue(stylesheet.contains(".slimming-current-job-section"))
        XCTAssertTrue(stylesheet.contains(".slimming-current-job-actions"))
        XCTAssertTrue(stylesheet.contains(".slimming-catalog-source-popover"))
        XCTAssertTrue(stylesheet.contains(".slimming-analysis-scope-actions"))
        XCTAssertTrue(stylesheet.contains(".lightbox-open-original-button"))
        XCTAssertTrue(
            script.contains(
                "await openOriginalAssetOnMac(item.id, lightboxMediaKind(), item.availability)"
            )
        )
        XCTAssertTrue(script.contains("function activeFilterSummaryText"))
        XCTAssertTrue(script.contains("function renderWorkspaceNotice"))
        XCTAssertTrue(script.contains("function workspaceNoticeVisibleActions("))
        XCTAssertTrue(script.contains("function syncWorkspaceNoticeActionButton("))
        XCTAssertTrue(script.contains("function workspaceNoticeFocusTarget("))
        XCTAssertTrue(script.contains("state.workspaceNotice.pendingReturnActionID"))
        XCTAssertTrue(script.contains("async function dismissWorkspaceNotice"))
        XCTAssertTrue(script.contains("async function performWorkspaceNoticeAction"))
        XCTAssertTrue(script.contains("function slimmingSemanticReturnFocusTarget"))
        XCTAssertTrue(script.contains("state.slimmingReturnTarget"))
        XCTAssertTrue(script.contains("kind: \"workspaceNoticeAction\""))
        XCTAssertTrue(stylesheet.contains(".workspace-notice-banner"))
        XCTAssertTrue(stylesheet.contains(".workspace-notice-actions"))
        XCTAssertTrue(script.contains("function generateGalleryPersonalSuggestions"))
        XCTAssertTrue(script.contains("搜索文件名、路径、标签或来源"))
        XCTAssertTrue(script.contains("id: \"search\", title: \"返回图库并搜索\", keys: [\"⌘F\"]"))
        XCTAssertTrue(script.contains("async function focusLibrarySearch"))
        XCTAssertTrue(script.contains("void focusLibrarySearch()"))
        XCTAssertTrue(script.contains("function clearInlineSearchFromEscape"))
        XCTAssertTrue(script.contains("target === elements.searchInput"))
        XCTAssertTrue(script.contains("target === elements.tagNavigationSearch"))
        XCTAssertTrue(script.contains("target === elements.selectionTagSearch"))
        XCTAssertTrue(script.contains("target === elements.inspectorTagSearch"))
        XCTAssertTrue(script.contains("target === elements.reviewTagSearch"))
        XCTAssertTrue(script.contains("target === elements.slimmingRecycleSearchInput"))
        XCTAssertTrue(script.contains("async function clearSlimmingRecycleSearch"))
        XCTAssertTrue(script.contains("function renderLightboxMedia"))
        XCTAssertTrue(script.contains("function cloudPreviewCurrentAssetID"))
        XCTAssertTrue(
            script.contains(
                "showCloudPreviewRecovery(assetID, \"available\", state.lightboxContext)"
            )
        )
        XCTAssertTrue(script.contains("function downloadReviewCloudPreview"))
        XCTAssertTrue(script.contains("function resetReviewCloudPreviewRecovery"))
        XCTAssertTrue(stylesheet.contains(".lightbox-cloud-preview-recovery"))
        XCTAssertTrue(script.contains("submitSourceManagementAction(\"refreshAll\")"))
        XCTAssertTrue(script.contains("async function viewAllSourcesFromActionMenu"))
        XCTAssertTrue(script.contains("function openSourceActionsContextMenu"))
        XCTAssertTrue(script.contains("target.closest(\"#sourceSectionHeading\")"))
        XCTAssertTrue(
            script.contains(
                "elements.sourceSectionHeading.addEventListener(\"contextmenu\""
            )
        )
        XCTAssertTrue(
            script.contains(
                "[\"gallery\", \"galleryOverview\", \"worldMap\", \"review\", \"training\", \"slimming\"]"
            )
        )
        XCTAssertTrue(script.contains("await selectSource(\"\")"))
        XCTAssertTrue(script.contains("closeMobileSidebar({ restoreFocus: false })"))
        XCTAssertTrue(script.contains("elements.workspace.append(elements.sourceActionsPopover)"))
        XCTAssertTrue(script.contains("elements.workspace.append(elements.tagActionsPopover)"))
        XCTAssertTrue(script.contains("function renderTagActionsMenu"))
        XCTAssertTrue(script.contains("openActionMenu(\"tagActions\")"))
        XCTAssertTrue(script.contains("target.closest(\"#tagSectionHeading\")"))
        XCTAssertTrue(script.contains("openTagManagerForNewGroup"))
        XCTAssertTrue(script.contains("function currentTagManagerHistoryContext()"))
        XCTAssertTrue(script.contains("function applyTagManagerHistoryContext(context = {})"))
        XCTAssertTrue(script.contains("async function restoreTagManagerLayoutFromHistory()"))
        XCTAssertTrue(script.contains("async function reconcileTagManagerFromWorkspaceHistory("))
        XCTAssertTrue(script.contains("...currentTagManagerHistoryContext()"))
        XCTAssertTrue(script.contains("TAG_MANAGER_HISTORY_FOCUS_IDS"))
        XCTAssertTrue(script.contains("TAG_MANAGER_HISTORY_RETURN_SURFACES"))
        XCTAssertTrue(script.contains("tagManagerTargetGroupID"))
        XCTAssertTrue(script.contains("tagManagerReturnSurface"))
        XCTAssertTrue(html.contains("id=\"tagManagerNotice\""))
        XCTAssertTrue(script.contains("未提交的标签或分组名称不会保存到浏览器历史。"))
        XCTAssertTrue(stylesheet.contains(".tag-manager-notice"))
        XCTAssertTrue(script.contains("presentNewTagDialog({ returnFocus: elements.tagManagerButton })"))
        XCTAssertTrue(script.contains("const NEW_TAG_HISTORY_CONTROL_IDS"))
        XCTAssertTrue(script.contains("const NEW_TAG_HISTORY_RETURN_IDS"))
        XCTAssertTrue(script.contains("function currentNewTagHistoryContext()"))
        XCTAssertTrue(script.contains("function applyNewTagHistoryContext(context = {})"))
        XCTAssertTrue(script.contains("async function restoreNewTagLayoutFromHistory()"))
        XCTAssertTrue(script.contains("...currentNewTagHistoryContext()"))
        XCTAssertTrue(script.contains("state.newTagRestorable = true"))
        XCTAssertTrue(html.contains("为保护标签隐私"))
        XCTAssertTrue(stylesheet.contains(".sheet-dialog-restore-note"))
        XCTAssertTrue(script.contains("submitSourceManagementAction(\"prewarmAllThumbnails\")"))
        XCTAssertTrue(script.contains("submitSourceManagementAction(\"prewarmAllOriginalAspect\")"))
        XCTAssertTrue(script.contains("submitSourceManagementAction(\"reauthorizeAll\")"))
        XCTAssertTrue(script.contains("submitSourceManagementAction(\"refreshAllFolderMutationAuthorizations\")"))
        XCTAssertTrue(script.contains("function constrainedLightboxOffset"))
        XCTAssertTrue(script.contains("function syncLightboxViewport"))
        XCTAssertTrue(script.contains("function handleLightboxWheel"))
        XCTAssertTrue(script.contains("function beginLightboxPan"))
        XCTAssertTrue(script.contains("function beginLightboxPinch"))
        XCTAssertTrue(script.contains("function lightboxGesturePair"))
        XCTAssertTrue(script.contains("function lightboxControlOwnsKeyboardEvent"))
        XCTAssertTrue(script.contains("if (lightboxControlOwnsKeyboardEvent(event)) return"))
        XCTAssertTrue(script.contains("restoreFavoriteFocus"))
        XCTAssertTrue(html.contains("id=\"lightboxGestureHint\""))
        XCTAssertTrue(stylesheet.contains(".lightbox-zoom-controls"))
        XCTAssertTrue(stylesheet.contains(".lightbox-stage"))
        XCTAssertTrue(stylesheet.contains(".lightbox-gesture-hint"))
        XCTAssertTrue(stylesheet.contains(".lightbox-delete-button"))
        XCTAssertTrue(script.contains("id: \"previewDelete\""))
        XCTAssertTrue(script.contains("删除当前项目并由 Mac 确认"))
        XCTAssertTrue(
            script.contains(
                "[\"library\", \"review\", \"slimming\"].includes("
            )
        )
        XCTAssertTrue(script.contains("surface: state.lightboxContext === \"review\" ? \"review\" : \"gallery\""))
        XCTAssertTrue(script.contains("[\"library\", \"review\"].includes(state.lightboxContext)"))
        XCTAssertTrue(script.contains("function loadMoreLightboxItems"))
        XCTAssertTrue(script.contains("function syncLibraryLightboxSelection"))
        XCTAssertTrue(script.contains("function lightboxNavigationFocusTarget"))
        XCTAssertTrue(script.contains("function libraryGridRovingAssetID"))
        XCTAssertTrue(script.contains("function syncLibraryGridTabStops"))
        XCTAssertTrue(script.contains("mainButton.tabIndex = isTabStop ? 0 : -1"))
        XCTAssertTrue(script.contains("favoriteButton.tabIndex = isTabStop ? 0 : -1"))
        XCTAssertTrue(script.contains("elements.assetGrid.addEventListener(\"focusin\""))
        XCTAssertTrue(script.contains("function reviewGridRovingKey"))
        XCTAssertTrue(script.contains("function syncReviewGridTabStops"))
        XCTAssertTrue(script.contains("state.review.gridFocusReviewKey"))
        XCTAssertTrue(script.contains("elements.reviewGrid.addEventListener(\"focusin\""))
        XCTAssertTrue(script.contains("function slimmingMemberGridRovingAssetID"))
        XCTAssertTrue(script.contains("function syncSlimmingMemberGridTabStops"))
        XCTAssertTrue(script.contains("state.slimming.memberGridFocusAssetID"))
        XCTAssertTrue(script.contains("elements.slimmingMemberGrid.addEventListener(\"focusin\""))
        XCTAssertTrue(script.contains("function slimmingWorkspaceCollectionFingerprint"))
        XCTAssertTrue(script.contains("function slimmingWorkspaceCanPreserveCollections"))
        XCTAssertTrue(script.contains("renderedCollectionFingerprint"))
        XCTAssertTrue(script.contains("row.dataset.slimmingFingerprint = fingerprint"))
        XCTAssertTrue(script.contains("card.dataset.slimmingFingerprint = fingerprint"))
        XCTAssertTrue(script.contains("data-slimming-member-main-part=\"image\""))
        XCTAssertTrue(script.contains("function slimmingRecycleGridRovingEntryID"))
        XCTAssertTrue(script.contains("function syncSlimmingRecycleGridTabStops"))
        XCTAssertTrue(script.contains("function slimmingRecycleCountdown"))
        XCTAssertTrue(script.contains("function slimmingRecycleLifecycleIcon"))
        XCTAssertTrue(script.contains("function slimmingRecycleMovedCaption"))
        XCTAssertTrue(script.contains("function slimmingRecycleQuerySignature"))
        XCTAssertTrue(script.contains("function slimmingRecycleEntryFingerprint"))
        XCTAssertTrue(script.contains("function updateSlimmingRecycleRows"))
        XCTAssertTrue(script.contains("function renderSlimmingRecycleEntryState"))
        XCTAssertTrue(script.contains("function captureSlimmingRecycleActionContinuity"))
        XCTAssertTrue(script.contains("button.dataset.slimmingRecycleActionKey = key"))
        XCTAssertTrue(script.contains("reconcileStableChildren(actions, wantedActions)"))
        XCTAssertTrue(
            script.contains("reconcileStableChildren(row, [thumbnail, copy, policy, actions])")
        )
        XCTAssertTrue(script.contains("function restoreRenderedSlimmingRecycleQuery"))
        XCTAssertTrue(script.contains("function cancelPendingSlimmingRecycleSearch"))
        XCTAssertTrue(script.contains("renderedQuerySignature"))
        XCTAssertTrue(script.contains("renderedLimit"))
        XCTAssertTrue(script.contains("updateRecycleIDs"))
        XCTAssertTrue(script.contains("slimmingRecycleAssetId"))
        XCTAssertTrue(script.contains("recycleAction: action"))
        XCTAssertTrue(script.contains("pending.recycleAction"))
        XCTAssertTrue(script.contains("if (previous.continuity) restoreSlimmingRecycleContinuity"))
        XCTAssertTrue(script.contains("ImageAll 即将清理此记录"))
        XCTAssertTrue(script.contains("entry.state === \"recycled\""))
        XCTAssertTrue(script.contains("state.slimming.recycle.focusEntryID"))
        XCTAssertTrue(script.contains("elements.slimmingRecycleList.addEventListener(\"focusin\""))
        XCTAssertTrue(script.contains("renderedGridPageItemCount(\n      elements.slimmingRecycleBody"))
        XCTAssertTrue(stylesheet.contains(".slimming-recycle-row:focus-within"))
        XCTAssertTrue(stylesheet.contains(".slimming-recycle-thumbnail-card:focus-visible"))
        XCTAssertTrue(stylesheet.contains(".slimming-recycle-detail.folder-countdown"))
        XCTAssertTrue(stylesheet.contains(".slimming-recycle-actions .button.button-primary"))
        XCTAssertTrue(script.contains("focusedNavigationButton"))
        XCTAssertTrue(
            script.contains(
                "restoreOverlayFocus(lightboxNavigationFocusTarget(focusedNavigationButton))"
            )
        )
        XCTAssertTrue(script.contains("lightboxPendingDirection"))
        XCTAssertTrue(script.contains("function applyLightboxReviewDecision"))
        XCTAssertTrue(script.contains("function selectAllReviewItems"))
        XCTAssertTrue(script.contains("function startReviewMarqueeSelection"))
        XCTAssertTrue(script.contains("state.review.selectedAssetIDs"))
        XCTAssertFalse(script.contains("confirmBatchTagDecision"))
        XCTAssertTrue(script.contains("tagAction:accept:${tag.id}"))
        XCTAssertTrue(script.contains("sourceAction:${action}:${selectedSource.id}"))
        XCTAssertTrue(script.contains("async function executeSourceCommandAction"))
        XCTAssertTrue(
            script.contains(
                "executeSourceCommandAction(action, sourceID, commandReturnFocus)"
            )
        )
        XCTAssertTrue(
            script.contains(
                "executeSourceCommandAction(\"refreshAll\", null, commandReturnFocus)"
            )
        )
        XCTAssertTrue(
            script.contains(
                "executeSourceCommandAction(\"prewarmAllThumbnails\", null, commandReturnFocus)"
            )
        )
        XCTAssertTrue(script.contains("openLightbox(\"worldMap\""))
        XCTAssertNotNil(store.asset(for: "/world-map/index.html"))
        XCTAssertTrue(script.contains("setProtectedImageSource"))
        XCTAssertTrue(script.contains("Basic ${btoa(binary)}"))
        XCTAssertTrue(script.contains("assetPageFingerprint"))
        XCTAssertTrue(script.contains("fetchLoadedAssetWindow"))
        XCTAssertTrue(script.contains("reviewPageFingerprint"))
        XCTAssertTrue(script.contains("preserveUnchangedGrid: true"))
        XCTAssertTrue(script.contains("preserveLoadedWindow: true"))
        XCTAssertTrue(script.contains("syncAssetCardImage"))
        XCTAssertTrue(script.contains("function assetCardMainButton"))
        XCTAssertTrue(script.contains("function syncAssetCardFavoriteButton"))
        XCTAssertTrue(script.contains("async function toggleAssetCardFavorite"))
        XCTAssertTrue(script.contains("button.dataset.assetCardFavorite = \"true\""))
        XCTAssertTrue(script.contains("existing.get(asset.id) || document.createElement(\"div\")"))
        XCTAssertFalse(script.contains("existing.get(asset.id) || document.createElement(\"button\")"))
        XCTAssertTrue(stylesheet.contains(".asset-card-main"))
        XCTAssertTrue(stylesheet.contains(".asset-card-favorite"))
        XCTAssertTrue(script.contains("function reviewCardMainButton"))
        XCTAssertTrue(script.contains("function syncReviewCardFavoriteButton"))
        XCTAssertTrue(script.contains("async function toggleReviewCardFavorite"))
        XCTAssertTrue(script.contains("button.dataset.reviewCardFavorite = \"true\""))
        XCTAssertTrue(script.contains("existing.get(key) || document.createElement(\"div\")"))
        XCTAssertTrue(stylesheet.contains(".review-card-main"))
        XCTAssertTrue(stylesheet.contains(".review-card-favorite"))
        XCTAssertTrue(script.contains("function slimmingMemberMainButton"))
        XCTAssertTrue(script.contains("function syncSlimmingMemberFavoriteButton"))
        XCTAssertTrue(script.contains("async function toggleSlimmingMemberFavorite"))
        XCTAssertTrue(script.contains("function syncSlimmingRecycleFavoriteButton"))
        XCTAssertTrue(script.contains("async function toggleSlimmingRecycleFavorite"))
        XCTAssertTrue(script.contains("async function toggleSlimmingRecycleFavoriteEntry"))
        XCTAssertTrue(script.contains("function showSlimmingRecycleContextMenu"))
        XCTAssertTrue(script.contains("data-slimming-recycle-thumbnail-entry-id"))
        XCTAssertTrue(script.contains("function slimmingRecycleRecoveryDescriptor"))
        XCTAssertTrue(script.contains("async function submitSlimmingRecycleRecoveryAction"))
        XCTAssertTrue(script.contains("function openSlimmingRecycleExplanation"))
        XCTAssertTrue(script.contains("refreshSourceBeforeRetry"))
        XCTAssertTrue(script.contains("requestPhotosAuthorization"))
        XCTAssertTrue(script.contains("retryFromAnalysis"))
        XCTAssertTrue(script.contains("function startSlimmingMarqueeSelection"))
        XCTAssertTrue(script.contains("button.dataset.slimmingMemberFavorite = \"true\""))
        XCTAssertTrue(script.contains("button.dataset.slimmingRecycleFavorite = \"true\""))
        XCTAssertTrue(script.contains("红心只用于整理，不会阻止恢复、回收或永久删除"))
        XCTAssertTrue(script.contains("function assetIsDeletionProtected"))
        XCTAssertTrue(script.contains("function removalFavoriteProtectionPlan"))
        XCTAssertTrue(script.contains("favoriteProtectedAssetIDs"))
        XCTAssertTrue(script.contains("所选项目均有红心保护；请先取消红心"))
        XCTAssertFalse(script.contains("红心只用于整理，不会暂停本次删除"))
        XCTAssertTrue(html.contains("Apple Photos 的“最近删除”由系统管理，红心不能暂停系统永久删除。"))
        XCTAssertTrue(stylesheet.contains(".slimming-member-main"))
        XCTAssertTrue(stylesheet.contains(".slimming-member-favorite"))
        XCTAssertTrue(stylesheet.contains(".slimming-recycle-favorite"))
        XCTAssertTrue(stylesheet.contains(".context-menu-note"))
        XCTAssertTrue(stylesheet.contains("max-height: calc(100dvh - 12px)"))
        XCTAssertTrue(stylesheet.contains("overflow-y: auto"))
        XCTAssertTrue(stylesheet.contains("overscroll-behavior: contain"))
        XCTAssertTrue(script.contains("function contextMenuVisualViewportBounds()"))
        XCTAssertTrue(script.contains("function repositionActiveContextMenu()"))
        XCTAssertTrue(script.contains("function containContextMenuBackgroundScroll(event)"))
        XCTAssertTrue(script.contains("function contextMenuActionButtons(menu)"))
        XCTAssertTrue(script.contains("function focusContextMenuAction(menu, button)"))
        XCTAssertTrue(script.contains("function moveContextMenuFocus(event)"))
        XCTAssertTrue(script.contains("menu.addEventListener(\"keydown\", moveContextMenuFocus)"))
        XCTAssertTrue(script.contains("function segmentedControlButtons(container, selector)"))
        XCTAssertTrue(script.contains("function syncRovingSegmentedControl(container, selector)"))
        XCTAssertTrue(script.contains("function moveRovingSegmentedSelection(event, container, selector)"))
        XCTAssertTrue(script.contains("elements.mediaKindTabs.addEventListener(\"keydown\""))
        XCTAssertTrue(script.contains("elements.activeFilterRelation.addEventListener(\"keydown\""))
        XCTAssertTrue(script.contains("elements.trainingSetupMethods.addEventListener(\"keydown\""))
        XCTAssertTrue(script.contains("elements.trainingMediaKindTabs.addEventListener(\"keydown\""))
        XCTAssertTrue(script.contains("elements.slimmingWorkspaceTabs.addEventListener(\"keydown\""))
        XCTAssertTrue(script.contains("elements.slimmingMediaKindTabs.addEventListener(\"keydown\""))
        XCTAssertTrue(script.contains("function moveAuthMethodSelection(event)"))
        XCTAssertTrue(script.contains("elements.toolbarDisplayModeControl.addEventListener(\"keydown\""))
        XCTAssertTrue(script.contains("elements.slimmingClusterScopes.addEventListener(\"keydown\""))
        XCTAssertTrue(script.contains("elements.slimmingRecycleScopes.addEventListener(\"keydown\""))
        XCTAssertTrue(script.contains("function clearToast()"))
        XCTAssertTrue(html.contains("role=\"tabpanel\""))
        XCTAssertTrue(html.contains("aria-labelledby=\"accountLoginTab\""))
        XCTAssertTrue(html.contains("aria-labelledby=\"pairingLoginTab\""))
        XCTAssertTrue(script.contains("visualViewport?.addEventListener(\"resize\""))
        XCTAssertTrue(script.contains("visualViewport?.addEventListener(\"scroll\""))
        XCTAssertTrue(script.contains("\"wheel\", containContextMenuBackgroundScroll"))
        XCTAssertTrue(script.contains("\"touchmove\", containContextMenuBackgroundScroll"))
        XCTAssertTrue(stylesheet.contains(".slimming-member-pending-overlay"))
        XCTAssertTrue(stylesheet.contains("@media (hover: none), (pointer: coarse), (max-width: 640px)"))
        XCTAssertTrue(script.contains("button.dataset.imageKey === imageKey"))
        XCTAssertTrue(script.contains("syncAssetCardPosition(button, index)"))
        XCTAssertFalse(script.contains("elements.assetGrid.append(button);"))
        XCTAssertTrue(script.contains("async function applyBatchTagDecision"))
        XCTAssertTrue(script.contains("submitSourceManagementAction"))
        XCTAssertTrue(script.contains("renderSidebarSourceActions"))
        XCTAssertTrue(script.contains("openSourceManagerForAction"))
        XCTAssertTrue(script.contains("moveSidebarPrimaryNavigation"))
        XCTAssertTrue(script.contains("focusCurrentSidebarPrimaryNavigation"))
        XCTAssertTrue(script.contains("longListNavigationTarget(\n    items,\n    currentIndex,\n    event.key,\n    elements.sourceSidebar"))
        XCTAssertTrue(html.contains("ArrowUp ArrowDown PageUp PageDown Home End"))
        XCTAssertTrue(html.contains("ArrowUp ArrowDown ArrowLeft ArrowRight PageUp PageDown Home End"))
        XCTAssertTrue(script.contains("function librarySuggestionJobActionKey("))
        XCTAssertTrue(script.contains("function syncLibrarySuggestionJobAction("))
        XCTAssertTrue(script.contains("function restoreLibrarySuggestionJobActionFocus("))
        XCTAssertTrue(script.contains("function restorePendingLibrarySuggestionTerminalFocus("))
        XCTAssertTrue(script.contains("state.librarySuggestions.pendingTerminalFocus = {"))
        XCTAssertTrue(script.contains("data-library-suggestion-action-part=label"))
        XCTAssertTrue(script.contains("reconcileStableChildren(container, [...staticControls, ...wanted])"))
        XCTAssertTrue(script.contains("scheduleSourceManagementPoll"))
        XCTAssertTrue(script.contains("function sourceManagementSnapshotFingerprint("))
        XCTAssertTrue(script.contains("function sourceManagerRowFingerprint("))
        XCTAssertTrue(script.contains("function syncSourceManagerRow("))
        XCTAssertTrue(
            script.contains(
                "ArrowUp ArrowDown PageUp PageDown Home End ArrowLeft ArrowRight"
            )
        )
        XCTAssertTrue(script.contains("row.tabIndex = selected ? 0 : -1"))
        XCTAssertTrue(
            script.contains(
                "longListNavigationTarget(rows, index, event.key, navigation)"
            )
        )
        XCTAssertTrue(
            script.contains(
                "row?.scrollIntoView({ block: \"nearest\", inline: \"nearest\" })"
            )
        )
        XCTAssertTrue(script.contains("function sourceManagerActionDisabled("))
        XCTAssertTrue(script.contains("function syncSourceManagerActionButton("))
        XCTAssertTrue(script.contains("function syncSourceManagerActionGroup("))
        XCTAssertTrue(script.contains("function syncSourceManagerDetail("))
        XCTAssertTrue(script.contains("function reconcileSourceManagerContent("))
        XCTAssertTrue(script.contains("function renderSourceManagement({ preserveContent = false, reconcileContent = true } = {})"))
        XCTAssertTrue(script.contains("renderSourceManagement({ reconcileContent: true })"))
        XCTAssertTrue(script.contains("reconcileStableChildren(navigation, wantedRows)"))
        XCTAssertTrue(script.contains("focusedRow && !wantedRows.includes(focusedRow)"))
        XCTAssertTrue(script.contains("function sourceManagerPendingPart("))
        XCTAssertTrue(script.contains("function syncSourceManagerPending("))
        XCTAssertTrue(script.contains("renderSourceManagement({"))
        XCTAssertTrue(script.contains("reconcileContent: reconcileLoadedContent"))
        XCTAssertTrue(script.contains("data-source-manager-action-group"))
        XCTAssertTrue(script.contains("function selectSourceManagerSource"))
        XCTAssertTrue(script.contains("function handleSourceManagerKeyboardNavigation"))
        XCTAssertTrue(script.contains("function handleSourceManagerAllActionsKeyboard"))
        XCTAssertTrue(script.contains("function closeSourceManagerAllActions"))
        XCTAssertTrue(script.contains("viewButton.dataset.sourceManagerView = source.id"))
        XCTAssertTrue(script.contains("source-manager-action-group-${group}"))
        XCTAssertTrue(script.contains("function currentSourceManagerHistoryContext("))
        XCTAssertTrue(script.contains("function applySourceManagerHistoryContext("))
        XCTAssertTrue(script.contains("async function restoreSourceManagerLayoutFromHistory("))
        XCTAssertTrue(script.contains("SOURCE_MANAGER_HISTORY_CONTROL_IDS"))
        XCTAssertTrue(script.contains("SOURCE_MANAGER_HISTORY_RETURN_CONTROL_IDS"))
        XCTAssertTrue(script.contains("...currentSourceManagerHistoryContext()"))
        XCTAssertTrue(stylesheet.contains(".source-manager-source-list"))
        XCTAssertTrue(stylesheet.contains(".source-manager-detail"))
        XCTAssertTrue(stylesheet.contains(".source-manager-all-actions-menu"))
        XCTAssertTrue(stylesheet.contains(".source-manager-history-notice"))
        XCTAssertTrue(script.contains("function syncCommandItem("))
        XCTAssertTrue(script.contains("function commandItemFingerprint("))
        XCTAssertTrue(script.contains("function syncCommandPaletteAccessibility("))
        XCTAssertTrue(script.contains("const previousCommandID = state.commandItems[state.commandIndex]?.id"))
        XCTAssertTrue(script.contains("command.id === previousCommandID"))
        XCTAssertTrue(script.contains("const previousVisualTop = preservesVisualAnchor"))
        XCTAssertTrue(script.contains("elements.commandList.scrollTop += visualDelta"))
        XCTAssertTrue(script.contains("reconcileStableChildren(elements.commandList, wantedItems)"))
        XCTAssertTrue(script.contains("if (elements.commandPalette.open) renderCommandItems()"))
        XCTAssertFalse(script.contains("clearElement(elements.commandList)"))
        XCTAssertTrue(html.contains("role=\"combobox\" aria-label=\"搜索命令\" aria-controls=\"commandList\""))
        XCTAssertTrue(html.contains("aria-autocomplete=\"list\" aria-expanded=\"false\""))
        XCTAssertTrue(stylesheet.contains(".command-item:disabled"))
        XCTAssertTrue(script.contains("prewarmThumbnails"))
        XCTAssertTrue(script.contains("prewarmOriginalAspect"))
        XCTAssertTrue(script.contains("cancelPrewarm"))
        XCTAssertTrue(script.contains("requestPhotosWriteAuthorization"))
        XCTAssertTrue(script.contains("refreshFolderMutationAuthorization"))
        XCTAssertTrue(script.contains("sourcePrewarmStatusButton"))
        XCTAssertTrue(script.contains("emptyOpenPhotosSettingsButton"))
        XCTAssertTrue(script.contains("openPhotosPrivacySettings"))
        XCTAssertTrue(script.contains("重新检查并同步"))
        XCTAssertTrue(script.contains("重新启用…"))
        XCTAssertTrue(script.contains("sourcePrewarmCancelButton"))
        XCTAssertTrue(script.contains("function cancelActiveSourcePrewarm"))
        XCTAssertTrue(stylesheet.contains(".source-prewarm-cancel"))
        XCTAssertTrue(script.contains("renderStorageMaintenance"))
        XCTAssertTrue(script.contains("storageActionAvailability"))
        XCTAssertTrue(script.contains("storageMaintenanceNeedsPoll"))
        XCTAssertTrue(script.contains("librarySlimmingAnalysisInProgress"))
        XCTAssertTrue(script.contains("submitStorageMaintenanceAction"))
        XCTAssertTrue(script.contains("requestStorageMaintenanceAction"))
        XCTAssertTrue(script.contains("清理预览缓存？"))
        XCTAssertTrue(script.contains("清理全部长期原图副本？"))
        XCTAssertTrue(script.contains("returnFocus: { storageAction: action }"))
        XCTAssertTrue(script.contains("scheduleStorageMaintenancePoll"))
        XCTAssertTrue(script.contains("function storageRequestFingerprint("))
        XCTAssertTrue(script.contains("function createStorageHistoryRow("))
        XCTAssertTrue(script.contains("function syncStorageHistoryRow("))
        XCTAssertTrue(script.contains("function reconcileStorageHistory("))
        XCTAssertTrue(script.contains("reconcileStableChildren(elements.storageHistory, rows)"))
        XCTAssertFalse(script.contains("clearElement(elements.storageHistory)"))
        XCTAssertTrue(script.contains("returnFocus: elements.storageRefreshButton"))
        XCTAssertTrue(script.contains("const STORAGE_MAINTENANCE_HISTORY_FOCUS_IDS"))
        XCTAssertTrue(script.contains("const STORAGE_MAINTENANCE_HISTORY_RETURN_IDS"))
        XCTAssertTrue(script.contains("function currentStorageMaintenanceHistoryContext()"))
        XCTAssertTrue(script.contains("function applyStorageMaintenanceHistoryContext(context = {})"))
        XCTAssertTrue(script.contains("async function restoreStorageMaintenanceLayoutFromHistory()"))
        XCTAssertTrue(script.contains("...currentStorageMaintenanceHistoryContext()"))
        XCTAssertTrue(script.contains("state.storageRestorable = true"))
        XCTAssertTrue(script.contains("function createSuggestionThresholdMethod("))
        XCTAssertTrue(script.contains("function syncSuggestionThresholdMethod("))
        XCTAssertTrue(script.contains("function createSuggestionThresholdCard("))
        XCTAssertTrue(script.contains("function syncSuggestionThresholdCard("))
        XCTAssertTrue(script.contains("function reconcileSuggestionThresholdCards("))
        XCTAssertTrue(script.contains("reconcileStableChildren(elements.suggestionThresholdList, cards)"))
        XCTAssertTrue(script.contains("const GENERAL_SETTINGS_HISTORY_CONTROL_IDS"))
        XCTAssertTrue(script.contains("const GENERAL_SETTINGS_HISTORY_RETURN_IDS"))
        XCTAssertTrue(script.contains("function currentGeneralSettingsHistoryContext()"))
        XCTAssertTrue(script.contains("function applyGeneralSettingsHistoryContext(context = {})"))
        XCTAssertTrue(script.contains("async function restoreGeneralSettingsLayoutFromHistory("))
        XCTAssertTrue(script.contains("async function restoreSuggestionThresholdLayoutFromHistory()"))
        XCTAssertTrue(script.contains("...currentGeneralSettingsHistoryContext()"))
        XCTAssertTrue(script.contains("state.generalSettings.restorable = true"))
        XCTAssertTrue(script.contains("function restoreThresholdFocus(key, { onlyIfUnfocused = false } = {})"))
        XCTAssertTrue(script.contains("function stepSuggestionThresholdInput(input, step)"))
        XCTAssertTrue(html.contains("id=\"generalSettingsSaveStatus\""))
        XCTAssertTrue(script.contains("function pendingGeneralSettingsUpdates()"))
        XCTAssertTrue(script.contains("function processGeneralSettingsUpdateQueue()"))
        XCTAssertTrue(script.contains("manager.updateQueue.push({ patch, resolve: resolveResult, result })"))
        XCTAssertTrue(script.contains("pendingGeneralSettingsValue("))
        XCTAssertTrue(stylesheet.contains(".general-settings-save-status"))
        XCTAssertTrue(html.contains("data-suggestion-default-step=\"-0.05\""))
        XCTAssertTrue(html.contains("data-suggestion-default-step=\"0.05\""))
        XCTAssertTrue(script.contains("data-threshold-step"))
        XCTAssertTrue(stylesheet.contains(".suggestion-threshold-stepper"))
        XCTAssertTrue(stylesheet.contains(".threshold-step-button"))
        XCTAssertTrue(stylesheet.contains("grid-auto-rows: max-content"))
        XCTAssertTrue(script.contains("function syncSlimmingThresholdInteractionSurface(surface)"))
        XCTAssertTrue(script.contains("function bindSlimmingThresholdInteractionSurface(surface)"))
        XCTAssertTrue(html.contains("data-threshold-number-target=\"slimmingRecallTopK\""))
        XCTAssertTrue(html.contains("data-threshold-mode-target=\"slimmingThresholdRecallMode\""))
        XCTAssertTrue(html.contains("data-threshold-select-target=\"slimmingBucketingMode\""))
        XCTAssertTrue(stylesheet.contains(".slimming-threshold-value-editor"))
        XCTAssertTrue(stylesheet.contains(".slimming-threshold-segmented"))
        XCTAssertTrue(script.contains("manager.pendingThresholdFocus = activeFocusKey"))
        XCTAssertTrue(script.contains("const hasLocalDraft = input.dataset.persistedValue !== undefined"))
        XCTAssertFalse(script.contains("elements.suggestionThresholdList.replaceChildren()"))
        XCTAssertTrue(html.contains("保留策略：默认长期保留，不自动过期或按容量淘汰"))
        XCTAssertTrue(html.contains("相同检测运行期间不能清理；暂停或完成后可操作。"))
        XCTAssertTrue(stylesheet.contains(".storage-action-note"))
        XCTAssertTrue(script.contains("submitSlimmingRecycleAction"))
        XCTAssertTrue(script.contains("function requestConfirmation"))
        XCTAssertTrue(script.contains("elements.slimmingRecycleExplanationDialog.open"))
        XCTAssertTrue(script.contains("function requestSourceManagementAction"))
        XCTAssertTrue(script.contains("继续并请求照片权限"))
        XCTAssertTrue(script.contains("保留历史并连接"))
        XCTAssertTrue(script.contains("开始完整修复扫描"))
        XCTAssertTrue(script.contains("交给 Mac 确认"))
        XCTAssertTrue(script.contains("returnFocus: { sourceID: sourceID || null, sourceAction: action }"))
        XCTAssertTrue(script.contains("trainingOperationID"))
        XCTAssertTrue(script.contains("recycleEntryID"))
        XCTAssertTrue(script.contains("slimmingJobID"))
        XCTAssertFalse(script.contains("window.confirm"))
        XCTAssertTrue(stylesheet.contains(".confirm-dialog-mark"))
        XCTAssertTrue(stylesheet.contains(".confirm-dialog[data-tone=\"warning\"]"))
        XCTAssertTrue(script.contains("function commandContextSnapshot"))
        XCTAssertTrue(script.contains("function closeCommandPalette"))
        XCTAssertTrue(script.contains("async function openWorkspaceFromCommand"))
        XCTAssertTrue(script.contains("async function refreshCommandContext"))
        XCTAssertTrue(script.contains("async function switchCommandMediaKind"))
        XCTAssertTrue(script.contains("function commandSelectionContext"))
        XCTAssertTrue(script.contains("function selectAllCommandContext"))
        XCTAssertTrue(script.contains("function previewCommandContext"))
        XCTAssertTrue(script.contains("function openReviewLightbox"))
        XCTAssertTrue(script.contains("reviewKey: reviewItemKey(item)"))
        XCTAssertTrue(script.contains("primaryReviewKey: reviewItemKey(primaryItem)"))
        XCTAssertTrue(script.contains("openReviewLightbox(item, options)"))
        XCTAssertTrue(script.contains("const selectionContext = commandSelectionContext(contextRoute)"))
        XCTAssertTrue(script.contains("previewCommandContext(contextRoute, selectionContext)"))
        XCTAssertEqual(
            script.components(separatedBy: "openLightbox(\"review\"").count - 1,
            1
        )
        XCTAssertTrue(script.contains("id: \"reviewAcceptSelection\""))
        XCTAssertTrue(script.contains("id: \"reviewRejectSelection\""))
        XCTAssertTrue(script.contains("id: \"reviewDeferSelection\""))
        XCTAssertTrue(script.contains("id: \"recycleSlimmingSelection\""))
        XCTAssertTrue(script.contains("id: \"releaseSlimmingSelection\""))
        XCTAssertTrue(script.contains("currentWorkspaceHistoryContext"))
        XCTAssertTrue(script.contains("id: \"openSlimming\""))
        XCTAssertTrue(stylesheet.contains(".command-palette footer span:first-child"))
        XCTAssertTrue(script.contains("scheduleSlimmingRecyclePoll"))
        XCTAssertTrue(script.contains("navigateSlimmingJob"))
        XCTAssertTrue(script.contains("renderSlimmingJobStatus"))
        XCTAssertTrue(script.contains("renderSlimmingInspector"))
        XCTAssertTrue(script.contains("openSlimmingJobFromActivity"))
        XCTAssertTrue(script.contains("openAssociatedActivity"))
        XCTAssertTrue(script.contains("openTrainingWorkspaceForReviewTag"))
        XCTAssertTrue(script.contains("openReviewFromTrainingRun"))
        XCTAssertTrue(script.contains("reviewFeatureTagId"))
        XCTAssertTrue(script.contains("trainingReviewRunId"))
        XCTAssertTrue(script.contains("jobFailureGuidance"))
        XCTAssertTrue(script.contains("openSlimmingVerificationReport"))
        XCTAssertTrue(script.contains("targetRetainedAssetCount"))
        XCTAssertFalse(script.contains("确认要为 ${mediaItemCountText(assetCount)}${actionText}标签"))
        XCTAssertTrue(script.contains("event.metaKey || event.ctrlKey"))
        XCTAssertTrue(script.contains("event.shiftKey"))
        XCTAssertTrue(script.contains("selectAssetRange"))
        XCTAssertTrue(script.contains("selectAllLoadedAssets"))
        XCTAssertTrue(script.contains("renderTagNavigation"))
        XCTAssertTrue(script.contains("function sidebarTagNavigationSections("))
        XCTAssertTrue(script.contains("function syncSidebarTagNavigationSection("))
        XCTAssertTrue(script.contains("function syncSidebarTagNavigationChip("))
        XCTAssertTrue(script.contains("sidebarTagNavigationSectionCache.get("))
        XCTAssertTrue(script.contains("sidebarTagNavigationChipCache.get("))
        XCTAssertTrue(script.contains("const focus = captureFolderSidebarFocus();"))
        XCTAssertTrue(script.contains("restoreFolderSidebarFocus(focus);"))
        XCTAssertTrue(script.contains("function reconcileInspectorTagGroups("))
        XCTAssertTrue(script.contains("function syncInspectorTagGroup("))
        XCTAssertTrue(script.contains("function syncInspectorTagChip("))
        XCTAssertTrue(script.contains("function syncSingleInspectorTagRow("))
        XCTAssertTrue(script.contains("function syncSelectionInspectorTagRow("))
        XCTAssertTrue(script.contains("function syncReviewInspectorTagRow("))
        XCTAssertTrue(script.contains("function syncPlaceholderInspectorTagRow("))
        XCTAssertFalse(script.contains("clearElement(elements.inspectorTags)"))
        XCTAssertFalse(script.contains("clearElement(elements.selectionInspectorTags)"))
        XCTAssertFalse(script.contains("clearElement(elements.reviewTags)"))
        XCTAssertTrue(script.contains("function createInspectorSuggestionRow("))
        XCTAssertTrue(script.contains("function syncInspectorSuggestionRow("))
        XCTAssertTrue(script.contains("data-inspector-suggestion-row-key"))
        XCTAssertFalse(script.contains("clearElement(elements.inspectorSuggestions)"))
        XCTAssertTrue(script.contains("function syncAssetLocalSuggestionState("))
        XCTAssertTrue(script.contains("function createAssetLocalSuggestionRow("))
        XCTAssertTrue(script.contains("function syncAssetLocalSuggestionRow("))
        XCTAssertTrue(script.contains("function reconcileAssetLocalSuggestionRows("))
        XCTAssertTrue(script.contains("data-local-suggestion-row-id"))
        XCTAssertTrue(script.contains("applyQuickTagFilter"))
        XCTAssertTrue(script.contains("function moveLibrarySelection(key, { extendRange = false } = {})"))
        XCTAssertTrue(script.contains("selectLibraryAssetByIndex(nextIndex, { focusGrid: true, extendRange })"))
        XCTAssertTrue(script.contains("ArrowLeft ArrowRight ArrowUp ArrowDown Home End PageUp PageDown Space"))
        XCTAssertTrue(script.contains("扩展连续选择"))
        XCTAssertTrue(script.contains("startMarqueeSelection"))
        XCTAssertTrue(script.contains("function marqueeAutoScrollStep"))
        XCTAssertTrue(script.contains("function marqueeSelectionBounds"))
        XCTAssertTrue(script.contains("function cardIntersectsMarquee"))
        XCTAssertTrue(script.contains("function scheduleMarqueeAutoScroll"))
        XCTAssertTrue(script.contains("function stopMarqueeAutoScroll"))
        XCTAssertTrue(script.contains("function renderLibraryMarqueeSelection"))
        XCTAssertTrue(script.contains("function renderReviewMarqueeSelection"))
        XCTAssertTrue(script.contains("function deferReviewQueueRefreshUntilMarqueeEnds"))
        XCTAssertTrue(script.contains("function reviewMarqueeBlocksQueueRefresh"))
        XCTAssertTrue(script.contains("function flushDeferredReviewQueueRefresh"))
        XCTAssertTrue(script.contains("state.review.deferredQueueRefresh"))
        XCTAssertTrue(script.contains("function renderSlimmingMarqueeSelection"))
        XCTAssertTrue(script.contains("function slimmingMemberScrollContainer"))
        XCTAssertTrue(script.contains("function autoPaginateReviewQueueIfNeeded"))
        XCTAssertTrue(script.contains("function scheduleReviewAutoPagination"))
        XCTAssertTrue(script.contains("renderAssetSelectionState"))
        XCTAssertTrue(script.contains("openCommandPalette"))
        XCTAssertTrue(script.contains("function keyboardShortcutsContextSnapshot("))
        XCTAssertTrue(script.contains("function keyboardShortcutSections("))
        XCTAssertTrue(script.contains("function renderKeyboardShortcuts("))
        for shortcutID in [
            "galleryNavigate",
            "reviewDecision",
            "trainingPrimary",
            "slimmingNavigate",
            "worldMapReturn",
            "galleryOverviewReturn",
            "previewZoom",
            "previewReviewDecision",
        ] {
            XCTAssertTrue(script.contains("id: \"\(shortcutID)\""))
        }
        for commandID in [
            "openReviewSources",
            "newTrainingTask",
            "toggleTrainingNavigator",
            "openSlimmingSetup",
            "openSlimmingThresholdEditor",
            "toggleSlimmingNavigator",
            "showSlimmingRecycle",
            "showSlimmingAnalysis",
            "openWorldMapPlaceTags",
            "openWorldMapLocationBackfill",
            "browseWorldMapCluster",
        ] {
            XCTAssertTrue(script.contains("id: \"\(commandID)\""))
            XCTAssertTrue(script.contains("case \"\(commandID)\":"))
        }
        XCTAssertTrue(script.contains("persistWorkspacePreferences"))
        XCTAssertTrue(script.contains("new IntersectionObserver"))
        XCTAssertTrue(script.contains("expandedRefreshKinds"))
        XCTAssertTrue(script.contains("loadTrainingWorkspace"))
        XCTAssertTrue(script.contains("renderTrainingDetail"))
        XCTAssertTrue(script.contains("storageMaintenanceActiveRequest"))
        XCTAssertTrue(script.contains("可继续浏览，点击查看"))
        XCTAssertTrue(script.contains("selectionPrimaryAssetID"))
        XCTAssertTrue(script.contains("loadSelectionPrimaryDetail"))
        XCTAssertTrue(script.contains("trainingRunListContextKey"))
        XCTAssertTrue(script.contains("captureTrainingRunListScroll"))
        XCTAssertTrue(script.contains("currentActiveTrainingActivity"))
        XCTAssertTrue(script.contains("openTrainingSetupDialog"))
        XCTAssertTrue(script.contains("openTrainingSetupForRun"))
        XCTAssertTrue(script.contains("openAssociatedJob"))
        XCTAssertTrue(script.contains("function reconcileTrainingDetailActions("))
        XCTAssertTrue(script.contains("data-training-detail-action-key"))
        XCTAssertFalse(script.contains("clearElement(elements.trainingDetailActions)"))
        XCTAssertTrue(script.contains("submitTrainingSetup"))
        XCTAssertTrue(script.contains("renderSlimmingWorkspace"))
        XCTAssertTrue(script.contains("renderIdenticalCleanupBlockingOverlay"))
        XCTAssertTrue(script.contains("identicalCleanupExecutionPresentation"))
        XCTAssertTrue(script.contains("hasSlimmingVerificationReport"))
        XCTAssertTrue(script.contains("verificationUnavailableMessage"))
        XCTAssertTrue(script.contains("未显示未经证实的保留数量"))
        XCTAssertTrue(script.contains("目标是保留全部红心资产"))
        XCTAssertTrue(script.contains("selectSlimmingMember"))
        XCTAssertTrue(script.contains("showSlimmingMemberContextMenu"))
        XCTAssertTrue(script.contains("data-slimming-member-context-action"))
        XCTAssertTrue(script.contains("function reconcileContextMenuActionButtons("))
        XCTAssertTrue(script.contains("data-context-action-part=\"label\""))
        XCTAssertTrue(script.contains("data-context-action-part=\"shortcut\""))
        XCTAssertFalse(script.contains("elements.slimmingMemberContextMenuActions.replaceChildren()"))
        XCTAssertFalse(script.contains("elements.slimmingJobContextMenuActions.replaceChildren()"))
        XCTAssertFalse(script.contains("elements.sourceContextMenuActions.replaceChildren()"))
        XCTAssertFalse(script.contains("elements.tagContextMenuActions.replaceChildren()"))
        XCTAssertTrue(script.contains("renderSlimmingClusterScopes"))
        XCTAssertTrue(script.contains("query.set(\"jobLimit\""))
        XCTAssertTrue(script.contains("expandSlimmingJobWindow"))
        XCTAssertTrue(script.contains("totalJobCount"))
        XCTAssertTrue(script.contains("setSlimmingClusterReviewDisposition"))
        XCTAssertTrue(script.contains("isHistoricalProcessedRecord"))
        XCTAssertTrue(script.contains("历史处理记录"))
        XCTAssertTrue(script.contains("showSlimmingJobContextMenu"))
        XCTAssertTrue(script.contains("data-slimming-job-context-action"))
        XCTAssertTrue(stylesheet.contains(".slimming-cluster-scopes"))
        XCTAssertTrue(stylesheet.contains(".slimming-cluster-review-button"))
        XCTAssertTrue(stylesheet.contains(".slimming-cluster-history-mark"))
        XCTAssertTrue(stylesheet.contains(".slimming-navigator-pane"))
        XCTAssertTrue(stylesheet.contains("clamp(196px, 22vw, 244px)"))
        XCTAssertTrue(stylesheet.contains(".slimming-inspector:not([open])"))
        XCTAssertTrue(stylesheet.contains(".slimming-recycle-heading"))
        XCTAssertTrue(stylesheet.contains("minmax(min(380px, 100%), 640px)"))
        XCTAssertTrue(script.contains("elements.slimmingNavigatorPane.scrollTop"))
        XCTAssertTrue(script.contains("elements.slimmingInspector.open = false"))
        XCTAssertTrue(script.contains("function renderSlimmingRecycleHeader"))
        XCTAssertTrue(script.contains("elements.slimmingRecycleEmptyAction.dataset.action"))
        XCTAssertTrue(script.contains("renderSlimmingRecycleScopes"))
        XCTAssertTrue(script.contains("toggleSlimmingNavigator"))
        XCTAssertTrue(script.contains("replacementSlimmingPreviewAssetID"))
        XCTAssertTrue(script.contains("[\"Backspace\", \"Delete\"].includes(event.key)"))
        XCTAssertTrue(script.contains("scope: recycle.scope"))
        XCTAssertTrue(script.contains("state.layout.density"))
        XCTAssertTrue(script.contains("GRID_DENSITY_OPTIONS"))
        XCTAssertTrue(script.contains("GRID_DENSITY_SCALE_VERSION"))
        XCTAssertTrue(script.contains("migrateLegacyGridDensity"))
        XCTAssertTrue(script.contains("微缩"))
        XCTAssertTrue(script.contains("巨大"))
        XCTAssertFalse(html.contains("gridDensitySlider"))
        XCTAssertFalse(html.contains("reviewGridDensitySlider"))
        XCTAssertFalse(html.contains("slimmingGridDensitySlider"))
        XCTAssertTrue(script.contains("state.layout.aspectMode"))
        XCTAssertTrue(script.contains("thumbnailAspectPresentation"))
        XCTAssertTrue(script.contains("syncThumbnailRenderedAspect"))
        XCTAssertTrue(script.contains("当前缩略图为正方形"))
        XCTAssertTrue(script.contains("当前优先显示已手动缓存的原比例缩略图"))
        XCTAssertTrue(html.contains("thumbnail-aspect-label\">正方形"))
        XCTAssertFalse(html.contains("aria-pressed=\"false\" title=\"完整显示照片宽高比\""))
        XCTAssertTrue(html.contains("library-toolbar-mode-button"))
        XCTAssertTrue(html.contains("library-toolbar-label"))
        XCTAssertTrue(stylesheet.contains("data-toolbar-display-mode=\"iconOnly\""))
        XCTAssertTrue(stylesheet.contains(".library-toolbar-mode-button"))
        XCTAssertTrue(stylesheet.contains(".personal-model-toolbar-actions"))
        XCTAssertTrue(stylesheet.contains("@container library-workspace"))
        XCTAssertTrue(script.contains("syncPersonalModelToolbarPresentation"))
        XCTAssertTrue(script.contains("syncSelectionFavoriteToolbarPresentation"))
        XCTAssertTrue(script.contains("syncPersonalModelSelectionActionPresentation"))
        XCTAssertTrue(script.contains("elements.toolbarFavoriteSelectedButton"))
        XCTAssertTrue(script.contains("elements.toolbarUnfavoriteSelectedButton"))
        XCTAssertTrue(script.contains("toolbarRebuildPersonalModelButton"))
        XCTAssertTrue(script.contains("loadTrainingActivities"))
        XCTAssertTrue(script.contains("personalModelOperationState"))
        XCTAssertTrue(script.contains("/v1/training/activities"))
        XCTAssertTrue(script.contains("const connectionChanged = previousOnline !== online"))
        XCTAssertTrue(script.contains("online && previousOnline && previousLabel"))
        XCTAssertTrue(script.contains("renderSampleSuggestions();\n  syncInlineTagCreationControls();"))
        XCTAssertTrue(script.contains("function beginSplitResize"))
        XCTAssertTrue(script.contains("function adjustSplitWidthFromKeyboard"))
        XCTAssertTrue(script.contains("sidebarWidth: state.layout.sidebarWidth"))
        XCTAssertTrue(script.contains("inspectorWidth: state.layout.inspectorWidth"))
        XCTAssertTrue(script.contains("reviewModelWidth: state.layout.reviewModelWidth"))
        XCTAssertTrue(script.contains("reviewInspectorWidth: state.layout.reviewInspectorWidth"))
        XCTAssertTrue(script.contains("REVIEW_MODEL_WIDTH"))
        XCTAssertTrue(script.contains("REVIEW_INSPECTOR_WIDTH"))
        XCTAssertTrue(stylesheet.contains(".split-resize-handle"))
        XCTAssertTrue(stylesheet.contains("--sidebar-width"))
        XCTAssertTrue(stylesheet.contains("--inspector-width"))
        XCTAssertTrue(stylesheet.contains("--review-model-width"))
        XCTAssertTrue(stylesheet.contains(".review-overview-resize-handle"))
        XCTAssertTrue(stylesheet.contains("--review-inspector-width"))
        XCTAssertTrue(stylesheet.contains(".review-queue-resize-handle"))
        XCTAssertTrue(script.contains("openSlimmingSetupDialog"))
        XCTAssertTrue(script.contains("submitSlimmingSetup"))
        XCTAssertTrue(script.contains("saveSlimmingThresholds"))
        XCTAssertTrue(script.contains("applySlimmingJobAction"))
        XCTAssertTrue(script.contains("allSourcesSelected ? null : selectedSourceIDs"))
        XCTAssertTrue(script.contains("state.slimming.selectedMemberIDs = new Set"))
        XCTAssertTrue(script.contains("trainingLaunchUnavailable"))
        XCTAssertTrue(script.contains("assetLoadPromise"))
        XCTAssertTrue(script.contains("assetQuerySignature"))
        XCTAssertTrue(script.contains("renderReviewOverview"))
        XCTAssertTrue(script.contains("function currentReviewQueueOverview()"))
        XCTAssertTrue(script.contains("function currentReviewOverviewScopeKey()"))
        XCTAssertTrue(script.contains("function reviewQueueSummaryText({ selectedCount = 0 } = {})"))
        XCTAssertTrue(script.contains("function reviewQueueEmptyState()"))
        XCTAssertTrue(script.contains("function renderReviewEmptyState()"))
        XCTAssertTrue(script.contains("function reviewWorkspaceTitleText()"))
        XCTAssertTrue(script.contains("function renderReviewWorkspaceTitle()"))
        XCTAssertTrue(script.contains("return displayName ? `审核“${displayName}”建议` : \"审核建议\""))
        XCTAssertTrue(script.contains("elements.reviewWorkspace.setAttribute(\"aria-label\", accessibilityTitle)"))
        XCTAssertTrue(script.contains("reviewSourceIDs: resolvedReviewSourceFilter()"))
        XCTAssertTrue(script.contains("function applyReviewSourceFilterHistoryContext(context = {})"))
        XCTAssertTrue(script.contains("applyReviewSourceFilterHistoryContext(context)"))
        XCTAssertTrue(script.contains("reviewSelectionMode: state.review.mode === \"queue\""))
        XCTAssertTrue(script.contains("reviewSelectedAssetIDs: state.review.mode === \"queue\""))
        XCTAssertTrue(script.contains("reviewSelectionAnchorKey: state.review.mode === \"queue\""))
        XCTAssertTrue(script.contains("reviewGridScrollLeft: elements.reviewGrid.scrollLeft"))
        XCTAssertTrue(script.contains("function applyReviewSelectionHistoryContext(context = {})"))
        XCTAssertTrue(script.contains("checkpointWorkspaceHistoryAfterApply"))
        XCTAssertTrue(script.contains("galleryContext: currentGalleryHistoryContext()"))
        XCTAssertTrue(html.contains("id=\"slimmingSetupNotice\""))
        XCTAssertTrue(script.contains("function currentSlimmingSetupHistoryContext()"))
        XCTAssertTrue(script.contains("function applySlimmingSetupHistoryContext(context = {})"))
        XCTAssertTrue(script.contains("async function restoreSlimmingSetupLayoutFromHistory"))
        XCTAssertTrue(script.contains("slimmingSetupThresholdsOpen"))
        XCTAssertTrue(script.contains("[\"automatic\", \"always\", \"never\"].includes"))
        XCTAssertTrue(script.contains("const workspaceSnapshot = historyContext"))
        XCTAssertTrue(script.contains("if (awaitCatalogSources) await catalogSourcesPromise"))
        XCTAssertTrue(script.contains("function currentTrainingSetupHistoryContext()"))
        XCTAssertTrue(script.contains("function applyTrainingSetupHistoryContext(context = {})"))
        XCTAssertTrue(script.contains("async function restoreTrainingSetupScrollFromHistory"))
        XCTAssertTrue(script.contains("historyMode: \"none\""))
        XCTAssertTrue(script.contains("historyContext: context"))
        XCTAssertTrue(
            script.contains(
                "preserveSelection: state.review.selectedAssetIDs.size > 1"
            )
        )
        XCTAssertTrue(script.contains("reviewQueueMissingSamplesDescription(overview)"))
        XCTAssertTrue(script.contains("title: \"样本不足\""))
        XCTAssertTrue(script.contains("title: \"正在生成建议\""))
        XCTAssertTrue(script.contains("title: \"已全部审核\""))
        XCTAssertTrue(script.contains("title: \"任务失败\""))
        XCTAssertTrue(
            script.contains(
                "state.review.overviewLoadedScopeKey !== currentReviewOverviewScopeKey()"
            )
        )
        XCTAssertTrue(script.contains("state.review.loadedScopeKey === currentReviewScopeKey()"))
        XCTAssertTrue(script.contains("loadedCount <= pendingCount"))
        XCTAssertTrue(script.contains("!hasMore || loadedCount < pendingCount"))
        XCTAssertTrue(script.contains("正在分析 · 已检查 ${checkedText} · 跳过 ${skipped}"))
        XCTAssertTrue(
            script.contains(
                "if (state.review.mode === \"queue\") renderReviewCollectionSummary();"
            )
        )
        XCTAssertFalse(script.contains("`待审核 ${state.review.items.length} 项"))
        XCTAssertTrue(html.contains("id=\"reviewEmptyTitle\""))
        XCTAssertTrue(html.contains("id=\"reviewEmptyDescription\""))
        XCTAssertTrue(html.contains("id=\"reviewWorkspaceTitle\">待审核建议"))
        XCTAssertTrue(html.contains("id=\"reviewEmpty\" class=\"review-empty\" role=\"status\""))
        XCTAssertTrue(stylesheet.contains(".review-empty[data-state=\"failure\"] > span"))
        XCTAssertTrue(stylesheet.contains(".review-empty[data-state=\"complete\"] > span"))
        XCTAssertTrue(stylesheet.contains("max-width: min(28vw, 240px)"))
        XCTAssertTrue(stylesheet.contains("text-overflow: ellipsis"))
        XCTAssertTrue(script.contains("renderTagManager"))
        XCTAssertTrue(script.contains("installPresetTags"))
        XCTAssertTrue(script.contains("/v1/tags/install-presets"))
        XCTAssertTrue(script.contains("开始建立你的照片资料库"))
        XCTAssertTrue(script.contains("setupSidebarReordering"))
        XCTAssertTrue(script.contains("sourceSidebarHelpDetail"))
        XCTAssertTrue(script.contains("button.dataset.helpKind = \"source\""))
        XCTAssertTrue(script.contains("CONTEXT_LONG_PRESS_DELAY_MS = 520"))
        XCTAssertTrue(script.contains("CONTEXT_LONG_PRESS_MOVE_TOLERANCE = 11"))
        XCTAssertTrue(script.contains("function contextLongPressDescriptor"))
        XCTAssertTrue(script.contains("function beginContextLongPress"))
        XCTAssertTrue(script.contains("showSourceContextMenu(x, y, source.dataset.sourceId)"))
        XCTAssertTrue(script.contains("function applySourceManagementSourcesToWorkspace(sources)"))
        XCTAssertTrue(script.contains("applySourceManagementSourcesToWorkspace(snapshot.sources)"))
        XCTAssertFalse(script.contains("refreshWorkspace({ quiet: true, kinds: [\"sourcesChanged\"] })"))
        XCTAssertTrue(script.contains("function showReviewContextMenu"))
        XCTAssertTrue(script.contains("function toggleReviewItemFavorite"))
        XCTAssertTrue(
            script.contains(
                "showReviewContextMenu(event.clientX, event.clientY, card.dataset.reviewKey)"
            )
        )
        XCTAssertTrue(script.contains("reviewCard.dataset.reviewKey"))
        XCTAssertTrue(script.contains("visibleWorkspaceRoute() !== \"gallery\""))
        XCTAssertTrue(script.contains("visibleWorkspaceRoute() === \"gallery\""))
        XCTAssertTrue(script.contains("galleryAssetsRefreshPending"))
        XCTAssertTrue(script.contains("function scheduleDeferredGalleryAssetsRefresh"))
        XCTAssertTrue(script.contains("requestSourceManagementAction(action, sourceID)"))
        XCTAssertTrue(script.contains("[\"actionMenu\", \"layoutMenu\"].includes(current?.navigationLevel)"))
        XCTAssertTrue(stylesheet.contains(".context-long-press-active"))
        XCTAssertTrue(script.contains("setSidebarTagData(button, \"helpTitle\", tag.displayName)"))
        XCTAssertTrue(script.contains("当前：${stateLabel}"))
        XCTAssertTrue(script.contains("Shift+F10 ContextMenu"))
        XCTAssertTrue(stylesheet.contains(".persistent-help[data-kind=\"source\"]"))
        XCTAssertTrue(script.contains("sourceOrderIDs"))
        XCTAssertTrue(script.contains("tagOrderIDsByGroup"))
        XCTAssertTrue(script.contains("label: \"上移来源\""))
        XCTAssertTrue(script.contains("label: \"下移来源\""))
        XCTAssertTrue(script.contains("label: \"在分组内前移\""))
        XCTAssertTrue(script.contains("label: \"移到下一分组\""))
        XCTAssertTrue(script.contains("reorderSourceByOffset(sourceID, action === \"moveEarlier\" ? -1 : 1)"))
        XCTAssertTrue(script.contains("moveSidebarTagToAdjacentGroup(tagID, 1)"))
        XCTAssertTrue(script.contains("collapsedSidebarTagGroupIDs"))
        XCTAssertTrue(script.contains("collapsedTagGroupIDs"))
        XCTAssertTrue(script.contains("toggleSharedTagGroupCollapsed"))
        XCTAssertTrue(script.contains("function handleTagGroupNavigationKeydown"))
        XCTAssertTrue(script.contains("function tagGroupNavigationViewport"))
        XCTAssertTrue(script.contains("ArrowLeft ArrowRight ArrowUp ArrowDown PageUp PageDown Home End"))
        XCTAssertTrue(script.contains("target?.scrollIntoView({ block: \"nearest\", inline: \"nearest\" })"))
        XCTAssertTrue(script.contains("tagReturnFocusDescriptor"))
        XCTAssertTrue(script.contains("resolveTagReturnFocusTarget"))
        XCTAssertTrue(script.contains("renderTagNavigation();"))
        XCTAssertTrue(script.contains("data-sidebar-tag-group-toggle"))
        XCTAssertTrue(script.contains("data-tag-reorder-surface"))
        XCTAssertTrue(script.contains("setInspectorTagData(chip, \"tagReorderSurface\", surface)"))
        XCTAssertTrue(script.contains("moveSidebarTagToAdjacentGroup"))
        XCTAssertTrue(script.contains("toggleSidebarTagFilter"))
        XCTAssertTrue(script.contains("showTagContextMenu"))
        XCTAssertTrue(script.contains("showTagGroupContextMenu"))
        XCTAssertTrue(script.contains("data-tag-context-action"))
        XCTAssertTrue(script.contains("function setSelectOptions"))
        XCTAssertTrue(script.contains("const existingOptions = new Map("))
        XCTAssertTrue(script.contains("reconcileStableChildren(select, wantedOptions)"))
        XCTAssertFalse(script.contains("clearElement(select);"))
        XCTAssertTrue(script.contains("openTagManagerForTag"))
        XCTAssertTrue(script.contains("undoLatestDecision"))
        XCTAssertTrue(script.contains("state.undo.tag"))
        XCTAssertTrue(script.contains("state.undo.review"))
        XCTAssertFalse(script.contains("operationID: crypto.randomUUID(), undoID"))
        XCTAssertTrue(script.contains("protectedImageRequests"))
        XCTAssertTrue(script.contains("protectedImageAbortControllers"))
        XCTAssertTrue(script.contains("protectedImageIntersectionObserver"))
        XCTAssertTrue(script.contains("startProtectedImageRequest"))
        XCTAssertTrue(script.contains("image.loading === \"lazy\""))
        XCTAssertTrue(script.contains("rootMargin: \"600px\""))
        XCTAssertTrue(script.contains("{ priority: \"high\","))
        XCTAssertTrue(script.contains("assetThumbnailPlaceholder"))
        XCTAssertTrue(script.contains("showPreviewPlaceholder"))
        XCTAssertTrue(script.contains("hidePreviewPlaceholder"))
        XCTAssertTrue(script.contains("cloud preview required"))
        XCTAssertTrue(script.contains("downloadSelectedCloudPreview"))
        XCTAssertTrue(script.contains("/cloud-preview"))
        XCTAssertTrue(script.contains("supportsCloudPreviewLifecycle"))
        XCTAssertTrue(script.contains("/cloud-preview-requests"))
        XCTAssertTrue(script.contains("cancelSelectedCloudPreview"))
        XCTAssertTrue(script.contains("forceFetch: true"))
        XCTAssertTrue(script.contains("showInspectorVideo"))
        XCTAssertTrue(script.contains("function beginAssetHoverVideo"))
        XCTAssertTrue(script.contains("async function mountAssetHoverVideo"))
        XCTAssertTrue(script.contains("function stopAssetHoverVideo"))
        XCTAssertTrue(script.contains("video.muted = true"))
        XCTAssertTrue(script.contains("video.loop = true"))
        XCTAssertTrue(script.contains("asset-video-badge"))
        XCTAssertTrue(script.contains("function navigateWorldMapPhotoStrip(event)"))
        XCTAssertTrue(script.contains("worldMapPhotoNavigate"))
        XCTAssertTrue(script.contains("button.dataset.worldMapPhotoLabel"))
        XCTAssertTrue(script.contains("第 ${index + 1} 张，共 ${cards.length} 张"))
        XCTAssertTrue(script.contains("Math.floor(elements.worldMapPhotoStrip.clientWidth / stride)"))
        XCTAssertTrue(script.contains("prefers-reduced-motion: reduce"))
        XCTAssertTrue(script.contains("updateMediaWorkerAuthorization"))
        XCTAssertTrue(mediaWorker.contains("headers.set(\"Authorization\", authorization)"))
        XCTAssertTrue(mediaWorker.contains("event.request.headers"))
        XCTAssertTrue(mediaWorker.contains("requestAuthorizationFromClient(event.clientId)"))
        XCTAssertTrue(mediaWorker.contains("self.clients.matchAll"))
        XCTAssertTrue(mediaWorker.contains("includeUncontrolled: false"))
        XCTAssertTrue(mediaWorker.contains("new Request(event.request.url"))
        XCTAssertTrue(mediaWorker.contains("mode: \"same-origin\""))
        XCTAssertTrue(script.contains("imageall-media-authorization-request"))
        XCTAssertTrue(script.contains("updateViaCache: \"none\""))
        XCTAssertTrue(script.contains("navigator.serviceWorker.controller?.scriptURL !== expectedURL"))
        XCTAssertTrue(script.contains("elements.previewVideo.dataset.contentRevision === contentRevision"))
        XCTAssertTrue(script.contains("formatDuration(detail.durationMs)"))
        XCTAssertTrue(script.contains("formatFileSize(detail.fingerprintSizeBytes)"))
        XCTAssertTrue(script.contains("openSelectedOriginalOnMac"))
        XCTAssertFalse(mediaWorker.contains("localStorage"))
        XCTAssertTrue(script.contains("state.layout.aspectMode"))
        XCTAssertTrue(script.contains("已显示缩略图，大图暂不可用"))
        XCTAssertTrue(script.contains("new AbortController()"))
        XCTAssertTrue(script.contains("imageall-protected-load"))
        XCTAssertTrue(script.contains("card.dataset.reviewKey = reviewItemKey(item)"))
        XCTAssertTrue(script.contains("scheduleProjectionPoll"))
        XCTAssertTrue(script.contains("PROJECTION_POLL_INTERACTION_SETTLE_MS"))
        XCTAssertTrue(script.contains("function markWorkspaceInteraction()"))
        XCTAssertTrue(script.contains("function bindWorkspaceInteractionDeferral()"))
        XCTAssertTrue(script.contains("state.authMode === \"pairedDevice\""))
        XCTAssertTrue(script.contains("scheduleProjectionPoll(generation, Math.ceil(settleRemaining))"))
        XCTAssertTrue(script.contains("currentReviewScopeKey"))
        XCTAssertTrue(script.contains("state.workspaceGeneration"))
        XCTAssertTrue(script.contains("pendingRestoreEntry"))
        XCTAssertTrue(script.contains("function checkpointActiveWorkspaceHistory()"))
        XCTAssertTrue(script.contains("trainingDetailScrollTop"))
        XCTAssertTrue(script.contains("galleryLoadedCount"))
        XCTAssertTrue(script.contains("normalizedGalleryHistoryContext"))
        XCTAssertTrue(script.contains("normalizedLightboxHistoryContext"))
        XCTAssertTrue(script.contains("currentLightboxHistoryContext"))
        XCTAssertTrue(script.contains("restoreLightboxFromHistory"))
        XCTAssertTrue(script.contains("galleryLightbox"))
        XCTAssertTrue(script.contains("reviewLightbox"))
        XCTAssertTrue(script.contains("slimmingLightbox"))
        XCTAssertTrue(script.contains("worldMapLightbox"))
        XCTAssertTrue(script.contains("const safeNavigationLevel"))
        XCTAssertTrue(script.contains("mode === \"pushLightbox\""))
        XCTAssertTrue(script.contains("mode === \"pushInspector\""))
        XCTAssertTrue(script.contains("mode === \"pushSidebar\""))
        XCTAssertTrue(script.contains("\"pushToolbarMenu\""))
        XCTAssertTrue(script.contains("\"pushCommandPalette\""))
        XCTAssertTrue(script.contains("\"pushJobs\""))
        XCTAssertTrue(script.contains("\"pushFilter\""))
        XCTAssertTrue(script.contains("\"pushLayoutMenu\""))
        XCTAssertTrue(script.contains("\"pushActionMenu\""))
        XCTAssertTrue(script.contains("\"pushContextMenu\""))
        XCTAssertTrue(script.contains("\"pushGeneralSettings\""))
        XCTAssertTrue(script.contains("\"pushSuggestionThreshold\""))
        XCTAssertTrue(script.contains("\"pushKeyboardShortcuts\""))
        XCTAssertTrue(script.contains("\"pushSourceManager\""))
        XCTAssertTrue(script.contains("\"pushStorageMaintenance\""))
        XCTAssertTrue(script.contains("\"pushConfirmation\""))
        XCTAssertTrue(script.contains("\"pushNewTag\""))
        XCTAssertTrue(script.contains("\"pushTagManager\""))
        XCTAssertTrue(script.contains("\"pushTrainingSetup\""))
        XCTAssertTrue(script.contains("\"pushTagSuggestion\""))
        XCTAssertTrue(script.contains("\"pushSlimmingSetup\""))
        XCTAssertTrue(script.contains("\"pushSlimmingThreshold\""))
        XCTAssertTrue(script.contains("\"pushSlimmingIdenticalCleanup\""))
        XCTAssertTrue(script.contains("\"pushSlimmingVerification\""))
        XCTAssertTrue(script.contains("\"pushSlimmingRecycleExplanation\""))
        XCTAssertTrue(script.contains("\"pushWorldMapLocationBackfill\""))
        XCTAssertTrue(script.contains("\"pushWorldMapPlaceTags\""))
        XCTAssertTrue(script.contains("function reconcileLightboxFromWorkspaceHistory"))
        XCTAssertTrue(script.contains("function reconcileGalleryInspectorFromWorkspaceHistory"))
        XCTAssertTrue(script.contains("function reconcileMobileSidebarFromWorkspaceHistory"))
        XCTAssertTrue(script.contains("function reconcileCompactToolbarMenuFromWorkspaceHistory"))
        XCTAssertTrue(script.contains("function reconcileCommandPaletteFromWorkspaceHistory"))
        XCTAssertTrue(script.contains("function reconcileJobsPopoverFromWorkspaceHistory"))
        XCTAssertTrue(script.contains("function reconcileFilterPopoverFromWorkspaceHistory"))
        XCTAssertTrue(script.contains("function reconcileLayoutMenuFromWorkspaceHistory"))
        XCTAssertTrue(script.contains("function reconcileActionMenuFromWorkspaceHistory"))
        XCTAssertTrue(script.contains("function returnFromActionMenu"))
        XCTAssertTrue(script.contains("function activeContextMenuDescriptor"))
        XCTAssertTrue(script.contains("function returnFromContextMenu"))
        XCTAssertTrue(script.contains("function reconcileContextMenuFromWorkspaceHistory"))
        XCTAssertTrue(script.contains("contextMenuKind"))
        XCTAssertTrue(script.contains("function reconcileGeneralSettingsFromWorkspaceHistory"))
        XCTAssertTrue(script.contains("function reconcileKeyboardShortcutsFromWorkspaceHistory"))
        XCTAssertTrue(script.contains("function reconcileSourceManagerFromWorkspaceHistory"))
        XCTAssertTrue(script.contains("function reconcileStorageMaintenanceFromWorkspaceHistory"))
        XCTAssertTrue(script.contains("function reconcileConfirmationFromWorkspaceHistory"))
        XCTAssertTrue(script.contains("function reconcileNewTagFromWorkspaceHistory"))
        XCTAssertTrue(script.contains("function reconcileTagManagerFromWorkspaceHistory"))
        XCTAssertTrue(script.contains("function reconcileTrainingSetupFromWorkspaceHistory"))
        XCTAssertTrue(script.contains("function reconcileTagSuggestionFromWorkspaceHistory"))
        XCTAssertTrue(script.contains("function currentTagSuggestionHistoryContext"))
        XCTAssertTrue(script.contains("function applyTagSuggestionHistoryContext"))
        XCTAssertTrue(script.contains("function restoreTagSuggestionLayoutFromHistory"))
        XCTAssertTrue(script.contains("tagSuggestionSourcesScrollTop"))
        XCTAssertTrue(script.contains("function tagLibrarySuggestionMethodAvailable"))
        XCTAssertTrue(script.contains(
            "applyWorkspaceHistoryEntry(restoreEntry, { restoringReload: true })"
        ))
        XCTAssertTrue(script.contains("refreshTagSuggestions: !restoringReload"))
        XCTAssertFalse(script.contains(
            "checkpointWorkspaceHistoryAfterApply ||= await reconcileTagSuggestionFromWorkspaceHistory"
        ))
        XCTAssertTrue(script.contains("function reconcileSlimmingSetupFromWorkspaceHistory"))
        XCTAssertTrue(script.contains("function reconcileSlimmingThresholdFromWorkspaceHistory"))
        XCTAssertTrue(script.contains("function reconcileSlimmingIdenticalCleanupFromWorkspaceHistory"))
        XCTAssertTrue(script.contains("function reconcileSlimmingVerificationFromWorkspaceHistory"))
        XCTAssertTrue(script.contains("function reconcileSlimmingRecycleExplanationFromWorkspaceHistory"))
        XCTAssertTrue(script.contains("function reconcileWorldMapLocationBackfillFromWorkspaceHistory"))
        XCTAssertTrue(script.contains("function reconcileWorldMapPlaceTagsFromWorkspaceHistory"))
        XCTAssertTrue(script.contains("function returnFromLightbox()"))
        XCTAssertTrue(script.contains("function returnFromInspector()"))
        XCTAssertTrue(script.contains("function returnFromMobileSidebar()"))
        XCTAssertTrue(script.contains("function returnFromCompactToolbarMenu"))
        XCTAssertTrue(script.contains("function returnFromCommandPalette"))
        XCTAssertTrue(script.contains("function returnFromJobsPopover"))
        XCTAssertTrue(script.contains("function returnFromFilterPopover"))
        XCTAssertTrue(script.contains("function returnFromLayoutMenu"))
        XCTAssertTrue(script.contains("function returnFromGeneralSettings"))
        XCTAssertTrue(script.contains("function returnFromSuggestionThreshold"))
        XCTAssertTrue(script.contains("function returnFromKeyboardShortcuts"))
        XCTAssertTrue(script.contains("function returnFromSourceManager"))
        XCTAssertTrue(script.contains("function returnFromStorageMaintenance"))
        XCTAssertTrue(script.contains("function returnFromConfirmation"))
        XCTAssertTrue(script.contains("function returnFromNewTag"))
        XCTAssertTrue(script.contains("function returnFromTagManager"))
        XCTAssertTrue(script.contains("function returnFromTrainingSetup"))
        XCTAssertTrue(script.contains("function returnFromTagSuggestion"))
        XCTAssertTrue(script.contains("function returnFromSlimmingSetup"))
        XCTAssertTrue(script.contains("function returnFromSlimmingThreshold"))
        XCTAssertTrue(script.contains("function returnFromSlimmingIdenticalCleanup"))
        XCTAssertTrue(script.contains("function returnFromSlimmingVerification"))
        XCTAssertTrue(script.contains("function returnFromSlimmingRecycleExplanation"))
        XCTAssertTrue(script.contains("function returnFromWorldMapLocationBackfill"))
        XCTAssertTrue(script.contains("function returnFromWorldMapPlaceTags"))
        XCTAssertTrue(html.contains("id=\"slimmingL2Distance\" type=\"number\" min=\"0\" max=\"200\" step=\"any\""))
        XCTAssertTrue(script.contains("function openSelectionInspectorOverlay()"))
        XCTAssertTrue(script.contains("function openGalleryInspectorOverlay"))
        XCTAssertTrue(script.contains("function toggleInspectorVisibility"))
        XCTAssertTrue(script.contains("inspectorVisibilityIsPresented() ? \"隐藏检查器\" : \"显示检查器\""))
        XCTAssertTrue(script.contains("compactToolbarAction(elements.inspectorVisibilityButton"))
        XCTAssertTrue(script.contains("function toggleSidebarVisibility"))
        XCTAssertTrue(script.contains("sidebarVisibilityIsPresented() ? \"隐藏侧栏\" : \"显示侧栏\""))
        XCTAssertTrue(script.contains("openMobileSidebar({ returnFocus })"))
        XCTAssertTrue(script.contains("state.sidebarOverlayReturnFocus = returnFocus instanceof HTMLElement"))
        XCTAssertTrue(script.contains("function openJobsPopover({"))
        XCTAssertTrue(script.contains("const origin = returnFocus instanceof HTMLElement"))
        XCTAssertTrue(script.contains("openJobsPopover({\n      returnFocus: commandReturnFocus"))
        XCTAssertTrue(script.contains("function openJobsFromKeyboardShortcut()"))
        XCTAssertTrue(script.contains("openJobsFromKeyboardShortcut();"))
        XCTAssertTrue(script.contains("if (alreadyOpen) return;"))
        XCTAssertTrue(script.contains("function trainingWorkspaceContentFingerprint()"))
        XCTAssertTrue(script.contains("function trainingWorkspaceCanPreserveContent()"))
        XCTAssertTrue(script.contains("function galleryOverviewContentFingerprint()"))
        XCTAssertTrue(script.contains("function galleryOverviewCanPreserveContent()"))
        XCTAssertTrue(script.contains("function syncGalleryOverviewText("))
        XCTAssertTrue(script.contains("function syncGalleryOverviewMediaCard("))
        XCTAssertTrue(script.contains("function syncGalleryOverviewBarRow("))
        XCTAssertTrue(script.contains("function reconcileGalleryOverviewMediaCards("))
        XCTAssertTrue(
            script.contains(
                "syncGalleryOverviewText(elements.galleryOverviewTotalMetric"
            )
        )
        XCTAssertTrue(
            script.contains(
                "syncGalleryOverviewText(year.querySelector(\":scope > span\"), key)"
            )
        )
        XCTAssertFalse(
            script.contains(
                "button.querySelector(\".gallery-overview-bar-label\").textContent ="
            )
        )
        XCTAssertFalse(
            script.contains(
                "row.querySelector(\"strong\").textContent = galleryOverviewCount"
            )
        )
        XCTAssertTrue(script.contains("function reviewOverviewContentFingerprint()"))
        XCTAssertTrue(script.contains("function reviewOverviewCanPreserveContent()"))
        XCTAssertTrue(script.contains("function reviewOverviewPartKey("))
        XCTAssertTrue(script.contains("function syncReviewOverviewAttributes("))
        XCTAssertTrue(script.contains("function syncReviewOverviewNode("))
        XCTAssertTrue(script.contains("function syncReviewOverviewStableNode("))
        XCTAssertTrue(script.contains("function reconcileReviewOverviewCard("))
        XCTAssertTrue(script.contains("function syncReviewOverviewGroupToggle("))
        XCTAssertTrue(script.contains("function toggleReviewOverviewGroup("))
        XCTAssertTrue(script.contains("function syncReviewOverviewCardTabStops("))
        XCTAssertTrue(script.contains("function moveReviewOverviewCardFocus(event)"))
        XCTAssertTrue(script.contains("state.review.overviewFocusTagID"))
        XCTAssertTrue(script.contains("if (moveReviewOverviewCardFocus(event)) return;"))
        XCTAssertTrue(script.contains("button.setAttribute(\"aria-posinset\""))
        XCTAssertTrue(script.contains("button.setAttribute(\"aria-setsize\""))
        XCTAssertTrue(script.contains("function focusReviewSourceFilterButton("))
        XCTAssertTrue(script.contains("function moveReviewSourceFilterFocus(event)"))
        XCTAssertTrue(
            script.contains(
                "longListNavigationTarget(\n      buttons,\n      current,\n      event.key,\n      elements.reviewSourceFilterOptions"
            )
        )
        XCTAssertTrue(script.contains("focusReviewSourceFilterButton(buttons[next])"))
        XCTAssertTrue(
            script.contains(
                "ArrowLeft ArrowRight ArrowUp ArrowDown PageUp PageDown Home End"
            )
        )
        XCTAssertTrue(script.contains("function handleChoiceGridNavigation(event, {"))
        XCTAssertTrue(script.contains("container: elements.trainingTagOptions"))
        XCTAssertTrue(script.contains("inputSelector: \"input[data-training-tag-id]\""))
        XCTAssertTrue(script.contains("selectRadioOnMove: true"))
        XCTAssertTrue(script.contains("container: elements.tagSuggestionSourceOptions"))
        XCTAssertTrue(script.contains("container: elements.trainingScopeOptions"))
        XCTAssertTrue(script.contains("container: elements.slimmingSourceOptions"))
        XCTAssertTrue(script.contains("container: elements.slimmingCatalogSourceOptions"))
        XCTAssertTrue(script.contains("container: elements.slimmingMaintenanceSourceOptions"))
        XCTAssertTrue(script.contains("inputSelector: 'input[type=\"checkbox\"]'"))
        XCTAssertTrue(script.contains("inputSelector: \"input[data-training-source-id]\""))
        XCTAssertTrue(script.contains("inputSelector: \"input[data-slimming-source-id]\""))
        XCTAssertTrue(
            script.contains(
                "inputSelector: \"input[data-slimming-catalog-source-id]\""
            )
        )
        XCTAssertTrue(
            script.contains(
                "inputSelector: \"input[data-slimming-maintenance-source-id]\""
            )
        )
        XCTAssertTrue(script.contains("revealCheckboxGridRow(container, targetRow)"))
        XCTAssertTrue(script.contains("renderReviewOverview({ reconcileContent: true });"))
        XCTAssertTrue(
            script.contains(
                "toggleReviewOverviewGroup(groupToggle.dataset.reviewOverviewGroupToggle)"
            )
        )
        XCTAssertTrue(script.contains("data-review-overview-part=\"group-title\""))
        XCTAssertTrue(script.contains("card-origin-${key}"))
        let reviewStableSyncStart = try XCTUnwrap(
            script.range(of: "function syncReviewOverviewStableNode(")
        )
        let reviewStableSyncEnd = try XCTUnwrap(
            script.range(
                of: "function reconcileReviewOverviewCard(",
                range: reviewStableSyncStart.upperBound..<script.endIndex
            )
        )
        XCTAssertFalse(
            script[reviewStableSyncStart.lowerBound..<reviewStableSyncEnd.lowerBound]
                .contains("replaceChildren")
        )
        let reviewGroupToggleStart = try XCTUnwrap(
            script.range(of: "function syncReviewOverviewGroupToggle(")
        )
        let reviewGroupToggleEnd = try XCTUnwrap(
            script.range(
                of: "function organizeReviewOverviewGroups(",
                range: reviewGroupToggleStart.upperBound..<script.endIndex
            )
        )
        XCTAssertFalse(
            script[reviewGroupToggleStart.lowerBound..<reviewGroupToggleEnd.lowerBound]
                .contains("replaceChildren")
        )
        let reviewGroupOrganizerEnd = try XCTUnwrap(
            script.range(
                of: "function reviewOverviewContentFingerprint(",
                range: reviewGroupToggleEnd.upperBound..<script.endIndex
            )
        )
        let reviewGroupOrganizerScript = script[
            reviewGroupToggleEnd.lowerBound..<reviewGroupOrganizerEnd.lowerBound
        ]
        XCTAssertFalse(reviewGroupOrganizerScript.contains("grid.replaceChildren"))
        XCTAssertFalse(reviewGroupOrganizerScript.contains("group.replaceChildren"))
        XCTAssertTrue(script.contains("function syncAssetCardOverlayText("))
        XCTAssertTrue(script.contains("function syncAssetTagCountBadge("))
        XCTAssertTrue(script.contains("data-asset-tag-count-part=\"symbol\""))
        XCTAssertTrue(script.contains("data-asset-tag-count-part=\"value\""))
        XCTAssertTrue(
            script.contains(
                "标签：已确认 ${asset.acceptedTagCount}，已拒绝 ${asset.rejectedTagCount}"
            )
        )
        let assetMetaStart = try XCTUnwrap(
            script.range(of: "function syncAssetCardMeta(")
        )
        let assetMetaEnd = try XCTUnwrap(
            script.range(
                of: "function syncAssetCardMediaBadge(",
                range: assetMetaStart.upperBound..<script.endIndex
            )
        )
        let assetMetaScript = script[assetMetaStart.lowerBound..<assetMetaEnd.lowerBound]
        XCTAssertFalse(assetMetaScript.contains("clearElement"))
        XCTAssertFalse(assetMetaScript.contains("replaceChildren"))
        XCTAssertTrue(script.contains("data-asset-video-badge-part=\"icon\""))
        XCTAssertTrue(script.contains("data-asset-video-badge-part=\"duration\""))
        let assetVideoBadgeStart = try XCTUnwrap(
            script.range(of: "function syncAssetCardMediaBadge(")
        )
        let assetVideoBadgeEnd = try XCTUnwrap(
            script.range(
                of: "function favoriteSyncText(",
                range: assetVideoBadgeStart.upperBound..<script.endIndex
            )
        )
        let assetVideoBadgeScript = script[
            assetVideoBadgeStart.lowerBound..<assetVideoBadgeEnd.lowerBound
        ]
        XCTAssertFalse(assetVideoBadgeScript.contains("badge.textContent"))
        XCTAssertFalse(assetVideoBadgeScript.contains("replaceChildren"))
        let mediaFavoriteStart = try XCTUnwrap(
            script.range(of: "function syncMediaFavoriteButton(")
        )
        let mediaFavoriteEnd = try XCTUnwrap(
            script.range(
                of: "function syncAssetCardFavoriteButton(",
                range: mediaFavoriteStart.upperBound..<script.endIndex
            )
        )
        let mediaFavoriteScript = script[
            mediaFavoriteStart.lowerBound..<mediaFavoriteEnd.lowerBound
        ]
        XCTAssertTrue(mediaFavoriteScript.contains("syncAssetCardOverlayText(icon"))
        XCTAssertTrue(mediaFavoriteScript.contains("syncAssetCardOverlayText(badge"))
        XCTAssertFalse(mediaFavoriteScript.contains(".textContent ="))
        XCTAssertTrue(script.contains("syncWorldMapPhotoFavoriteButton(card, asset)"))
        XCTAssertTrue(script.contains("syncReviewCardFavoriteButton(card, item)"))
        XCTAssertTrue(script.contains("syncSlimmingMemberFavoriteButton(card, member)"))
        XCTAssertTrue(script.contains("syncSlimmingRecycleFavoriteButton(card, entry)"))
        let assetSelectionMarkStart = try XCTUnwrap(
            script.range(of: "function syncAssetCardSelectionMark(")
        )
        let assetSelectionMarkEnd = try XCTUnwrap(
            script.range(
                of: "function syncAssetCardOverlayText(",
                range: assetSelectionMarkStart.upperBound..<script.endIndex
            )
        )
        let assetSelectionMarkScript = script[
            assetSelectionMarkStart.lowerBound..<assetSelectionMarkEnd.lowerBound
        ]
        XCTAssertTrue(assetSelectionMarkScript.contains("classList.toggle(\"hidden\""))
        XCTAssertTrue(assetSelectionMarkScript.contains("syncAssetCardOverlayText("))
        XCTAssertFalse(assetSelectionMarkScript.contains(".remove()"))
        XCTAssertFalse(assetSelectionMarkScript.contains(".textContent ="))
        let reviewSelectionMarkStart = try XCTUnwrap(
            script.range(of: "function syncReviewCardSelection(")
        )
        let reviewSelectionMarkEnd = try XCTUnwrap(
            script.range(
                of: "function syncReviewSelectionModeControls(",
                range: reviewSelectionMarkStart.upperBound..<script.endIndex
            )
        )
        let reviewSelectionMarkScript = script[
            reviewSelectionMarkStart.lowerBound..<reviewSelectionMarkEnd.lowerBound
        ]
        XCTAssertTrue(reviewSelectionMarkScript.contains("syncAssetCardOverlayText(mark, \"✓\")"))
        XCTAssertFalse(reviewSelectionMarkScript.contains("mark?.remove()"))
        XCTAssertTrue(stylesheet.contains(".review-card.selected .review-selection-mark,"))
        XCTAssertTrue(
            stylesheet.contains(
                ".review-workspace.touch-selection-mode .review-card:not(.selected) .review-selection-mark {"
            )
        )
        XCTAssertFalse(
            stylesheet.contains(
                ".review-workspace.touch-selection-mode .review-card:not(.selected)::before {"
            )
        )
        XCTAssertTrue(stylesheet.contains(".asset-tag-count {"))
        XCTAssertTrue(stylesheet.contains("display: inline-flex;"))
        XCTAssertTrue(script.contains("function reviewCardFingerprint("))
        XCTAssertTrue(script.contains("function reviewPageStructureMatches("))
        XCTAssertTrue(script.contains("function renderReviewCardsForKeys("))
        XCTAssertTrue(script.contains("let changedReviewKeys = null;"))
        XCTAssertTrue(script.contains("const canPreserveExistingGrid = preserveUnchangedGrid"))
        XCTAssertTrue(script.contains("renderReviewCardsForKeys(changedReviewKeys);"))
        let reviewCommandRefreshStart = try XCTUnwrap(
            script.range(of: "async function refreshCommandContext()")
        )
        let reviewCommandRefreshEnd = try XCTUnwrap(
            script.range(
                of: "async function switchCommandMediaKind",
                range: reviewCommandRefreshStart.upperBound..<script.endIndex
            )
        )
        let reviewCommandRefreshScript = String(
            script[
                reviewCommandRefreshStart.lowerBound..<reviewCommandRefreshEnd.lowerBound
            ]
        )
        XCTAssertTrue(reviewCommandRefreshScript.contains("preserveLoadedWindow: true"))
        XCTAssertTrue(reviewCommandRefreshScript.contains("preserveUnchangedGrid: true"))
        let reviewButtonRefreshStart = try XCTUnwrap(
            script.range(of: "elements.refreshReviewButton.addEventListener")
        )
        let reviewButtonRefreshEnd = try XCTUnwrap(
            script.range(
                of: "elements.generateStandardLibrarySuggestionsButton.addEventListener",
                range: reviewButtonRefreshStart.upperBound..<script.endIndex
            )
        )
        let reviewButtonRefreshScript = String(
            script[
                reviewButtonRefreshStart.lowerBound..<reviewButtonRefreshEnd.lowerBound
            ]
        )
        XCTAssertTrue(reviewButtonRefreshScript.contains("preserveLoadedWindow: true"))
        XCTAssertTrue(reviewButtonRefreshScript.contains("preserveUnchangedGrid: true"))
        let trainingSlotSyncStart = try XCTUnwrap(
            script.range(of: "function syncTrainingSlot(")
        )
        let trainingSlotSyncEnd = try XCTUnwrap(
            script.range(
                of: "function renderTrainingSlots(",
                range: trainingSlotSyncStart.upperBound..<script.endIndex
            )
        )
        let trainingSlotSyncScript = String(
            script[trainingSlotSyncStart.lowerBound..<trainingSlotSyncEnd.lowerBound]
        )
        XCTAssertTrue(trainingSlotSyncScript.contains("data-training-slot-part"))
        XCTAssertTrue(trainingSlotSyncScript.contains("data-training-slot-copy-part"))
        XCTAssertFalse(trainingSlotSyncScript.contains("clearElement(item);"))
        let trainingRunSyncStart = try XCTUnwrap(
            script.range(of: "function syncTrainingRunRow(")
        )
        let trainingRunSyncEnd = try XCTUnwrap(
            script.range(
                of: "function renderTrainingRunList(",
                range: trainingRunSyncStart.upperBound..<script.endIndex
            )
        )
        let trainingRunSyncScript = String(
            script[trainingRunSyncStart.lowerBound..<trainingRunSyncEnd.lowerBound]
        )
        XCTAssertTrue(trainingRunSyncScript.contains("data-training-run-part"))
        XCTAssertTrue(trainingRunSyncScript.contains("data-training-run-context-part"))
        XCTAssertFalse(trainingRunSyncScript.contains("clearElement(row);"))
        let slimmingJobRowSyncStart = try XCTUnwrap(
            script.range(of: "function syncSlimmingJobRow(")
        )
        let slimmingJobRowSyncEnd = try XCTUnwrap(
            script.range(
                of: "function appendSlimmingJobRows(",
                range: slimmingJobRowSyncStart.upperBound..<script.endIndex
            )
        )
        let slimmingJobRowSyncScript = String(
            script[slimmingJobRowSyncStart.lowerBound..<slimmingJobRowSyncEnd.lowerBound]
        )
        XCTAssertTrue(script.contains("function syncSlimmingJobRowProgress("))
        XCTAssertTrue(script.contains("function syncSlimmingScanProgressElement("))
        XCTAssertTrue(script.contains("function syncSlimmingCurrentJobProgress("))
        XCTAssertTrue(script.contains("data-slimming-scan-progress-part"))
        XCTAssertTrue(slimmingJobRowSyncScript.contains("data-slimming-job-row-part"))
        XCTAssertTrue(slimmingJobRowSyncScript.contains("syncSlimmingJobRowProgress"))
        XCTAssertFalse(slimmingJobRowSyncScript.contains("clearElement(row);"))
        XCTAssertFalse(
            script.contains("clearElement(elements.slimmingCurrentJobProgress);")
        )
        let slimmingMemberCardSyncStart = try XCTUnwrap(
            script.range(of: "function syncSlimmingMemberCard(")
        )
        let slimmingMemberCardSyncEnd = try XCTUnwrap(
            script.range(
                of: "function appendSlimmingMemberCards(",
                range: slimmingMemberCardSyncStart.upperBound..<script.endIndex
            )
        )
        let slimmingMemberCardSyncScript = String(
            script[
                slimmingMemberCardSyncStart.lowerBound..<slimmingMemberCardSyncEnd.lowerBound
            ]
        )
        XCTAssertTrue(slimmingMemberCardSyncScript.contains("data-slimming-member-main-part"))
        XCTAssertTrue(slimmingMemberCardSyncScript.contains("data-slimming-member-footer-part"))
        XCTAssertTrue(slimmingMemberCardSyncScript.contains("data-slimming-member-card-part"))
        XCTAssertTrue(slimmingMemberCardSyncScript.contains("data-slimming-member-overlay-part"))
        XCTAssertFalse(slimmingMemberCardSyncScript.contains("existingImage?.remove()"))
        XCTAssertFalse(slimmingMemberCardSyncScript.contains("clearElement(existingMain)"))
        XCTAssertTrue(script.contains("function trainingDetailFingerprint("))
        XCTAssertTrue(script.contains("renderTrainingWorkspace({ preserveContent:"))
        XCTAssertTrue(script.contains("function syncTrainingBatchCard("))
        XCTAssertTrue(script.contains("function syncTrainingBatchTags("))
        XCTAssertTrue(script.contains("data-training-batch-tag-id"))
        XCTAssertTrue(script.contains("function syncTrainingTagActivityList("))
        XCTAssertTrue(script.contains("data-training-tag-activity-id"))
        XCTAssertFalse(script.contains("clearElement(tags);"))
        XCTAssertFalse(script.contains("clearElement(list);"))
        XCTAssertTrue(script.contains("trainingActivityOperationId"))
        XCTAssertTrue(script.contains("restoreFocusedActivityAction"))
        XCTAssertTrue(script.contains("restoreFocusedBatchAction"))
        XCTAssertTrue(html.contains("aria-keyshortcuts=\"J\""))
        XCTAssertTrue(script.contains("id: \"activity\", title: \"打开或关闭活动\", keys: [\"J\"]"))
        XCTAssertTrue(stylesheet.contains("z-index: 150;"))
        XCTAssertTrue(html.contains("aria-keyshortcuts=\"Meta+, Control+,\""))
        XCTAssertTrue(script.contains("if (blockingDialogOpen || elements.commandPalette.open) return;"))
        XCTAssertTrue(script.contains("(showsSelection || showsDetail)"))
        XCTAssertTrue(script.contains("&& !state.inspectorDismissed"))
        XCTAssertTrue(html.contains("id=\"selectionInspectorOverlayButton\""))
        XCTAssertTrue(stylesheet.contains("scroll-snap-type: inline proximity"))
        XCTAssertTrue(stylesheet.contains("touch-action: pan-x"))
        XCTAssertTrue(script.contains("function resetCompactSelectionToolScroll"))
        XCTAssertTrue(script.contains("function revealCompactSelectionToolAction"))
        XCTAssertTrue(script.contains("elements.selectionToolActions.addEventListener(\"focusout\""))
        XCTAssertTrue(html.contains("id=\"mobileSidebarScrim\""))
        XCTAssertTrue(stylesheet.contains(".mobile-sidebar-scrim"))
        XCTAssertTrue(stylesheet.contains(".app-shell.mobile-sidebar-open #sidebarToggle"))
        XCTAssertTrue(script.contains("galleryContext: currentGalleryHistoryContext()"))
        XCTAssertTrue(script.contains("function supportsFolderHierarchy()"))
        XCTAssertTrue(script.contains("function loadFolderBranch("))
        XCTAssertTrue(script.contains("function selectFolder("))
        XCTAssertTrue(script.contains("branchRequestGenerations: new Map()"))
        XCTAssertTrue(script.contains("searchRequestGenerations: new Map()"))
        XCTAssertTrue(script.contains("searchTimers: new Map()"))
        XCTAssertTrue(script.contains("function expandFolderScopeAncestors("))
        XCTAssertTrue(script.contains("function loadExpandedFolderBranches("))
        XCTAssertTrue(script.contains("function moveFolderTreeHorizontalNavigation("))
        XCTAssertTrue(script.contains("function firstFolderTreeChild("))
        XCTAssertTrue(script.contains("function retryFolderBranch("))
        XCTAssertTrue(script.contains("function loadMoreFolderBranch("))
        XCTAssertTrue(script.contains("loadMoreError"))
        XCTAssertTrue(script.contains("source-folder-capacity"))
        XCTAssertTrue(script.contains("folder-capacity:"))
        XCTAssertTrue(script.contains("function focusFolderBreadcrumbNavigation("))
        XCTAssertTrue(script.contains("function retryFolderSearch("))
        XCTAssertTrue(script.contains("function submitFolderSearch("))
        XCTAssertTrue(script.contains("data-folder-retry-source-id"))
        XCTAssertTrue(script.contains("data-folder-search-retry-source-id"))
        XCTAssertTrue(script.contains("data-folder-search-submit-source-id"))
        XCTAssertTrue(script.contains("role\", \"treeitem"))
        XCTAssertTrue(script.contains("button.setAttribute(\"aria-owns\""))
        XCTAssertTrue(script.contains("[data-folder-search-source-id]"))
        XCTAssertTrue(script.contains("query.set(\"folderRelativePath\""))
        XCTAssertTrue(script.contains("galleryFolderSessionID"))
        XCTAssertTrue(stylesheet.contains(".source-folder-tree"))
        XCTAssertTrue(stylesheet.contains(".source-folder-search-results"))
        XCTAssertTrue(stylesheet.contains(".source-folder-search-controls"))
        XCTAssertTrue(stylesheet.contains(".source-folder-search-submit"))
        XCTAssertTrue(stylesheet.contains(".source-folder-retry"))
        XCTAssertTrue(stylesheet.contains(".source-folder-search-retry"))
        XCTAssertTrue(stylesheet.contains(".folder-breadcrumb"))
        XCTAssertTrue(html.contains("id=\"sourceList\" class=\"sidebar-list\" role=\"tree\""))
        XCTAssertTrue(script.contains("loadWorldMapSnapshot({ bounds: state.worldMap.viewport })"))
        XCTAssertTrue(script.contains("function renderWorldMapFooter()"))
        XCTAssertTrue(script.contains("function restorePendingWorldMapViewport()"))
        XCTAssertTrue(script.contains("state.worldMap.viewportRefreshSuppression = target"))
        XCTAssertTrue(script.contains("function syncWorldMapLocationActionTabStops("))
        XCTAssertTrue(script.contains("function moveWorldMapLocationActionFocus("))
        XCTAssertTrue(script.contains("function nearestWorldMapLocationAction("))
        XCTAssertTrue(script.contains("worldMapLocationNavigationShortcuts"))
        XCTAssertTrue(html.contains("方向键逐项、Page Up/Down 翻页"))
        XCTAssertTrue(script.contains("function syncGalleryOverviewRovingItems("))
        XCTAssertTrue(script.contains("function moveGalleryOverviewChartFocus("))
        XCTAssertTrue(script.contains("function updateGalleryOverviewTimelineStatus("))
        XCTAssertTrue(script.contains("function updateGalleryOverviewAvailabilityStatus("))
        XCTAssertTrue(script.contains("availability: button.dataset.galleryOverviewAvailability"))
        XCTAssertTrue(script.contains("ArrowLeft ArrowRight PageUp PageDown Home End"))
        XCTAssertTrue(script.contains("ArrowUp ArrowDown PageUp PageDown Home End"))
        XCTAssertTrue(html.contains("id=\"galleryOverviewTimelineStatus\""))
        XCTAssertTrue(html.contains("id=\"galleryOverviewAvailabilityStatus\""))
        XCTAssertTrue(html.contains("可用状态；使用上下方向键浏览，按 Enter 筛选图库"))
        XCTAssertTrue(html.contains("时间分布；使用左右方向键或 Page Up/Down 浏览年份"))
        XCTAssertTrue(stylesheet.contains(".gallery-overview-availability-row:focus-visible"))
        XCTAssertTrue(stylesheet.contains(".gallery-overview-year:focus-visible"))
        XCTAssertTrue(stylesheet.contains(".world-map-footer"))
        XCTAssertTrue(stylesheet.contains(".world-map-viewport-readout"))
        XCTAssertTrue(worldMapScript.contains("function currentViewport()"))
        XCTAssertTrue(worldMapScript.contains("function restoreViewport(viewport)"))
        XCTAssertTrue(worldMapScript.contains("function syncClusterNavigator("))
        XCTAssertTrue(worldMapScript.contains("function moveKeyboardCluster("))
        XCTAssertTrue(worldMapScript.contains("keyboard-city-ring"))
        XCTAssertTrue(worldMapScript.contains("clusterNavigatorCurrent.addEventListener(\"click\""))
        XCTAssertTrue(html.contains("Tab 键浏览照片塔"))
        XCTAssertTrue(worldMapScript.contains("restoreViewport,"))
        XCTAssertTrue(worldMapScript.contains("if (!bridge && globalThis.parent"))
        XCTAssertTrue(worldMapScript.contains("post({ type: \"escapePressed\" })"))
        XCTAssertTrue(script.contains("case \"escapePressed\":"))
        XCTAssertTrue(script.contains("elements.lightboxVideo.currentTime"))
        XCTAssertTrue(script.contains("elements.lightboxVideo.pause()"))
        XCTAssertTrue(script.contains("\"loadedmetadata\""))
        XCTAssertTrue(script.contains("targetLoadedCount: galleryRestore?.loadedCount"))
        XCTAssertTrue(script.contains("loadWorkspace({ restoreHistory: true })"))
        XCTAssertTrue(script.contains("state.inspectorRequestGeneration"))
        XCTAssertTrue(script.contains("state.inspectorDismissed"))
        XCTAssertTrue(script.contains("state.pendingInspectorRefresh"))
        XCTAssertTrue(script.contains("preserveExisting: true"))
        XCTAssertTrue(script.contains("function closeReviewWorkspace({ restoreFocus = true } = {})"))
        XCTAssertTrue(script.contains("function closeLightbox({ restoreFocus = true } = {})"))
        XCTAssertTrue(script.contains("function compactToolbarSections()"))
        XCTAssertTrue(script.contains("function renderCompactToolbarMenu()"))
        XCTAssertTrue(script.contains("function reconcileCompactToolbarMenuContent()"))
        XCTAssertTrue(script.contains("data-compact-toolbar-section"))
        XCTAssertTrue(script.contains("function reconcileMetadataRows(container, rows)"))
        XCTAssertTrue(script.contains("data-metadata-key"))
        XCTAssertTrue(script.contains("function reconcileTrainingFacts(container, facts)"))
        XCTAssertTrue(script.contains("data-training-context-key"))
        XCTAssertTrue(script.contains("data-training-technical-key"))
        XCTAssertTrue(script.contains("function reconcileTrainingSetupSummary(rows)"))
        XCTAssertTrue(script.contains("data-training-summary-key"))
        XCTAssertTrue(script.contains("trainingMetricsFingerprint"))
        let trainingMetricsSyncStart = try XCTUnwrap(
            script.range(of: "function syncTrainingChartElement(")
        )
        let trainingMetricsSyncEnd = try XCTUnwrap(
            script.range(
                of: "function reconcileTrainingFacts(",
                range: trainingMetricsSyncStart.upperBound..<script.endIndex
            )
        )
        let trainingMetricsSyncScript = String(
            script[trainingMetricsSyncStart.lowerBound..<trainingMetricsSyncEnd.lowerBound]
        )
        XCTAssertTrue(trainingMetricsSyncScript.contains("data-training-chart-part"))
        XCTAssertTrue(trainingMetricsSyncScript.contains("data-training-metric-key"))
        XCTAssertTrue(trainingMetricsSyncScript.contains("data-training-metric-copy-part"))
        XCTAssertTrue(trainingMetricsSyncScript.contains("function syncTrainingMetricPointSelection("))
        XCTAssertTrue(trainingMetricsSyncScript.contains("function moveTrainingMetricPoint("))
        XCTAssertTrue(trainingMetricsSyncScript.contains("function nearestTrainingMetricMark("))
        XCTAssertTrue(trainingMetricsSyncScript.contains("activeMetricEpoch"))
        XCTAssertTrue(html.contains("id=\"trainingMetricPointStatus\""))
        XCTAssertTrue(html.contains("aria-roledescription=\"可探索图表\""))
        XCTAssertTrue(stylesheet.contains(".training-loss-chart:focus-visible"))
        XCTAssertTrue(stylesheet.contains(".training-chart-point[data-current=\"true\"]"))
        XCTAssertFalse(
            trainingMetricsSyncScript.contains("clearElement(elements.trainingMetricHighlights)")
        )
        XCTAssertFalse(
            trainingMetricsSyncScript.contains("clearElement(elements.trainingLossChart)")
        )
        XCTAssertTrue(script.contains("function reconcileSlimmingInspectorFields(target, fields)"))
        XCTAssertTrue(script.contains("data-slimming-inspector-field-key"))
        XCTAssertTrue(script.contains("function syncSlimmingClusterReviewButton("))
        XCTAssertTrue(script.contains("function reconcileSlimmingClusterReviewButtons("))
        XCTAssertTrue(script.contains("reconcileStableChildren(main, [image, text])"))
        XCTAssertTrue(script.contains("const focusedDisposition = focusedReview?.dataset.slimmingClusterReview"))
        XCTAssertTrue(script.contains("function slimmingInspectorFilterScopeSummary()"))
        XCTAssertTrue(script.contains("function slimmingInspectorSourceIndexValue()"))
        XCTAssertTrue(script.contains("key: \"pendingSeeds\""))
        XCTAssertTrue(script.contains("key: \"sourceIndex\""))
        XCTAssertTrue(script.contains("function closeCompactToolbarMenu({ restoreFocus = true, checkpoint = true } = {})"))
        XCTAssertTrue(script.contains("function syncCompactToolbarMenu()"))
        XCTAssertTrue(script.contains("function fullToolbarRequiredWidth({ condensed = false } = {})"))
        XCTAssertTrue(script.contains("fullToolbarRequiredWidth({ condensed: true })"))
        XCTAssertTrue(script.contains("toolbarNormalRequiredWidth"))
        XCTAssertTrue(script.contains("toolbarLayout"))
        XCTAssertTrue(script.contains("function syncAdaptiveToolbar()"))
        XCTAssertTrue(script.contains("function scheduleAdaptiveToolbarSync()"))
        XCTAssertTrue(script.contains("new ResizeObserver(scheduleAdaptiveToolbarSync)"))
        XCTAssertTrue(stylesheet.contains(".compact-toolbar-menu-button"))
        XCTAssertTrue(stylesheet.contains(".compact-toolbar-menu-item"))
        XCTAssertTrue(stylesheet.contains(".app-shell.toolbar-condensed"))
        XCTAssertTrue(stylesheet.contains(".app-shell.toolbar-measuring"))
        XCTAssertTrue(stylesheet.contains(".app-shell.compact-toolbar-active"))
        XCTAssertTrue(stylesheet.contains("#catalogProgressStatusButton"))
        XCTAssertTrue(stylesheet.contains(".thumbnail-recovery-status"))
        XCTAssertTrue(script.contains("THUMBNAIL_RECOVERY_FAILURE_THRESHOLD = 3"))
        XCTAssertTrue(script.contains("function startThumbnailRecovery"))
        XCTAssertTrue(script.contains("function scheduleThumbnailRecoveryProbe"))
        XCTAssertTrue(script.contains("function reconcileThumbnailRecoveryConnection"))
        XCTAssertTrue(script.contains("const thumbnailRecoveryVisibilityObserver"))
        XCTAssertTrue(script.contains("descriptor.failedGeneration"))
        XCTAssertTrue(script.contains("image.dataset.protectedPath === path && !forceFetch"))
        let protectedImageObserverStart = try XCTUnwrap(
            script.range(of: "const protectedImageIntersectionObserver")
        )
        let protectedImageObserverEnd = try XCTUnwrap(
            script.range(
                of: "const thumbnailRecoveryVisibilityObserver",
                range: protectedImageObserverStart.upperBound..<script.endIndex
            )
        )
        let protectedImageObserverScript = String(
            script[protectedImageObserverStart.lowerBound..<protectedImageObserverEnd.lowerBound]
        )
        XCTAssertTrue(protectedImageObserverScript.contains("root: null"))
        XCTAssertTrue(protectedImageObserverScript.contains("scrollMargin: \"600px\""))
        XCTAssertFalse(protectedImageObserverScript.contains("root: elements.libraryScroll"))
        XCTAssertTrue(protectedImageObserverScript.contains("shared by the library, review"))
        XCTAssertTrue(script.contains("function trapOverlayFocus"))
        XCTAssertTrue(script.contains("state.review.mutating"))
        XCTAssertTrue(script.contains("state.tagMutating"))
        XCTAssertTrue(script.contains("throwOnError: true"))
        XCTAssertTrue(script.contains("界面同步暂时失败，正在重试"))
        XCTAssertTrue(script.contains("applyReviewDecision(\"accept\")"))
        XCTAssertTrue(script.contains("deferReviewSelection"))
        XCTAssertTrue(script.contains("function renderReviewInspectorActions"))
        XCTAssertTrue(script.contains("function applyReviewInspectorFavorite"))
        XCTAssertTrue(script.contains("surface: \"review\""))
        XCTAssertTrue(script.contains("deleteReviewSelection"))
        XCTAssertTrue(script.contains("function setReviewSelectionMode"))
        XCTAssertTrue(script.contains("function setSlimmingSelectionMode"))
        XCTAssertTrue(script.contains("function renderedGridColumnCount"))
        XCTAssertTrue(script.contains("function renderedGridPageItemCount"))
        XCTAssertTrue(script.contains("function moveReviewSelection"))
        XCTAssertTrue(script.contains("function moveSlimmingMemberSelection"))
        XCTAssertTrue(script.contains("state.review.selectionMode"))
        XCTAssertTrue(script.contains("state.slimming.selectionMode"))
        XCTAssertTrue(stylesheet.contains(".workspace-selection-mode-button"))
        XCTAssertTrue(stylesheet.contains(".touch-selection-mode"))
        XCTAssertTrue(stylesheet.contains("@media (prefers-contrast: more)"))
        XCTAssertTrue(stylesheet.contains("@media (forced-colors: active)"))
        XCTAssertTrue(stylesheet.contains("--separator: ButtonBorder"))
        XCTAssertTrue(stylesheet.contains("outline: 3px solid Highlight"))
        XCTAssertFalse(script.contains("applyReviewDecision(\"clear\")"))
        XCTAssertTrue(script.contains("event.key.toLowerCase() === \"p\""))
        XCTAssertTrue(script.contains("event.key.toLowerCase() === \"x\""))
        XCTAssertTrue(script.contains("event.key.toLowerCase() === \"u\""))
        let selectAllShortcut = try XCTUnwrap(
            script.range(
                of: "if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === \"a\")"
            )
        )
        let interactiveControlGuard = try XCTUnwrap(
            script.range(
                of: "if (isInteractiveControlTarget(event.target)) return;",
                range: selectAllShortcut.lowerBound..<script.endIndex
            )
        )
        XCTAssertLessThan(selectAllShortcut.lowerBound, interactiveControlGuard.lowerBound)
        let selectReviewStart = try XCTUnwrap(
            script.range(of: "function selectReviewIndex")
        )
        let reviewFingerprintStart = try XCTUnwrap(
            script.range(
                of: "function reviewPageFingerprint",
                range: selectReviewStart.upperBound..<script.endIndex
            )
        )
        let selectReviewScript = String(
            script[selectReviewStart.lowerBound..<reviewFingerprintStart.lowerBound]
        )
        XCTAssertFalse(selectReviewScript.contains("renderReview();"))
        let reviewDecisionStart = try XCTUnwrap(
            script.range(of: "async function applyReviewDecision")
        )
        let deferReviewStart = try XCTUnwrap(
            script.range(
                of: "function deferReviewSelection",
                range: reviewDecisionStart.upperBound..<script.endIndex
            )
        )
        let reviewDecisionScript = String(
            script[reviewDecisionStart.lowerBound..<deferReviewStart.lowerBound]
        )
        XCTAssertTrue(reviewDecisionScript.contains("preserveLoadedWindow: true"))
        XCTAssertTrue(reviewDecisionScript.contains("preserveUnchangedGrid: true"))
        let deferReviewEnd = try XCTUnwrap(
            script.range(
                of: "function lightboxItemsForContext",
                range: deferReviewStart.upperBound..<script.endIndex
            )
        )
        let deferReviewScript = String(
            script[deferReviewStart.lowerBound..<deferReviewEnd.lowerBound]
        )
        XCTAssertTrue(script.contains("async function deferReviewSelection"))
        XCTAssertTrue(deferReviewScript.contains("append: true"))
        XCTAssertTrue(deferReviewScript.contains("preserveUnchangedGrid: true"))
        XCTAssertTrue(deferReviewScript.contains("throwOnError: true"))
        XCTAssertTrue(deferReviewScript.contains("schedulePagination: false"))
        XCTAssertTrue(deferReviewScript.contains("continuationRequestGeneration"))
        XCTAssertTrue(deferReviewScript.contains("selectionUnchanged"))
        XCTAssertTrue(deferReviewScript.contains("advancesByReviewRow"))
        XCTAssertTrue(deferReviewScript.contains("selectedReviewKey"))
        XCTAssertTrue(deferReviewScript.contains("已到审核队列末尾，没有修改标签决定"))
        XCTAssertTrue(script.contains("function reviewGridRovingKey"))
        XCTAssertTrue(script.contains("gridFocusReviewKey"))
        XCTAssertTrue(script.contains("function lightboxItemIndex"))
        XCTAssertTrue(script.contains("lightboxReviewKey"))
        XCTAssertTrue(script.contains("reviewKey: reviewItemKey(item)"))
        XCTAssertTrue(
            script.contains(
                "reviewItemKey: reviewItemKey(state.review.items[state.review.selectedIndex])"
            )
        )
        XCTAssertTrue(
            script.contains(
                "if (await deferReviewSelection()) syncReviewLightboxSelection();"
            )
        )
        XCTAssertTrue(script.contains("sort: \"fileNameAscending\""))
        XCTAssertTrue(
            html.contains(
                "<option value=\"fileNameAscending\" selected>文件名升序</option>"
            )
        )
        XCTAssertTrue(html.contains("id=\"sortButton\""))
        XCTAssertTrue(html.contains("id=\"sortPopover\""))
        XCTAssertTrue(script.contains("function renderSortControls"))
        XCTAssertTrue(script.contains("function toggleSortPopover"))
        XCTAssertTrue(script.contains("function openJobsPopover"))
        XCTAssertTrue(script.contains("function togglePersonalModelPopover"))
        XCTAssertTrue(script.contains("function openCompactToolbarMenu"))
        XCTAssertTrue(script.contains("closeLayoutMenu({ restoreFocus: false });"))
    }

    func testWebRootLoadsWithoutAuthenticationAndUsesBrowserSecurityHeaders() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "RemoteHTTPServerTests-Web-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("<main>ImageAll Web</main>".utf8)
            .write(to: directory.appendingPathComponent("index.html"))
        let worldMapDirectory = directory.appendingPathComponent("WorldMap", isDirectory: true)
        try FileManager.default.createDirectory(
            at: worldMapDirectory,
            withIntermediateDirectories: true
        )
        try Data("<main>Photo Atlas</main>".utf8)
            .write(to: worldMapDirectory.appendingPathComponent("index.html"))

        let port = UInt16.random(in: 19_000...29_000)
        let (server, _) = makeServer(
            port: port,
            webAssetStore: RemoteWebCompanionAssetStore(
                directoryURL: directory,
                worldMapDirectoryURL: worldMapDirectory
            )
        )
        try await server.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        defer { Task { await server.stop() } }

        let (data, response) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(port)/")!
        )
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "<main>ImageAll Web</main>")
        XCTAssertEqual(http.value(forHTTPHeaderField: "X-Frame-Options"), "DENY")
        XCTAssertEqual(http.value(forHTTPHeaderField: "X-Content-Type-Options"), "nosniff")
        XCTAssertTrue(
            try XCTUnwrap(http.value(forHTTPHeaderField: "Content-Security-Policy"))
                .contains("frame-ancestors 'none'")
        )
        XCTAssertTrue(
            try XCTUnwrap(http.value(forHTTPHeaderField: "Content-Security-Policy"))
                .contains("worker-src 'self'")
        )

        let (_, mapResponse) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(port)/world-map/index.html")!
        )
        let mapHTTP = try XCTUnwrap(mapResponse as? HTTPURLResponse)
        XCTAssertEqual(mapHTTP.statusCode, 200)
        XCTAssertEqual(mapHTTP.value(forHTTPHeaderField: "X-Frame-Options"), "SAMEORIGIN")
        XCTAssertTrue(
            try XCTUnwrap(mapHTTP.value(forHTTPHeaderField: "Content-Security-Policy"))
                .contains("frame-ancestors 'self'")
        )
    }

    func testByteRangeParserSupportsBrowserRangeForms() {
        XCTAssertEqual(
            RemoteHTTPServer.parseByteRange(nil, contentLength: 10),
            .full
        )
        XCTAssertEqual(
            RemoteHTTPServer.parseByteRange("bytes=2-5", contentLength: 10),
            .partial(RemoteHTTPByteRange(lowerBound: 2, upperBound: 5))
        )
        XCTAssertEqual(
            RemoteHTTPServer.parseByteRange("bytes=7-", contentLength: 10),
            .partial(RemoteHTTPByteRange(lowerBound: 7, upperBound: 9))
        )
        XCTAssertEqual(
            RemoteHTTPServer.parseByteRange("bytes=-3", contentLength: 10),
            .partial(RemoteHTTPByteRange(lowerBound: 7, upperBound: 9))
        )
        XCTAssertEqual(
            RemoteHTTPServer.parseByteRange("bytes=20-30", contentLength: 10),
            .unsatisfiable
        )
        XCTAssertEqual(
            RemoteHTTPServer.parseByteRange("bytes=0-1,4-5", contentLength: 10),
            .unsatisfiable
        )
    }

    func testMediaRouteStreamsRealMIMEAndSingleByteRange() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteHTTPServerTests-Media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixtureURL = directory.appendingPathComponent("fixture.mp4")
        try Data("0123456789".utf8).write(to: fixtureURL)

        let assetID = UUID()
        let port = UInt16.random(in: 19_000...29_000)
        let (server, _) = makeServer(
            port: port,
            mediaResources: RemoteHTTPServerTestMediaProvider(url: fixtureURL)
        )
        try await server.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        defer { Task { await server.stop() } }

        let endpointURL = try XCTUnwrap(
            URL(string: "http://127.0.0.1:\(port)/v1/assets/\(assetID.uuidString)/media")
        )
        func request(
            method: String = "GET",
            range: String? = nil
        ) async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: endpointURL)
            request.httpMethod = method
            request.setValue(
                "Bearer \(Self.legacyDebugToken)",
                forHTTPHeaderField: "Authorization"
            )
            if let range {
                request.setValue(range, forHTTPHeaderField: "Range")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, try XCTUnwrap(response as? HTTPURLResponse))
        }

        let (data, http) = try await request(range: "bytes=2-5")
        XCTAssertEqual(http.statusCode, 206)
        XCTAssertEqual(data, Data("2345".utf8))
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Type"), "video/mp4")
        XCTAssertEqual(http.value(forHTTPHeaderField: "Accept-Ranges"), "bytes")
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Range"), "bytes 2-5/10")
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Length"), "4")

        let (headData, head) = try await request(method: "HEAD", range: "bytes=7-")
        XCTAssertEqual(head.statusCode, 206)
        XCTAssertTrue(headData.isEmpty)
        XCTAssertEqual(head.value(forHTTPHeaderField: "Content-Range"), "bytes 7-9/10")
        XCTAssertEqual(head.value(forHTTPHeaderField: "Content-Length"), "3")

        let (rejectedData, rejected) = try await request(range: "bytes=20-30")
        XCTAssertEqual(rejected.statusCode, 416)
        XCTAssertTrue(rejectedData.isEmpty)
        XCTAssertEqual(rejected.value(forHTTPHeaderField: "Content-Range"), "bytes */10")

        let (fullData, full) = try await request()
        XCTAssertEqual(full.statusCode, 200)
        XCTAssertEqual(fullData, Data("0123456789".utf8))
        XCTAssertEqual(full.value(forHTTPHeaderField: "Content-Type"), "video/mp4")
        XCTAssertEqual(full.value(forHTTPHeaderField: "Accept-Ranges"), "bytes")
    }

    func testOriginalRouteUsesTheProtectedRangeStream() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteHTTPServerTests-Original-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixtureURL = directory.appendingPathComponent("fixture.jpg")
        try Data("original-bytes".utf8).write(to: fixtureURL)

        let assetID = UUID()
        let port = UInt16.random(in: 19_000...29_000)
        let (server, _) = makeServer(
            port: port,
            mediaResources: RemoteHTTPServerTestMediaProvider(
                url: fixtureURL,
                contentType: "image/jpeg"
            )
        )
        try await server.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        defer { Task { await server.stop() } }

        var request = URLRequest(
            url: try XCTUnwrap(
                URL(string: "http://127.0.0.1:\(port)/v1/assets/\(assetID.uuidString)/original")
            )
        )
        request.setValue(
            "Bearer \(Self.legacyDebugToken)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue("bytes=0-7", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)

        XCTAssertEqual(http.statusCode, 206)
        XCTAssertEqual(data, Data("original".utf8))
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Type"), "image/jpeg")
        XCTAssertEqual(http.value(forHTTPHeaderField: "Accept-Ranges"), "bytes")
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Range"), "bytes 0-7/14")
        XCTAssertEqual(http.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertEqual(http.value(forHTTPHeaderField: "X-Content-Type-Options"), "nosniff")

        var headRequest = request
        headRequest.httpMethod = "HEAD"
        headRequest.setValue(nil, forHTTPHeaderField: "Range")
        let (headData, headResponse) = try await URLSession.shared.data(for: headRequest)
        let headHTTP = try XCTUnwrap(headResponse as? HTTPURLResponse)
        XCTAssertEqual(headHTTP.statusCode, 200)
        XCTAssertTrue(headData.isEmpty)
        XCTAssertEqual(headHTTP.value(forHTTPHeaderField: "Content-Length"), "14")
        XCTAssertEqual(headHTTP.value(forHTTPHeaderField: "Accept-Ranges"), "bytes")
        XCTAssertEqual(headHTTP.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertEqual(headHTTP.value(forHTTPHeaderField: "X-Content-Type-Options"), "nosniff")
    }

    func testOpenOriginalRouteDelegatesToMacOpener() async throws {
        let port = UInt16.random(in: 19_000...29_000)
        let assetID = UUID()
        let opener = await MainActor.run { RemoteOriginalAssetOpenerSpy() }
        let (server, _) = makeServer(
            port: port,
            originalAssetOpener: opener
        )
        try await server.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        defer { Task { await server.stop() } }

        var request = URLRequest(
            url: URL(
                string: "http://127.0.0.1:\(port)/v1/assets/\(assetID.uuidString)/open-original"
            )!
        )
        request.httpMethod = "POST"
        request.setValue(
            "Bearer \(Self.legacyDebugToken)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(
            "http://127.0.0.1:\(port)",
            forHTTPHeaderField: "Origin"
        )
        request.setValue("127.0.0.1:\(port)", forHTTPHeaderField: "Host")
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")

        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual(try XCTUnwrap(response as? HTTPURLResponse).statusCode, 204)
        XCTAssertTrue(data.isEmpty)
        let openedAssetIDs = await MainActor.run { opener.openedAssetIDs }
        XCTAssertEqual(openedAssetIDs, [assetID])
    }

    func testLoopbackWebPortServesTheSameCompanionWithoutChangingPrimaryPort() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "RemoteHTTPServerTests-LoopbackWeb-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("<main>Local ImageAll Web</main>".utf8)
            .write(to: directory.appendingPathComponent("index.html"))

        let primaryPort = UInt16.random(in: 19_000...23_000)
        let localWebPort = UInt16.random(in: 25_000...29_000)
        let store = makePairingStore(listenPort: Int(primaryPort))
        let accountStore = makeAccessAccountStore()
        _ = try await accountStore.upsert(
            username: "local-owner",
            password: "local-debug-password"
        )
        let server = RemoteHTTPServer(
            facade: RemoteCatalogFacade(
                catalog: RemoteHTTPServerTestCatalog(),
                review: EmptyPersonalizationReviewPort(),
                idempotency: makeIdempotencyStore(),
                hostAppVersion: "1.0.0",
                listenPort: Int(primaryPort)
            ),
            pairingStore: store,
            accessAccountStore: accountStore,
            eventBroker: RemoteEventBroker(),
            webAssetStore: RemoteWebCompanionAssetStore(directoryURL: directory),
            secIdentity: nil,
            port: primaryPort,
            localWebPort: localWebPort
        )
        try await server.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        defer { Task { await server.stop() } }

        for port in [primaryPort, localWebPort] {
            let (data, response) = try await URLSession.shared.data(
                from: URL(string: "http://127.0.0.1:\(port)/")!
            )
            XCTAssertEqual(
                try XCTUnwrap(response as? HTTPURLResponse).statusCode,
                200
            )
            XCTAssertEqual(
                String(decoding: data, as: UTF8.self),
                "<main>Local ImageAll Web</main>"
            )
        }

        let basic = Data("local-owner:local-debug-password".utf8).base64EncodedString()
        var login = URLRequest(
            url: URL(
                string: "http://127.0.0.1:\(localWebPort)/web/account/login"
            )!
        )
        login.httpMethod = "POST"
        login.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        login.setValue(
            "http://127.0.0.1:\(localWebPort)",
            forHTTPHeaderField: "Origin"
        )
        login.setValue(
            "127.0.0.1:\(localWebPort)",
            forHTTPHeaderField: "Host"
        )
        login.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")

        let (loginData, loginResponse) = try await URLSession.shared.data(for: login)
        XCTAssertEqual(
            try XCTUnwrap(loginResponse as? HTTPURLResponse).statusCode,
            200
        )
        XCTAssertTrue(String(decoding: loginData, as: UTF8.self).contains(
            "\"authMode\":\"account\""
        ))

        if let nonLoopbackIPv4 = Host.current().addresses.first(where: {
            $0.contains(".") && !$0.hasPrefix("127.")
        }) {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 0.5
            configuration.timeoutIntervalForResource = 0.5
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }

            do {
                let (_, response) = try await session.data(
                    from: URL(
                        string: "http://\(nonLoopbackIPv4):\(localWebPort)/"
                    )!
                )
                XCTFail(
                    "Loopback Web port unexpectedly accepted a non-loopback request: \(response)"
                )
            } catch {
                // Expected: the local Web listener is bound only to 127.0.0.1.
            }
        }
    }

    func testCookieAuthenticationReadsCapabilitiesAndRejectsCrossOriginWrites() async throws {
        let port = UInt16.random(in: 19_000...29_000)
        let (server, store) = makeServer(port: port, hostAppVersion: "3.0.0")
        let offer = await store.issueOffer()
        let tokens = try await store.completePairing(
            RemotePairingCompleteRequest(
                pairingToken: offer.pairingToken,
                deviceName: "Safari",
                devicePublicKeySPKI_SHA256: "web-client"
            )
        )
        try await server.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        defer { Task { await server.stop() } }

        var capabilitiesRequest = URLRequest(
            url: URL(string: "http://127.0.0.1:\(port)/v1/capabilities")!
        )
        capabilitiesRequest.setValue(
            "\(RemoteWebCompanionSession.accessCookieName)=\(tokens.accessToken)",
            forHTTPHeaderField: "Cookie"
        )
        let (capabilitiesData, capabilitiesResponse) = try await URLSession.shared.data(
            for: capabilitiesRequest
        )
        XCTAssertEqual(
            try XCTUnwrap(capabilitiesResponse as? HTTPURLResponse).statusCode,
            200
        )
        XCTAssertEqual(
            try JSONDecoder().decode(RemoteCapabilities.self, from: capabilitiesData)
                .hostAppVersion,
            "3.0.0"
        )

        var rejectedRequest = URLRequest(
            url: URL(string: "http://127.0.0.1:\(port)/v1/tag-decisions/batch")!
        )
        rejectedRequest.httpMethod = "POST"
        rejectedRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        rejectedRequest.setValue(
            "\(RemoteWebCompanionSession.accessCookieName)=\(tokens.accessToken)",
            forHTTPHeaderField: "Cookie"
        )
        rejectedRequest.setValue(
            "https://attacker.example",
            forHTTPHeaderField: "Origin"
        )
        rejectedRequest.httpBody = try JSONEncoder().encode(
            RemoteBatchTagDecisionRequest(
                operationID: UUID(),
                tagID: UUID(),
                assetIDs: [UUID()],
                action: .accept
            )
        )
        let (_, rejectedResponse) = try await URLSession.shared.data(for: rejectedRequest)
        XCTAssertEqual(
            try XCTUnwrap(rejectedResponse as? HTTPURLResponse).statusCode,
            403
        )

        var acceptedRequest = rejectedRequest
        acceptedRequest.setValue(
            "http://127.0.0.1:\(port)",
            forHTTPHeaderField: "Origin"
        )
        acceptedRequest.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        let (_, acceptedResponse) = try await URLSession.shared.data(for: acceptedRequest)
        XCTAssertEqual(
            try XCTUnwrap(acceptedResponse as? HTTPURLResponse).statusCode,
            200
        )
    }

    func testAssetRouteMapsAdvancedWebQueryFilters() async throws {
        let sourceID = UUID()
        let acceptedTagID = UUID()
        let excludedTagID = UUID()
        let catalog = RemoteHTTPServerTestCatalog()
        let port = UInt16.random(in: 19_000...29_000)
        let (server, _) = makeServer(port: port, catalog: catalog)
        try await server.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        defer { Task { await server.stop() } }

        var components = URLComponents(
            string: "http://127.0.0.1:\(port)/v1/assets"
        )!
        components.queryItems = [
            URLQueryItem(name: "sourceIDs", value: sourceID.uuidString),
            URLQueryItem(name: "acceptedTagIDs", value: acceptedTagID.uuidString),
            URLQueryItem(name: "excludedTagIDs", value: excludedTagID.uuidString),
            URLQueryItem(name: "tagMatchMode", value: "any"),
            URLQueryItem(name: "availabilities", value: "available,missing"),
            URLQueryItem(name: "mediaKinds", value: "video"),
            URLQueryItem(name: "mediaTypes", value: "public.mpeg-4"),
            URLQueryItem(name: "tagPresence", value: "tagged"),
            URLQueryItem(name: "favorite", value: "favorited"),
            URLQueryItem(name: "worldMapCellDegrees", value: "0.25"),
            URLQueryItem(name: "worldMapLongitudeBucket", value: "1205"),
            URLQueryItem(name: "worldMapLatitudeBucket", value: "485"),
            URLQueryItem(name: "worldMapWest", value: "118"),
            URLQueryItem(name: "worldMapSouth", value: "30"),
            URLQueryItem(name: "worldMapEast", value: "123"),
            URLQueryItem(name: "worldMapNorth", value: "33"),
            URLQueryItem(name: "worldMapMaximumAssets", value: "36"),
        ]
        var request = URLRequest(url: try XCTUnwrap(components.url))
        request.setValue(
            "Bearer \(Self.legacyDebugToken)",
            forHTTPHeaderField: "Authorization"
        )

        let (_, response) = try await URLSession.shared.data(for: request)

        XCTAssertEqual(
            try XCTUnwrap(response as? HTTPURLResponse).statusCode,
            200
        )
        let filter = try XCTUnwrap(catalog.lastRequestedFilter)
        XCTAssertEqual(filter.sourceIDs, [sourceID])
        XCTAssertEqual(
            filter.tagDecisionFilters,
            [TagDecisionFilter(tagID: acceptedTagID, decision: .accepted)]
        )
        XCTAssertEqual(filter.excludedTagIDs, [excludedTagID])
        XCTAssertEqual(filter.tagMatchMode, .any)
        XCTAssertEqual(filter.availabilities, [.available, .missing])
        XCTAssertEqual(filter.mediaKinds, [.video])
        XCTAssertEqual(filter.mediaTypes, ["public.mpeg-4"])
        XCTAssertEqual(filter.tagPresence, .tagged)
        XCTAssertEqual(filter.favorite, .favorited)
        XCTAssertEqual(
            filter.worldMapSelection,
            WorldMapCatalogSelectionQuery(
                cellDegrees: 0.25,
                longitudeBucket: 1_205,
                latitudeBucket: 485,
                bounds: WorldMapCatalogBounds(
                    west: 118,
                    south: 30,
                    east: 123,
                    north: 33
                ),
                maximumAssets: 36
            )
        )
        XCTAssertEqual(catalog.lastRequestedSort, .fileNameAscending)

        var invalidRequest = URLRequest(
            url: URL(
                string: "http://127.0.0.1:\(port)/v1/assets?worldMapCellDegrees=0.25"
            )!
        )
        invalidRequest.setValue(
            "Bearer \(Self.legacyDebugToken)",
            forHTTPHeaderField: "Authorization"
        )
        let (_, invalidResponse) = try await URLSession.shared.data(for: invalidRequest)
        XCTAssertEqual(
            try XCTUnwrap(invalidResponse as? HTTPURLResponse).statusCode,
            400
        )
    }

    func testPreviewRouteConvertsPhotoKitTIFFIntoBrowserCompatibleImage() async throws {
        let assetID = UUID()
        let sourceTIFF = try XCTUnwrap(FolderReconcileTestSupport.minimalTIFFData())
        let catalog = RemoteHTTPServerTestCatalog(previewData: sourceTIFF)
        let port = UInt16.random(in: 19_000...29_000)
        let (server, _) = makeServer(port: port, catalog: catalog)
        try await server.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        defer { Task { await server.stop() } }

        var request = URLRequest(
            url: URL(
                string: "http://127.0.0.1:\(port)/v1/assets/\(assetID.uuidString)/preview"
            )!
        )
        request.setValue(
            "Bearer \(Self.legacyDebugToken)",
            forHTTPHeaderField: "Authorization"
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)

        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let outputType = try XCTUnwrap(CGImageSourceGetType(source) as String?)
        XCTAssertTrue([UTType.jpeg.identifier, UTType.png.identifier].contains(outputType))
        XCTAssertEqual(
            http.value(forHTTPHeaderField: "Content-Type"),
            outputType == UTType.png.identifier ? "image/png" : "image/jpeg"
        )
    }

    func testThumbnailRouteSelectsCachedOriginalAspectVariant() async throws {
        let assetID = UUID()
        let sourceTIFF = try XCTUnwrap(FolderReconcileTestSupport.minimalTIFFData())
        let catalog = RemoteHTTPServerTestCatalog(
            thumbnailData: sourceTIFF,
            originalAspectThumbnailData: sourceTIFF
        )
        let port = UInt16.random(in: 19_000...29_000)
        let (server, _) = makeServer(port: port, catalog: catalog)
        try await server.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        defer { Task { await server.stop() } }

        func request(aspect: String?) async throws -> HTTPURLResponse {
            var components = URLComponents(
                string: "http://127.0.0.1:\(port)/v1/assets/\(assetID.uuidString)/thumbnail"
            )!
            components.queryItems = [URLQueryItem(name: "w", value: "420")]
            if let aspect {
                components.queryItems?.append(URLQueryItem(name: "aspect", value: aspect))
            }
            var request = URLRequest(url: try XCTUnwrap(components.url))
            request.setValue(
                "Bearer \(Self.legacyDebugToken)",
                forHTTPHeaderField: "Authorization"
            )
            let (_, response) = try await URLSession.shared.data(for: request)
            return try XCTUnwrap(response as? HTTPURLResponse)
        }

        let originalResponse = try await request(aspect: "original")
        XCTAssertEqual(originalResponse.statusCode, 200)
        XCTAssertEqual(catalog.originalAspectThumbnailCallCount, 1)
        XCTAssertEqual(catalog.thumbnailCallCount, 0)

        let squareResponse = try await request(aspect: nil)
        XCTAssertEqual(squareResponse.statusCode, 200)
        XCTAssertEqual(catalog.thumbnailCallCount, 1)
    }

    func testCloudOnlyPreviewRequiresExplicitPostAndReturnsBrowserImage() async throws {
        let assetID = UUID()
        let sourceTIFF = try XCTUnwrap(FolderReconcileTestSupport.minimalTIFFData())
        let catalog = RemoteHTTPServerTestCatalog(
            previewError: .cloudOnly,
            cloudPreviewData: sourceTIFF
        )
        let port = UInt16.random(in: 19_000...29_000)
        let (server, _) = makeServer(port: port, catalog: catalog)
        try await server.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        defer { Task { await server.stop() } }

        let previewURL = URL(
            string: "http://127.0.0.1:\(port)/v1/assets/\(assetID.uuidString)/preview"
        )!
        var ordinaryRequest = URLRequest(url: previewURL)
        ordinaryRequest.setValue(
            "Bearer \(Self.legacyDebugToken)",
            forHTTPHeaderField: "Authorization"
        )
        let (ordinaryData, ordinaryResponse) = try await URLSession.shared.data(
            for: ordinaryRequest
        )
        XCTAssertEqual(
            try XCTUnwrap(ordinaryResponse as? HTTPURLResponse).statusCode,
            409
        )
        XCTAssertEqual(
            try JSONDecoder().decode(RemoteAPIError.self, from: ordinaryData),
            RemoteAPIError(code: .conflict, message: "cloud preview required")
        )

        var cloudRequest = URLRequest(
            url: URL(
                string: "http://127.0.0.1:\(port)/v1/assets/\(assetID.uuidString)/cloud-preview"
            )!
        )
        cloudRequest.httpMethod = "POST"
        cloudRequest.setValue(
            "Bearer \(Self.legacyDebugToken)",
            forHTTPHeaderField: "Authorization"
        )
        let (cloudData, cloudResponse) = try await URLSession.shared.data(for: cloudRequest)
        let cloudHTTP = try XCTUnwrap(cloudResponse as? HTTPURLResponse)
        XCTAssertEqual(cloudHTTP.statusCode, 200)
        XCTAssertEqual(catalog.cloudPreviewCallCount, 1)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(cloudData as CFData, nil))
        let outputType = try XCTUnwrap(CGImageSourceGetType(source) as String?)
        XCTAssertTrue([UTType.jpeg.identifier, UTType.png.identifier].contains(outputType))
    }

    func testCloudPreviewLifecyclePublishesProgressCancelsAndCompletes() async throws {
        let assetID = UUID()
        let catalog = RemoteHTTPServerTestCatalog(
            cloudPreviewData: Data([0x01]),
            cloudPreviewProgress: [0.2, 0.6, 1],
            cloudPreviewDelayNanoseconds: 160_000_000
        )
        let port = UInt16.random(in: 19_000...29_000)
        let (server, _) = makeServer(port: port, catalog: catalog)
        try await server.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        defer { Task { await server.stop() } }

        let baseURL = try XCTUnwrap(URL(
            string: "http://127.0.0.1:\(port)/v1/assets/\(assetID.uuidString)/cloud-preview-requests"
        ))
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        func send<T: Encodable>(
            method: String,
            url: URL,
            body: T
        ) async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.httpBody = try encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(
                "Bearer \(Self.legacyDebugToken)",
                forHTTPHeaderField: "Authorization"
            )
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, try XCTUnwrap(response as? HTTPURLResponse))
        }

        func readSnapshot() async throws -> (RemoteCloudPreviewSnapshot, HTTPURLResponse) {
            var request = URLRequest(url: baseURL)
            request.setValue(
                "Bearer \(Self.legacyDebugToken)",
                forHTTPHeaderField: "Authorization"
            )
            let (data, response) = try await URLSession.shared.data(for: request)
            return (
                try decoder.decode(RemoteCloudPreviewSnapshot.self, from: data),
                try XCTUnwrap(response as? HTTPURLResponse)
            )
        }

        let firstOperationID = UUID()
        let (startData, startResponse) = try await send(
            method: "POST",
            url: baseURL,
            body: RemoteCloudPreviewStartRequest(operationID: firstOperationID)
        )
        XCTAssertEqual(startResponse.statusCode, 202)
        XCTAssertEqual(
            try decoder.decode(RemoteCloudPreviewSnapshot.self, from: startData).phase,
            .downloading
        )

        var progressSnapshot = (try await readSnapshot()).0
        for _ in 0 ..< 20 where progressSnapshot.progress < 0.2 {
            try await Task.sleep(nanoseconds: 30_000_000)
            progressSnapshot = (try await readSnapshot()).0
        }
        XCTAssertEqual(progressSnapshot.operationID, firstOperationID)
        XCTAssertGreaterThanOrEqual(progressSnapshot.progress, 0.2)

        let cancelURL = baseURL.appending(path: "cancel")
        let (cancelData, cancelResponse) = try await send(
            method: "POST",
            url: cancelURL,
            body: RemoteCloudPreviewCancelRequest(operationID: firstOperationID)
        )
        XCTAssertEqual(cancelResponse.statusCode, 200)
        XCTAssertEqual(
            try decoder.decode(RemoteCloudPreviewSnapshot.self, from: cancelData).phase,
            .cancelled
        )
        for _ in 0 ..< 20 where catalog.cloudPreviewCancellationCount == 0 {
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertEqual(catalog.cloudPreviewCancellationCount, 1)
        let cancelledSnapshot = (try await readSnapshot()).0
        XCTAssertEqual(cancelledSnapshot.phase, .cancelled)

        let secondOperationID = UUID()
        let (_, secondStartResponse) = try await send(
            method: "POST",
            url: baseURL,
            body: RemoteCloudPreviewStartRequest(operationID: secondOperationID)
        )
        XCTAssertEqual(secondStartResponse.statusCode, 202)
        let (_, replayResponse) = try await send(
            method: "POST",
            url: baseURL,
            body: RemoteCloudPreviewStartRequest(operationID: secondOperationID)
        )
        XCTAssertEqual(replayResponse.statusCode, 202)

        var completedSnapshot = (try await readSnapshot()).0
        for _ in 0 ..< 30 where completedSnapshot.phase != .completed {
            try await Task.sleep(nanoseconds: 40_000_000)
            completedSnapshot = (try await readSnapshot()).0
        }
        XCTAssertEqual(completedSnapshot.operationID, secondOperationID)
        XCTAssertEqual(completedSnapshot.phase, .completed)
        XCTAssertEqual(completedSnapshot.progress, 1)
        XCTAssertEqual(catalog.cloudPreviewCallCount, 2)
    }

    func testWebSocketAcceptValueMatchesRFC6455Example() {
        // RFC 6455 §1.3 canonical example.
        let accept = RemoteHTTPServer.webSocketAcceptValue(secWebSocketKey: "dGhlIHNhbXBsZSBub25jZQ==")
        XCTAssertEqual(accept, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }
}

private actor RemoteHTTPWorkspaceNoticePortStub: RemoteWorkspaceNoticePort {
    private var notice: WorkspaceNoticeProjection?

    init(notice: WorkspaceNoticeProjection?) {
        self.notice = notice
    }

    func currentWorkspaceNotice() async -> WorkspaceNoticeProjection? {
        notice
    }

    func dismissWorkspaceNotice(noticeID: String) async -> Bool {
        guard notice?.id == noticeID else { return false }
        notice = nil
        return true
    }

    func performWorkspaceNoticeAction(noticeID: String, actionID: String) async -> Bool {
        guard let notice, notice.id == noticeID else { return false }
        return notice.actions.contains(where: { $0.id == actionID })
    }

    func replace(with notice: WorkspaceNoticeProjection?) {
        self.notice = notice
    }
}

private final class RemoteHTTPTrainingWorkspaceStub: TrainingWorkspacePort, @unchecked Sendable {
    private let lock = NSLock()
    private let storedSnapshot: TrainingWorkspaceSnapshot
    private var storedLastMediaKind: MediaKind?
    private var storedLastMethod: TrainingRunMethod?

    var lastMediaKind: MediaKind? { lock.withLock { storedLastMediaKind } }
    var lastMethod: TrainingRunMethod? { lock.withLock { storedLastMethod } }

    init(snapshot: TrainingWorkspaceSnapshot) {
        storedSnapshot = snapshot
    }

    func snapshot(
        mediaKind: MediaKind,
        method: TrainingRunMethod?,
        limit: Int
    ) throws -> TrainingWorkspaceSnapshot {
        _ = limit
        lock.withLock {
            storedLastMediaKind = mediaKind
            storedLastMethod = method
        }
        return storedSnapshot
    }
}

private final class RemoteHTTPTrainingCommandStub: RemoteTrainingCommandPort, @unchecked Sendable {
    private let lock = NSLock()
    private let setupSnapshot: TrainingCommandSetupSnapshot
    private let receipt: TrainingLaunchReceipt
    private let trainingActivity: TrainingCommandActivitySnapshot?
    private let embeddingActivity: EmbeddingPreparationActivitySnapshot?
    private let sampleActivity: SampleSuggestionActivitySnapshot?
    private let tagSuggestionActivity: TagLibrarySuggestionActivitySnapshot?
    private let tagSuggestionOption: TagLibrarySuggestionTagOption?
    private let librarySuggestionSnapshot: LibrarySuggestionWorkspaceSnapshot?
    private let librarySuggestionReceipt: LibrarySuggestionReceipt?
    private let assetLocalSuggestionSnapshot: AssetLocalSuggestionSnapshot?
    private var storedLaunchCallCount = 0
    private var storedCancelCallCount = 0
    private var storedLastCommand: TrainingLaunchCommand?
    private var storedEmbeddingPrepareCallCount = 0
    private var storedEmbeddingCancelCallCount = 0
    private var storedSampleSuggestionSubmitCallCount = 0
    private var storedSampleSuggestionCancelCallCount = 0
    private var storedTagSuggestionSubmitCallCount = 0
    private var storedTagSuggestionCancelCallCount = 0
    private var storedLibrarySuggestionSnapshotCallCount = 0
    private var storedLibrarySuggestionLaunchCallCount = 0
    private var storedLastLibrarySuggestionMediaKind: MediaKind?
    private var storedLastLibrarySuggestionRefreshHealth = false
    private var storedLastLibrarySuggestionCommand: LibrarySuggestionCommand?
    private var storedAssetLocalSuggestionCallCount = 0
    private var storedLastAssetLocalSuggestionCommand: AssetLocalSuggestionCommand?

    var launchCallCount: Int { lock.withLock { storedLaunchCallCount } }
    var cancelCallCount: Int { lock.withLock { storedCancelCallCount } }
    var lastCommand: TrainingLaunchCommand? { lock.withLock { storedLastCommand } }
    var embeddingPrepareCallCount: Int { lock.withLock { storedEmbeddingPrepareCallCount } }
    var embeddingCancelCallCount: Int { lock.withLock { storedEmbeddingCancelCallCount } }
    var sampleSuggestionSubmitCallCount: Int {
        lock.withLock { storedSampleSuggestionSubmitCallCount }
    }
    var sampleSuggestionCancelCallCount: Int {
        lock.withLock { storedSampleSuggestionCancelCallCount }
    }
    var tagSuggestionSubmitCallCount: Int {
        lock.withLock { storedTagSuggestionSubmitCallCount }
    }
    var tagSuggestionCancelCallCount: Int {
        lock.withLock { storedTagSuggestionCancelCallCount }
    }
    var librarySuggestionSnapshotCallCount: Int {
        lock.withLock { storedLibrarySuggestionSnapshotCallCount }
    }
    var librarySuggestionLaunchCallCount: Int {
        lock.withLock { storedLibrarySuggestionLaunchCallCount }
    }
    var lastLibrarySuggestionMediaKind: MediaKind? {
        lock.withLock { storedLastLibrarySuggestionMediaKind }
    }
    var lastLibrarySuggestionRefreshHealth: Bool {
        lock.withLock { storedLastLibrarySuggestionRefreshHealth }
    }
    var lastLibrarySuggestionCommand: LibrarySuggestionCommand? {
        lock.withLock { storedLastLibrarySuggestionCommand }
    }
    var assetLocalSuggestionCallCount: Int {
        lock.withLock { storedAssetLocalSuggestionCallCount }
    }
    var lastAssetLocalSuggestionCommand: AssetLocalSuggestionCommand? {
        lock.withLock { storedLastAssetLocalSuggestionCommand }
    }

    init(
        setupSnapshot: TrainingCommandSetupSnapshot,
        receipt: TrainingLaunchReceipt,
        trainingActivity: TrainingCommandActivitySnapshot? = nil,
        embeddingActivity: EmbeddingPreparationActivitySnapshot? = nil,
        sampleActivity: SampleSuggestionActivitySnapshot? = nil,
        tagSuggestionActivity: TagLibrarySuggestionActivitySnapshot? = nil,
        tagSuggestionOption: TagLibrarySuggestionTagOption? = nil,
        librarySuggestionSnapshot: LibrarySuggestionWorkspaceSnapshot? = nil,
        librarySuggestionReceipt: LibrarySuggestionReceipt? = nil,
        assetLocalSuggestionSnapshot: AssetLocalSuggestionSnapshot? = nil
    ) {
        self.setupSnapshot = setupSnapshot
        self.receipt = receipt
        self.trainingActivity = trainingActivity
        self.embeddingActivity = embeddingActivity
        self.sampleActivity = sampleActivity
        self.tagSuggestionActivity = tagSuggestionActivity
        self.tagSuggestionOption = tagSuggestionOption
        self.librarySuggestionSnapshot = librarySuggestionSnapshot
        self.librarySuggestionReceipt = librarySuggestionReceipt
        self.assetLocalSuggestionSnapshot = assetLocalSuggestionSnapshot
    }

    func assetLocalSuggestions(
        _ command: AssetLocalSuggestionCommand
    ) async throws -> AssetLocalSuggestionSnapshot {
        guard let snapshot = assetLocalSuggestionSnapshot else {
            throw TrainingCommandError.unavailable
        }
        lock.withLock {
            storedAssetLocalSuggestionCallCount += 1
            storedLastAssetLocalSuggestionCommand = command
        }
        return AssetLocalSuggestionSnapshot(
            operationID: command.operationID,
            assetID: command.assetID,
            track: command.track,
            state: snapshot.state,
            suggestions: snapshot.suggestions,
            replayed: snapshot.replayed
        )
    }

    func setup(mediaKind: MediaKind) async throws -> TrainingCommandSetupSnapshot {
        XCTAssertEqual(mediaKind, setupSnapshot.mediaKind)
        return setupSnapshot
    }

    func launch(_ command: TrainingLaunchCommand) async throws -> TrainingLaunchReceipt {
        lock.withLock {
            storedLaunchCallCount += 1
            storedLastCommand = command
        }
        return TrainingLaunchReceipt(
            operationID: command.operationID,
            method: receipt.method,
            acceptedAtMs: receipt.acceptedAtMs,
            scheduledTagCount: receipt.scheduledTagCount,
            jobID: receipt.jobID
        )
    }

    func activities(mediaKind: MediaKind) async -> [TrainingCommandActivitySnapshot] {
        guard let trainingActivity, trainingActivity.mediaKind == mediaKind else { return [] }
        return [trainingActivity]
    }

    func cancelActivity(operationID: UUID) async throws -> TrainingCommandActivitySnapshot {
        lock.withLock { storedCancelCallCount += 1 }
        return TrainingCommandActivitySnapshot(
            operationID: operationID,
            mediaKind: .image,
            method: .personalCentroid,
            phase: .cancelled,
            completedUnitCount: 0,
            totalUnitCount: 1,
            sampleCount: nil,
            errorCode: nil
        )
    }

    func embeddingPreparationAvailable() async -> Bool {
        embeddingActivity != nil
    }

    func prepareEmbeddings(
        _ command: EmbeddingPreparationCommand
    ) async throws -> EmbeddingPreparationReceipt {
        guard let embeddingActivity else { throw TrainingCommandError.unavailable }
        lock.withLock { storedEmbeddingPrepareCallCount += 1 }
        XCTAssertEqual(command.operationID, embeddingActivity.operationID)
        return EmbeddingPreparationReceipt(activity: embeddingActivity, replayed: false)
    }

    func embeddingPreparationActivities(
        mediaKind: MediaKind
    ) async -> [EmbeddingPreparationActivitySnapshot] {
        guard let embeddingActivity, embeddingActivity.mediaKind == mediaKind else { return [] }
        return [embeddingActivity]
    }

    func cancelEmbeddingPreparation(
        operationID: UUID
    ) async throws -> EmbeddingPreparationActivitySnapshot {
        guard let embeddingActivity, embeddingActivity.operationID == operationID else {
            throw TrainingCommandError.activityNotFound
        }
        lock.withLock { storedEmbeddingCancelCallCount += 1 }
        return EmbeddingPreparationActivitySnapshot(
            operationID: operationID,
            mediaKind: embeddingActivity.mediaKind,
            phase: .cancelled,
            completedUnitCount: embeddingActivity.completedUnitCount,
            totalUnitCount: embeddingActivity.totalUnitCount,
            preparedCount: embeddingActivity.preparedCount,
            cachedCount: embeddingActivity.cachedCount,
            cloudOnlyCount: embeddingActivity.cloudOnlyCount,
            failedCount: embeddingActivity.failedCount,
            errorCode: nil
        )
    }

    func sampleSuggestionsAvailable(mediaKind: MediaKind) async -> Bool {
        sampleActivity?.mediaKind == mediaKind
    }

    func generateSampleSuggestions(
        _ command: SampleSuggestionCommand
    ) async throws -> SampleSuggestionReceipt {
        guard let sampleActivity else { throw TrainingCommandError.unavailable }
        lock.withLock { storedSampleSuggestionSubmitCallCount += 1 }
        XCTAssertEqual(command.operationID, sampleActivity.operationID)
        return SampleSuggestionReceipt(activity: sampleActivity, replayed: false)
    }

    func sampleSuggestionActivities(
        mediaKind: MediaKind
    ) async -> [SampleSuggestionActivitySnapshot] {
        guard let sampleActivity, sampleActivity.mediaKind == mediaKind else { return [] }
        return [sampleActivity]
    }

    func cancelSampleSuggestions(
        operationID: UUID
    ) async throws -> SampleSuggestionActivitySnapshot {
        guard let sampleActivity, sampleActivity.operationID == operationID else {
            throw TrainingCommandError.activityNotFound
        }
        lock.withLock { storedSampleSuggestionCancelCallCount += 1 }
        return SampleSuggestionActivitySnapshot(
            operationID: operationID,
            mediaKind: sampleActivity.mediaKind,
            phase: .cancelled,
            completedUnitCount: sampleActivity.completedUnitCount,
            totalUnitCount: sampleActivity.totalUnitCount,
            suggestedCount: sampleActivity.suggestedCount,
            skippedCount: sampleActivity.skippedCount,
            errorCode: nil
        )
    }

    func tagLibrarySuggestionsAvailable(
        mediaKind: MediaKind,
        method: TagLibrarySuggestionMethod
    ) async -> Bool {
        guard let tagSuggestionActivity else { return false }
        return tagSuggestionActivity.mediaKind == mediaKind
            && tagSuggestionActivity.method == method
    }

    func tagLibrarySuggestionTagOptions(
        mediaKind: MediaKind
    ) async throws -> [TagLibrarySuggestionTagOption] {
        guard mediaKind == tagSuggestionActivity?.mediaKind,
              let tagSuggestionOption
        else { return [] }
        return [tagSuggestionOption]
    }

    func generateTagLibrarySuggestions(
        _ command: TagLibrarySuggestionCommand
    ) async throws -> TagLibrarySuggestionReceipt {
        guard let tagSuggestionActivity else { throw TrainingCommandError.unavailable }
        lock.withLock { storedTagSuggestionSubmitCallCount += 1 }
        XCTAssertEqual(command.operationID, tagSuggestionActivity.operationID)
        XCTAssertEqual(command.tagID, tagSuggestionActivity.tagID)
        XCTAssertFalse(command.sourceIDs.isEmpty)
        return TagLibrarySuggestionReceipt(activity: tagSuggestionActivity, replayed: false)
    }

    func tagLibrarySuggestionActivities(
        mediaKind: MediaKind
    ) async -> [TagLibrarySuggestionActivitySnapshot] {
        guard let tagSuggestionActivity, tagSuggestionActivity.mediaKind == mediaKind else {
            return []
        }
        return [tagSuggestionActivity]
    }

    func cancelTagLibrarySuggestions(
        operationID: UUID
    ) async throws -> TagLibrarySuggestionActivitySnapshot {
        guard let tagSuggestionActivity,
              tagSuggestionActivity.operationID == operationID
        else { throw TrainingCommandError.activityNotFound }
        lock.withLock { storedTagSuggestionCancelCallCount += 1 }
        return TagLibrarySuggestionActivitySnapshot(
            operationID: operationID,
            mediaKind: tagSuggestionActivity.mediaKind,
            method: tagSuggestionActivity.method,
            tagID: tagSuggestionActivity.tagID,
            phase: .cancelled,
            completedUnitCount: tagSuggestionActivity.completedUnitCount,
            totalUnitCount: tagSuggestionActivity.totalUnitCount,
            aboveThresholdCount: tagSuggestionActivity.aboveThresholdCount,
            insertedCount: tagSuggestionActivity.insertedCount,
            skippedCount: tagSuggestionActivity.skippedCount,
            errorCode: nil
        )
    }

    func librarySuggestions(
        mediaKind: MediaKind,
        refreshServiceHealth: Bool
    ) async throws -> LibrarySuggestionWorkspaceSnapshot {
        guard let librarySuggestionSnapshot else {
            throw TrainingCommandError.unavailable
        }
        lock.withLock {
            storedLibrarySuggestionSnapshotCallCount += 1
            storedLastLibrarySuggestionMediaKind = mediaKind
            storedLastLibrarySuggestionRefreshHealth = refreshServiceHealth
        }
        return librarySuggestionSnapshot
    }

    func generateLibrarySuggestions(
        _ command: LibrarySuggestionCommand
    ) async throws -> LibrarySuggestionReceipt {
        guard let librarySuggestionReceipt else {
            throw TrainingCommandError.unavailable
        }
        lock.withLock {
            storedLibrarySuggestionLaunchCallCount += 1
            storedLastLibrarySuggestionCommand = command
        }
        return LibrarySuggestionReceipt(
            operationID: command.operationID,
            track: librarySuggestionReceipt.track,
            jobID: librarySuggestionReceipt.jobID,
            replayed: librarySuggestionReceipt.replayed
        )
    }
}

@MainActor
private final class RemoteOriginalAssetOpenerSpy: LibraryOriginalAssetOpening {
    private(set) var openedAssetIDs: [UUID] = []

    func openOriginalAsset(assetID: UUID) async throws {
        openedAssetIDs.append(assetID)
    }
}

private final class RemoteHTTPServerTestCatalog: RemoteCatalogServing, @unchecked Sendable {
    private let lock = NSLock()
    private var storedLastRequestedFilter: AssetPageFilter?
    private var storedLastRequestedSort: AssetPageSort?
    private let previewData: Data
    private let thumbnailData: Data
    private let originalAspectThumbnailData: Data?
    private let previewError: PhotosLibraryError?
    private let cloudPreviewData: Data
    private let cloudPreviewProgress: [Double]
    private let cloudPreviewDelayNanoseconds: UInt64
    private let createTagResult: TagCreateAndApplyResult?
    private let presetInstallResult: TagPresetInstallResult?
    private let worldMapLocationBackfills: [WorldMapLocationBackfillSnapshot]
    private let worldMapPlaceResolutions: [WorldMapPlaceTagResolution]
    private let worldMapPlaceSearchResult: WorldMapPlaceTagResolution?
    private let worldMapPlaceConfirmResult: WorldMapPlaceTagResolution?
    private var storedCreateTagCallCount = 0
    private var storedCloudPreviewCallCount = 0
    private var storedCloudPreviewCancellationCount = 0
    private var storedThumbnailCallCount = 0
    private var storedOriginalAspectThumbnailCallCount = 0
    private var storedPresetInstallCallCount = 0
    private var storedWorldMapLocationBackfillStartCount = 0
    private var storedWorldMapPlaceSearchCount = 0
    private var storedFavoriteMutationCallCount = 0
    private var storedFavoriteRetryCallCount = 0
    private var storedFavoriteStates: [UUID: MediaFavoriteState] = [:]

    init(
        thumbnailData: Data = Data(),
        originalAspectThumbnailData: Data? = nil,
        previewData: Data = Data(),
        previewError: PhotosLibraryError? = nil,
        cloudPreviewData: Data = Data(),
        cloudPreviewProgress: [Double] = [],
        cloudPreviewDelayNanoseconds: UInt64 = 0,
        createTagResult: TagCreateAndApplyResult? = nil,
        presetInstallResult: TagPresetInstallResult? = nil,
        worldMapLocationBackfills: [WorldMapLocationBackfillSnapshot] = [],
        worldMapPlaceResolutions: [WorldMapPlaceTagResolution] = [],
        worldMapPlaceSearchResult: WorldMapPlaceTagResolution? = nil,
        worldMapPlaceConfirmResult: WorldMapPlaceTagResolution? = nil
    ) {
        self.thumbnailData = thumbnailData
        self.originalAspectThumbnailData = originalAspectThumbnailData
        self.previewData = previewData
        self.previewError = previewError
        self.cloudPreviewData = cloudPreviewData
        self.cloudPreviewProgress = cloudPreviewProgress
        self.cloudPreviewDelayNanoseconds = cloudPreviewDelayNanoseconds
        self.createTagResult = createTagResult
        self.presetInstallResult = presetInstallResult
        self.worldMapLocationBackfills = worldMapLocationBackfills
        self.worldMapPlaceResolutions = worldMapPlaceResolutions
        self.worldMapPlaceSearchResult = worldMapPlaceSearchResult
        self.worldMapPlaceConfirmResult = worldMapPlaceConfirmResult
    }

    var cloudPreviewCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCloudPreviewCallCount
    }

    var cloudPreviewCancellationCount: Int {
        lock.withLock { storedCloudPreviewCancellationCount }
    }

    var thumbnailCallCount: Int {
        lock.withLock { storedThumbnailCallCount }
    }

    var originalAspectThumbnailCallCount: Int {
        lock.withLock { storedOriginalAspectThumbnailCallCount }
    }

    var lastRequestedFilter: AssetPageFilter? {
        lock.lock()
        defer { lock.unlock() }
        return storedLastRequestedFilter
    }

    var lastRequestedSort: AssetPageSort? {
        lock.lock()
        defer { lock.unlock() }
        return storedLastRequestedSort
    }

    var createTagCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCreateTagCallCount
    }

    var presetInstallCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedPresetInstallCallCount
    }

    var worldMapLocationBackfillStartCount: Int {
        lock.withLock { storedWorldMapLocationBackfillStartCount }
    }

    var worldMapPlaceSearchCount: Int {
        lock.withLock { storedWorldMapPlaceSearchCount }
    }

    var favoriteMutationCallCount: Int {
        lock.withLock { storedFavoriteMutationCallCount }
    }

    var favoriteRetryCallCount: Int {
        lock.withLock { storedFavoriteRetryCallCount }
    }

    func fetchSources() throws -> [LibrarySourceSummary] { [] }

    func listTags() throws -> [TagListItem] { [] }

    func installPresetTags() throws -> TagPresetInstallResult {
        lock.lock()
        storedPresetInstallCallCount += 1
        lock.unlock()
        return presetInstallResult ?? TagPresetInstallResult(createdTags: [])
    }

    func fetchAssetPage(
        filter: AssetPageFilter,
        sort: AssetPageSort,
        cursor: AssetPageCursor?,
        limit: Int
    ) throws -> AssetPageResult {
        _ = cursor
        _ = limit
        lock.lock()
        storedLastRequestedFilter = filter
        storedLastRequestedSort = sort
        lock.unlock()
        return AssetPageResult(items: [], nextCursor: nil)
    }

    func fetchFavoriteStates(assetIDs: [UUID]) throws -> [UUID: MediaFavoriteState] {
        lock.withLock {
            Dictionary(uniqueKeysWithValues: assetIDs.map { assetID in
                (assetID, storedFavoriteStates[assetID] ?? .none(assetID: assetID))
            })
        }
    }

    func setFavorite(assetIDs: [UUID], isFavorite: Bool) throws -> FavoriteMutationSummary {
        lock.withLock {
            storedFavoriteMutationCallCount += 1
            var changedCount = 0
            for assetID in assetIDs {
                let previous = storedFavoriteStates[assetID] ?? .none(assetID: assetID)
                if previous.isFavorite != isFavorite { changedCount += 1 }
                storedFavoriteStates[assetID] = MediaFavoriteState(
                    assetID: assetID,
                    isFavorite: isFavorite,
                    photosObservedValue: nil,
                    syncStatus: .localOnly,
                    intentRevision: 1,
                    requestedAtMs: 123,
                    photosObservedModifiedAtMs: nil,
                    lastErrorCode: nil
                )
            }
            return FavoriteMutationSummary(
                changedCount: changedCount,
                localOnlyCount: assetIDs.count,
                syncedCount: 0,
                pendingCount: 0,
                failedCount: 0
            )
        }
    }

    func retryPendingFavoriteSync(sourceIDs: Set<UUID>?) throws -> FavoriteMutationSummary {
        XCTAssertNil(sourceIDs)
        return lock.withLock {
            storedFavoriteRetryCallCount += 1
            return FavoriteMutationSummary(
                changedCount: 0,
                localOnlyCount: 0,
                syncedCount: storedFavoriteStates.count,
                pendingCount: 0,
                failedCount: 0
            )
        }
    }

    func loadThumbnail(assetID: UUID) async throws -> Data {
        _ = assetID
        return lock.withLock {
            storedThumbnailCallCount += 1
            return thumbnailData
        }
    }

    func loadOriginalAspectThumbnailIfCached(assetID: UUID) async throws -> Data? {
        _ = assetID
        return lock.withLock {
            storedOriginalAspectThumbnailCallCount += 1
            return originalAspectThumbnailData
        }
    }

    func loadPreview(assetID: UUID) async throws -> Data {
        if let previewError { throw previewError }
        return previewData
    }

    func downloadCloudPreview(
        assetID: UUID,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> Data {
        _ = assetID
        lock.withLock {
            storedCloudPreviewCallCount += 1
        }
        do {
            let progressValues = cloudPreviewProgress.isEmpty ? [1] : cloudPreviewProgress
            for progress in progressValues {
                try Task.checkCancellation()
                onProgress(progress)
                if cloudPreviewDelayNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: cloudPreviewDelayNanoseconds)
                }
            }
            try Task.checkCancellation()
            return cloudPreviewData
        } catch is CancellationError {
            lock.withLock {
                storedCloudPreviewCancellationCount += 1
            }
            throw CancellationError()
        }
    }

    func fetchInspectorDetail(assetID: UUID) throws -> AssetInspectorDetail {
        AssetInspectorDetail(
            assetID: assetID,
            sourceID: UUID(),
            sourceDisplayName: "",
            sourceState: .active,
            relativePath: nil,
            fileName: nil,
            mediaType: "image",
            mediaCreatedAtMs: nil,
            mediaModifiedAtMs: nil,
            width: nil,
            height: nil,
            availability: .available,
            contentRevision: 0,
            acceptedTagCount: 0,
            rejectedTagCount: 0,
            fingerprintSizeBytes: nil,
            fingerprintModifiedAtNs: nil,
            tags: []
        )
    }

    func fetchWorldMapLocationBackfillSnapshots() throws
        -> [WorldMapLocationBackfillSnapshot]
    {
        worldMapLocationBackfills
    }

    func startWorldMapLocationBackfill(sourceID: UUID) throws {
        _ = sourceID
        lock.withLock { storedWorldMapLocationBackfillStartCount += 1 }
    }

    func cancelWorldMapLocationBackfill(sourceID: UUID) throws {
        _ = sourceID
    }

    func fetchWorldMapPlaceTagResolutions() throws -> [WorldMapPlaceTagResolution] {
        worldMapPlaceResolutions
    }

    func searchWorldMapPlaceTag(
        tagID: UUID,
        query: String
    ) async throws -> WorldMapPlaceTagResolution {
        _ = tagID
        _ = query
        lock.withLock { storedWorldMapPlaceSearchCount += 1 }
        guard let worldMapPlaceSearchResult else { throw CatalogQueryError.notFound }
        return worldMapPlaceSearchResult
    }

    func confirmWorldMapPlaceCandidate(
        tagID: UUID,
        placeID: String
    ) throws -> WorldMapPlaceTagResolution {
        _ = tagID
        _ = placeID
        guard let worldMapPlaceConfirmResult else { throw CatalogQueryError.notFound }
        return worldMapPlaceConfirmResult
    }

    func selectionAggregate(tagIDs: [UUID], assetIDs: [UUID]) throws -> [TagSelectionAggregate] { [] }

    func mutateTag(
        tagID: UUID,
        assetIDs: [UUID],
        action: LibraryTagDecisionAction
    ) throws -> TagMutationPriorStateSnapshot {
        TagMutationPriorStateSnapshot(tagID: tagID, priorStates: [])
    }

    func createTagAndAccept(
        rawName: String,
        assetIDs: [UUID]
    ) throws -> TagCreateAndApplyResult {
        lock.lock()
        storedCreateTagCallCount += 1
        lock.unlock()
        return createTagResult ?? TagCreateAndApplyResult(
            tagID: UUID(),
            displayName: rawName,
            normalizedName: rawName,
            priorStates: assetIDs.map {
                TagMutationPriorState(assetID: $0, priorState: .unknown)
            }
        )
    }

    func fetchJobActivity() throws -> [JobActivityItem] { [] }

    func applyJobActivityAction(_ action: JobActivityAction, jobID: UUID) throws {}
}

private final class RemoteHTTPServerSlimmingAnalysisStub:
    LibrarySlimmingAnalysisJobPort,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storedLastMediaKind: MediaKind?

    var lastMediaKind: MediaKind? { lock.withLock { storedLastMediaKind } }

    func enqueue(
        mode _: LibrarySlimmingAnalyzeMode,
        assetIDs _: [UUID],
        seedAssetIDs _: [UUID]
    ) throws -> LibrarySlimmingAnalysisJobSnapshot {
        throw CatalogQueryError.notFound
    }

    func runPending() throws {}
    func pause(jobID _: UUID) throws -> LibrarySlimmingAnalysisJobSnapshot {
        throw CatalogQueryError.notFound
    }
    func resume(jobID _: UUID) throws -> LibrarySlimmingAnalysisJobSnapshot {
        throw CatalogQueryError.notFound
    }
    func snapshot(jobID _: UUID) throws -> LibrarySlimmingAnalysisJobSnapshot {
        throw CatalogQueryError.notFound
    }
    func latestActiveOrCompleted() throws -> LibrarySlimmingAnalysisJobSnapshot? { nil }
    func listJobs() throws -> [LibrarySlimmingAnalysisJobSummary] { [] }
    func listJobs(mediaKind: MediaKind) throws -> [LibrarySlimmingAnalysisJobSummary] {
        lock.withLock { storedLastMediaKind = mediaKind }
        return []
    }
    func delete(jobID _: UUID) throws {}
}

private final class RemoteHTTPSlimmingCommandStub:
    RemoteLibrarySlimmingCommandPort,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let sourceID: UUID
    private let jobID: UUID
    let recycleEntryID = UUID()
    let recycleAssetID = UUID()
    private var storedLaunchCount = 0
    private var storedSourceMaintenanceCount = 0
    private var storedLastAction: LibrarySlimmingJobCommandAction?
    private var storedLastClusterReviewJobID: UUID?
    private var storedLastClusterReviewClusterID: UUID?
    private var storedLastClusterReviewDisposition: LibrarySlimmingClusterReviewDisposition?
    private var storedLastRecycleCommand: LibrarySlimmingRecycleCommandRequest?
    private var storedLastRemovalCommand: LibrarySlimmingRemovalCommand?
    private var storedLastIdenticalCleanupCommand: LibrarySlimmingIdenticalCleanupCommand?
    private let identicalCleanupPlanID = UUID()

    var launchCount: Int { lock.withLock { storedLaunchCount } }
    var sourceMaintenanceCount: Int { lock.withLock { storedSourceMaintenanceCount } }
    var lastAction: LibrarySlimmingJobCommandAction? { lock.withLock { storedLastAction } }
    var lastClusterReviewJobID: UUID? { lock.withLock { storedLastClusterReviewJobID } }
    var lastClusterReviewClusterID: UUID? { lock.withLock { storedLastClusterReviewClusterID } }
    var lastClusterReviewDisposition: LibrarySlimmingClusterReviewDisposition? {
        lock.withLock { storedLastClusterReviewDisposition }
    }
    var lastRecycleCommand: LibrarySlimmingRecycleCommandRequest? {
        lock.withLock { storedLastRecycleCommand }
    }
    var lastRemovalCommand: LibrarySlimmingRemovalCommand? {
        lock.withLock { storedLastRemovalCommand }
    }
    var lastIdenticalCleanupCommand: LibrarySlimmingIdenticalCleanupCommand? {
        lock.withLock { storedLastIdenticalCleanupCommand }
    }

    init(sourceID: UUID, jobID: UUID) {
        self.sourceID = sourceID
        self.jobID = jobID
    }

    private var thresholds: NearDuplicateSceneThresholds {
        NearDuplicateSceneThresholds(
            featurePrintRecallTopK: 32,
            featurePrintMaxL2Distance: 0.4,
            dinoCosineMinSimilarity: 0.85,
            sceneBucketActivationAssetCount: 700,
            featurePrintRecallMode: .topK,
            featurePrintL2Mode: .radius,
            dinoCosineMode: .minimum,
            sceneBucketingMode: .automatic
        )
    }

    func setup(mediaKind: MediaKind) async throws -> LibrarySlimmingCommandSetupSnapshot {
        LibrarySlimmingCommandSetupSnapshot(
            mediaKind: mediaKind,
            sources: [
                LibrarySourceSummary(
                    id: sourceID,
                    kind: .photos,
                    displayName: "Apple Photos",
                    state: .active
                ),
            ],
            thresholds: thresholds,
            factoryThresholds: .factory,
            sourceSimilarityIndexAvailable: true,
            sourceSimilarityIndexStatuses: [
                sourceID: SourceSimilarityIndexStatus(
                    sourceID: sourceID,
                    mediaKind: mediaKind,
                    state: .ready,
                    assetCount: 12,
                    indexedCount: 12,
                    clusterCount: 3,
                    pendingCount: 0,
                    updatedAtMs: 123,
                    lastError: nil
                ),
            ]
        )
    }

    func maintainSources(
        _ command: LibrarySlimmingSourceMaintenanceCommand
    ) async throws -> LibrarySlimmingCommandSetupSnapshot {
        lock.withLock { storedSourceMaintenanceCount += 1 }
        return try await setup(mediaKind: command.mediaKind)
    }

    func launch(_ command: LibrarySlimmingLaunchCommand) async throws
        -> LibrarySlimmingLaunchReceipt
    {
        lock.withLock { storedLaunchCount += 1 }
        return LibrarySlimmingLaunchReceipt(
            operationID: command.operationID,
            jobID: jobID,
            acceptedAtMs: 123,
            memberCount: 12
        )
    }

    func apply(
        jobID: UUID,
        action: LibrarySlimmingJobCommandAction
    ) async throws -> LibrarySlimmingJobCommandResult {
        XCTAssertEqual(jobID, self.jobID)
        lock.withLock { storedLastAction = action }
        return LibrarySlimmingJobCommandResult(snapshot: nil, deleted: action == .deleteRecord)
    }

    func updateThresholds(_ thresholds: NearDuplicateSceneThresholds) async throws
        -> NearDuplicateSceneThresholds
    {
        thresholds
    }

    func setClusterReviewDisposition(
        jobID: UUID,
        clusterID: UUID,
        disposition: LibrarySlimmingClusterReviewDisposition?
    ) async throws -> LibrarySlimmingClusterReviewDisposition? {
        lock.withLock {
            storedLastClusterReviewJobID = jobID
            storedLastClusterReviewClusterID = clusterID
            storedLastClusterReviewDisposition = disposition
        }
        return disposition
    }

    func recycleSnapshot(
        mediaKind: MediaKind,
        sourceID _: UUID?,
        searchText _: String?,
        scope: LibrarySlimmingRecycleCommandScope,
        limit _: Int
    ) async throws -> LibrarySlimmingRecycleCommandSnapshot {
        XCTAssertEqual(scope, .files)
        return LibrarySlimmingRecycleCommandSnapshot(
            entries: [
                RecycleEntryRecord(
                    id: recycleEntryID,
                    assetID: recycleAssetID,
                    sourceID: sourceID,
                    sourceKind: .file,
                    mediaKind: mediaKind,
                    trashedAtMs: 100,
                    purgeAfterMs: 200,
                    state: .recycled,
                    quarantineRelativePath: "private/quarantine",
                    originalRelativePath: "private/original",
                    photosLocalIdentifier: nil,
                    errorCode: nil,
                    fileName: "IMG_0001.HEIC"
                ),
            ],
            totalCount: 1,
            sourceNames: [sourceID: "Archive"],
            requests: [],
            scopeCounts: LibrarySlimmingRecycleCommandScopeCounts(
                all: 1,
                photos: 0,
                files: 1,
                attention: 0
            )
        )
    }

    func submitRecycle(
        _ command: LibrarySlimmingRecycleCommandRequest
    ) async throws -> LibrarySlimmingRecycleCommandRequestSnapshot {
        lock.withLock { storedLastRecycleCommand = command }
        return LibrarySlimmingRecycleCommandRequestSnapshot(
            id: UUID(),
            operationID: command.operationID,
            entryID: command.entryID,
            action: command.action,
            fileName: "IMG_0001.HEIC",
            phase: .awaitingMac,
            message: "请回到 Mac 完成原生确认",
            updatedAtMs: 123
        )
    }

    func removalSnapshot(
        mediaKind: MediaKind
    ) async throws -> LibrarySlimmingRemovalCommandSnapshot {
        let assetID = UUID()
        return LibrarySlimmingRemovalCommandSnapshot(requests: [
            LibrarySlimmingRemovalCommandRequestSnapshot(
                id: UUID(),
                operationID: UUID(),
                scope: .analysisCluster,
                jobID: jobID,
                clusterID: UUID(),
                mediaKind: mediaKind,
                assetIDs: [assetID],
                mode: .recoverableRecycle,
                phase: .running,
                progress: LibrarySlimmingRemovalCommandProgress(
                    phase: .copying,
                    completedAssetCount: 1,
                    totalAssetCount: 2,
                    copiedBytes: 32,
                    totalFileBytes: 64
                ),
                audit: nil,
                message: "正在复制到可恢复隔离区…",
                updatedAtMs: 456
            ),
        ])
    }

    func submitRemoval(
        _ command: LibrarySlimmingRemovalCommand
    ) async throws -> LibrarySlimmingRemovalCommandRequestSnapshot {
        lock.withLock { storedLastRemovalCommand = command }
        return LibrarySlimmingRemovalCommandRequestSnapshot(
            id: UUID(),
            operationID: command.operationID,
            scope: command.scope,
            jobID: command.jobID,
            clusterID: command.clusterID,
            mediaKind: command.mediaKind,
            assetIDs: command.assetIDs,
            mode: command.mode,
            phase: .awaitingMac,
            progress: nil,
            audit: nil,
            message: "请回到 Mac 核对并确认这次批量操作",
            updatedAtMs: 456
        )
    }

    func prepareIdenticalCleanup(
        jobID: UUID,
        mediaKind: MediaKind
    ) async throws -> LibrarySlimmingIdenticalCleanupPlanSnapshot {
        XCTAssertEqual(jobID, self.jobID)
        return LibrarySlimmingIdenticalCleanupPlanSnapshot(
            id: identicalCleanupPlanID,
            jobID: jobID,
            mediaKind: mediaKind,
            groupCount: 2,
            byteIdenticalGroupCount: 1,
            perfectVisualGroupCount: 1,
            verifiedAssetCount: 5,
            retainedAssetCount: 2,
            favoriteRetainedAssetCount: 1,
            ordinaryRetainedAssetCount: 1,
            protectedSkippedAssetCount: 2,
            removalAssetCount: 3,
            skippedGroupCount: 1,
            photosAssetCount: 1,
            fileAssetCount: 2,
            groupSizeHistogram: [2: 1, 3: 1],
            preparedAtMs: 456
        )
    }

    func identicalCleanupSnapshot(
        mediaKind: MediaKind
    ) async throws -> LibrarySlimmingIdenticalCleanupSnapshot {
        LibrarySlimmingIdenticalCleanupSnapshot(requests: [
            LibrarySlimmingIdenticalCleanupRequestSnapshot(
                id: UUID(),
                operationID: UUID(),
                planID: identicalCleanupPlanID,
                jobID: jobID,
                mediaKind: mediaKind,
                mode: .recoverableRecycle,
                phase: .completed,
                executionStage: .verifyingResult,
                progress: nil,
                audit: nil,
                verification: LibrarySlimmingIdenticalCleanupVerificationSnapshot(
                    verifiedGroupCount: 2,
                    targetGroupCount: 2,
                    targetRetainedAssetCount: 2,
                    observedAssetCount: 5,
                    currentAvailableAssetCount: 2,
                    retainedNonredundantAssetCount: 2,
                    recycledRedundantAssetCount: 3,
                    remainingRedundantAssetCount: 0,
                    unresolvedAssetCount: 0,
                    unresolvedGroupCount: 0,
                    isComplete: true
                ),
                message: "已完成去重 2/2 组",
                updatedAtMs: 789
            ),
        ])
    }

    func submitIdenticalCleanup(
        _ command: LibrarySlimmingIdenticalCleanupCommand
    ) async throws -> LibrarySlimmingIdenticalCleanupRequestSnapshot {
        lock.withLock { storedLastIdenticalCleanupCommand = command }
        return LibrarySlimmingIdenticalCleanupRequestSnapshot(
            id: UUID(),
            operationID: command.operationID,
            planID: command.planID,
            jobID: jobID,
            mediaKind: .image,
            mode: command.mode,
            phase: .awaitingMac,
            progress: nil,
            audit: nil,
            verification: nil,
            message: "请回到 Mac 核对并确认一键清理方案",
            updatedAtMs: 456
        )
    }
}

private final class RemoteHTTPSourceManagementCommandStub:
    RemoteSourceManagementCommandPort,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let sourceID: UUID
    private let operationID: UUID
    private var storedLastCommand: SourceManagementCommandRequest?

    var lastCommand: SourceManagementCommandRequest? {
        lock.withLock { storedLastCommand }
    }

    init(sourceID: UUID, operationID: UUID) {
        self.sourceID = sourceID
        self.operationID = operationID
    }

    private var receipt: SourceManagementCommandRequestSnapshot {
        SourceManagementCommandRequestSnapshot(
            id: UUID(uuidString: "bbbbbbbb-1111-2222-3333-bbbbbbbbbbbb")!,
            operationID: operationID,
            action: .reauthorize,
            sourceID: sourceID,
            sourceDisplayName: "Archive",
            phase: .awaitingMac,
            message: "请回到 Mac 完成系统选择器",
            updatedAtMs: 123
        )
    }

    func snapshot() async throws -> SourceManagementCommandSnapshot {
        SourceManagementCommandSnapshot(
            sources: [
                LibrarySourceSummary(
                    id: sourceID,
                    kind: .folder,
                    displayName: "Archive",
                    state: .authorizationRequired
                ),
            ],
            requests: [receipt]
        )
    }

    func submit(
        _ command: SourceManagementCommandRequest
    ) async throws -> SourceManagementCommandRequestSnapshot {
        lock.withLock { storedLastCommand = command }
        return receipt
    }
}

private final class RemoteHTTPStorageMaintenanceCommandStub:
    RemoteStorageMaintenanceCommandPort,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let operationID: UUID
    private var storedLastCommand: StorageMaintenanceCommandRequest?

    var lastCommand: StorageMaintenanceCommandRequest? {
        lock.withLock { storedLastCommand }
    }

    init(operationID: UUID) {
        self.operationID = operationID
    }

    private var receipt: StorageMaintenanceCommandRequestSnapshot {
        StorageMaintenanceCommandRequestSnapshot(
            id: UUID(uuidString: "cccccccc-1111-2222-3333-cccccccccccc")!,
            operationID: operationID,
            action: .clearPreviewCache,
            phase: .awaitingMac,
            message: "请回到 Mac 确认清理操作",
            updatedAtMs: 123,
            result: nil
        )
    }

    func snapshot() async throws -> StorageMaintenanceCommandSnapshot {
        StorageMaintenanceCommandSnapshot(
            previewCache: StorageMaintenanceUsageSummary(
                entryCount: 12,
                registeredBytes: 1_500_000
            ),
            photosOriginals: StorageMaintenanceUsageSummary(
                entryCount: 3,
                registeredBytes: 9_000_000
            ),
            clearPreviewCacheAvailability: StorageMaintenanceActionAvailability(
                isAvailable: true
            ),
            clearPhotosOriginalsAvailability: StorageMaintenanceActionAvailability(
                isAvailable: false,
                reason: .librarySlimmingAnalysisInProgress
            ),
            appStorage: StorageMaintenanceAppStorageSummary(
                kind: .internalStorage,
                requiresRestart: true,
                pendingExternalRootName: "ImageAll-External"
            ),
            requests: [receipt]
        )
    }

    func submit(
        _ command: StorageMaintenanceCommandRequest
    ) async throws -> StorageMaintenanceCommandRequestSnapshot {
        lock.withLock { storedLastCommand = command }
        return receipt
    }
}

private struct RemoteHTTPServerTestMediaProvider: RemoteMediaResourceProviding {
    let url: URL
    var contentType = "video/mp4"

    func openMediaResource(assetID _: UUID) async throws -> RemoteMediaResource {
        let descriptor = try DerivedImageSecureIO.openReadOnlyNoFollow(at: url)
        do {
            let facts = try DerivedImageSecureIO.fstatRegularFile(fd: descriptor)
            return RemoteMediaResource(
                descriptor: descriptor,
                contentType: contentType,
                contentLength: facts.sizeBytes
            ) {
                Darwin.close(descriptor)
            }
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }
}
