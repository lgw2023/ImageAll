/// Media import starts only after the explicitly shared organization facts
/// have converged. A received directory alone cannot satisfy this gate.
public struct ImageAllPhoneImportReadiness: Sendable, Equatable {
    public let conflicts: Int
    public let remainingOperations: Int
    public let deferredOperations: Int
    public let hasMoreTagChanges: Bool
    public let hasMoreCollectionChanges: Bool
    public let hasMoreFavoriteChanges: Bool

    public init(conflicts: Int, remainingOperations: Int, deferredOperations: Int,
                hasMoreTagChanges: Bool, hasMoreCollectionChanges: Bool, hasMoreFavoriteChanges: Bool) {
        self.conflicts = conflicts
        self.remainingOperations = remainingOperations
        self.deferredOperations = deferredOperations
        self.hasMoreTagChanges = hasMoreTagChanges
        self.hasMoreCollectionChanges = hasMoreCollectionChanges
        self.hasMoreFavoriteChanges = hasMoreFavoriteChanges
    }
    public var canStartMediaImport: Bool {
        conflicts == 0 && remainingOperations == 0 && deferredOperations == 0
            && !hasMoreTagChanges && !hasMoreCollectionChanges && !hasMoreFavoriteChanges
    }
}
