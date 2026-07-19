import Foundation

struct TagListItem: Sendable, Equatable {
    let id: UUID
    let displayName: String
    let state: TagState
}

enum TagPresetCatalog {
    static let starterDisplayNames = [
        "人像", "风景", "美食", "动物", "植物", "建筑", "旅行", "截图", "文档",
    ]
}

struct TagPresetInstallResult: Sendable, Equatable {
    let createdTags: [TagListItem]
}

struct StandardOntologyConceptInput: Sendable, Equatable {
    let conceptID: String
    let canonicalName: String
}

struct StandardOntologyEdgeInput: Sendable, Equatable {
    let parentConceptID: String
    let childConceptID: String
}

struct StandardOntologyPackageInput: Sendable, Equatable {
    let standardPackID: String
    let standardPackRevision: String
    let ontologyID: String
    let ontologyRevision: String
    let localeRevision: String
    let manifestSHA256: String
    let provider: String
    let modelRevision: String
    let preprocessingRevision: String
    let mappingRevision: String
    let policyRevision: String
    let weightsSHA256: String
    let concepts: [StandardOntologyConceptInput]
    let edges: [StandardOntologyEdgeInput]
}

struct StandardOntologyInstallResult: Sendable, Equatable {
    let installedTags: [TagListItem]
    let wasAlreadyInstalled: Bool
}

enum StandardOntologyCatalogError: Error, Sendable, Equatable {
    case invalidPackage
    case conflictingPackage
    case persistenceFailure
}

struct TagSelectionAggregate: Sendable, Equatable {
    let tagID: UUID
    let acceptedCount: Int
    let rejectedCount: Int
    let unknownCount: Int
}

struct TagMutationPriorState: Sendable, Equatable {
    let assetID: UUID
    let priorState: TagDecisionQueryState
}

struct TagMutationResult: Sendable, Equatable {
    let priorStates: [TagMutationPriorState]
}

struct TagCreateAndApplyResult: Sendable, Equatable {
    let tagID: UUID
    let displayName: String
    let normalizedName: String
    let priorStates: [TagMutationPriorState]

    func restoreSnapshot() -> TagMutationPriorStateSnapshot {
        TagMutationPriorStateSnapshot(tagID: tagID, priorStates: priorStates)
    }
}

struct TagMutationPriorStateSnapshot: Sendable, Equatable {
    let tagID: UUID
    let priorStates: [TagMutationPriorState]
}
