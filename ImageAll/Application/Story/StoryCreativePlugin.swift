import CryptoKit
import Foundation
import AVFoundation

/// Optional project state; no migration or catalog fact writes.
struct StoryCreativeReceipt: Codable, Sendable, Equatable {
    var requestID: String
    var requestSHA256: String
    var baseFingerprint: String
    var aspect: TimeStoryPackageAspect
    var appliedPlanSHA256: String?
    var observations: [String] = []
    var uncertainties: [String] = []
}

// MARK: - Full Atelier project exchange (protocol 2.0)

struct StoryAtelierReceipt: Codable, Sendable, Equatable, Identifiable {
    var requestID: String
    var requestSHA256: String
    var baseFingerprint: String
    var scopeDigestSHA256: String
    var requestRevision: Int
    var projectRevision: String? = nil
    var proposalSHA256: String? = nil
    var resultSHA256: String? = nil
    var id: String { requestID }
}

struct StoryAtelierRequest: Codable, Sendable {
    var protocolVersion = "2.0"
    var profile = "atelier-project-v1"
    var requestID: String
    var projectID: String
    var requestRevision: Int
    var baseFingerprint: String
    var scopeDigestSHA256: String
    var intent: String
    var feedback: String?
    var parentProjectRevision: String?
    var subject: String
    var aspect = "portrait"
    var targetFrames: Int
    var externalSendAllowed = false
    var assets: [Asset]
    var selectedAssetIDs: [String]
    var lockedAssetIDs: [String]
    var lockedShots: [LockedShot]
    var excludedAssetIDs: [String]

    enum CodingKeys: String, CodingKey {
        case protocolVersion, profile, requestID, projectID, requestRevision, baseFingerprint
        case scopeDigestSHA256, intent, feedback, parentProjectRevision, subject, aspect
        case targetFrames, externalSendAllowed, assets, selectedAssetIDs, lockedAssetIDs
        case lockedShots, excludedAssetIDs
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(profile, forKey: .profile)
        try container.encode(requestID, forKey: .requestID)
        try container.encode(projectID, forKey: .projectID)
        try container.encode(requestRevision, forKey: .requestRevision)
        try container.encode(baseFingerprint, forKey: .baseFingerprint)
        try container.encode(scopeDigestSHA256, forKey: .scopeDigestSHA256)
        try container.encode(intent, forKey: .intent)
        try container.encode(feedback, forKey: .feedback)
        try container.encode(parentProjectRevision, forKey: .parentProjectRevision)
        try container.encode(subject, forKey: .subject)
        try container.encode(aspect, forKey: .aspect)
        try container.encode(targetFrames, forKey: .targetFrames)
        try container.encode(externalSendAllowed, forKey: .externalSendAllowed)
        try container.encode(assets, forKey: .assets)
        try container.encode(selectedAssetIDs, forKey: .selectedAssetIDs)
        try container.encode(lockedAssetIDs, forKey: .lockedAssetIDs)
        try container.encode(lockedShots, forKey: .lockedShots)
        try container.encode(excludedAssetIDs, forKey: .excludedAssetIDs)
    }

    struct Asset: Codable, Sendable {
        var assetID: String
        var relativePath: String
        var contentVersion: String
        var sha256: String
        var captureTimeMs: Int64?
        var captureTimeSource: String?
        var placeName: String?

        enum CodingKeys: String, CodingKey {
            case assetID, relativePath, contentVersion, sha256, captureTimeMs
            case captureTimeSource, placeName
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(assetID, forKey: .assetID)
            try container.encode(relativePath, forKey: .relativePath)
            try container.encode(contentVersion, forKey: .contentVersion)
            try container.encode(sha256, forKey: .sha256)
            try container.encode(captureTimeMs, forKey: .captureTimeMs)
            try container.encode(captureTimeSource, forKey: .captureTimeSource)
            try container.encode(placeName, forKey: .placeName)
        }
    }
    struct LockedShot: Codable, Sendable {
        var assetID: String
        var orderIndex: Int
        var caption: String
        var durationFrames: Int
    }
}

struct StoryAtelierProposal: Codable, Sendable {
    var protocolVersion: String
    var profile: String
    var requestID: String
    var requestSHA256: String
    var scopeDigestSHA256: String
    var projectRevision: String
    var manifestSHA256: String
    var entryPoint: String
    var propsPath: String
    var compositionID: String
    var renderRuntime: String
    var runtimeVersion: String
    var width: Int
    var height: Int
    var fps: Int
    var totalFrames: Int
    var title: String
    var summary: String
    var files: [File]

    struct File: Codable, Sendable {
        var path: String
        var sizeBytes: Int
        var sha256: String
    }
}

struct StoryAtelierResult: Codable, Sendable {
    var protocolVersion: String
    var requestID: String
    var requestSHA256: String
    var projectRevision: String
    var manifestSHA256: String
    var status: String
    var outputPath: String?
    var outputSHA256: String?
    var width: Int?
    var height: Int?
    var fps: Int?
    var frames: Int?
    var errorCode: String?
}

struct StoryAtelierExchange: Sendable {
    let rootProvider: any OpenMontageTaskRootProviding
    let media: any TimeStoryMediaLoading
    let validator: any TimeStoryMediaValidating

