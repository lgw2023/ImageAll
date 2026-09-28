import CryptoKit
import Foundation
import ImageAllRemoteClient
import ImageAllRemoteProtocol
import XCTest

final class MigrationTransferClientTests: XCTestCase {
    func testArchiveUploadResumesFromReceiverOffsetAndSealsVerifiedPackage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MigrationTransferClient-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let receiver = root.appendingPathComponent("receiver", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: receiver, withIntermediateDirectories: true)
        let migrationID = UUID()
        let deviceID = UUID()
        let resourceID = UUID()
        let path = "resources/\(resourceID.uuidString.lowercased()).bin"
        let resourceBytes = Data(repeating: 0x33, count: 160 * 1_024)
        let resourceURL = source.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: resourceURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try resourceBytes.write(to: resourceURL)
        let header = ImageAllMigrationHeader(
            migrationID: migrationID, sourceDeviceID: deviceID, sourceEpoch: UUID(),
            scopeRevision: 1, inventoryWatermark: 1, declaredItemCount: 1
        )
        let item = ImageAllMigrationItem(
            mediaID: UUID(), sourceLocalIdentifier: "selected-photo",
            mediaKind: .image, createdAtMs: nil, favoriteTarget: nil,
            observedFavorite: false, factRevision: 1,
            tagDecisions: [], collections: [], resources: [.init(
                id: resourceID, role: "original", version: 1,
                uniformTypeIdentifier: "public.data", required: true,
                status: .present, relativePath: path,
                byteCount: Int64(resourceBytes.count), sha256: hash(resourceBytes)
            )]
        )
        try ImageAllMigrationArchive.write(header: header, items: [item], to: source)
        let manifest = try Data(contentsOf: source.appendingPathComponent("manifest.jsonl"))
        let store = try ImageAllMigrationTransferStore(
            root: receiver, maximumChunkBytes: 64 * 1_024
        )
        _ = try await store.begin(migrationID: migrationID, authenticatedDeviceID: deviceID)
        let prefix = Data(manifest.prefix(32))
        _ = try await store.append(
            migrationID: migrationID, authenticatedDeviceID: deviceID,
            relativePath: "manifest.jsonl", offset: 0,
            bytes: prefix, sha256: hash(prefix)
        )

