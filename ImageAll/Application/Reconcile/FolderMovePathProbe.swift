import Foundation

struct FolderMoveCandidateBinding: Equatable, Sendable {
    let assetID: UUID
    let oldRelativePath: String
    let resourceID: Data
}

enum FolderMovePathProbe: Equatable, Sendable {
    case noCandidate
    case reconnectCandidate(FolderMoveCandidateBinding)
    case oldPathDifferentResourceID(FolderMoveCandidateBinding)
    case oldPathSameResourceID(FolderMoveCandidateBinding)
    case oldPathProbeError(binding: FolderMoveCandidateBinding?)
    case multipleCandidates
}
