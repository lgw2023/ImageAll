@preconcurrency import AVFoundation
import Combine
import Foundation
import UniformTypeIdentifiers

/// AVFoundation sees only a private scheme. All network reads go through the
/// paired client's transport (including its pinning and redirect policy).
@MainActor
public final class RemoteVideoPlayback: ObservableObject {
    public enum State: Equatable {
        case idle, loading, ready
        case failed(String)
    }

    public let player = AVPlayer()
    public private(set) var assetID: UUID?
    public private(set) var contentRevision: Int?
    @Published public private(set) var state: State = .idle
    private var generation: UUID?
    private var loader: RemoteVideoResourceLoader?
    private var asset: AVURLAsset?
    private var observation: NSKeyValueObservation?

    public init() {}

    public func load(assetID: UUID, contentRevision: Int, client: RemoteLibraryClient) async {
        stop()
        let token = UUID()
        generation = token
        self.assetID = assetID
        self.contentRevision = contentRevision
        state = .loading
        let loader = RemoteVideoResourceLoader(client: client, assetID: assetID, revision: contentRevision) {
            [weak self] error in
            self?.fail(token: token, error: error)
        }
        self.loader = loader
        let url = URL(string: "imageall-video://asset/\(assetID.uuidString.lowercased())/video")!
        let asset = AVURLAsset(url: url)
        self.asset = asset
        asset.resourceLoader.setDelegate(loader, queue: .main)
        do {
            let playable = try await asset.load(.isPlayable)
            try Task.checkCancellation()
            guard generation == token else { return }
            guard playable else { throw RemoteVideoError.unavailable }
            let item = AVPlayerItem(asset: asset)
            item.preferredForwardBufferDuration = 10
            player.replaceCurrentItem(with: item)
            observation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                guard item.status == .failed else { return }
                Task { @MainActor [weak self] in self?.fail(token: token, error: RemoteVideoError.unavailable) }
            }
            state = .ready
        } catch {
            guard generation == token else { return }
            if Task.isCancelled || error is CancellationError { stop() }
            else { fail(token: token, error: error) }
        }
    }

    public func stop() {
        generation = nil
        assetID = nil
        contentRevision = nil
        observation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        loader?.stop()
        loader = nil
        asset?.cancelLoading()
        asset = nil
        state = .idle
    }

    private func fail(token: UUID, error: Error) {
        guard generation == token else { return }
        stop()
        state = .failed((error as? RemoteVideoError)?.errorDescription ?? "视频暂时无法播放，请检查 Mac 连接后重试。")
    }
}

/// The main queue is both the AVFoundation delegate queue and the actor executor.
/// One network read is active at a time; each response is at most 256 KiB. There
/// is no original-file download, persistent cache or credential-bearing media URL.
@MainActor
private final class RemoteVideoResourceLoader: NSObject, @preconcurrency AVAssetResourceLoaderDelegate {
    private let client: RemoteLibraryClient
    private let assetID: UUID
    private let revision: Int
    private let failure: @MainActor (Error) -> Void
    private var requests: [ObjectIdentifier: AVAssetResourceLoadingRequest] = [:]
    private var order: [ObjectIdentifier] = []
    private var activeID: ObjectIdentifier?
    private var task: Task<Void, Never>?
    private var stopped = false
    private var totalBytes: Int64?
    private var contentType: String?

    init(client: RemoteLibraryClient, assetID: UUID, revision: Int, failure: @escaping @MainActor (Error) -> Void) {
        self.client = client
        self.assetID = assetID
        self.revision = revision
        self.failure = failure
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        guard !stopped, request.request.url?.scheme == "imageall-video" else { return false }
        let id = ObjectIdentifier(request)
        requests[id] = request
        order.append(id)
        pump()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        let id = ObjectIdentifier(request)
        requests.removeValue(forKey: id)
        order.removeAll { $0 == id }
        if activeID == id {
            task?.cancel()
            task = nil
            activeID = nil
            pump()
        }
    }

    func stop() {
        stopped = true
        task?.cancel()
        task = nil
        activeID = nil
        let pending = Array(requests.values)
        requests.removeAll()
        order.removeAll()
        for request in pending where !request.isCancelled && !request.isFinished {
            request.finishLoading(with: URLError(.cancelled))
        }
    }

    private func pump() {
        guard !stopped, activeID == nil, !order.isEmpty else { return }
        let id = order.removeFirst()
        guard let request = requests[id] else { pump(); return }
        activeID = id
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await fulfill(request)
                try Task.checkCancellation()
                if requests[id] != nil, !request.isCancelled { request.finishLoading() }
            } catch {
                if !Task.isCancelled, requests[id] != nil, !request.isCancelled {
                    request.finishLoading(with: error)
                    failure(error)
                }
            }
            requests.removeValue(forKey: id)
            if activeID == id { activeID = nil; task = nil; pump() }
        }
    }

    private func read(offset: Int64, count: Int) async throws -> RemoteVideoChunk {
        let chunk = try await client.readVideoRange(assetID: assetID, contentRevision: revision, offset: offset, count: count)
        try Task.checkCancellation()
        if let totalBytes, totalBytes != chunk.totalBytes { throw RemoteVideoError.contentChanged }
        if let contentType, contentType != chunk.contentType { throw RemoteVideoError.contentChanged }
        totalBytes = chunk.totalBytes
        contentType = chunk.contentType
        return chunk
    }

    private func fulfill(_ request: AVAssetResourceLoadingRequest) async throws {
        if totalBytes == nil { _ = try await read(offset: 0, count: 2) }
        guard let totalBytes, let contentType,
              let type = UTType(mimeType: contentType)?.identifier else { throw RemoteVideoError.invalidResponse }
        if let info = request.contentInformationRequest {
            info.contentLength = totalBytes
            info.contentType = type
            info.isByteRangeAccessSupported = true
        }
        guard let dataRequest = request.dataRequest else { return }
        var offset = max(dataRequest.requestedOffset, dataRequest.currentOffset)
        guard offset >= 0, dataRequest.requestedLength >= 0,
              dataRequest.requestedOffset <= Int64.max - Int64(dataRequest.requestedLength) else {
            throw RemoteVideoError.invalidRange
        }
        let end = dataRequest.requestsAllDataToEndOfResource ? totalBytes
            : min(totalBytes, dataRequest.requestedOffset + Int64(dataRequest.requestedLength))
        while offset < end {
            try Task.checkCancellation()
            guard !stopped, !request.isCancelled else { throw CancellationError() }
            let chunk = try await read(offset: offset, count: Int(min(Int64(RemoteVideoChunk.maximumBytes), end - offset)))
            guard !stopped, !request.isCancelled else { throw CancellationError() }
            dataRequest.respond(with: chunk.data)
            offset += Int64(chunk.data.count)
        }
    }
}
