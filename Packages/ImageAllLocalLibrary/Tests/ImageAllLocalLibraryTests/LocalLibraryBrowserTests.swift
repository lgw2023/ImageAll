import Foundation
import Testing
@testable import ImageAllLocalLibrary

@MainActor
private final class SyntheticBrowsingSource: LocalLibraryBrowsingSource {
    var canRead = true
    var names = ["a", "b", "c"]
    var visible: Set<String> = ["a", "b", "c"]
    var pageCalls = 0
    var pauseNext = false
    var pending: CheckedContinuation<[LocalObservedAsset], Never>?
    var captured: [LocalObservedAsset] = []

    func refresh() async throws -> Int { names.count }
    func observations(in range: Range<Int>) async throws -> [LocalObservedAsset] {
        pageCalls += 1
        let page = range.map { LocalObservedAsset(localIdentifier: names[$0], kind: "image",
                                                  creationDate: nil, isFavorite: false) }
        if pauseNext {
            pauseNext = false
            captured = page
            return await withCheckedContinuation { pending = $0 }
        }
        return page
    }
    func visibleIdentifiers(in candidates: Set<String>) throws -> Set<String> { candidates.intersection(visible) }
    func resume() {
        pending?.resume(returning: captured)
        pending = nil
    }
}

@MainActor
@Test func browsePermissionContractionPreservesFactsAcrossRestart() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("local.sqlite")
    let store = try LocalLibraryStore(url: url)
    let source = SyntheticBrowsingSource()
    let browser = LocalLibraryBrowser(store: store, source: source, pageSize: 2)
    try await browser.refresh()
    #expect(browser.assets.map(\.localIdentifier) == ["a", "b"])
    let a = try #require(browser.assets.first)
    let tag = try await store.createTag(name: "保留")
    try await store.setDecision(assetID: a.id, tagID: tag, decision: .accepted)
    try await store.setShared(assetID: a.id, shared: true)
    try await store.setFavoriteTarget(assetID: a.id, isFavorite: true)
    let pending = try await store.pendingSharedOperations().map(\.id)
    source.visible = ["b", "c"] // limited authorization keeps its enum but loses an asset
    try await browser.loadMore()
    #expect(browser.assets.map(\.localIdentifier) == ["b", "c"])
    source.canRead = false
    try await browser.refresh()
    #expect(browser.assets.isEmpty && !browser.hasMore)
    let calls = source.pageCalls
    try await browser.loadMore()
    #expect(source.pageCalls == calls)
    let reopened = try LocalLibraryStore(url: url)
    #expect(try await reopened.decisions(assetID: a.id)[tag] == .accepted)
    #expect(try await reopened.pendingSharedOperations().map(\.id) == pending)
    source.canRead = true
    source.visible = ["a", "b", "c"]
    let afterRestart = LocalLibraryBrowser(store: reopened, source: source, pageSize: 2)
    try await afterRestart.refresh()
    #expect(afterRestart.assets.first?.id == a.id)
    #expect(afterRestart.assets.first?.favoriteTarget == true)
}

@MainActor
@Test(arguments: [false, true])
func oldBrowsePageCannotReappearAfterRefresh(deny: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalLibraryStore(url: root.appendingPathComponent("local.sqlite"))
    let source = SyntheticBrowsingSource()
    let browser = LocalLibraryBrowser(store: store, source: source, pageSize: 1)
    try await browser.refresh()
    source.pauseNext = true
    let oldLoad = Task { try await browser.loadMore() }
    while source.pending == nil { await Task.yield() }
    try await browser.loadMore() // repeated UI action must not request the same page twice
    #expect(source.pageCalls == 2)
    source.canRead = !deny
    source.names = ["c"]
    source.visible = ["c"]
    try await browser.refresh()
    source.resume()
    try await oldLoad.value
    #expect(browser.assets.map(\.localIdentifier) == (deny ? [] : ["c"]))
    #expect(!browser.hasMore)
}
