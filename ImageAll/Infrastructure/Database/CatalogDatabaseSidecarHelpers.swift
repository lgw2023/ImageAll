import Foundation

enum CatalogDatabaseSidecarHelpers {
    static func walURL(for databaseURL: URL) -> URL {
        URL(fileURLWithPath: databaseURL.path + "-wal")
    }

    static func shmURL(for databaseURL: URL) -> URL {
        URL(fileURLWithPath: databaseURL.path + "-shm")
    }

    static func sidecarURLs(for databaseURL: URL) -> [URL] {
        [walURL(for: databaseURL), shmURL(for: databaseURL)]
    }

    static func hasSidecars(at databaseURL: URL, fileManager: FileManager = .default) -> Bool {
        sidecarURLs(for: databaseURL).contains { fileManager.fileExists(atPath: $0.path) }
    }

    static func removeSidecarsIfPresent(
        at databaseURL: URL,
        fileManager: FileManager = .default
    ) throws {
        for sidecarURL in sidecarURLs(for: databaseURL) where fileManager.fileExists(atPath: sidecarURL.path) {
            try fileManager.removeItem(at: sidecarURL)
        }
    }

    static func requireNoSidecars(
        at databaseURL: URL,
        fileManager: FileManager = .default
    ) throws {
        guard !hasSidecars(at: databaseURL, fileManager: fileManager) else {
            throw CatalogSnapshotError.sidecarConvergenceFailed
        }
    }

    static func isSameVolume(_ lhs: URL, _ rhs: URL) throws -> Bool {
        let keys: Set<URLResourceKey> = [.volumeIdentifierKey]
        let lhsValues = try lhs.resourceValues(forKeys: keys)
        let rhsValues = try rhs.resourceValues(forKeys: keys)
        guard let lhsID = lhsValues.volumeIdentifier, let rhsID = rhsValues.volumeIdentifier else {
            return false
        }
        return (lhsID as AnyObject).isEqual(rhsID)
    }
}
