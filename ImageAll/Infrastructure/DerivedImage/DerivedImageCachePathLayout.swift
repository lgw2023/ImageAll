import Foundation

enum DerivedImageCachePathLayout {
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
}
