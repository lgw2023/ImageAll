import Foundation
import Testing
@testable import ImageAllLocalLibrary

@MainActor
private final class BulkShareSource: LocalLibraryBrowsingSource {
    var canRead = true
    var names = (0..<7).map { "synthetic-\($0)" }
    var visible = Set((0..<7).map { "synthetic-\($0)" })
    var pageCalls = 0
    func refresh() async throws -> Int { names.count }
    func observations(in range: Range<Int>) async throws -> [LocalObservedAsset] {
        pageCalls += 1
        return range.map { .init(localIdentifier: names[$0], kind: $0 % 2 == 0 ? "image" : "video",
                                 creationDate: nil, isFavorite: false) }
    }
    func visibleIdentifiers(in candidates: Set<String>) throws -> Set<String> { candidates.intersection(visible) }
}

@MainActor
@Test func bulkSharePreviewRequiresConfirmationAndOneAtomicScopeChange() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalLibraryStore(url: root.appendingPathComponent("local.sqlite"))
    // Existing selection outside this visible preview is retained, never treated as deleted.
    try await store.observe([.init(localIdentifier: "older-hidden", kind: "image", creationDate: nil, isFavorite: false)])
    let old = try #require(await store.assets(visibleIdentifiers: ["older-hidden"]).first)
    try await store.setShared(assetID: old.id, shared: true)
    let before = try await store.shareSelectionVersion()
    let source = BulkShareSource()
    let browser = LocalLibraryBrowser(store: store, source: source, pageSize: 2)
    let preview = try await browser.prepareBulkSharePreview()
    #expect(preview.photoCount == 4 && preview.videoCount == 3)
    #expect(source.pageCalls == 4)
    #expect(try await store.sharedSelections().count == 1)
    #expect(try await store.shareSelectionVersion() == before)
    #expect(try await browser.confirmBulkSharePreview(preview) == 7)
    #expect(try await store.sharedSelections().count == 8)
    #expect(try await store.shareSelectionVersion().revision == before.revision + 1)
    await #expect(throws: LocalLibraryError.sharePlanExpired) { try await browser.confirmBulkSharePreview(preview) }
    let again = try await browser.prepareBulkSharePreview()
    #expect(try await browser.confirmBulkSharePreview(again) == 0)
    #expect(try await store.shareSelectionVersion().revision == before.revision + 1)
    #expect(try await store.pendingSharedOperations().isEmpty)
}

private enum BulkChange: CaseIterable { case visibility, generation, shareScope }
@MainActor
@Test(arguments: BulkChange.allCases)
private func changedBulkPreviewCannotPartiallySelect(change: BulkChange) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalLibraryStore(url: root.appendingPathComponent("local.sqlite"))
    let source = BulkShareSource()
    let browser = LocalLibraryBrowser(store: store, source: source, pageSize: 2)
    let preview = try await browser.prepareBulkSharePreview()
    switch change {
    case .visibility: source.visible.remove("synthetic-6")
    case .generation: try await browser.refresh()
    case .shareScope:
        let one = try #require(await store.assets(visibleIdentifiers: ["synthetic-0"]).first)
        try await store.setShared(assetID: one.id, shared: true)
    }
    let before = try await store.sharedSelections()
    await #expect(throws: LocalLibraryError.sharePlanExpired) { try await browser.confirmBulkSharePreview(preview) }
    #expect(try await store.sharedSelections().map(\.id) == before.map(\.id))
}
