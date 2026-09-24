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
        let receipt = try await client.uploadMigrationArchive(at: source)
        XCTAssertEqual(receipt.migrationID, migrationID)
        XCTAssertEqual(receipt.resourceCount, 1)
        XCTAssertEqual(receipt.verifiedBytes, Int64(resourceBytes.count))
        let (package, verified) = try await store.sealVerifiedArchive(
            migrationID: migrationID, authenticatedDeviceID: deviceID
        )
        XCTAssertEqual(receipt.manifestSHA256, verified.manifestSHA256)
        XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent(path)), resourceBytes)
        XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent("manifest.jsonl")), manifest)
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
                hostAppVersion: "test", capabilities: [.migrationTransfer]
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
