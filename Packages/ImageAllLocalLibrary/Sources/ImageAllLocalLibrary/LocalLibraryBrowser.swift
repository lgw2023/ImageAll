import Foundation

@MainActor
public protocol LocalLibraryBrowsingSource: AnyObject {
    var canRead: Bool { get }
    func refresh() async throws -> Int
    func observations(in range: Range<Int>) async throws -> [LocalObservedAsset]
    func visibleIdentifiers(in candidates: Set<String>) throws -> Set<String>
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

    public init(store: LocalLibraryStore, source: any LocalLibraryBrowsingSource, pageSize: Int = 100) {
        self.store = store
        self.source = source
        self.pageSize = max(1, pageSize)
    }

    public func invalidate() {
        generation = UUID()
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

    private func isCurrent(_ current: UUID) -> Bool {
        guard generation == current else { return false }
        guard source.canRead else { invalidate(); return false }
        return true
    }
}