    private struct Capability: Decodable {
        let protocolVersion: String
        let profile: String
        let pluginID: String
        let pluginVersion: String
        let planningMode: String
        let automaticPlanning: Bool
        let renderRuntime: String
        let compositionMode: String
    }
    private struct Ready: Decodable {
        let requestSHA256: String
        let proposalSHA256: String
    }

    static func scopeDigest(_ assets: [StoryAtelierRequest.Asset]) -> String {
        let lines = assets.sorted { $0.assetID < $1.assetID }
            .map { "\($0.assetID)|\($0.contentVersion)|\($0.sha256)\n" }.joined()
        return StoryCreativePlugin.hash(Data(lines.utf8))
    }

    private func withRoot<T>(_ operation: (URL) throws -> T) throws -> T {
        let root = try rootProvider.resolveTaskRoot()
        guard rootProvider.startAccessing(root) else { throw OpenMontageTaskError.taskRootAuthorizationRequired }
        defer { rootProvider.stopAccessing(root) }
        return try operation(root)
    }
    private func directory(_ receipt: StoryAtelierReceipt, root: URL) throws -> URL {
        guard receipt.requestID.hasPrefix("atelier-"),
              UUID(uuidString: String(receipt.requestID.dropFirst(8))) != nil else {
            throw StoryCreativeError.invalid("INVALID_REQUEST_ID")
        }
        return try StoryCreativePlugin.safe("creative/atelier-requests/\(receipt.requestID)", root: root)
    }
    private static func decode<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        guard data.count <= 2_000_000 else { throw StoryCreativeError.invalid("OVERSIZE_DOCUMENT") }
        return try JSONDecoder().decode(type, from: data)
    }
    private static func requireExactKeys(_ data: Data, _ keys: Set<String>) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == keys else { throw StoryCreativeError.invalid("UNSUPPORTED_FIELDS") }
    }

    func publish(project: TimeStoryProject, feedback: String? = nil,
                 parentProjectRevision: String? = nil) async throws -> StoryAtelierReceipt {
        let intent = (project.creativeIntent ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let note = feedback?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !intent.isEmpty, intent.count <= 4000, (note?.count ?? 0) <= 4000 else {
            throw StoryCreativeError.invalid("请填写创作意图；修改意见不能超过 4000 字。")
        }
        let selected = Set(project.shots.map(\.assetID))
        let candidates = project.candidateSnapshot.candidates.filter { $0.availability == .available && selected.contains($0.assetID) }
            .sorted { ($0.mediaCreatedAtMs ?? .max, $0.assetID.uuidString) < ($1.mediaCreatedAtMs ?? .max, $1.assetID.uuidString) }
        guard !candidates.isEmpty, candidates.count <= 100,
              Set(project.shots.map(\.assetID)).isSubset(of: Set(candidates.map(\.assetID))) else {
            throw StoryCreativeError.invalid("Atelier 支持当前已选的 1–100 张可用照片。")
        }
        var check = project
        let chapterID = project.chapters.first?.id ?? UUID()
        check.shots = candidates.map { candidate in
            TimeStoryShot(id: candidate.assetID, assetID: candidate.assetID,
                          contentRevision: candidate.contentRevision, chapterID: chapterID,
                          caption: "", durationSeconds: 2, presentationMode: .fullFrameWithBackground,
                          reasons: [], isLocked: false, isUserEdited: false)
        }
        guard try validator.validate(check).isEmpty else { throw StoryCreativeError.invalid("候选素材已变化或不可用。") }
        let root = try rootProvider.resolveTaskRoot()
        guard rootProvider.startAccessing(root) else { throw OpenMontageTaskError.taskRootAuthorizationRequired }
        defer { rootProvider.stopAccessing(root) }
        let capabilityURL = try StoryCreativePlugin.safe("creative/atelier-capabilities.json", root: root)
        let capability = try Self.decode(Capability.self, capabilityURL)
        guard ["2.0", "2.1"].contains(capability.protocolVersion), capability.profile == "atelier-project-v1",
              capability.pluginID == "openmontage", !capability.pluginVersion.isEmpty,
              capability.planningMode == "agent-assisted", !capability.automaticPlanning,
              capability.renderRuntime == "remotion", capability.compositionMode == "atelier" else {
            throw StoryCreativeError.invalid("INCOMPATIBLE_PLUGIN")
        }
        guard capability.protocolVersion == "2.1" || candidates.count <= 26 else {
            throw StoryCreativeError.invalid("请更新 OpenMontage 制作端以支持超过 26 张照片。")
        }
        let requestID = "atelier-" + UUID().uuidString.lowercased()
        let requests = try StoryCreativePlugin.safe("creative/atelier-requests", root: root)
        try FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)
        let staging = try StoryCreativePlugin.safe("creative/atelier-requests/.\(requestID)", root: root)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: staging) } }
        let assetsDirectory = staging.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assetsDirectory, withIntermediateDirectories: false)
        var assets: [StoryAtelierRequest.Asset] = []
        for candidate in candidates {
            try Task.checkCancellation()
            let id = StoryRenderPackageExporter.packageAssetID(projectID: project.id, assetID: candidate.assetID)
            let relative = "assets/\(id).jpg"
            let file = staging.appendingPathComponent(relative)
            try StoryRenderPackageExporter.writeNormalizedJPEG(
                try await media.loadStoryImage(assetID: candidate.assetID), to: file)
            assets.append(.init(assetID: id, relativePath: relative,
                                contentVersion: "catalog-revision-\(candidate.contentRevision)",
                                sha256: try OpenMontageTaskFileValidation.sha256(file),
                                captureTimeMs: candidate.mediaCreatedAtMs,
                                captureTimeSource: candidate.captureTimeSource,
                                placeName: candidate.placeName))
        }
        guard try validator.validate(check).isEmpty else { throw StoryCreativeError.invalid("导出期间候选素材发生变化。") }
        let map = Dictionary(uniqueKeysWithValues: candidates.map {
            ($0.assetID, StoryRenderPackageExporter.packageAssetID(projectID: project.id, assetID: $0.assetID))
        })
        let parent = parentProjectRevision ?? project.atelierVersions?.last?.projectRevision
        let revision = (project.atelierVersions?.last?.requestRevision ?? 0) + 1
        let request = StoryAtelierRequest(protocolVersion: capability.protocolVersion, requestID: requestID,
            projectID: StoryRenderPackageExporter.packageProjectID(for: project.id),
            requestRevision: revision, baseFingerprint: try StoryCreativePlugin.fingerprint(project),
            scopeDigestSHA256: Self.scopeDigest(assets), intent: intent, feedback: note,
            parentProjectRevision: parent, subject: project.subjectTagDisplayName,
            targetFrames: project.creativeTargetFrames ?? 1350, assets: assets,
            selectedAssetIDs: project.shots.compactMap { map[$0.assetID] },
            lockedAssetIDs: project.shots.filter { $0.isLocked || $0.isUserEdited }.compactMap { map[$0.assetID] },
            lockedShots: project.shots.enumerated().compactMap { index, shot in
                guard (shot.isLocked || shot.isUserEdited), let id = map[shot.assetID] else { return nil }
                return .init(assetID: id, orderIndex: index, caption: shot.caption,
                             durationFrames: Int((shot.durationSeconds * 30).rounded()))
            },
            excludedAssetIDs: project.excludedAssetIDs.compactMap { map[$0] }.sorted())
        let data = try StoryCreativePlugin.encode(request)
        let digest = StoryCreativePlugin.hash(data)
        try data.write(to: staging.appendingPathComponent("request.json"), options: .atomic)
        try StoryCreativePlugin.encode(["requestSHA256": digest]).write(to: staging.appendingPathComponent("complete.json"), options: .atomic)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: staging, to: requests.appendingPathComponent(requestID))
        published = true
        return StoryAtelierReceipt(requestID: requestID, requestSHA256: digest,
            baseFingerprint: request.baseFingerprint, scopeDigestSHA256: request.scopeDigestSHA256,
            requestRevision: revision)
    }

    func status(_ receipt: StoryAtelierReceipt) throws -> String {
        try withRoot { root in
            let dir = try directory(receipt, root: root)
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("cancel.json").path) { return "已取消；可发布新版本。" }
            let resultURL = dir.appendingPathComponent("result.json")
            if FileManager.default.fileExists(atPath: resultURL.path) {
                let result = try Self.decode(StoryAtelierResult.self, resultURL)
                switch result.status {
                case "succeeded": return "已返回成片；读取并核验。"
                case "cancelled": return "制作已取消；可发布新版本。"
                case "failed": return "制作失败：\(result.errorCode ?? "未知错误")；可发布新版本。"
                default: throw StoryCreativeError.invalid("INVALID_RESULT_STATUS")
                }
            }
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("render-request.json").path) { return "制作任务已提交；等待 OpenMontage 渲染。" }
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("ready.json").path) { return "完整创作项目已返回；可审阅并提交制作。" }
            return "等待创作 Agent · 非无人值守规划"
        }
    }

    func loadProposal(_ receipt: StoryAtelierReceipt, project: TimeStoryProject,
                      requireCurrentProject: Bool = false) throws -> StoryAtelierProposal {
        try withRoot { root in
            let dir = try directory(receipt, root: root)
            if requireCurrentProject {
                guard try StoryCreativePlugin.fingerprint(project) == receipt.baseFingerprint else {
                    throw StoryCreativeError.invalid("STALE_PROJECT：意图、素材或用户编辑已变化。")
                }
            }
            guard !FileManager.default.fileExists(atPath: dir.appendingPathComponent("cancel.json").path) else {
                throw StoryCreativeError.invalid("CANCELLED")
            }
            let requestURL = try StoryCreativePlugin.safe("request.json", root: dir)
            let requestData = try Data(contentsOf: requestURL)
            guard StoryCreativePlugin.hash(requestData) == receipt.requestSHA256 else { throw StoryCreativeError.invalid("REQUEST_CHANGED") }
            let request = try Self.decode(StoryAtelierRequest.self, requestURL)
            guard ["2.0", "2.1"].contains(request.protocolVersion), request.profile == "atelier-project-v1",
                  request.requestID == receipt.requestID, request.scopeDigestSHA256 == receipt.scopeDigestSHA256,
                  Self.scopeDigest(request.assets) == request.scopeDigestSHA256,
                  request.baseFingerprint == receipt.baseFingerprint,
                  request.requestRevision == receipt.requestRevision else { throw StoryCreativeError.invalid("REQUEST_MISMATCH") }
            if requireCurrentProject {
                let selected = Set(project.shots.map(\.assetID))
                let current = project.candidateSnapshot.candidates.filter { $0.availability == .available && selected.contains($0.assetID) }
                let currentVersions = Dictionary(uniqueKeysWithValues: current.map { ($0.assetID, "catalog-revision-\($0.contentRevision)") })
                guard request.assets.count == current.count,
                      request.assets.allSatisfy({ asset in
                          current.contains { candidate in
                              StoryRenderPackageExporter.packageAssetID(projectID: project.id, assetID: candidate.assetID) == asset.assetID
                                  && currentVersions[candidate.assetID] == asset.contentVersion
                          }
                      }) else { throw StoryCreativeError.invalid("STALE_SCOPE") }
            }
            for asset in request.assets {
                let file = try StoryCreativePlugin.safe(asset.relativePath, root: dir)
                guard try OpenMontageTaskFileValidation.sha256(file) == asset.sha256 else { throw StoryCreativeError.invalid("SOURCE_CHANGED") }
            }
            let proposalURL = try StoryCreativePlugin.safe("proposal.json", root: dir)
            let bytes = try Data(contentsOf: proposalURL)
            let ready = try Self.decode(Ready.self, try StoryCreativePlugin.safe("ready.json", root: dir))
            guard ready.requestSHA256 == receipt.requestSHA256,
                  ready.proposalSHA256 == StoryCreativePlugin.hash(bytes) else { throw StoryCreativeError.invalid("PROPOSAL_HASH_MISMATCH") }
            try Self.requireExactKeys(bytes, ["protocolVersion", "profile", "requestID", "requestSHA256", "scopeDigestSHA256",
                                               "projectRevision", "manifestSHA256", "entryPoint", "propsPath", "compositionID",
                                               "renderRuntime", "runtimeVersion", "width", "height", "fps", "totalFrames",
                                               "title", "summary", "files"])
            let proposal = try JSONDecoder().decode(StoryAtelierProposal.self, from: bytes)
            guard proposal.protocolVersion == request.protocolVersion, proposal.profile == "atelier-project-v1",
                  proposal.requestID == receipt.requestID, proposal.requestSHA256 == receipt.requestSHA256,
                  proposal.scopeDigestSHA256 == receipt.scopeDigestSHA256,
                  proposal.renderRuntime == "remotion", proposal.width == 1080, proposal.height == 1920,
                  proposal.fps == 30, (300...5400).contains(proposal.totalFrames),
                  proposal.projectRevision == proposal.manifestSHA256,
                  proposal.files.count >= 3,
                  Set(proposal.files.map(\.path)).count == proposal.files.count else {
                throw StoryCreativeError.invalid("INVALID_PROPOSAL")
            }
            var manifest = try StoryCreativePlugin.encode(["files": proposal.files])
            manifest.append(0x0A) // Python exchange canonical JSON terminates with one LF.
            guard StoryCreativePlugin.hash(manifest) == proposal.manifestSHA256 else { throw StoryCreativeError.invalid("MANIFEST_HASH_MISMATCH") }
            let frozen = try StoryCreativePlugin.safe("revisions/\(proposal.projectRevision)", root: dir)
            for file in proposal.files {
                let url = try StoryCreativePlugin.safe(file.path, root: frozen)
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true, values.fileSize == file.sizeBytes,
                      try OpenMontageTaskFileValidation.sha256(url) == file.sha256 else {
                    throw StoryCreativeError.invalid("FROZEN_PROJECT_CHANGED")
                }
            }
            guard proposal.files.contains(where: { $0.path == proposal.entryPoint }),
                  proposal.files.contains(where: { $0.path == proposal.propsPath }) else {
                throw StoryCreativeError.invalid("MISSING_RENDER_ENTRY")
            }
            return proposal
        }
    }

    func requestRender(_ receipt: StoryAtelierReceipt, project: TimeStoryProject) throws -> StoryAtelierProposal {
        let proposal = try loadProposal(receipt, project: project, requireCurrentProject: true)
        try withRoot { root in
            let dir = try directory(receipt, root: root)
            let marker = try StoryCreativePlugin.safe("render-request.json", root: dir)
            let data = try StoryCreativePlugin.encode(["requestSHA256": receipt.requestSHA256,
                                                       "projectRevision": proposal.projectRevision])
            if FileManager.default.fileExists(atPath: marker.path) {
                guard try Data(contentsOf: marker) == data else { throw StoryCreativeError.invalid("RENDER_REQUEST_CONFLICT") }
            } else { try data.write(to: marker, options: .atomic) }
        }
        return proposal
    }

    func proposalHash(_ receipt: StoryAtelierReceipt) throws -> String {
        try withRoot { root in
            let dir = try directory(receipt, root: root)
            let file = try StoryCreativePlugin.safe("proposal.json", root: dir)
            return StoryCreativePlugin.hash(try Data(contentsOf: file))
        }
    }

    func verifiedResult(_ receipt: StoryAtelierReceipt, project: TimeStoryProject) async throws -> (StoryAtelierResult, URL) {
        let proposal = try loadProposal(receipt, project: project)
        let root = try rootProvider.resolveTaskRoot()
        guard rootProvider.startAccessing(root) else { throw OpenMontageTaskError.taskRootAuthorizationRequired }
        defer { rootProvider.stopAccessing(root) }
        let dir = try directory(receipt, root: root)
        let resultURL = try StoryCreativePlugin.safe("result.json", root: dir)
        let result = try Self.decode(StoryAtelierResult.self, resultURL)
        guard result.protocolVersion == proposal.protocolVersion, result.requestID == receipt.requestID,
              result.requestSHA256 == receipt.requestSHA256,
              result.projectRevision == proposal.projectRevision,
              result.manifestSHA256 == proposal.manifestSHA256,
              result.status == "succeeded", result.width == proposal.width,
              result.height == proposal.height, result.fps == proposal.fps,
              result.frames == proposal.totalFrames,
              result.outputPath == "renders/\(proposal.projectRevision).mp4",
              let outputPath = result.outputPath, let outputSHA = result.outputSHA256 else {
            throw StoryCreativeError.invalid("RESULT_NOT_VERIFIED_OR_FAILED")
        }
        let output = try StoryCreativePlugin.safe(outputPath, root: dir)
        guard try OpenMontageTaskFileValidation.sha256(output) == outputSHA else { throw StoryCreativeError.invalid("RESULT_HASH_MISMATCH") }
        let asset = AVURLAsset(url: output)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw StoryCreativeError.invalid("RESULT_NO_VIDEO") }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let dimensions = size.applying(transform)
        let fps = Double(try await track.load(.nominalFrameRate))
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(readerOutput) else { throw StoryCreativeError.invalid("RESULT_UNREADABLE") }
        reader.add(readerOutput)
        guard reader.startReading() else { throw StoryCreativeError.invalid("RESULT_UNREADABLE") }
        var frames = 0
        while let sample = readerOutput.copyNextSampleBuffer() {
            try Task.checkCancellation()
            frames += CMSampleBufferGetNumSamples(sample)
        }
        guard reader.status == .completed,
              Int(abs(dimensions.width).rounded()) == proposal.width,
              Int(abs(dimensions.height).rounded()) == proposal.height,
              abs(fps - Double(proposal.fps)) < 0.01,
              frames == proposal.totalFrames else { throw StoryCreativeError.invalid("RESULT_MEDIA_MISMATCH") }
        return (result, output)
    }

    func cancel(_ receipt: StoryAtelierReceipt) throws {
        try withRoot { root in
            let dir = try directory(receipt, root: root)
            guard !FileManager.default.fileExists(atPath: dir.appendingPathComponent("result.json").path) else {
                throw StoryCreativeError.invalid("RESULT_ALREADY_EXISTS")
            }
            let marker = try StoryCreativePlugin.safe("cancel.json", root: dir)
            try StoryCreativePlugin.encode(["requestSHA256": receipt.requestSHA256]).write(to: marker, options: .atomic)
        }
    }
}