        let transport = TransferFixtureTransport(store: store, deviceID: deviceID)
        let client = RemoteLibraryClient(
            endpoint: try RemoteHostEndpoint(
                host: "127.0.0.1", port: 8787, accessToken: "synthetic-bearer"
            ), transport: transport
        )
        // A prepared resource can finish before the manifest exists locally.
        let manifestURL = source.appendingPathComponent("manifest.jsonl")
        try FileManager.default.removeItem(at: manifestURL)
        let resourcePrefix = Data(resourceBytes.prefix(123))
        _ = try await store.append(migrationID: migrationID, authenticatedDeviceID: deviceID,
            relativePath: path, offset: 0, bytes: resourcePrefix, sha256: hash(resourcePrefix))
        let uploaded = try await client.uploadMigrationFile(
            at: resourceURL, migrationID: migrationID, relativePath: path,
            byteCount: Int64(resourceBytes.count), sha256: hash(resourceBytes)
        )
        XCTAssertFalse(uploaded.sealed)
        XCTAssertEqual(uploaded.files.first { $0.relativePath == path }?.committedBytes,
                       Int64(resourceBytes.count))
        let resourceReceipt = try await client.verifyMigrationResource(
            migrationID: migrationID, deviceID: deviceID,
            request: .init(relativePath: path, byteCount: Int64(resourceBytes.count), sha256: hash(resourceBytes)))
        XCTAssertEqual(resourceReceipt.resource.sha256, hash(resourceBytes))
        // Simulate the one-resource window being released, then regenerated for
        // an archive retry. The receiver must retain exactly the first copy.
        try FileManager.default.removeItem(at: resourceURL)
        try Data("unexpected manifest contents".utf8).write(to: manifestURL)
        do {
            _ = try await client.finishPreparedMigration(at: source, header: header, items: [item])
            XCTFail("planning manifest changed without detection")
        } catch let error as RemoteAPIError { XCTAssertEqual(error.code, .conflict) }
        try manifest.write(to: manifestURL)
        let streamed = try await client.finishPreparedMigration(at: source, header: header, items: [item])
        XCTAssertEqual(streamed.verifiedBytes, Int64(resourceBytes.count))
        XCTAssertFalse(FileManager.default.fileExists(atPath: resourceURL.path),
                       "stream completion must not require a full local resource copy")
        try resourceBytes.write(to: resourceURL)
        let receipt = try await client.uploadMigrationArchive(at: source, pairedDeviceID: deviceID)
        XCTAssertEqual(receipt.migrationID, migrationID)
        XCTAssertEqual(receipt.resourceCount, 1)
        XCTAssertEqual(receipt.verifiedBytes, Int64(resourceBytes.count))
        let (package, verified) = try await store.sealVerifiedArchive(
            migrationID: migrationID, authenticatedDeviceID: deviceID
        )
        XCTAssertEqual(receipt.manifestSHA256, verified.manifestSHA256)
        XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent(path)), resourceBytes)
        XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent("manifest.jsonl")), manifest)

        let factFile = root.appendingPathComponent("tail.imageallfacts")
        try ImageAllMigrationFacts.write(.init(
            sourceDeviceID: deviceID, sourceEpoch: header.sourceEpoch,
            scopeRevision: header.scopeRevision, snapshotSequence: 2,
            factWatermark: 2, items: [.init(
                mediaID: item.mediaID, observedFavorite: true,
                favoriteTarget: true, tagDecisions: [], collections: []
            )]
        ), to: factFile)
        _ = try ImageAllMigrationFacts.publish(from: factFile, into: source)
        let updatedReceipt = try await client.uploadMigrationArchive(at: source, pairedDeviceID: deviceID)
        XCTAssertNotNil(updatedReceipt.factsSHA256)
        XCTAssertEqual(updatedReceipt.verifiedBytes, receipt.verifiedBytes)
        let (_, updatedVerification) = try await store.sealVerifiedArchive(
            migrationID: migrationID, authenticatedDeviceID: deviceID
        )
        XCTAssertEqual(updatedReceipt.factsSHA256, updatedVerification.factsSHA256)
    }

    func testPreparedFileRejectsChangedDigestAndCancellationWithoutSealing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let receiver = root.appendingPathComponent("receiver")
        try FileManager.default.createDirectory(at: receiver, withIntermediateDirectories: true)
        let store = try ImageAllMigrationTransferStore(root: receiver, maximumChunkBytes: 32)
        let deviceID = UUID(), migrationID = UUID()
        let file = root.appendingPathComponent("prepared.bin")
        let bytes = Data(repeating: 0x44, count: 99)
        try bytes.write(to: file)
        let client = RemoteLibraryClient(endpoint: try RemoteHostEndpoint(
            host: "127.0.0.1", port: 8787, accessToken: "synthetic-bearer"
        ), transport: TransferFixtureTransport(store: store, deviceID: deviceID))
        let path = "resources/\(UUID().uuidString.lowercased()).bin"
        do {
            _ = try await client.uploadMigrationFile(at: file, migrationID: migrationID,
                relativePath: path, byteCount: 99, sha256: hash(Data(repeating: 0x55, count: 99)))
            XCTFail("wrong digest accepted")
        } catch let error as RemoteAPIError { XCTAssertEqual(error.code, .conflict) }
        let progress = try await store.status(migrationID: migrationID, authenticatedDeviceID: deviceID)
        XCTAssertFalse(progress.sealed)
        // Even a fully committed file must be rehashed when resuming.
        do {
            _ = try await client.uploadMigrationFile(at: file, migrationID: migrationID,
                relativePath: path, byteCount: 99, sha256: hash(Data(repeating: 0x55, count: 99)))
            XCTFail("committed offset bypassed source digest")
        } catch let error as RemoteAPIError { XCTAssertEqual(error.code, .conflict) }
        let canceledID = UUID()
        do {
            _ = try await client.uploadMigrationFile(at: file, migrationID: canceledID,
                relativePath: path, byteCount: 99, sha256: hash(bytes),
                beforeChunk: { throw CancellationError() })
            XCTFail("cancellation ignored")
        } catch is CancellationError {}
        do {
            _ = try await store.status(migrationID: canceledID, authenticatedDeviceID: deviceID)
            XCTFail("canceled preparation created a receiver session")
        } catch let error as ImageAllMigrationTransferError { XCTAssertEqual(error, .invalidSession) }
        let interruptedID = UUID()
        let gate = PreparedFileGate()
        do {
            _ = try await client.uploadMigrationFile(at: file, migrationID: interruptedID,
                relativePath: path, byteCount: 99, sha256: hash(bytes),
                beforeChunk: { try await gate.check() })
            XCTFail("in-flight cancellation ignored")
        } catch is CancellationError {}
        let partial = try await store.status(migrationID: interruptedID, authenticatedDeviceID: deviceID)
        XCTAssertEqual(partial.files.first?.committedBytes, 32)
        let resumed = try await client.uploadMigrationFile(at: file, migrationID: interruptedID,
            relativePath: path, byteCount: 99, sha256: hash(bytes))
        XCTAssertEqual(resumed.files.first?.committedBytes, 99)
        XCTAssertFalse(resumed.sealed)
        let link = root.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        do {
            _ = try await client.uploadMigrationFile(at: link, migrationID: UUID(),
                relativePath: path, byteCount: 99, sha256: hash(bytes))
            XCTFail("source symlink accepted")
        } catch let error as RemoteAPIError { XCTAssertEqual(error.code, .badRequest) }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testPreparedFileRejectsMalformedProgressBeforeSendingBytes() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bytes = Data([1, 2, 3])
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let id = UUID()
        let path = "resources/\(UUID().uuidString.lowercased()).bin"
        let valid: [String: Any] = ["migrationID": id.uuidString, "maximumChunkBytes": 32,
            "maximumSessionBytes": 1024, "files": [], "sealed": false]
        var cases: [[String: Any]] = []
        for changes: [String: Any] in [
            ["migrationID": UUID().uuidString], ["maximumChunkBytes": 0],
            ["maximumChunkBytes": ImageAllMigrationTransferStore.defaultMaximumChunkBytes + 1],
            ["files": [["relativePath": path, "committedBytes": 4]]],
            ["files": [["relativePath": path, "committedBytes": -1]]],
            ["files": [["relativePath": path, "committedBytes": 0],
                       ["relativePath": path, "committedBytes": 0]]]
        ] {
            cases.append(valid.merging(changes) { _, new in new })
        }
        for value in cases {
            let transport = InvalidProgressTransport(payload: try JSONSerialization.data(withJSONObject: value))
            let client = RemoteLibraryClient(endpoint: try RemoteHostEndpoint(
                host: "127.0.0.1", port: 8787, accessToken: "synthetic-bearer"
            ), transport: transport)
            do {
                _ = try await client.uploadMigrationFile(at: file, migrationID: id,
                    relativePath: path, byteCount: 3, sha256: hash(bytes))
                XCTFail("invalid receiver progress accepted")
            } catch let error as RemoteAPIError { XCTAssertEqual(error.code, .conflict) }
            let count = await transport.requestCount
            XCTAssertEqual(count, 1, "invalid begin response must stop before a chunk request")
        }
    }

    private func hash(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
    }
}

