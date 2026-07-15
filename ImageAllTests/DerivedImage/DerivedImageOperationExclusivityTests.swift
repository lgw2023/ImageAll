import XCTest
@testable import ImageAll

final class DerivedImageOperationExclusivityTests: XCTestCase {
    func testMaintenanceWaitsWhileGenerationHoldsProtectedStaging() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "excl-gen-maint")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        let checkpoint = DerivedImageTestSupport.PublishStagingCheckpoint()
        let (service, _) = env.makeService(
            publishCheckpoint: checkpoint,
            volumeReader: DerivedImageTestSupport.generousVolume
        )

        let generationTask = Task {
            try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
        }
        let stagingName = try checkpoint.waitUntilStagingReached(timeout: 5)
        let stagingFile = DerivedImageCachePathLayout.stagingDirectory(under: env.cacheVersionRoot())
            .appendingPathComponent(stagingName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingFile.path))

        let maintenanceFinishedEarly = expectation(description: "maintenance must not finish while generation holds gate")
        maintenanceFinishedEarly.isInverted = true
        let maintenanceTask = Task {
            try await service.performMaintenance()
            if !checkpoint.isGenerationReleased() {
                maintenanceFinishedEarly.fulfill()
            }
        }
        await fulfillment(of: [maintenanceFinishedEarly], timeout: 0.3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingFile.path))

        checkpoint.releaseGeneration()
        _ = try await generationTask.value
        _ = try await maintenanceTask.value

        let counts = try await env.cacheArtifactCounts()
        XCTAssertEqual(counts.entries, 1)
        XCTAssertEqual(counts.objects, 1)
        let second = try await service.performMaintenance()
        XCTAssertEqual(second.removedEntries, 0)
        XCTAssertEqual(second.removedObjects, 0)
    }

    func testGenerationWaitsWhileMaintenanceHoldsGate() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "excl-maint-gen")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        let checkpoint = DerivedImageTestSupport.MaintenanceHoldCheckpoint()
        let (service, _) = env.makeService(
            maintenanceCheckpoint: checkpoint,
            volumeReader: DerivedImageTestSupport.generousVolume
        )

        let maintenanceTask = Task {
            try await service.performMaintenance()
        }
        try checkpoint.waitUntilMaintenanceHeld(timeout: 5)

        let generationFinishedEarly = expectation(description: "generation must not finish while maintenance holds gate")
        generationFinishedEarly.isInverted = true
        let generationTask = Task {
            let payload = try await service.loadOrGenerate(
                DerivedImageRequest(assetID: env.assetID, variant: .gridSmall)
            )
            if !checkpoint.isMaintenanceReleased() {
                generationFinishedEarly.fulfill()
            }
            return payload
        }
        await fulfillment(of: [generationFinishedEarly], timeout: 0.3)

        let counts = try await env.cacheArtifactCounts()
        XCTAssertEqual(counts.entries, 0)
        XCTAssertEqual(counts.objects, 0)
        XCTAssertEqual(counts.stagingFiles, 0)

        checkpoint.releaseMaintenance()
        _ = try await maintenanceTask.value
        let payload = try await generationTask.value
        XCTAssertEqual(payload.origin, .generated)
        let after = try await env.cacheArtifactCounts()
        XCTAssertEqual(after.entries, 1)
        XCTAssertEqual(after.objects, 1)
    }
}
