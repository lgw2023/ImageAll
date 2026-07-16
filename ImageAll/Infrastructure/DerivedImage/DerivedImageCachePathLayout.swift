import Foundation

enum DerivedImageCachePathLayout {
    static let cachesParentComponent = "Caches"
    static let cachesLeafComponent = "ImageAll"
    static let rootComponent = "DerivedImages"
    static let versionComponent = "v1"
    static let stagingComponent = "staging"
    static let objectsComponent = "objects"

    static func versionRoot(under cachesDirectory: URL) -> URL {
        cachesDirectory
            .appendingPathComponent(rootComponent, isDirectory: true)
            .appendingPathComponent(versionComponent, isDirectory: true)
    }

    static func stagingDirectory(under versionRoot: URL) -> URL {
        versionRoot.appendingPathComponent(stagingComponent, isDirectory: true)
    }

    static func objectsDirectory(under versionRoot: URL) -> URL {
        versionRoot.appendingPathComponent(objectsComponent, isDirectory: true)
    }

    static func objectRelativePath(entryID: UUID, format: DerivedImageStorageFormat) -> String {
        let canonical = entryID.uuidString.lowercased()
        let hex = canonical.replacingOccurrences(of: "-", with: "")
        let shard = String(hex.prefix(2))
        let fileExtension = format == .jpeg ? "jpg" : "png"
        return "\(objectsComponent)/\(shard)/\(canonical).\(fileExtension)"
    }

    static func objectURL(versionRoot: URL, entryID: UUID, format: DerivedImageStorageFormat) -> URL {
        let canonical = entryID.uuidString.lowercased()
        let hex = canonical.replacingOccurrences(of: "-", with: "")
        let shard = String(hex.prefix(2))
        let fileExtension = format == .jpeg ? "jpg" : "png"
        return objectsDirectory(under: versionRoot)
            .appendingPathComponent(shard, isDirectory: true)
            .appendingPathComponent("\(canonical).\(fileExtension)")
    }

    static func stagingFileName() -> String {
        UUID().uuidString.lowercased()
    }

    static func isKnownStagingFileName(_ name: String) -> Bool {
        guard let id = UUID(uuidString: name) else { return false }
        return name == id.uuidString.lowercased()
    }

    static func shardName(for entryID: UUID) -> String {
        String(entryID.uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(2))
    }

    static func isValidShardComponent(_ name: String) -> Bool {
        guard name.count == 2 else { return false }
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        return name.unicodeScalars.allSatisfy { hex.contains($0) }
    }

    static func parseObjectFileName(_ name: String) -> (entryID: UUID, format: DerivedImageStorageFormat)? {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let stem = String(parts[0])
        let ext = String(parts[1])
        guard stem == stem.lowercased(), stem.contains("-") == true else { return nil }
        guard let entryID = UUID(uuidString: stem) else { return nil }
        let format: DerivedImageStorageFormat?
        switch ext {
        case "jpg": format = .jpeg
        case "png": format = .png
        default: format = nil
        }
        guard let format else { return nil }
        return (entryID, format)
    }

    static func isKnownObjectRelativePath(_ relativePath: String) -> Bool {
        let prefix = "\(objectsComponent)/"
        guard relativePath.hasPrefix(prefix) else { return false }
        let remainder = String(relativePath.dropFirst(prefix.count))
        let parts = remainder.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let shard = String(parts[0])
        guard isValidShardComponent(shard),
              let parsed = parseObjectFileName(String(parts[1]))
        else {
            return false
        }
        return shard == shardName(for: parsed.entryID)
    }
}
