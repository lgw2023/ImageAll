import Foundation

enum WorkspaceNoticeSeverity: String, Equatable, Sendable {
    case information
    case success
    case warning
}

enum WorkspaceNoticeActionKind: String, Equatable, Sendable {
    case undoTagMutation
    case openRecycleBin
}

struct WorkspaceNoticeActionProjection: Equatable, Sendable {
    let id: String
    let kind: WorkspaceNoticeActionKind
    let title: String
    let sourceID: UUID?
}

struct WorkspaceNoticeProjection: Equatable, Sendable {
    let id: String
    let severity: WorkspaceNoticeSeverity
    let message: String
    let actions: [WorkspaceNoticeActionProjection]
}

protocol RemoteWorkspaceNoticePort: Sendable {
    func currentWorkspaceNotice() async -> WorkspaceNoticeProjection?
    func dismissWorkspaceNotice(noticeID: String) async -> Bool
    func performWorkspaceNoticeAction(noticeID: String, actionID: String) async -> Bool
}

/// Records Host-side workflow outcomes that must surface through the same
/// authoritative notice channel as actions initiated from the Mac workspace.
/// Keeping this separate from `RemoteWorkspaceNoticePort` lets command services
/// publish a result without gaining access to notice dismissal or action handling.
protocol RemoteWorkspaceNoticeRecording: Sendable {
    func recordSourceDeletionBlocked(
        sourceID: UUID,
        displayName: String,
        blockers: LibrarySourceDeletionBlockers
    ) async
}
