import CryptoKit
import Foundation

public extension RemoteHTTPPaths {
    static let localLibrarySnapshotChunk = "/v1/sync/local-library/snapshot-chunk"
}

public struct RemoteLocalLibrarySnapshotChunk: Codable, Sendable, Equatable {
    public static let maximumChunkBytes = 64 * 1_024
    public static let maximumSnapshotBytes = 128 * 1_024 * 1_024
    public static let maximumAssetCount = 250_000
    public let snapshot: RemoteLocalLibrarySnapshotReceiptLookup
    public let totalBytes: Int
    public let offset: Int
    public let bytes: Data

    public init(snapshot: RemoteLocalLibrarySnapshotReceiptLookup, totalBytes: Int, offset: Int, bytes: Data) {
        self.snapshot = snapshot
        self.totalBytes = totalBytes
        self.offset = offset
        self.bytes = bytes
    }
}

public struct RemoteLocalLibrarySnapshotChunkReceipt: Codable, Sendable, Equatable {
    public let hostID: UUID
    public let deviceID: UUID
    public let requestSHA256: String
    public let receivedBytes: Int
    public let snapshotReceipt: RemoteLocalLibrarySnapshotReceipt?

    public init(hostID: UUID, deviceID: UUID, requestSHA256: String, receivedBytes: Int,
                snapshotReceipt: RemoteLocalLibrarySnapshotReceipt?) {
        self.hostID = hostID
        self.deviceID = deviceID
        self.requestSHA256 = requestSHA256
        self.receivedBytes = receivedBytes
        self.snapshotReceipt = snapshotReceipt
    }
}

/// Called serially by the Host sync actor. Only complete, digest-verified bytes
/// leave this receiver-owned staging area; it never modifies a gallery source.
public struct RemoteLocalLibrarySnapshotChunkStaging: Sendable {
    private struct Header: Codable, Equatable {
        let snapshot: RemoteLocalLibrarySnapshotReceiptLookup
        let totalBytes: Int
    }
    private let root: URL
    public init(root: URL) { self.root = root.standardizedFileURL }

