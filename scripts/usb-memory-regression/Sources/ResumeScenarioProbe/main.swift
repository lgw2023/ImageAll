import CryptoKit
import Foundation
import ImageAllRemoteClient
import ImageAllRemoteProtocol

enum ScenarioError: Error { case mismatch(String) }
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw ScenarioError.mismatch(message) }
}

struct Scenario: Codable {
    let migrationID: UUID
    let deviceID: UUID
    let installID: UUID
    let sourceEpoch: UUID
    let resources: [ImageAllMigrationResource]
    let prefixBytes: Int64
    let totalBytes: Int64
}

/// Routes production client requests directly to the production store.
/// Deliberately excludes USB/TLS and PhotoKit; counters measure request bodies.
actor FixtureTransport: RemoteHTTPTransporting {
    let store: ImageAllMigrationTransferStore
    let deviceID: UUID
    var resourceBytes: Int64 = 0
    var metadataBytes: Int64 = 0
    var firstResourceOffset: Int64?
    var resourcePUTs = 0
    var resumeCalls = 0
    init(store: ImageAllMigrationTransferStore, deviceID: UUID) {
        self.store = store; self.deviceID = deviceID
    }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url,
              request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic",
              !request.allowsCellularAccess,
              let id = url.path.split(separator: "/").dropFirst(2).first.flatMap({ UUID(uuidString: String($0)) })
        else { throw ScenarioError.mismatch("request identity") }
        let payload: Data
        if url.path == RemoteHTTPPaths.migrationTransfer(id), request.httpMethod == "POST" {
            payload = try JSONEncoder().encode(await store.begin(migrationID: id,
                authenticatedDeviceID: deviceID,
                sourceInstallID: request.value(forHTTPHeaderField: "X-ImageAll-Source-Install-ID").flatMap(UUID.init(uuidString:))))
        } else if url.path == RemoteHTTPPaths.migrationTransferResume(id) {
            resumeCalls += 1
            payload = try JSONEncoder().encode(await store.resumeCheckpoint(migrationID: id, authenticatedDeviceID: deviceID))
        } else if url.path == RemoteHTTPPaths.migrationTransferChunks(id), request.httpMethod == "PUT" {
            let body = request.httpBody ?? Data()
            let path = request.value(forHTTPHeaderField: "X-ImageAll-File") ?? ""
            let offset = Int64(request.value(forHTTPHeaderField: "X-ImageAll-Offset") ?? "") ?? -1
            if path.hasPrefix("resources/") {
                resourceBytes += Int64(body.count); resourcePUTs += 1
                if firstResourceOffset == nil { firstResourceOffset = offset }
            } else { metadataBytes += Int64(body.count) }
            payload = try JSONEncoder().encode(await store.append(migrationID: id,
                authenticatedDeviceID: deviceID, relativePath: path, offset: offset, bytes: body,
                sha256: request.value(forHTTPHeaderField: "X-ImageAll-SHA256") ?? "",
                fileProgressOnly: request.value(forHTTPHeaderField: "X-ImageAll-Progress-Scope") == "file"))
        } else if url.path == RemoteHTTPPaths.migrationTransferVerifyResource(id) {
            let resource = try JSONDecoder().decode(ImageAllMigrationResourceVerificationRequest.self, from: request.httpBody!)
            payload = try JSONEncoder().encode(await store.verifyResource(migrationID: id,
                authenticatedDeviceID: deviceID, request: resource))
        } else if url.path == RemoteHTTPPaths.migrationTransferSeal(id) {
            let (_, verified) = try await store.sealVerifiedArchive(migrationID: id, authenticatedDeviceID: deviceID)
            payload = try JSONEncoder().encode(ImageAllMigrationTransferSealReceipt(verification: verified))
        } else { throw ScenarioError.mismatch("unexpected route") }
        return (payload, HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

@main struct ResumeScenarioProbe {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        try require(FileManager.default.fileExists(atPath: root.appendingPathComponent("SYNTHETIC-ONLY").path), "synthetic marker")
        let scenario = try JSONDecoder().decode(Scenario.self, from: Data(contentsOf: root.appendingPathComponent("scenario.json")))
        let repeatRun = FileManager.default.fileExists(atPath: root.appendingPathComponent("first-result.json").path)
        let clock = ContinuousClock()
        let start = clock.now
        func elapsed() -> Double {
            let value = start.duration(to: clock.now).components
            return Double(value.seconds) + Double(value.attoseconds) / 1e18
        }
        let store = try ImageAllMigrationTransferStore(root: root.appendingPathComponent("receiver"))
        let transport = FixtureTransport(store: store, deviceID: scenario.deviceID)
        let client = RemoteLibraryClient(endpoint: try RemoteHostEndpoint(host: "127.0.0.1", port: 1, accessToken: "synthetic"),
                                         transport: transport)
        print("cold begin; committed bytes will be rehashed"); fflush(stdout)
        let progress = try await client.beginMigrationTransfer(migrationID: scenario.migrationID, sourceInstallID: scenario.installID)
        let beginSeconds = elapsed()
        try require(progress.migrationID == scenario.migrationID, "same migration")
        let receipts = try await client.migrationResumeCheckpoint(migrationID: scenario.migrationID,
            deviceID: scenario.deviceID, sourceInstallID: scenario.installID)
        let checkpointSeconds = elapsed()
        print("checkpoint validated seconds=\(checkpointSeconds) receipts=\(receipts.count)"); fflush(stdout)
        try require(receipts.count == (repeatRun ? 2889 : 2888), "receipt count")
        var skipped = 0
        for resource in scenario.resources.dropLast() {
            guard let receipt = receipts[resource.relativePath!] else { throw ScenarioError.mismatch("missing completed resource") }
            try require(receipt.resource.byteCount == resource.byteCount && receipt.resource.sha256 == resource.sha256, "completed descriptor")
            skipped += 1
        }
        let pending = scenario.resources.last!
        let path = pending.relativePath!
        let before = progress.files.first { $0.relativePath == path }!.committedBytes
        try require(before == (repeatRun ? pending.byteCount! : scenario.prefixBytes), "durable offset")
        let recoveredFile = root.appendingPathComponent("receiver/.imageall-transfer-\(scenario.migrationID.uuidString.lowercased())/package/\(path)")
        let size = try recoveredFile.resourceValues(forKeys: [.fileSizeKey]).fileSize!
        try require(Int64(size) == before, "uncommitted tail truncated")
        if repeatRun {
            try require(receipts[path]?.resource.sha256 == pending.sha256, "pending now verified")
            skipped += 1
        } else {
            _ = try await client.uploadMigrationFile(at: root.appendingPathComponent("source/pending.bin"),
                migrationID: scenario.migrationID, relativePath: path, byteCount: pending.byteCount!,
                sha256: pending.sha256!, sourceInstallID: scenario.installID)
            _ = try await client.verifyMigrationResource(migrationID: scenario.migrationID, deviceID: scenario.deviceID,
                request: .init(relativePath: path, byteCount: pending.byteCount!, sha256: pending.sha256!))
        }
        let resourceCompleteSeconds = elapsed()
        let header = ImageAllMigrationHeader(migrationID: scenario.migrationID, sourceDeviceID: scenario.installID,
            sourceEpoch: scenario.sourceEpoch, scopeRevision: 1, inventoryWatermark: 1, declaredItemCount: scenario.resources.count)
        let items = scenario.resources.enumerated().map { index, resource in
            ImageAllMigrationItem(mediaID: resource.id, sourceLocalIdentifier: "synthetic-\(index)", mediaKind: .image,
                createdAtMs: nil, favoriteTarget: nil, observedFavorite: false, factRevision: 1,
                tagDecisions: [], collections: [], resources: [resource])
        }
        let planning = root.appendingPathComponent("sender")
        if !repeatRun { try ImageAllMigrationArchive.write(header: header, items: items, to: planning) }
        let sealed = try await client.finishPreparedMigration(at: planning, header: header, items: items)
        try require(sealed.migrationID == scenario.migrationID && sealed.itemCount == 2889
                    && sealed.resourceCount == 2889 && sealed.verifiedBytes == scenario.totalBytes, "complete archive")
        let uploaded = await transport.resourceBytes
        let offset = await transport.firstResourceOffset
        try require(uploaded == (repeatRun ? 0 : pending.byteCount! - scenario.prefixBytes), "only remaining bytes uploaded")
        try require(repeatRun ? offset == nil : offset == scenario.prefixBytes, "first PUT offset")
        let metadataBytes = await transport.metadataBytes
        if repeatRun { try require(metadataBytes == 0, "no metadata reupload") }
        let result: [String: Any] = [
            "repeatRun": repeatRun, "migrationID": scenario.migrationID.uuidString,
            "items": sealed.itemCount, "resourceCount": sealed.resourceCount, "verifiedBytes": sealed.verifiedBytes,
            "skippedResources": skipped, "resourceUploadBytes": uploaded, "metadataUploadBytes": metadataBytes,
            "firstResourceOffset": offset as Any? ?? NSNull(), "durablePrefixBytes": before,
            "resourcePUTs": await transport.resourcePUTs, "resumeCalls": await transport.resumeCalls,
            "coldBeginSeconds": beginSeconds, "validatedCheckpointSeconds": checkpointSeconds,
            "firstEffectiveProgressSeconds": checkpointSeconds, "fiveSecondTargetMet": checkpointSeconds <= 5,
            "resourceCompleteSeconds": resourceCompleteSeconds, "totalSeconds": elapsed(),
            "manifestSHA256": sealed.manifestSHA256,
            "scope": "production client and receiver store with synthetic in-process transport; excludes USB, PhotoKit and UI"]
        let name = repeatRun ? "repeat-result.json" : "first-result.json"
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent(name), options: .atomic)
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
}
