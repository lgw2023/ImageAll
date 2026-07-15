import Foundation

enum FolderMovePathProbe: Equatable, Sendable {
    case noCandidate
    case oldPathMissing
    case oldPathDifferentResourceID
    case oldPathSameResourceID
    case oldPathProbeError
    case multipleCandidates
}
