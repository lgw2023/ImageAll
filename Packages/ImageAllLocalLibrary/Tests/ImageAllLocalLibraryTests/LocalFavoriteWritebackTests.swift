import Foundation
import Testing
@testable import ImageAllLocalLibrary

private enum SyntheticSourceFailure: Error { case denied, invisible, writeFailed, readFailed }

private actor SyntheticFavoriteSource: LocalFavoriteSource {
    var writes = 0
    var reads = 0
    let writeFailure: SyntheticSourceFailure?
    let readFailure: SyntheticSourceFailure?
    let observed: Bool
    let duringWrite: (@Sendable () async throws -> Void)?

    init(writeFailure: SyntheticSourceFailure? = nil, readFailure: SyntheticSourceFailure? = nil,
         observed: Bool = true, duringWrite: (@Sendable () async throws -> Void)? = nil) {
        self.writeFailure = writeFailure
        self.readFailure = readFailure
        self.observed = observed
        self.duringWrite = duringWrite
    }

    func writeFavorite(_ favorite: Bool, localIdentifier: String) async throws {
        #expect(favorite && localIdentifier == "synthetic-favorite")
        if let writeFailure { throw writeFailure }
        writes += 1
        try await duringWrite?()
    }

    func readFavorite(localIdentifier: String) async throws -> Bool {
        reads += 1
        if let readFailure { throw readFailure }
        return observed
    }
}

private func fixture(_ root: URL) async throws -> (LocalLibraryStore, UUID) {
    let store = try LocalLibraryStore(url: root.appendingPathComponent("local.sqlite"))
    try await store.observe([.init(localIdentifier: "synthetic-favorite", kind: "image",
                                  creationDate: nil, isFavorite: false)])
    let asset = try #require(await store.assets(visibleIdentifiers: ["synthetic-favorite"]).first)
    try await store.setShared(assetID: asset.id, shared: true)
    try await store.setFavoriteTarget(assetID: asset.id, isFavorite: true)
    return (store, asset.id)
}

@Test func favoriteSourceFailureThenRestartRetryPreservesIntent() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, assetID) = try await fixture(root)
    let original = try await store.prepareFavoriteWriteback(assetID: assetID, expectedTarget: true)
    let pending = try await store.pendingSharedOperations().map(\.id)
    let denied = SyntheticFavoriteSource(writeFailure: .denied)
    await #expect(throws: SyntheticSourceFailure.self) {
        try await LocalFavoriteWriteback.perform(original, store: store, source: denied)
    }
    #expect(await denied.writes == 0)
    #expect(await denied.reads == 0)
    let reopened = try LocalLibraryStore(url: root.appendingPathComponent("local.sqlite"))
    #expect(try await reopened.assets(visibleIdentifiers: ["synthetic-favorite"]).first?.favoriteWritebackState == .failed)
    let retry = try await reopened.prepareFavoriteWriteback(assetID: assetID, expectedTarget: true)
    #expect(retry == original)
    let available = SyntheticFavoriteSource()
    #expect(try await LocalFavoriteWriteback.perform(retry, store: reopened, source: available) == .matched)
    #expect(await available.writes == 1)
    #expect(await available.reads == 1)
    let final = try #require(await reopened.assets(visibleIdentifiers: ["synthetic-favorite"]).first)
    #expect(final.favoriteTarget == true && final.observedFavorite && final.favoriteWritebackState == .matched)
    #expect(try await reopened.pendingSharedOperations().map(\.id) == pending)
}

@Test(arguments: ["invisible", "writeFailure", "readFailure", "mismatch"])
func favoriteSourceMustReadBackBeforeMatching(failure: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, assetID) = try await fixture(root)
    let intent = try await store.prepareFavoriteWriteback(assetID: assetID, expectedTarget: true)
    let source = SyntheticFavoriteSource(
        writeFailure: failure == "invisible" ? .invisible : failure == "writeFailure" ? .writeFailed : nil,
        readFailure: failure == "readFailure" ? .readFailed : nil, observed: false
    )
    if failure == "mismatch" {
        #expect(try await LocalFavoriteWriteback.perform(intent, store: store, source: source) == .readbackMismatch)
    } else {
        await #expect(throws: SyntheticSourceFailure.self) {
            try await LocalFavoriteWriteback.perform(intent, store: store, source: source)
        }
    }
    let current = try #require(await store.assets(visibleIdentifiers: ["synthetic-favorite"]).first)
    #expect(current.favoriteTarget == true && current.favoriteWritebackState == .failed)
    #expect(!current.observedFavorite)
}

@Test func favoriteLateReplyCannotConfirmNewerEqualTarget() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, assetID) = try await fixture(root)
    let old = try await store.prepareFavoriteWriteback(assetID: assetID, expectedTarget: true)
    let source = SyntheticFavoriteSource(duringWrite: {
        try await store.setFavoriteTarget(assetID: assetID, isFavorite: false)
        try await store.setFavoriteTarget(assetID: assetID, isFavorite: true)
    })
    #expect(try await LocalFavoriteWriteback.perform(old, store: store, source: source) == .superseded)
    #expect(await source.writes == 1)
    #expect(await source.reads == 0)
    let current = try await store.prepareFavoriteWriteback(assetID: assetID, expectedTarget: true)
    #expect(current.operationID != old.operationID)
    #expect(try await store.finishFavoriteWriteback(old, observedValue: true) == false)
    #expect(try await store.finishFavoriteWriteback(old, observedValue: nil) == false)
    let stored = try #require(await store.assets(visibleIdentifiers: ["synthetic-favorite"]).first)
    #expect(stored.favoriteWritebackState == .pending && !stored.observedFavorite)
    let untouched = SyntheticFavoriteSource()
    #expect(try await LocalFavoriteWriteback.perform(old, store: store, source: untouched) == .superseded)
    #expect(await untouched.writes == 0)
}