    public func receive(_ chunk: RemoteLocalLibrarySnapshotChunk, deviceID: UUID) throws
        -> (receivedBytes: Int, complete: Data?) {
        let size = RemoteLocalLibrarySnapshotChunk.maximumChunkBytes
        let digest = chunk.snapshot.requestSHA256
        guard digest.count == 64, digest.allSatisfy({ "0123456789abcdef".contains($0) }),
              chunk.snapshot.scopeRevision >= 0, chunk.snapshot.snapshotSequence > 0,
              chunk.totalBytes > 0, chunk.totalBytes <= RemoteLocalLibrarySnapshotChunk.maximumSnapshotBytes,
              chunk.offset >= 0, chunk.offset < chunk.totalBytes, chunk.offset % size == 0,
              chunk.bytes.count == min(size, chunk.totalBytes - chunk.offset) else {
            throw RemoteAPIError(code: .badRequest, message: "invalid snapshot chunk")
        }
        try directory(root)
        let deviceRoot = root.appendingPathComponent(deviceID.uuidString, isDirectory: true)
        try directory(deviceRoot)
        let session = deviceRoot.appendingPathComponent(digest, isDirectory: true)
        let expected = Header(snapshot: chunk.snapshot, totalBytes: chunk.totalBytes)
        let existing = try FileManager.default.contentsOfDirectory(at: deviceRoot, includingPropertiesForKeys: nil)
        for prior in existing {
            try checkSession(prior)
            if prior.lastPathComponent == digest, chunk.offset == 0,
               try FileManager.default.contentsOfDirectory(atPath: prior.path).isEmpty {
                try JSONEncoder().encode(expected).write(to: prior.appendingPathComponent("header.json"), options: .atomic)
            }
            let old = try JSONDecoder().decode(Header.self, from: read(prior.appendingPathComponent("header.json")))
            guard old.snapshot.hostID == chunk.snapshot.hostID,
                  old.snapshot.installID == chunk.snapshot.installID,
                  old.snapshot.sourceEpoch == chunk.snapshot.sourceEpoch,
                  old.snapshot.snapshotSequence <= chunk.snapshot.snapshotSequence,
                  old.snapshot.scopeRevision <= chunk.snapshot.scopeRevision,
                  old.snapshot.snapshotSequence != chunk.snapshot.snapshotSequence || old == expected else {
                throw RemoteAPIError(code: .conflict, message: "snapshot staging identity changed")
            }
        }
        if !FileManager.default.fileExists(atPath: session.path) {
            guard chunk.offset == 0 else { throw RemoteAPIError(code: .conflict, message: "snapshot starts at offset zero") }
            try directory(session)
            try JSONEncoder().encode(expected).write(to: session.appendingPathComponent("header.json"), options: .atomic)
        }
        try checkSession(session)
        guard try JSONDecoder().decode(Header.self, from: read(session.appendingPathComponent("header.json"))) == expected else {
            throw RemoteAPIError(code: .conflict, message: "snapshot chunk header changed")
        }
        // A newer frozen snapshot supersedes only this device's older staging.
        for prior in existing where prior.lastPathComponent != digest { try FileManager.default.removeItem(at: prior) }
        let target = file(session, offset: chunk.offset)
        if FileManager.default.fileExists(atPath: target.path) {
            guard try read(target) == chunk.bytes else {
                throw RemoteAPIError(code: .conflict, message: "snapshot chunk retry changed bytes")
            }
        } else {
            if chunk.offset > 0 {
                let previous = file(session, offset: chunk.offset - size)
                guard FileManager.default.fileExists(atPath: previous.path), try read(previous).count == size else {
                    throw RemoteAPIError(code: .conflict, message: "snapshot chunk gap")
                }
            }
            try chunk.bytes.write(to: target, options: .atomic)
            let handle = try FileHandle(forWritingTo: target)
            defer { try? handle.close() }
            try handle.synchronize()
        }
        var received = 0
        while received < chunk.totalBytes {
            let next = file(session, offset: received)
            guard FileManager.default.fileExists(atPath: next.path) else { break }
            let expectedSize = min(size, chunk.totalBytes - received)
            guard try regularFileSize(next) == expectedSize else {
                throw RemoteAPIError(code: .conflict, message: "snapshot staging truncated")
            }
            received += expectedSize
        }
        guard received == chunk.totalBytes else { return (received, nil) }
        var data = Data()
        data.reserveCapacity(chunk.totalBytes)
        for offset in stride(from: 0, to: received, by: size) { data.append(try read(file(session, offset: offset))) }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == digest else { throw RemoteAPIError(code: .conflict, message: "snapshot digest mismatch") }
        return (received, data)
    }

    public func discard(snapshotSHA256: String, deviceID: UUID) throws {
        guard snapshotSHA256.count == 64, snapshotSHA256.allSatisfy({ "0123456789abcdef".contains($0) }) else { return }
        let session = root.appendingPathComponent(deviceID.uuidString).appendingPathComponent(snapshotSHA256)
        guard FileManager.default.fileExists(atPath: session.path) else { return }
        try directory(root)
        try directory(session.deletingLastPathComponent())
        try checkSession(session)
        try FileManager.default.removeItem(at: session)
    }

    private func file(_ directory: URL, offset: Int) -> URL {
        directory.appendingPathComponent("chunk-\(offset).bin")
    }
    private func directory(_ url: URL) throws {
        guard url.resolvingSymlinksInPath().path == url.standardizedFileURL.path else {
            throw RemoteAPIError(code: .conflict, message: "unsafe snapshot staging directory")
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw RemoteAPIError(code: .conflict, message: "unsafe snapshot staging directory")
        }
    }
    private func read(_ url: URL) throws -> Data {
        _ = try regularFileSize(url)
        return try Data(contentsOf: url)
    }
    private func regularFileSize(_ url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw RemoteAPIError(code: .conflict, message: "unsafe snapshot staging file")
        }
        return values.fileSize ?? -1
    }
    private func checkSession(_ url: URL) throws {
        guard url.lastPathComponent.count == 64,
              url.lastPathComponent.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw RemoteAPIError(code: .conflict, message: "unexpected snapshot staging entry")
        }
        try directory(url)
        for entry in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
            let name = entry.lastPathComponent
            guard name == "header.json" || (name.hasPrefix("chunk-") && name.hasSuffix(".bin")
                && Int(name.dropFirst(6).dropLast(4)) != nil) else {
                throw RemoteAPIError(code: .conflict, message: "unexpected snapshot staging file")
            }
            _ = try regularFileSize(entry)
        }
    }
}
