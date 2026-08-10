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
            )
        )
        let (server, _) = makeServer(port: port, trainingCommands: commands)
        try await server.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        defer { Task { await server.stop() } }

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

        for controlID in [
            "filterPopover",
            "batchBar",
            "reviewWorkspace",
            "reviewQueuePane",
            "reviewMarqueeSelection",
            "reviewSelectionSummary",
            "jobsPopover",
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
            "batchNewTagButton",
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
            "gridDensitySlider",
            "thumbnailAspectButton",
            "reviewThumbnailLayoutControls",
            "reviewGridDensitySlider",
            "reviewThumbnailAspectButton",
            "reviewSelectAllButton",
            "reviewSelectionModeButton",
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
            "inspectorPreviousButton",
            "inspectorNextButton",
            "previewPlaceholderImage",
            "previewVideo",
            "cloudPreviewRecovery",
            "cloudPreviewButton",
            "cloudPreviewProgress",
            "openOriginalButton",
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
            "tagManagerButton",
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
            "slimmingGridDensitySlider",
            "slimmingNavigatorButton",
            "slimmingAnalysisOptionsButton",
            "openSlimmingThresholdEditorButton",
            "slimmingThresholdDialog",
            "slimmingThresholdForm",
            "slimmingThresholdDialogContent",
            "slimmingThresholdRecallMode",
            "slimmingThresholdRecallTopK",
            "slimmingThresholdL2Mode",
            "slimmingThresholdL2Distance",
            "slimmingThresholdDINOMode",
            "slimmingThresholdDINOSimilarity",
            "slimmingThresholdBucketingMode",
            "slimmingThresholdBucketActivationCount",
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
            "slimmingVerificationMetrics",
            "slimmingVerificationResult",
            "closeSlimmingVerificationButton",
            "newSlimmingAnalysisButton",
            "slimmingJobActions",
            "slimmingSetupDialog",
            "slimmingModeOptions",
            "slimmingSourceOptions",
            "slimmingRecallMode",
            "slimmingL2Mode",
            "slimmingDINOMode",
            "slimmingBucketingMode",
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
            "slimmingJobContextMenu",
            "slimmingJobContextMenuTitle",
            "slimmingJobContextMenuActions",
            "sourceManagerButton",
            "sourceManagerDialog",
            "sourceConnectFolderButton",
            "sourceConnectPhotosButton",
            "sourceAllActionsPanel",
            "sourceAllActionsSummary",
            "sourceManagerPending",
            "sourceManagerListSummary",
            "sourceManagerList",
            "emptySourceRecoveryButton",
            "emptyOpenSourceManagerButton",
            "storageButton",
            "storageStatusLabel",
            "selectionInspectorPrimary",
            "selectionInspectorPrimaryPreview",
            "selectionInspectorPrimaryMetadata",
            "storageDialog",
            "storagePending",
            "previewCacheSize",
            "photosOriginalsSize",
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
            "worldMapDetail",
            "worldMapPhotoStrip",
            "openWorldMapLocationBackfillButton",
            "worldMapLocationBackfillDialog",
            "worldMapLocationBackfillSources",
            "openWorldMapPlaceTagsButton",
            "worldMapPlaceTagDialog",
            "worldMapPlaceTagBody",
            "worldMapPlaceTagItems",
            "galleryOverviewNavigationButton",
            "galleryOverviewWorkspace",
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
        XCTAssertTrue(script.contains("function createInlineTagAndApply"))
        XCTAssertTrue(script.contains("state.inlineTagOperations"))
        XCTAssertTrue(stylesheet.contains(".inspector-inline-tag-form"))
        XCTAssertTrue(script.contains("state.contextTagReturnFocus"))
        XCTAssertTrue(script.contains("toggle.dataset.helpDetail"))
        XCTAssertTrue(script.contains("chip.dataset.helpDetail"))
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
        XCTAssertTrue(script.contains("function appendWorldMapSelectionQuery"))
        XCTAssertTrue(script.contains("async function clearWorldMapGalleryScope"))
        XCTAssertTrue(script.contains("data-retry-world-map-selection"))
        XCTAssertTrue(script.contains("button.dataset.worldMapPhotoFavorite = \"true\""))
        XCTAssertTrue(stylesheet.contains(".world-map-photo-card"))
        XCTAssertTrue(stylesheet.contains(".world-map-photo-favorite"))
        XCTAssertTrue(stylesheet.contains(".world-map-gallery-banner"))
        XCTAssertTrue(stylesheet.contains(".world-map-browse-cluster"))
        XCTAssertTrue(stylesheet.contains(".world-map-photo-error"))
        XCTAssertTrue(script.contains("function renderGalleryOverview"))
        XCTAssertTrue(script.contains("async function refreshJobs"))
        XCTAssertTrue(script.contains("async function refreshCurrentSource"))
        XCTAssertTrue(script.contains("function syncCatalogProgressStatus"))
        XCTAssertTrue(script.contains("function scheduleCatalogProgressPoll"))
        XCTAssertTrue(script.contains("function catalogJobProgressLabel"))
        XCTAssertTrue(script.contains("function drillDownFromGalleryOverview"))
        XCTAssertTrue(script.contains("function renderActiveFilterBar"))
        XCTAssertTrue(script.contains("async function openLightboxOriginalOnMac"))
        XCTAssertTrue(script.contains("async function requestAssetLocalSuggestions"))
        XCTAssertTrue(script.contains("async function applyAssetLocalSuggestionDecision"))
        XCTAssertTrue(script.contains("function syncLightboxWorkspaceFrame"))
        XCTAssertTrue(script.contains("function trapLibraryLightboxFocus"))
        XCTAssertTrue(script.contains("function bindPersistentHelp"))
        XCTAssertTrue(script.contains("function schedulePersistentHelp"))
        XCTAssertTrue(script.contains("document.addEventListener(\"pointerover\""))
        XCTAssertFalse(script.contains("elements.appView.addEventListener(\"pointerover\""))
        XCTAssertTrue(script.contains("function configurePersistentHelp"))
        XCTAssertTrue(script.contains("kind: \"training\""))
        XCTAssertTrue(script.contains("function configureReviewWorkspacePersistentHelp"))
        XCTAssertTrue(script.contains("kind: \"review\""))
        XCTAssertTrue(script.contains("P 属于、X 不属于、U 稍后"))
        XCTAssertTrue(script.contains("不会替换已载入项目、清空选择或跳回顶部"))
        XCTAssertTrue(script.contains("ArrowUp ArrowDown Home End Meta+K"))
        XCTAssertTrue(script.contains("点击查看数据、配置、过程、产物和失败恢复"))
        XCTAssertTrue(script.contains("function assetCardHelpDetail"))
        XCTAssertTrue(script.contains("mainButton.dataset.helpDetail = assetCardHelpDetail(asset)"))
        XCTAssertTrue(script.contains("mainButton.dataset.helpKind = \"asset\""))
        XCTAssertTrue(script.contains("delete mainButton.dataset.helpDetail"))
        XCTAssertTrue(script.contains("async function openSlimmingThresholdEditor"))
        XCTAssertTrue(script.contains("async function saveSlimmingThresholdEditor"))
        XCTAssertTrue(html.contains("id=\"persistentHelp\""))
        XCTAssertTrue(html.contains("data-help-detail="))
        XCTAssertTrue(stylesheet.contains(".inspector-local-model"))
        XCTAssertTrue(stylesheet.contains(".lightbox.library-docked"))
        XCTAssertTrue(stylesheet.contains(".persistent-help"))
        XCTAssertTrue(stylesheet.contains("white-space: pre-line"))
        XCTAssertTrue(stylesheet.contains(".persistent-help[data-kind=\"asset\"]"))
        XCTAssertTrue(stylesheet.contains(".persistent-help[data-kind=\"training\"]"))
        XCTAssertTrue(stylesheet.contains(".persistent-help[data-kind=\"review\"]"))
        XCTAssertTrue(stylesheet.contains(".lightbox-open-original-button"))
        XCTAssertTrue(script.contains("function activeFilterSummaryText"))
        XCTAssertTrue(script.contains("function renderWorkspaceNotice"))
        XCTAssertTrue(script.contains("async function dismissWorkspaceNotice"))
        XCTAssertTrue(script.contains("async function performWorkspaceNoticeAction"))
        XCTAssertTrue(stylesheet.contains(".workspace-notice-banner"))
        XCTAssertTrue(stylesheet.contains(".workspace-notice-actions"))
        XCTAssertTrue(script.contains("function generateGalleryPersonalSuggestions"))
        XCTAssertTrue(script.contains("搜索文件名、路径、标签或来源"))
        XCTAssertTrue(script.contains("function renderLightboxMedia"))
        XCTAssertTrue(script.contains("submitSourceManagementAction(\"refreshAll\")"))
        XCTAssertTrue(script.contains("submitSourceManagementAction(\"prewarmAllThumbnails\")"))
        XCTAssertTrue(script.contains("submitSourceManagementAction(\"prewarmAllOriginalAspect\")"))
        XCTAssertTrue(script.contains("submitSourceManagementAction(\"reauthorizeAll\")"))
        XCTAssertTrue(script.contains("submitSourceManagementAction(\"refreshAllFolderMutationAuthorizations\")"))
        XCTAssertTrue(script.contains("function constrainedLightboxOffset"))
        XCTAssertTrue(script.contains("function syncLightboxViewport"))
        XCTAssertTrue(script.contains("function handleLightboxWheel"))
        XCTAssertTrue(script.contains("function beginLightboxPan"))
        XCTAssertTrue(stylesheet.contains(".lightbox-zoom-controls"))
        XCTAssertTrue(stylesheet.contains(".lightbox-stage"))
        XCTAssertTrue(stylesheet.contains(".lightbox-delete-button"))
        XCTAssertTrue(script.contains("function loadMoreLightboxItems"))
        XCTAssertTrue(script.contains("function syncLibraryLightboxSelection"))
        XCTAssertTrue(script.contains("lightboxPendingDirection"))
        XCTAssertTrue(script.contains("function applyLightboxReviewDecision"))
        XCTAssertTrue(script.contains("function selectAllReviewItems"))
        XCTAssertTrue(script.contains("function startReviewMarqueeSelection"))
        XCTAssertTrue(script.contains("state.review.selectedAssetIDs"))
        XCTAssertFalse(script.contains("confirmBatchTagDecision"))
        XCTAssertTrue(script.contains("tagAction:accept:${tag.id}"))
        XCTAssertTrue(script.contains("sourceAction:${action}:${selectedSource.id}"))
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
        XCTAssertTrue(stylesheet.contains(".slimming-member-main"))
        XCTAssertTrue(stylesheet.contains(".slimming-member-favorite"))
        XCTAssertTrue(stylesheet.contains(".slimming-recycle-favorite"))
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
        XCTAssertTrue(script.contains("scheduleSourceManagementPoll"))
        XCTAssertTrue(script.contains("function selectSourceManagerSource"))
        XCTAssertTrue(script.contains("function handleSourceManagerKeyboardNavigation"))
        XCTAssertTrue(script.contains("function handleSourceManagerAllActionsKeyboard"))
        XCTAssertTrue(script.contains("function closeSourceManagerAllActions"))
        XCTAssertTrue(script.contains("viewButton.dataset.sourceManagerView = selectedSource.id"))
        XCTAssertTrue(script.contains("source-manager-action-group-${group}"))
        XCTAssertTrue(stylesheet.contains(".source-manager-source-list"))
        XCTAssertTrue(stylesheet.contains(".source-manager-detail"))
        XCTAssertTrue(stylesheet.contains(".source-manager-all-actions-menu"))
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
        XCTAssertTrue(script.contains("submitStorageMaintenanceAction"))
        XCTAssertTrue(script.contains("requestStorageMaintenanceAction"))
        XCTAssertTrue(script.contains("清理预览缓存？"))
        XCTAssertTrue(script.contains("清理全部长期原图副本？"))
        XCTAssertTrue(script.contains("returnFocus: { storageAction: action }"))
        XCTAssertTrue(script.contains("scheduleStorageMaintenancePoll"))
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
        XCTAssertTrue(script.contains("applyQuickTagFilter"))
        XCTAssertTrue(script.contains("function moveLibrarySelection(key, { extendRange = false } = {})"))
        XCTAssertTrue(script.contains("selectLibraryAssetByIndex(nextIndex, { focusGrid: true, extendRange })"))
        XCTAssertTrue(script.contains("ArrowLeft ArrowRight ArrowUp ArrowDown Home End PageUp PageDown Space"))
        XCTAssertTrue(html.contains("扩展连续选择"))
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
        XCTAssertTrue(script.contains("renderTrainingDetailActions"))
        XCTAssertTrue(script.contains("submitTrainingSetup"))
        XCTAssertTrue(script.contains("renderSlimmingWorkspace"))
        XCTAssertTrue(script.contains("renderIdenticalCleanupBlockingOverlay"))
        XCTAssertTrue(script.contains("identicalCleanupExecutionPresentation"))
        XCTAssertTrue(script.contains("selectSlimmingMember"))
        XCTAssertTrue(script.contains("showSlimmingMemberContextMenu"))
        XCTAssertTrue(script.contains("data-slimming-member-context-action"))
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
        XCTAssertTrue(script.contains("state.layout.aspectMode"))
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
        XCTAssertTrue(script.contains("renderTagManager"))
        XCTAssertTrue(script.contains("installPresetTags"))
        XCTAssertTrue(script.contains("/v1/tags/install-presets"))
        XCTAssertTrue(script.contains("开始建立你的照片资料库"))
        XCTAssertTrue(script.contains("setupSidebarReordering"))
        XCTAssertTrue(script.contains("sourceSidebarHelpDetail"))
        XCTAssertTrue(script.contains("button.dataset.helpKind = \"source\""))
        XCTAssertTrue(script.contains("button.dataset.helpTitle = tag.displayName"))
        XCTAssertTrue(script.contains("当前：${stateLabel}"))
        XCTAssertTrue(script.contains("Shift+F10 ContextMenu"))
        XCTAssertTrue(stylesheet.contains(".persistent-help[data-kind=\"source\"]"))
        XCTAssertTrue(script.contains("sourceOrderIDs"))
        XCTAssertTrue(script.contains("tagOrderIDsByGroup"))
        XCTAssertTrue(script.contains("collapsedSidebarTagGroupIDs"))
        XCTAssertTrue(script.contains("collapsedTagGroupIDs"))
        XCTAssertTrue(script.contains("toggleSharedTagGroupCollapsed"))
        XCTAssertTrue(script.contains("tagReturnFocusDescriptor"))
        XCTAssertTrue(script.contains("resolveTagReturnFocusTarget"))
        XCTAssertTrue(script.contains("renderTagNavigation();"))
        XCTAssertTrue(script.contains("data-sidebar-tag-group-toggle"))
        XCTAssertTrue(script.contains("data-tag-reorder-surface"))
        XCTAssertTrue(script.contains("configureInspectorTagReordering"))
        XCTAssertTrue(script.contains("moveSidebarTagToAdjacentGroup"))
        XCTAssertTrue(script.contains("toggleSidebarTagFilter"))
        XCTAssertTrue(script.contains("showTagContextMenu"))
        XCTAssertTrue(script.contains("showTagGroupContextMenu"))
        XCTAssertTrue(script.contains("data-tag-context-action"))
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
        XCTAssertTrue(script.contains("{ priority: \"high\" }"))
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
        XCTAssertTrue(script.contains("button.dataset.reviewKey = key"))
        XCTAssertTrue(script.contains("scheduleProjectionPoll"))
        XCTAssertTrue(script.contains("currentReviewScopeKey"))
        XCTAssertTrue(script.contains("state.workspaceGeneration"))
        XCTAssertTrue(script.contains("state.inspectorRequestGeneration"))
        XCTAssertTrue(script.contains("state.inspectorDismissed"))
        XCTAssertTrue(script.contains("state.pendingInspectorRefresh"))
        XCTAssertTrue(script.contains("preserveExisting: true"))
        XCTAssertTrue(script.contains("function closeReviewWorkspace({ restoreFocus = true } = {})"))
        XCTAssertTrue(script.contains("function closeLightbox({ restoreFocus = true } = {})"))
        XCTAssertTrue(script.contains("function compactToolbarSections()"))
        XCTAssertTrue(script.contains("function renderCompactToolbarMenu()"))
        XCTAssertTrue(script.contains("function closeCompactToolbarMenu({ restoreFocus = true } = {})"))
        XCTAssertTrue(script.contains("function syncCompactToolbarMenu()"))
        XCTAssertTrue(script.contains("function fullToolbarRequiredWidth()"))
        XCTAssertTrue(script.contains("function syncAdaptiveToolbar()"))
        XCTAssertTrue(script.contains("function scheduleAdaptiveToolbarSync()"))
        XCTAssertTrue(script.contains("new ResizeObserver(scheduleAdaptiveToolbarSync)"))
        XCTAssertTrue(stylesheet.contains(".compact-toolbar-menu-button"))
        XCTAssertTrue(stylesheet.contains(".compact-toolbar-menu-item"))
        XCTAssertTrue(stylesheet.contains(".app-shell.compact-toolbar-active"))
        XCTAssertTrue(stylesheet.contains("#catalogProgressStatusButton"))
        XCTAssertTrue(script.contains("function trapOverlayFocus"))
        XCTAssertTrue(script.contains("state.review.mutating"))
        XCTAssertTrue(script.contains("state.tagMutating"))
        XCTAssertTrue(script.contains("throwOnError: true"))
        XCTAssertTrue(script.contains("界面同步暂时失败，正在重试"))
        XCTAssertTrue(script.contains("applyReviewDecision(\"accept\")"))
        XCTAssertTrue(script.contains("deferReviewSelection"))
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
        XCTAssertTrue(script.contains("sort: \"fileNameAscending\""))
        XCTAssertTrue(
            html.contains(
                "<option value=\"fileNameAscending\" selected>按文件名</option>"
            )
        )
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
        _ = mediaKind
        return []
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

    func openMediaResource(assetID _: UUID) async throws -> RemoteMediaResource {
        let descriptor = try DerivedImageSecureIO.openReadOnlyNoFollow(at: url)
        do {
            let facts = try DerivedImageSecureIO.fstatRegularFile(fd: descriptor)
            return RemoteMediaResource(
                descriptor: descriptor,
                contentType: "video/mp4",
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