struct StoryCreativeRequest: Codable, Sendable {
    var protocolVersion = "1.0"
    var profile = "editable-story-v1"
    var requestID: String
    var projectID: String
    var baseFingerprint: String
    var intent: String
    var subject: String
    var targetFrames: Int
    var aspect: TimeStoryPackageAspect
    var externalSendAllowed = false
    var storySHA256: String
    var facts: [Fact]
    var shots: [Shot]
    var chapters: [Chapter]
    var title: String
    struct Fact: Codable, Sendable {
        var assetID: String
        var contentVersion: String
        var sha256: String
        var captureTimeMs: Int64?
        var captureTimeSource: String?
        var placeName: String?
    }
    struct Shot: Codable, Sendable {
        var shotID: String
        var assetID: String
        var chapterID: String
        var caption: String
        var durationFrames: Int
        var locked: Bool
        var userEdited: Bool
    }
    struct Chapter: Codable, Sendable {
        var chapterID: String
        var title: String
    }
}

struct StoryCreativePlan: Codable, Sendable {
    var protocolVersion: String
    var profile: String
    var requestID: String
    var requestSHA256: String
    var pluginVersion: String
    var planningMode: String
    var title: String
    var chapters: [StoryCreativeRequest.Chapter]
    var shots: [Shot]
    var observations: [String]
    var uncertainties: [String]
    struct Shot: Codable, Sendable {
        var shotID: String
        var assetID: String
        var chapterID: String
        var caption: String
        var durationFrames: Int
        var factRefs: [String]
        var rationale: String
    }
}

