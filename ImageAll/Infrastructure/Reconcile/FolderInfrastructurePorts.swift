import Foundation

/// Read-only file resource facts used by media classification and move probing.
protocol FolderFileResourceReading: Sendable {
    func fileSizeBytes(for url: URL) -> Int64?
    func modifiedAtNs(for url: URL) -> Int64?
    func resourceIdentifier(for url: URL) -> Data?
}

struct FoundationFolderFileResourceReader: FolderFileResourceReading, Sendable {
    func fileSizeBytes(for url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize
        else {
            return nil
        }
        return Int64(size)
    }

    func modifiedAtNs(for url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
              let date = values.contentModificationDate
        else {
            return nil
        }
        return Int64(date.timeIntervalSince1970 * 1_000_000_000)
    }

    func resourceIdentifier(for url: URL) -> Data? {
        let values = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey])
        guard let object = values?.fileResourceIdentifier else {
            return nil
        }
        if let data = object as? Data {
            return data
        }
        if let number = object as? NSNumber {
            return number.stringValue.data(using: .utf8)
        }
        return nil
    }
}

/// Enumeration-time resource reads for directory entries.
protocol FolderEnumerationResourceReading: Sendable {
    func resourceValues(for url: URL, keys: Set<URLResourceKey>) throws -> URLResourceValues
    func isAliasFile(for url: URL) -> Bool?
}

extension FolderEnumerationResourceReading {
    func isAliasFile(for url: URL) -> Bool? { nil }
}

struct FoundationEnumerationResourceReader: FolderEnumerationResourceReading, Sendable {
    func resourceValues(for url: URL, keys: Set<URLResourceKey>) throws -> URLResourceValues {
        try url.resourceValues(forKeys: keys)
    }
}
