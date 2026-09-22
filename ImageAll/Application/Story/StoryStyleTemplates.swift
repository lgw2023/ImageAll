import AVFoundation
import Foundation

/// Data-only presets. Personal variants retain the trusted implementation identity.
struct StoryStyleTemplate: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var version = "1.0.0"
    var name: String
    var implementation: String
    var titleFrames = 27
    var cardFrames = 22
    var fontSize = 46
    var bottomPercent = 6
    var closingFrame = true
    var isPoem: Bool { implementation == "in-photo-handwritten-poem" }
    static let builtins: [Self] = [
        .init(id: "brief-title-dissolve", name: "短文案淡出", implementation: "brief-title-dissolve"),
        .init(id: "in-photo-handwritten-poem", name: "照片内手写诗句", implementation: "in-photo-handwritten-poem")
    ]
    func validate() throws {
        guard Self.builtins.contains(where: { $0.implementation == implementation }), version == "1.0.0",
              (1...90).contains(titleFrames), (10...60).contains(cardFrames),
              (24...64).contains(fontSize), (3...20).contains(bottomPercent),
              !name.isEmpty, name.count <= 80 else { throw StoryCreativeError.invalid("模板参数或版本不受支持。") }
    }
}

struct StoryStyleSelection: Codable, Equatable, Sendable {
    var template: StoryStyleTemplate
    /// One line per selected photo. Empty lines intentionally leave the photo without text.
    var lines: [String]
    var shotIDs: [UUID]? = nil
}
struct StoryStyleReceipt: Codable, Equatable, Sendable {
    var requestID: String
    var requestSHA256: String
    var implementationSHA256: String
}

struct StoryStyleCatalog {
    let directory: URL
    func load() throws -> [StoryStyleTemplate] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return StoryStyleTemplate.builtins }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let custom = try files.filter { $0.pathExtension == "json" }.map { url in
            let safe = try StoryCreativePlugin.safe(url.lastPathComponent, root: directory)
            let value = try JSONDecoder().decode(StoryStyleTemplate.self, from: Data(contentsOf: safe))
            try value.validate()
            return value
        }
        return StoryStyleTemplate.builtins + custom.sorted { $0.name < $1.name }
    }
    func saveVariant(_ template: StoryStyleTemplate, name: String) throws -> StoryStyleTemplate {
        var value = template
        value.id = UUID().uuidString.lowercased()
        value.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try value.validate()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = try StoryCreativePlugin.safe(value.id + ".json", root: directory)
        let staging = try StoryCreativePlugin.safe("." + value.id + ".pending", root: directory)
        defer { try? FileManager.default.removeItem(at: staging) }
        try StoryCreativePlugin.encode(value).write(to: staging, options: .atomic)
        try FileManager.default.moveItem(at: staging, to: url)
        return value
    }
}

