import Foundation

/// A source adapter must recheck authorization and source availability for each call.
/// The coordinator never treats successful mutation alone as a verified readback.
public protocol LocalFavoriteSource: Sendable {
    func writeFavorite(_ favorite: Bool, localIdentifier: String) async throws
    func readFavorite(localIdentifier: String) async throws -> Bool
}

public struct LocalFavoriteWritebackIntent: Sendable, Equatable {
    public let assetID: UUID
    public let sourceEpoch: UUID
    public let localIdentifier: String
    public let operationID: UUID
    public let target: Bool
}

public enum LocalFavoriteWritebackOutcome: Sendable, Equatable {
    case matched
    case readbackMismatch
    case superseded
}

public enum LocalFavoriteWriteback {
    /// Invoked only by an explicit source-write action. Retrying does not create
    /// a new local fact, shared operation, or source identity.
    public static func perform(
        _ intent: LocalFavoriteWritebackIntent,
        store: LocalLibraryStore, source: any LocalFavoriteSource
    ) async throws -> LocalFavoriteWritebackOutcome {
        guard try await store.isCurrentFavoriteWriteback(intent) else { return .superseded }
        do {
            try Task.checkCancellation()
            try await source.writeFavorite(intent.target, localIdentifier: intent.localIdentifier)
            try Task.checkCancellation()
            guard try await store.isCurrentFavoriteWriteback(intent) else { return .superseded }
            let observed = try await source.readFavorite(localIdentifier: intent.localIdentifier)
            guard try await store.finishFavoriteWriteback(intent, observedValue: observed) else {
                return .superseded
            }
            return observed == intent.target ? .matched : .readbackMismatch
        } catch {
            guard try await store.finishFavoriteWriteback(intent, observedValue: nil) else {
                return .superseded
            }
            throw error
        }
    }
}
