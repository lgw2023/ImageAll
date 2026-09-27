import Foundation

public enum RemoteVideoError: Error, Equatable, Sendable, LocalizedError {
    case invalidRange, invalidResponse, responseTooLarge, contentChanged, authorizationRequired, unavailable, cloudOriginalRequired, unsupportedRepresentation

    public var errorDescription: String? {
        switch self {
        case .authorizationRequired: "视频访问授权已失效，请重新连接 Mac。"
        case .contentChanged: "视频已变化或 Mac 不支持修订校验，请刷新详情或升级 Mac 后重试。"
        case .cloudOriginalRequired: "视频原件仍在 iCloud。请在 Mac ImageAll 打开此视频并明确获取原件，完成后在此重试；远端播放不会自动下载。"
        case .unsupportedRepresentation: "Photos 返回了编辑合成资源。请在 Mac“照片”中播放，或导出视频文件并接入 ImageAll 后重试。"
        case .unavailable: "原始视频在 Mac 本机不可用；不会自动下载 iCloud 原件。"
        default: "无法读取视频，请检查连接和文件后重试。"
        }
    }
}

public struct RemoteVideoChunk: Sendable {
    public static let maximumBytes = 256 * 1_024
    public let data: Data
    public let offset: Int64
    public let totalBytes: Int64
    public let contentType: String

    init(data: Data, response: HTTPURLResponse, requestedOffset: Int64, requestedCount: Int) throws {
        let rawRange = response.value(forHTTPHeaderField: "Content-Range") ?? ""
        let parts = rawRange.split(separator: " ")
        guard parts.count == 2, parts[0] == "bytes" else { throw RemoteVideoError.invalidResponse }
        let rangeAndTotal = parts[1].split(separator: "/")
        guard rangeAndTotal.count == 2, let total = Int64(rangeAndTotal[1]), total > 0 else {
            throw RemoteVideoError.invalidResponse
        }
        let bounds = rangeAndTotal[0].split(separator: "-")
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]),
              start == requestedOffset, end >= start, end < total,
              end - start + 1 == Int64(data.count),
              Int64(data.count) == min(Int64(requestedCount), total - start),
              let type = response.mimeType, type.hasPrefix("video/") else {
            throw RemoteVideoError.invalidResponse
        }
        self.data = data
        offset = start
        totalBytes = total
        contentType = type
    }
}
