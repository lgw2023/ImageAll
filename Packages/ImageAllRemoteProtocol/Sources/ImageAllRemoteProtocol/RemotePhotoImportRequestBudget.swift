import Foundation

/// Bounded deadlines for paired photo import work. Request parsing and ordinary
/// UI requests retain their short deadline; recovery must still verify disk bytes.
public enum RemotePhotoImportRequestBudget {
    public static let maximumRequestSeconds: TimeInterval = 1_800
    public static let pinnedResourceSeconds: TimeInterval = maximumRequestSeconds + 60

    public static func processingSeconds(method: String, path: String) -> TimeInterval? {
        let snapshotPosts: Set<String> = [RemoteHTTPPaths.localLibrarySnapshot,
            RemoteHTTPPaths.localLibrarySnapshotChunk, RemoteHTTPPaths.localLibrarySnapshotReceipt,
            RemoteHTTPPaths.localLibraryTagDecision, RemoteHTTPPaths.localLibraryCollectionMembership,
            RemoteHTTPPaths.localLibraryCollectionRename, RemoteHTTPPaths.localLibraryFavoriteTarget]
        let changeGets: Set<String> = [RemoteHTTPPaths.localLibraryTagChanges,
            RemoteHTTPPaths.localLibraryCollectionChanges, RemoteHTTPPaths.localLibraryFavoriteChanges]
        if (method == "POST" && snapshotPosts.contains(path))
            || (method == "GET" && changeGets.contains(path)) { return 180 }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 4, parts[0].isEmpty, parts[1] == "v1",
              parts[2] == "migration-transfers", UUID(uuidString: String(parts[3])) != nil else { return nil }
        if parts.count == 4, method == "GET" || method == "POST" { return 600 }
        guard parts.count == 5 else { return nil }
        switch (method, parts[4]) {
        case ("PUT", "chunks"): return 90
        case ("POST", "verify-resource"): return 600
        case ("POST", "accept-resource"): return 60
        case ("GET", "resume"): return 600
        case ("GET", "handoff"), ("POST", "handoff"): return 60
        case ("GET", "export-cleanup-receipt"): return maximumRequestSeconds
        case ("POST", "automatic-cleanup"): return maximumRequestSeconds
        case ("POST", "seal"): return maximumRequestSeconds
        default: return nil
        }
    }
}
