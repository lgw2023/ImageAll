import Foundation

enum JobQueueError: Error, Equatable, Sendable, LocalizedError {
    case referenceNotFound
    case activeCoalescingConflict(existingJobID: UUID)
    case invalidTransition(currentState: JobState, operation: String)
    case invalidClaimInput(reason: String)
    case jobNotFound(UUID)
    case jobNotRunning(UUID)
    case jobNotClaimed(UUID)
    case staleLease(UUID)
    case expiredLease(UUID)
    case unknownPersistedRawValue(field: String, value: String)
    case unknownJobKind(String)
    case unsupportedPayloadVersion(kind: String, version: Int)
    case unsupportedCheckpointVersion(kind: String, version: Int)
    case invalidProgress(reason: String)
    case invalidSafeErrorCode(rawValue: String)

    var errorDescription: String? {
        switch self {
        case .referenceNotFound:
            return "任务引用的来源不存在"
        case .activeCoalescingConflict:
            return "已有分析正在进行，请先暂停后再重新发起"
        case let .invalidTransition(currentState, operation):
            return "任务状态不允许\(operation)（当前：\(currentState.rawValue)）"
        case let .invalidClaimInput(reason):
            return "任务参数无效：\(reason)"
        case .jobNotFound:
            return "找不到指定的分析任务"
        case .jobNotRunning:
            return "任务未在运行"
        case .jobNotClaimed:
            return "任务未被领取"
        case .staleLease:
            return "任务租约已失效"
        case .expiredLease:
            return "任务租约已过期"
        case let .unknownPersistedRawValue(field, value):
            return "无法识别的持久化字段 \(field)=\(value)"
        case let .unknownJobKind(kind):
            return "未知任务类型：\(kind)"
        case let .unsupportedPayloadVersion(kind, version):
            return "不支持的任务载荷版本 \(kind)#\(version)"
        case let .unsupportedCheckpointVersion(kind, version):
            return "不支持的任务检查点版本 \(kind)#\(version)"
        case let .invalidProgress(reason):
            return "进度无效：\(reason)"
        case let .invalidSafeErrorCode(rawValue):
            return "无效的错误码：\(rawValue)"
        }
    }
}
