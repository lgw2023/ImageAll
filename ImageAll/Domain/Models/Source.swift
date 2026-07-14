import Foundation

struct Source: Equatable, Sendable {
    let id: UUID
    let kind: SourceKind
    var state: SourceState
}