enum StoryCreativeError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): "创作插件：\(message)" }
    }
}

struct StoryCreativePlugin: Sendable {
    let rootProvider: any OpenMontageTaskRootProviding
    let exporter: any TimeStoryPackageExporting
    let validator: any TimeStoryMediaValidating

    private struct Capability: Decodable {
        let protocolVersion: String
        let profile: String
        let pluginID: String
        let pluginVersion: String
        let planningMode: String
        let automaticPlanning: Bool
        let externalSendAllowed: Bool
        let renderProtocol: String
        let renderPackage: String
    }
    private struct Ready: Decodable {
        let requestSHA256: String
        let planSHA256: String
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func fingerprint(_ project: TimeStoryProject) throws -> String {
        var object = try JSONSerialization.jsonObject(with: encode(project)) as! [String: Any]
        object.removeValue(forKey: "creativeReceipt")
        object.removeValue(forKey: "atelierVersions")
        object.removeValue(forKey: "updatedAtMs")
        if let excluded = object["excludedAssetIDs"] as? [String] { object["excludedAssetIDs"] = excluded.sorted() }
        return hash(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
    }
    /// Check every existing component, including in-root symlinks, before accessing exchange files.
    static func safe(_ relative: String, root: URL) throws -> URL {
        guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else {
            throw StoryCreativeError.invalid("UNSAFE_PATH")
        }
        let root = root.standardizedFileURL
        guard root.resolvingSymlinksInPath().path == root.path else { throw StoryCreativeError.invalid("UNSAFE_ROOT") }
        var result = root
        for part in relative.split(separator: "/") {
            result.appendPathComponent(String(part))
            if FileManager.default.fileExists(atPath: result.path) {
                let values = try result.resourceValues(forKeys: [.isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw StoryCreativeError.invalid("UNSAFE_PATH") }
            }
        }
        guard result.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else {
            throw StoryCreativeError.invalid("UNSAFE_PATH")
        }
        return result
    }
    private func acquireRoot() throws -> URL {
        let root = try rootProvider.resolveTaskRoot()
        guard rootProvider.startAccessing(root) else { throw OpenMontageTaskError.taskRootAuthorizationRequired }
        return root
    }
    private func capability(_ root: URL) throws -> Capability {
        let url = try Self.safe("creative/capabilities.json", root: root)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw StoryCreativeError.invalid("尚未启用创作插件；现有本地制作仍可使用。")
        }
        let value = try JSONDecoder().decode(Capability.self, from: Data(contentsOf: url))
        guard ["1.0", "1.1"].contains(value.protocolVersion), value.profile == "editable-story-v1",
              value.pluginID == "openmontage", !value.pluginVersion.isEmpty,
              value.planningMode == "agent-assisted", !value.automaticPlanning,
              !value.externalSendAllowed, value.renderProtocol == "1.1", value.renderPackage == "0.1"
        else { throw StoryCreativeError.invalid("INCOMPATIBLE_PLUGIN：请使用兼容的插件版本。") }
        return value
    }

    func publish(project: TimeStoryProject, aspect: TimeStoryPackageAspect) async throws -> StoryCreativeReceipt {
        let intent = (project.creativeIntent ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !intent.isEmpty, intent.count <= 4000, !project.shots.isEmpty, project.shots.count <= 100 else {
            throw StoryCreativeError.invalid("请填写创作意图，并限定为 1–100 张当前故事照片。")
        }
        let issues = try validator.validate(project)
        guard issues.isEmpty else { throw TimeStoryError.mediaValidationFailed(issues) }
        let root = try acquireRoot()
        defer { rootProvider.stopAccessing(root) }
        let pluginCapability = try capability(root)
        let requestID = "creative-" + UUID().uuidString.lowercased()
        let requests = try Self.safe("creative/requests", root: root)
        try FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)
        let staging = try Self.safe("creative/requests/.\(requestID)", root: root)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        let package = staging.appendingPathComponent("package")
        _ = try await exporter.export(project: project, aspect: aspect, destinationURL: package, onProgress: { _ in })
        let storyData = try Data(contentsOf: package.appendingPathComponent("story.json"))
        let story = try JSONDecoder().decode(StoryRenderPackageDocument.self, from: storyData)
        let base = try Self.fingerprint(project)
        var facts: [StoryCreativeRequest.Fact] = []
        var seen: Set<UUID> = []
        for shot in project.shots where seen.insert(shot.assetID).inserted {
            let assetID = StoryRenderPackageExporter.packageAssetID(projectID: project.id, assetID: shot.assetID)
            guard let asset = story.assets.first(where: { $0.assetID == assetID }),
                  let candidate = project.candidateSnapshot.candidates.first(where: { $0.assetID == shot.assetID }) else {
                throw StoryCreativeError.invalid("候选与派生素材不一致。")
            }
            facts.append(.init(assetID: assetID, contentVersion: asset.sourceContentVersion,
                               sha256: asset.renderFileSHA256, captureTimeMs: candidate.mediaCreatedAtMs,
                               captureTimeSource: candidate.captureTimeSource, placeName: candidate.placeName))
        }
        let request = StoryCreativeRequest(
            protocolVersion: pluginCapability.protocolVersion, requestID: requestID, projectID: story.projectID, baseFingerprint: base, intent: intent,
            subject: project.subjectTagDisplayName, targetFrames: project.creativeTargetFrames ?? 1800,
            aspect: aspect, storySHA256: Self.hash(storyData), facts: facts,
            shots: project.shots.map { .init(shotID: $0.id.uuidString.lowercased(),
                assetID: StoryRenderPackageExporter.packageAssetID(projectID: project.id, assetID: $0.assetID),
                chapterID: $0.chapterID.uuidString.lowercased(), caption: $0.caption,
                durationFrames: Int(($0.durationSeconds * 30).rounded()), locked: $0.isLocked, userEdited: $0.isUserEdited) },
            chapters: project.chapters.map { .init(chapterID: $0.id.uuidString.lowercased(), title: $0.title) }, title: project.title)
        let data = try Self.encode(request)
        let digest = Self.hash(data)
        try data.write(to: staging.appendingPathComponent("request.json"), options: .atomic)
        try Self.encode(["requestSHA256": digest]).write(to: staging.appendingPathComponent("complete.json"), options: .atomic)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: staging, to: requests.appendingPathComponent(requestID))
        return .init(requestID: requestID, requestSHA256: digest, baseFingerprint: base, aspect: aspect)
    }

