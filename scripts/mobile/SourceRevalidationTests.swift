import Foundation
import CryptoKit
@testable import ImageAllRemoteProtocol

@main
struct SourceRevalidationTests {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let binding = Data("synthetic-source".utf8), version = Data("version-1".utf8)
        let checkpoint = try ImageAllMigrationExportCheckpoint(parent: root, binding: binding)
        defer { checkpoint.close() }
        let location = try checkpoint.resourceLocation(key: "synthetic|0", fileExtension: "bin")
        let bytes = Data(repeating: 0x31, count: 1_048_576)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let resource = ImageAllMigrationResource(id: location.id, role: "original", version: 1,
            uniformTypeIdentifier: "public.data", required: true, status: .present,
            relativePath: location.relativePath, byteCount: Int64(bytes.count), sha256: hash)
        try checkpoint.recordVerifiedStreamingResource(resource, receipt: .init(migrationID: checkpoint.migrationID,
            deviceID: UUID(), resource: .init(relativePath: location.relativePath, byteCount: Int64(bytes.count), sha256: hash)))
        let initiallyVerified = try checkpoint.isStreamingSourceVerified(resource, version: version)
        precondition(!initiallyVerified)
        var progress = LocalShareSourceRevalidationProgress()
        progress.begin(expectedBytes: Int64(bytes.count))
        progress.recordReadBytes(524_288)
        progress.recordReadBytes(1) // stale samples cannot move backwards
        precondition(progress.readBytes == 524_288 && progress.verifiedResources == 0)
        precondition(progress.message.contains("缺少当前来源版本") && progress.message.contains("比对摘要"))
        progress.recordReadBytes(Int64(bytes.count))
        precondition(progress.verifiedResources == 0, "read completion is not verification")
        do {
            try checkpoint.recordStreamingSourceVerification(resource, version: version,
                byteCount: Int64(bytes.count), sha256: String(repeating: "b", count: 64))
            preconditionFailure("same-size damaged source must be rejected")
        } catch ImageAllMigrationArchiveError.resourceChanged { }
        progress.stopReading()
        precondition(progress.wasRequired && !progress.isReading && progress.verifiedResources == 0)
        progress.recordReadBytes(9_999_999)
        precondition(progress.readBytes == Int64(bytes.count))
        progress.begin(expectedBytes: Int64(bytes.count))
        precondition(progress.readBytes == 0)
        progress.recordReadBytes(Int64(bytes.count))
        try checkpoint.recordStreamingSourceVerification(resource, version: version,
            byteCount: Int64(bytes.count), sha256: hash)
        progress.didVerify()
        progress.didVerify()
        precondition(progress.verifiedResources == 1 && !progress.isReading)
        let currentVerified = try checkpoint.isStreamingSourceVerified(resource, version: version)
        let changedVerified = try checkpoint.isStreamingSourceVerified(resource, version: Data("version-2".utf8))
        precondition(currentVerified && !changedVerified)
        progress = LocalShareSourceRevalidationProgress()
        precondition(!progress.wasRequired && progress.verifiedResources == 0)
        print("PASS: missing version proof exposes read progress; same-size damage rejected; only successful digest check advances verification; stop/reset and changed version preserved")
    }
}
