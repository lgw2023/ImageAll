import CryptoKit
import Foundation
import ImageAllRemoteProtocol

@main struct RecoveryProbe {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let fixture = try JSONDecoder().decode(Fixture.self,
            from: Data(contentsOf: root.appendingPathComponent("fixture.json")))
        let store = try ImageAllMigrationTransferStore(root: root)
        let started = Date()
        print("cold-begin"); fflush(stdout)
        let progress = try await store.begin(migrationID: fixture.migrationID,
            authenticatedDeviceID: fixture.deviceID)
        guard progress.files.count == fixture.files,
              progress.files.reduce(Int64(0), { $0 + $1.committedBytes }) == fixture.bytes else {
            throw ProbeError.mismatch
        }
        let checkpoint = try await store.resumeCheckpoint(migrationID: fixture.migrationID,
            authenticatedDeviceID: fixture.deviceID)
        guard checkpoint.resources.count == fixture.receipts else { throw ProbeError.mismatch }
        print("cold-recovery-ok seconds=\(Date().timeIntervalSince(started)) files=\(progress.files.count) bytes=\(fixture.bytes) receipts=\(checkpoint.resources.count)")
        fflush(stdout)
        if fixture.archive == true {
            guard let resource = checkpoint.resources.first?.resource else { throw ProbeError.mismatch }
            // Every cold read drained its buffers; now exercise receipt verification
            // and duplicate chunk ACKs before independently sealing the whole archive.
            let receipt = try await store.verifyResource(migrationID: fixture.migrationID,
                authenticatedDeviceID: fixture.deviceID, request: resource)
            guard receipt.resource == resource else { throw ProbeError.mismatch }
            if !progress.sealed {
                let bytes = Data(repeating: 0, count: 4 * 1024 * 1024)
                let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                let replay = try await store.append(migrationID: fixture.migrationID,
                    authenticatedDeviceID: fixture.deviceID, relativePath: resource.relativePath,
                    offset: 0, bytes: bytes, sha256: hash)
                guard replay.files == progress.files else { throw ProbeError.mismatch }
            }
            print("seal-begin"); fflush(stdout)
            let (package, sealed) = try await store.sealVerifiedArchive(migrationID: fixture.migrationID,
                authenticatedDeviceID: fixture.deviceID)
            let (_, replay) = try await store.sealVerifiedArchive(migrationID: fixture.migrationID,
                authenticatedDeviceID: fixture.deviceID)
            var visited = 0
            let visitedReceipt = try ImageAllMigrationArchive.visitVerifiedRecords(at: package,
                onHeader: { _ in }, onItem: { _ in visited += 1 })
            guard sealed == replay, sealed == visitedReceipt, sealed.isComplete,
                  sealed.itemCount == fixture.receipts, visited == fixture.receipts,
                  sealed.resourceCount == fixture.receipts else { throw ProbeError.mismatch }
            print("seal-replay-visit-ok seconds=\(Date().timeIntervalSince(started)) items=\(visited) bytes=\(sealed.verifiedBytes)")
            fflush(stdout)
        }
    }
    struct Fixture: Decodable { let migrationID: UUID; let deviceID: UUID; let files: Int; let bytes: Int64; let receipts: Int; let archive: Bool? }
    enum ProbeError: Error { case mismatch }
}