private struct TransferFixtureTransport: RemoteHTTPTransporting {
    let store: ImageAllMigrationTransferStore
    let deviceID: UUID

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-bearer",
              let url = request.url else {
            throw RemoteAPIError(code: .unauthorized, message: "missing bearer")
        }
        let path = url.path
        let migrationID: UUID? = {
            let parts = path.split(separator: "/")
            guard parts.count >= 3 else { return nil }
            return UUID(uuidString: String(parts[2]))
        }()
        let payload: Data
        if path == RemoteHTTPPaths.capabilities {
            payload = try JSONEncoder().encode(RemoteCapabilities(
                hostAppVersion: "test", capabilities: [.migrationTransfer, .migrationResourceVerification]
            ))
        } else if let migrationID,
                  path == RemoteHTTPPaths.migrationTransfer(migrationID),
                  request.httpMethod == "POST" {
            payload = try JSONEncoder().encode(try await store.begin(
                migrationID: migrationID, authenticatedDeviceID: deviceID
            ))
        } else if let migrationID,
                  path == RemoteHTTPPaths.migrationTransferChunks(migrationID),
                  request.httpMethod == "PUT" {
            let body = request.httpBody ?? Data()
            let progress = try await store.append(
                migrationID: migrationID, authenticatedDeviceID: deviceID,
                relativePath: request.value(forHTTPHeaderField: "X-ImageAll-File") ?? "",
                offset: Int64(request.value(forHTTPHeaderField: "X-ImageAll-Offset") ?? "") ?? -1,
                bytes: body,
                sha256: request.value(forHTTPHeaderField: "X-ImageAll-SHA256") ?? ""
            )
            payload = try JSONEncoder().encode(progress)
        } else if let migrationID,
                  path == RemoteHTTPPaths.migrationTransferVerifyResource(migrationID),
                  request.httpMethod == "POST" {
            let resource = try JSONDecoder().decode(ImageAllMigrationResourceVerificationRequest.self,
                from: request.httpBody ?? Data())
            payload = try JSONEncoder().encode(try await store.verifyResource(
                migrationID: migrationID, authenticatedDeviceID: deviceID, request: resource))
        } else if let migrationID,
                  path == RemoteHTTPPaths.migrationTransferSeal(migrationID),
                  request.httpMethod == "POST" {
            let (_, verification) = try await store.sealVerifiedArchive(
                migrationID: migrationID, authenticatedDeviceID: deviceID
            )
            payload = try JSONEncoder().encode(
                ImageAllMigrationTransferSealReceipt(verification: verification)
            )
        } else {
            throw RemoteAPIError(code: .notFound, message: "unexpected test route")
        }
        return (
            payload,
            HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
        )
    }
}

private actor PreparedFileGate {
    private var calls = 0
    func check() throws {
        calls += 1
        if calls >= 3 { throw CancellationError() }
    }
}

private actor InvalidProgressTransport: RemoteHTTPTransporting {
    let payload: Data
    private(set) var requestCount = 0
    init(payload: Data) { self.payload = payload }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requestCount += 1
        return (payload, HTTPURLResponse(url: request.url!, statusCode: 200,
                                         httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}
