import Foundation

public enum RemoteWorkspaceNoticeSeverity: String, Codable, Sendable, Equatable {
    case information
    case success
    case warning
}

public enum RemoteWorkspaceNoticeActionKind: String, Codable, Sendable, Equatable {
    case undoTagMutation
    case openRecycleBin
}

public struct RemoteWorkspaceNoticeAction: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: RemoteWorkspaceNoticeActionKind
    public let title: String
    public let sourceID: UUID?

    public init(
        id: String,
        kind: RemoteWorkspaceNoticeActionKind,
        title: String,
        sourceID: UUID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.sourceID = sourceID
    }
}

public struct RemoteWorkspaceNotice: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let severity: RemoteWorkspaceNoticeSeverity
    public let message: String
    public let actions: [RemoteWorkspaceNoticeAction]

    public init(
        id: String,
        severity: RemoteWorkspaceNoticeSeverity,
        message: String,
        actions: [RemoteWorkspaceNoticeAction] = []
    ) {
        self.id = id
        self.severity = severity
        self.message = message
        self.actions = actions
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case severity
        case message
        case actions
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        severity = try container.decode(RemoteWorkspaceNoticeSeverity.self, forKey: .severity)
        message = try container.decode(String.self, forKey: .message)
        actions = try container.decodeIfPresent(
            [RemoteWorkspaceNoticeAction].self,
            forKey: .actions
        ) ?? []
    }
}

public struct RemoteWorkspaceNoticeSnapshot: Codable, Sendable, Equatable {
    public let notice: RemoteWorkspaceNotice?

    public init(notice: RemoteWorkspaceNotice?) {
        self.notice = notice
    }
}

public struct RemoteWorkspaceNoticeDismissRequest: Codable, Sendable, Equatable {
    public let noticeID: String

    public init(noticeID: String) {
        self.noticeID = noticeID
    }
}

public struct RemoteWorkspaceNoticeDismissResponse: Codable, Sendable, Equatable {
    public let dismissed: Bool
    public let notice: RemoteWorkspaceNotice?

    public init(dismissed: Bool, notice: RemoteWorkspaceNotice?) {
        self.dismissed = dismissed
        self.notice = notice
    }
}

public struct RemoteWorkspaceNoticeActionRequest: Codable, Sendable, Equatable {
    public let noticeID: String
    public let actionID: String

    public init(noticeID: String, actionID: String) {
        self.noticeID = noticeID
        self.actionID = actionID
    }
}

public struct RemoteWorkspaceNoticeActionResponse: Codable, Sendable, Equatable {
    public let performed: Bool
    public let notice: RemoteWorkspaceNotice?

    public init(performed: Bool, notice: RemoteWorkspaceNotice?) {
        self.performed = performed
        self.notice = notice
    }
}
