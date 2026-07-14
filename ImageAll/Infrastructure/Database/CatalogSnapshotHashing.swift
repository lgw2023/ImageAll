import CryptoKit
import Foundation

enum CatalogSnapshotHashing {
    static func sha256Hex(of fileURL: URL) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            throw CatalogSnapshotError.invalidDatabaseChecksum
        }

        var hasher = SHA256()
        var readFailed = false

        while true {
            do {
                let chunk = try handle.read(upToCount: 65_536) ?? Data()
                if chunk.isEmpty {
                    break
                }
                hasher.update(data: chunk)
            } catch {
                readFailed = true
                break
            }
        }

        do {
            try handle.close()
        } catch {
            throw CatalogSnapshotError.invalidDatabaseChecksum
        }

        if readFailed {
            throw CatalogSnapshotError.invalidDatabaseChecksum
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func fileSize(of fileURL: URL) throws -> Int64 {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        } catch {
            throw CatalogSnapshotError.invalidDatabaseBytes
        }
        guard let size = attributes[.size] as? NSNumber else {
            throw CatalogSnapshotError.invalidDatabaseBytes
        }
        return size.int64Value
    }
}