struct StoryStyleExchange: Sendable {
    let rootProvider: any OpenMontageTaskRootProviding
    let exporter: any TimeStoryPackageExporting
    struct Capability: Codable { let protocolVersion: String; let implementations: [String: String]; let ready: Bool; let detail: String; let updatedAtMs: Int64 }
    struct Request: Codable {
        let protocolVersion: String
        let requestID: String
        let implementationSHA256: String
        let style: StoryStyleSelection
        let title: String
        let packageSHA256: String
        let photoFrames: [Int]
        let photoIDs: [String]
    }
    struct Result: Codable {
        let requestID: String
        let requestSHA256: String
        let implementationSHA256: String
        let status: String
        let detail: String
        let frames: Int?
        let outputSHA256: String?
    }
    private func acquire() throws -> URL {
        let root = try rootProvider.resolveTaskRoot()
        guard rootProvider.startAccessing(root) else { throw OpenMontageTaskError.taskRootAuthorizationRequired }
        return root
    }
    private func read<T: Decodable>(_ type: T.Type, _ relative: String, root: URL) throws -> T {
        let data = try Data(contentsOf: StoryCreativePlugin.safe(relative, root: root))
        guard data.count <= 2_000_000 else { throw StoryCreativeError.invalid("模板记录过大。") }
        return try JSONDecoder().decode(type, from: data)
    }
    func capability() throws -> Capability {
        let root = try acquire(); defer { rootProvider.stopAccessing(root) }
        guard FileManager.default.fileExists(atPath: try StoryCreativePlugin.safe("templates/capabilities.json", root: root).path) else {
            throw StoryCreativeError.invalid("此任务目录尚无模板制作端，请启动或更新 OpenMontage 后检查连接。")
        }
        let value = try read(Capability.self, "templates/capabilities.json", root: root)
        guard value.protocolVersion == "1.0", value.ready,
              abs(Date().timeIntervalSince1970 * 1000 - Double(value.updatedAtMs)) < 30_000 else {
            throw StoryCreativeError.invalid("模板制作端尚未就绪，请启动或更新本地 OpenMontage。" + value.detail)
        }
        return value
    }
    func publish(_ project: TimeStoryProject) async throws -> StoryStyleReceipt {
        guard let style = project.styleTemplate, (1...100).contains(project.shots.count),
              style.lines.count == project.shots.count, style.lines.allSatisfy({ $0.count <= 80 }) else {
            throw StoryCreativeError.invalid("请先套用模板并校对文案；本地制作支持 1–100 个照片镜头，每条文案最多 80 字。")
        }
        try style.template.validate()
        let capability = try capability()
        guard let digest = capability.implementations[style.template.implementation], digest.count == 64 else {
            throw StoryCreativeError.invalid("本地制作端缺少此模板，请更新 OpenMontage。")
        }
        let root = try acquire(); defer { rootProvider.stopAccessing(root) }
        let id = "template-" + UUID().uuidString.lowercased()
        let requests = try StoryCreativePlugin.safe("templates/requests", root: root)
        try FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)
        let staging = try StoryCreativePlugin.safe("." + id, root: requests)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: staging) } }
        _ = try await exporter.export(project: project, aspect: .portrait, destinationURL: staging.appendingPathComponent("package"), onProgress: { _ in })
        let request = Request(protocolVersion: "1.0", requestID: id, implementationSHA256: digest, style: style, title: project.title,
            packageSHA256: try OpenMontageTaskFileValidation.sha256(staging.appendingPathComponent("package/story.json")),
            photoFrames: project.shots.map { max(1, Int(($0.durationSeconds * 30).rounded())) },
            photoIDs: project.shots.map { StoryRenderPackageExporter.packageAssetID(projectID: project.id, assetID: $0.assetID) })
        let data = try StoryCreativePlugin.encode(request)
        let hash = StoryCreativePlugin.hash(data)
        try data.write(to: staging.appendingPathComponent("request.json"), options: .atomic)
        try StoryCreativePlugin.encode(["requestSHA256": hash]).write(to: staging.appendingPathComponent("complete.json"), options: .atomic)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: staging, to: requests.appendingPathComponent(id))
        published = true
        return .init(requestID: id, requestSHA256: hash, implementationSHA256: digest)
    }
    func status(_ receipt: StoryStyleReceipt) throws -> Result? {
        let root = try acquire(); defer { rootProvider.stopAccessing(root) }
        let relative = "templates/requests/\(receipt.requestID)/result.json"
        guard FileManager.default.fileExists(atPath: try StoryCreativePlugin.safe(relative, root: root).path) else { return nil }
        let result = try read(Result.self, relative, root: root)
        guard result.requestID == receipt.requestID, result.requestSHA256 == receipt.requestSHA256,
              result.implementationSHA256 == receipt.implementationSHA256 else { throw StoryCreativeError.invalid("模板结果与本次提交不匹配。") }
        return result
    }
    func verifiedURL(_ receipt: StoryStyleReceipt) async throws -> URL {
        guard let result = try status(receipt), result.status == "succeeded", let frames = result.frames,
              let digest = result.outputSHA256 else { throw StoryCreativeError.invalid("模板成片尚未完成。") }
        let root = try acquire(); defer { rootProvider.stopAccessing(root) }
        let url = try StoryCreativePlugin.safe("templates/requests/\(receipt.requestID)/final.mp4", root: root)
        guard try OpenMontageTaskFileValidation.sha256(url) == digest else { throw StoryCreativeError.invalid("成片校验失败。") }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw StoryCreativeError.invalid("成片缺少视频轨道。") }
        let size = try await track.load(.naturalSize)
        let fps = try await track.load(.nominalFrameRate)
        let duration = try await asset.load(.duration)
        guard size.width == 1080, size.height == 1920, abs(fps - 30) < 0.01,
              abs(duration.seconds * 30 - Double(frames)) < 1 else { throw StoryCreativeError.invalid("成片规格不匹配。") }
        return url
    }
}
