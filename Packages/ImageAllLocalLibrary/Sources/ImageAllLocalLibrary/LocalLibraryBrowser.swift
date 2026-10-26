import Foundation

@MainActor
public protocol LocalLibraryBrowsingSource: AnyObject {
    var canRead: Bool { get }
    func refresh() async throws -> Int
    func observations(in range: Range<Int>) async throws -> [LocalObservedAsset]
    func visibleIdentifiers(in candidates: Set<String>) throws -> Set<String>
}

public struct LocalBulkSharePreview: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let photoCount: Int
    public let videoCount: Int
    public var totalCount: Int { photoCount + videoCount }
}

/// Keeps a permission-filtered view over persistent local facts. Invalidating a
/// view never deletes facts, selections, or pending shared operations.
@MainActor
public final class LocalLibraryBrowser {
    public private(set) var assets: [LocalAsset] = []
    public private(set) var hasMore = false
    private let store: LocalLibraryStore
    private let source: any LocalLibraryBrowsingSource
    private let pageSize: Int
    private var generation = UUID()
    private var loading = false
    private var offset = 0
    private var total = 0
    private var sharePlan: (preview: LocalBulkSharePreview, generation: UUID,
                            identifiers: Set<String>, version: LocalShareSelectionVersion)?

    public init(store: LocalLibraryStore, source: any LocalLibraryBrowsingSource, pageSize: Int = 100) {
        self.store = store
        self.source = source
        self.pageSize = max(1, pageSize)
    }

    public func invalidate() {
        generation = UUID()
        sharePlan = nil
        assets = []
        hasMore = false
        loading = false
        offset = 0
        total = 0
    }

    public func refresh() async throws {
        invalidate()
        guard source.canRead else { return }
        let current = generation
        let count = try await source.refresh()
        guard isCurrent(current) else { return }
        total = max(0, count)
        hasMore = total > 0
        try await loadMore()
    }

    public func loadMore() async throws {
        guard source.canRead else { invalidate(); return }
        guard !loading, offset < total else { return }
        let current = generation
        loading = true
        defer { if generation == current { loading = false } }
        do {
            let end = min(total, offset + pageSize)
            let page = try await source.observations(in: offset..<end)
            guard isCurrent(current) else { return }
            try await store.observe(page)
            guard isCurrent(current) else { return }
            let order = assets.map(\.localIdentifier) + page.map(\.localIdentifier)
            let visible = try source.visibleIdentifiers(in: Set(order))
            let indexed = try await store.assets(visibleIdentifiers: visible)
            guard isCurrent(current) else { return }
            // A limited selection can change without changing the authorization enum.
            let stillVisible = try source.visibleIdentifiers(in: visible)
            let byLocator = Dictionary(uniqueKeysWithValues: indexed.map { ($0.localIdentifier, $0) })
            var seen = Set<String>()
            assets = order.compactMap { locator in
                guard stillVisible.contains(locator), seen.insert(locator).inserted else { return nil }
                return byLocator[locator]
            }
            offset = end
            hasMore = offset < total
        } catch {
            guard generation == current else { return }
            invalidate()
            throw error
        }
    }

    /// Enumerates source metadata only. Preparing never selects assets or sends anything.
    public func prepareBulkSharePreview(excludingAssetIDs: Set<UUID> = []) async throws -> LocalBulkSharePreview {
        invalidate()
        guard source.canRead else { throw LocalLibraryError.sharePlanExpired }
        let current = generation
        let version = try await store.shareSelectionVersion()
        let excluded = try await store.localIdentifiers(for: excludingAssetIDs, expected: version)
        let count = try await source.refresh()
        guard isCurrent(current), count >= 0 else { throw LocalLibraryError.sharePlanExpired }
        var identifiers = Set<String>()
        var photos = 0, videos = 0
        var seen = Set<String>()
        for start in stride(from: 0, to: count, by: pageSize) {
            try Task.checkCancellation()
            let end = min(count, start + pageSize)
            let page = try await source.observations(in: start..<end)
            guard isCurrent(current), page.count == end - start else { throw LocalLibraryError.sharePlanExpired }
            for item in page {
                guard seen.insert(item.localIdentifier).inserted,
                      item.kind == "image" || item.kind == "video" else { throw LocalLibraryError.sharePlanExpired }
                if excluded.contains(item.localIdentifier) { continue }
                identifiers.insert(item.localIdentifier)
                if item.kind == "video" { videos += 1 } else { photos += 1 }
            }
            try await store.observe(page.filter { !excluded.contains($0.localIdentifier) })
            guard isCurrent(current) else { throw LocalLibraryError.sharePlanExpired }
        }
        try await validateVisible(identifiers, generation: current)
        guard try await store.shareSelectionVersion() == version, isCurrent(current) else {
            throw LocalLibraryError.sharePlanExpired
        }
        let preview = LocalBulkSharePreview(id: UUID(), photoCount: photos, videoCount: videos)
        sharePlan = (preview, current, identifiers, version)
        return preview
    }

    public func confirmBulkSharePreview(_ preview: LocalBulkSharePreview, replacingSelection: Bool = false) async throws -> Int {
        guard let plan = sharePlan, plan.preview == preview, isCurrent(plan.generation) else {
            throw LocalLibraryError.sharePlanExpired
        }
        try await validateVisible(plan.identifiers, generation: plan.generation)
        // Consume before yielding to the actor: a repeated tap cannot submit this plan twice.
        sharePlan = nil
        if replacingSelection {
            return try await store.replaceSharedSelection(localIdentifiers: plan.identifiers, expected: plan.version)
        }
        return try await store.addSharedSelection(localIdentifiers: plan.identifiers, expected: plan.version)
    }

    public func cancelBulkSharePreview() { sharePlan = nil }

    private func validateVisible(_ identifiers: Set<String>, generation current: UUID) async throws {
        let ordered = Array(identifiers)
        for start in stride(from: 0, to: ordered.count, by: pageSize) {
            try Task.checkCancellation()
            let batch = Set(ordered[start..<min(ordered.count, start + pageSize)])
            guard isCurrent(current), try source.visibleIdentifiers(in: batch) == batch else {
                throw LocalLibraryError.sharePlanExpired
            }
            await Task.yield()
        }
        guard isCurrent(current) else { throw LocalLibraryError.sharePlanExpired }
    }

    private func isCurrent(_ current: UUID) -> Bool {
        guard generation == current else { return false }
        guard source.canRead else { invalidate(); return false }
        return true
    }
}
