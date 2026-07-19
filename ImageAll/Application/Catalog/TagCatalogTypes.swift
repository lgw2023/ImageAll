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

enum StandardOntologyCatalog {
    static let bundledSceneFixture = StandardOntologyPackageInput(
        standardPackID: "imageall-public-fixture",
        standardPackRevision: "pack-v1",
        ontologyID: "imageall-public-fixture",
        ontologyRevision: "ontology-v1",
        localeRevision: "zh-Hans-v1",
        manifestSHA256: "dc7b0a9a8391978a56b7e55f97c1abc73fe9e9834f1c2dd16152fc13883bd873",
        provider: "rgb-linear",
        modelRevision: "model-v1",
        preprocessingRevision: "rgb-channel-mean-v1",
        mappingRevision: "mapping-v1",
        policyRevision: "policy-v1",
        weightsSHA256: "4129427105a9392e02b5306b657a029f7d0034f05a10d1363254e5f3d579fce9",
        concepts: [
            StandardOntologyConceptInput(conceptID: "scene.environment", canonicalName: "环境"),
            StandardOntologyConceptInput(conceptID: "scene.outdoor", canonicalName: "户外"),
            StandardOntologyConceptInput(conceptID: "scene.water", canonicalName: "水域"),
        ],
        edges: [
            StandardOntologyEdgeInput(
                parentConceptID: "scene.environment",
                childConceptID: "scene.outdoor"
            ),
            StandardOntologyEdgeInput(
                parentConceptID: "scene.outdoor",
                childConceptID: "scene.water"
            ),
        ]
    )
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
