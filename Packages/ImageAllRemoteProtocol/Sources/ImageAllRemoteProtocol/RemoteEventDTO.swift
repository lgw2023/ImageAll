import Foundation

public enum RemoteEventKind: String, Codable, Sendable, Equatable {
    case ping
    case sourcesChanged
    case tagsChanged
    case assetsChanged
    case jobsChanged
    case reviewChanged
}

public struct RemoteEvent: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let kind: RemoteEventKind
    public let emittedAtMs: Int64
    public let sourceID: UUID?
    public let tagID: UUID?
    public let jobID: UUID?

    public init(
        id: UUID = UUID(),
        kind: RemoteEventKind,
        emittedAtMs: Int64,
        sourceID: UUID? = nil,
        tagID: UUID? = nil,
        jobID: UUID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.emittedAtMs = emittedAtMs
        self.sourceID = sourceID
        self.tagID = tagID
        self.jobID = jobID
    }
}