    func cancel(_ receipt: StoryCreativeReceipt) throws {
        let root = try acquireRoot()
        defer { rootProvider.stopAccessing(root) }
        let directory = try requestDirectory(receipt, root: root)
        try Self.encode(["requestSHA256": receipt.requestSHA256]).write(to: directory.appendingPathComponent("cancel.json"), options: .atomic)
    }
    private func requestDirectory(_ receipt: StoryCreativeReceipt, root: URL) throws -> URL {
        guard receipt.requestID.hasPrefix("creative-"), UUID(uuidString: String(receipt.requestID.dropFirst(9))) != nil else {
            throw StoryCreativeError.invalid("INVALID_REQUEST_ID")
        }
        return try Self.safe("creative/requests/\(receipt.requestID)", root: root)
    }
    func status(_ receipt: StoryCreativeReceipt) throws -> String {
        let root = try acquireRoot()
        defer { rootProvider.stopAccessing(root) }
        let directory = try requestDirectory(receipt, root: root)
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("cancel.json").path) { return "已取消创作；可发布新的请求。" }
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("ready.json").path) { return "方案已返回；读取并校验后可应用。" }
        return "等待创作 Agent · 当前插件不支持无人值守导演"
    }
    func loadPlan(_ receipt: StoryCreativeReceipt) throws -> (StoryCreativeRequest, StoryCreativePlan, String) {
        let root = try acquireRoot()
        defer { rootProvider.stopAccessing(root) }
        let directory = try requestDirectory(receipt, root: root)
        guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent("cancel.json").path) else {
            throw StoryCreativeError.invalid("CANCELLED：请创建新的请求。")
        }
        let requestData = try Data(contentsOf: Self.safe("request.json", root: directory))
        guard Self.hash(requestData) == receipt.requestSHA256 else { throw StoryCreativeError.invalid("REQUEST_CHANGED") }
        let ready = try JSONDecoder().decode(Ready.self, from: Data(contentsOf: Self.safe("ready.json", root: directory)))
        let planData = try Data(contentsOf: Self.safe("plan.json", root: directory))
        guard planData.count <= 2_000_000, ready.requestSHA256 == receipt.requestSHA256,
              Self.hash(planData) == ready.planSHA256 else { throw StoryCreativeError.invalid("PLAN_HASH_MISMATCH") }
        let request = try JSONDecoder().decode(StoryCreativeRequest.self, from: requestData)
        let plan = try JSONDecoder().decode(StoryCreativePlan.self, from: planData)
        // Codable ignores unknown keys; fail closed against executable or unsupported creative fields.
        try Self.checkPlanKeys(planData)
        guard plan.requestSHA256 == receipt.requestSHA256, request.requestID == receipt.requestID,
              plan.requestID == receipt.requestID, request.baseFingerprint == receipt.baseFingerprint else {
            throw StoryCreativeError.invalid("REQUEST_ID_MISMATCH")
        }
        let storyData = try Data(contentsOf: Self.safe("package/story.json", root: directory))
        guard Self.hash(storyData) == request.storySHA256 else { throw StoryCreativeError.invalid("SOURCE_CHANGED") }
        let story = try JSONDecoder().decode(StoryRenderPackageDocument.self, from: storyData)
        for asset in story.assets {
            let url = try Self.safe("package/" + asset.relativePath, root: directory)
            guard try OpenMontageTaskFileValidation.sha256(url) == asset.renderFileSHA256 else {
                throw StoryCreativeError.invalid("SOURCE_CHANGED")
            }
        }
        return (request, plan, ready.planSHA256)
    }
    private static func checkPlanKeys(_ data: Data) throws {
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        func keys(_ obj: [String: Any], _ permitted: Set<String>) throws {
            guard Set(obj.keys) == permitted else { throw StoryCreativeError.invalid("UNSUPPORTED_PLAN_FIELDS") }
        }
        try keys(obj, ["protocolVersion", "profile", "requestID", "requestSHA256", "pluginVersion", "planningMode", "title", "chapters", "shots", "observations", "uncertainties"])
        for shot in obj["shots"] as? [[String: Any]] ?? [] { try keys(shot, ["shotID", "assetID", "chapterID", "caption", "durationFrames", "factRefs", "rationale"]) }
        for chapter in obj["chapters"] as? [[String: Any]] ?? [] { try keys(chapter, ["chapterID", "title"]) }
    }
    func apply(_ plan: StoryCreativePlan, request: StoryCreativeRequest, digest: String,
               to project: TimeStoryProject) throws -> TimeStoryProject {
        guard try Self.fingerprint(project) == request.baseFingerprint else { throw StoryCreativeError.invalid("STALE_PROJECT：项目已修改，请重新发布。") }
        let issues = try validator.validate(project)
        guard issues.isEmpty else { throw TimeStoryError.mediaValidationFailed(issues) }
        guard ["1.0", "1.1"].contains(request.protocolVersion), plan.protocolVersion == request.protocolVersion, plan.profile == "editable-story-v1",
              plan.planningMode == "agent-assisted", !plan.pluginVersion.isEmpty,
              plan.requestID == request.requestID, plan.requestSHA256 == project.creativeReceipt?.requestSHA256,
              !plan.shots.isEmpty, plan.shots.count <= 100, plan.title.count <= 240,
              !plan.chapters.isEmpty, plan.chapters.count <= 100,
              Set(plan.shots.map(\.shotID)).count == plan.shots.count,
              Set(plan.chapters.map(\.chapterID)).count == plan.chapters.count,
              plan.observations.count <= 100, plan.uncertainties.count <= 100,
              (plan.observations + plan.uncertainties).allSatisfy({ $0.count <= 2000 }) else {
            throw StoryCreativeError.invalid("INCOMPATIBLE_OR_INVALID_PLAN")
        }
        var updated = project
        var shots: [TimeStoryShot] = []
        if request.protocolVersion == "1.1", plan.shots.map(\.shotID) != request.shots.map(\.shotID) {
            throw StoryCreativeError.invalid("USER_ORDER_CONFLICT：请保留当前镜头顺序与全部已选照片。")
        }
        var previousTime: Int64 = .min
        var seenChapters: Set<String> = []
        var lastChapter = ""
        for proposed in plan.shots {
            guard let original = project.shots.first(where: { $0.id.uuidString.lowercased() == proposed.shotID }),
                  let source = request.shots.first(where: { $0.shotID == proposed.shotID }),
                  proposed.assetID == source.assetID,
                  let fact = request.facts.first(where: { $0.assetID == proposed.assetID }),
                  let chapterID = UUID(uuidString: proposed.chapterID),
                  plan.chapters.contains(where: { $0.chapterID == proposed.chapterID }),
                  proposed.caption.count <= 600, proposed.rationale.count <= 2000,
                  (45...360).contains(proposed.durationFrames),
                  proposed.factRefs.allSatisfy({ ($0 == proposed.assetID + ".captureTimeMs" && fact.captureTimeMs != nil) || ($0 == proposed.assetID + ".placeName" && fact.placeName != nil) }) else {
                throw StoryCreativeError.invalid("INVALID_REFERENCE_OR_TIMELINE")
            }
            if source.locked || source.userEdited {
                guard proposed.caption == source.caption, proposed.durationFrames == source.durationFrames,
                      proposed.chapterID == source.chapterID else { throw StoryCreativeError.invalid("USER_CONSTRAINT_CONFLICT") }
            }
            if lastChapter != proposed.chapterID {
                guard seenChapters.insert(proposed.chapterID).inserted else { throw StoryCreativeError.invalid("CHAPTER_ORDER_CONFLICT") }
                lastChapter = proposed.chapterID
            }
            if request.protocolVersion == "1.0" {
                guard let time = fact.captureTimeMs, time >= previousTime else {
                    throw StoryCreativeError.invalid("INVALID_REFERENCE_OR_TIMELINE")
                }
                previousTime = time
            }
            var shot = original
            shot.chapterID = chapterID
            shot.caption = proposed.caption
            shot.durationSeconds = Double(proposed.durationFrames) / 30
            shot.reasons = ["创作建议：" + proposed.rationale]
            shots.append(shot)
        }
        guard request.shots.filter({ $0.locked || $0.userEdited }).allSatisfy({ original in plan.shots.contains { $0.shotID == original.shotID } }) else {
            throw StoryCreativeError.invalid("USER_CONSTRAINT_CONFLICT")
        }
        var chapters: [TimeStoryChapter] = []
        for chapter in plan.chapters {
            guard let id = UUID(uuidString: chapter.chapterID), chapter.title.count <= 240 else { throw StoryCreativeError.invalid("INVALID_CHAPTER") }
            let members = shots.filter { $0.chapterID == id }.map(\.id)
            guard !members.isEmpty else { throw StoryCreativeError.invalid("EMPTY_CHAPTER") }
            if let old = project.chapters.first(where: { $0.id == id }), old.isUserEdited, old.title != chapter.title {
                throw StoryCreativeError.invalid("USER_CONSTRAINT_CONFLICT")
            }
            chapters.append(.init(id: id, title: chapter.title, shotIDs: members, isUserEdited: project.chapters.first(where: { $0.id == id })?.isUserEdited ?? false))
        }
        guard chapters.flatMap(\.shotIDs) == shots.map(\.id) else { throw StoryCreativeError.invalid("CHAPTER_ORDER_CONFLICT") }
        updated.title = plan.title
        updated.shots = shots
        updated.chapters = chapters
        updated.creativeReceipt?.appliedPlanSHA256 = digest
        updated.creativeReceipt?.observations = plan.observations
        updated.creativeReceipt?.uncertainties = plan.uncertainties
        _ = try TimeStoryTimeline.normalize(project: updated)
        return updated
    }
}
