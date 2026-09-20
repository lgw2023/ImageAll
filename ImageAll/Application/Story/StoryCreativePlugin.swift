import CryptoKit
import Foundation

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
        guard value.protocolVersion == "1.0", value.profile == "editable-story-v1",
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
        _ = try capability(root)
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
            requestID: requestID, projectID: story.projectID, baseFingerprint: base, intent: intent,
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
        guard plan.protocolVersion == "1.0", plan.profile == "editable-story-v1",
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
                  proposed.factRefs.allSatisfy({ $0 == proposed.assetID + ".captureTimeMs" || ($0 == proposed.assetID + ".placeName" && fact.placeName != nil) }),
                  let time = fact.captureTimeMs, time >= previousTime else {
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
            previousTime = time
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
