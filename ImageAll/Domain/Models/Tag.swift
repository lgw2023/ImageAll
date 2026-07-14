import Foundation

struct TagNameParts: Equatable, Sendable {
    let displayName: String
    let normalizedName: String
    let normalizedNameKey: Data
}

struct Tag: Equatable, Sendable {
    let id: UUID
    let displayName: String
    let normalizedName: String
    let normalizedNameKey: Data
    var state: TagState
}
