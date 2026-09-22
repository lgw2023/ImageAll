import Foundation
import Security

struct OpenMontageConfiguration: Codable, Equatable, Sendable {
    struct ModelConnection: Codable, Equatable, Sendable {
        var baseURL = "", model = ""
        var temperature = 0.2, timeoutSeconds = 180.0
        var maxTokens = 2200
        var responseFormat = "json_object"
        var tokenParameter = "max_tokens"
        var organization = "", project = "", extraBody = "{}"
        var completionURL: String {
            let root = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return root.hasSuffix("/chat/completions") ? root : root + "/chat/completions"
        }
        func validate() throws {
            guard let url = URLComponents(string: completionURL), let host = url.host, !host.isEmpty,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)),
                  !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  temperature.isFinite, (0...2).contains(temperature), (1...1_000_000).contains(maxTokens),
                  timeoutSeconds.isFinite, (1...600).contains(timeoutSeconds),
                  ["json_object", "text"].contains(responseFormat), ["max_tokens", "max_completion_tokens"].contains(tokenParameter),
                  !organization.contains("\n"), !project.contains("\n") else { throw configurationError("请填写有效的接口地址、模型名称和调用参数。远程地址使用 HTTPS，本机服务可用 HTTP。") }
            guard let body = try? JSONSerialization.jsonObject(with: Data(extraBody.utf8)) as? [String: Any],
                  Set(body.keys).isDisjoint(with: ["model", "messages", "stream", "temperature", "max_tokens", "max_completion_tokens", "response_format", "api_key", "apiKey", "headers", "authorization", "base_url"]) else { throw configurationError("附加请求参数必须是 JSON 对象，不能覆盖模型、消息、密钥或上方已有字段。") }
        }
    }
    struct LLM: Codable, Equatable, Sendable {
        var provider = "anthropic", model: String? = nil
        var temperature = 0.7
        var max_tokens = 4096
    }
    struct Budget: Codable, Equatable, Sendable {
        var mode = "warn", total_usd = 10.0, reserve_pct = 0.1, single_action_approval_usd = 0.5
        var require_approval_for_new_paid_tool = true
    }
    struct Checkpoint: Codable, Equatable, Sendable { var policy = "guided", storage_dir = "pipeline" }
    struct Output: Codable, Equatable, Sendable {
        var default_format = "mp4", default_codec = "libx264", default_audio_codec = "aac", default_resolution = "1920x1080"
        var default_fps = 30, default_crf = 23
    }
    struct Paths: Codable, Equatable, Sendable {
        var pipeline_dir = "pipeline", library_dir = "library", styles_dir = "styles", skills_dir = "skills", output_dir = "output"
    }
    var connection: ModelConnection? = nil
    var llm = LLM(), budget = Budget(), checkpoint = Checkpoint(), output = Output(), paths = Paths()
    static let enabledKey = "OpenMontage.IntegrationEnabled.v1"
    static let configurationKey = "OpenMontage.Configuration.v1"
    static let servicesKey = "OpenMontage.ServicesEnabled.v1"
    static func enabled(_ defaults: UserDefaults = .standard) -> Bool { defaults.object(forKey: enabledKey) == nil || defaults.bool(forKey: enabledKey) }
    static func load(_ defaults: UserDefaults = .standard) throws -> Self {
        guard let data = defaults.data(forKey: configurationKey) else { return Self() }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate(); return value
    }
    func validate() throws {
        try connection?.validate()
        guard !llm.provider.isEmpty, llm.temperature.isFinite, (0...2).contains(llm.temperature), (1...1_000_000).contains(llm.max_tokens),
              ["observe", "warn", "cap"].contains(budget.mode), budget.total_usd.isFinite, budget.total_usd >= 0,
              budget.reserve_pct.isFinite, (0..<1).contains(budget.reserve_pct), budget.single_action_approval_usd.isFinite, budget.single_action_approval_usd >= 0,
              ["guided", "manual_all", "auto_noncreative"].contains(checkpoint.policy), (1...120).contains(output.default_fps), (0...51).contains(output.default_crf),
              output.default_resolution.range(of: "^[1-9][0-9]{1,4}x[1-9][0-9]{1,4}$", options: .regularExpression) != nil,
              !output.default_format.isEmpty, !output.default_codec.isEmpty, !output.default_audio_codec.isEmpty else { throw configurationError("模型、预算或输出参数不合法。") }
        for path in [checkpoint.storage_dir, paths.pipeline_dir, paths.library_dir, paths.styles_dir, paths.skills_dir, paths.output_dir] {
            guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw configurationError("工作目录必须是项目内的相对路径，不能包含 ..。") }
        }
    }
    var json: String { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return (try? String(decoding: encoder.encode(self), as: UTF8.self)) ?? "{}" }
}

func configurationError(_ message: String) -> NSError { NSError(domain: "ImageAll.OpenMontage", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }

struct OpenMontageServiceField: Identifiable, Sendable {
    let id: String
    let group: String
    var secret: Bool { ["KEY", "TOKEN", "SECRET"].contains(where: id.contains) }
    static let groups: [(String, String)] = [
        ("创作 Agent", "ANTHROPIC_API_KEY ANTHROPIC_BASE_URL OPENROUTER_API_KEY OLLAMA_HOST MISTRAL_API_KEY OPENAI_BASE_URL"),
        ("OpenAI / Google / xAI", "OPENAI_API_KEY GOOGLE_API_KEY GEMINI_API_KEY GOOGLE_TTS_API_KEY XAI_API_KEY GOOGLE_APPLICATION_CREDENTIALS GOOGLE_CLOUD_PROJECT GOOGLE_CLOUD_PROJECT_ID GCLOUD_PROJECT GOOGLE_CLOUD_LOCATION GOOGLE_GENAI_USE_VERTEXAI GOOGLE_GENAI_USE_ENTERPRISE"),
        ("图像与视频", "FAL_KEY FAL_AI_API_KEY MINIMAX_API_KEY MINIMAX_REGION MINIMAX_BASE_URL REPLICATE_API_TOKEN HIGGSFIELD_API_KEY HIGGSFIELD_API_SECRET HIGGSFIELD_KEY KLING_API_KEY KLING_API_BASE_URL ARK_API_KEY ARK_BASE_URL ARK_SEEDANCE_MODEL ARK_CNY_PER_USD HEYGEN_API_KEY RUNWAY_API_KEY RUNWAYML_API_SECRET VOLC_ACCESSKEY VOLC_SECRETKEY DASHSCOPE_API_KEY TENCENT_TOKENHUB_API_KEY"),
        ("配音与音乐", "ELEVENLABS_API_KEY DOUBAO_SPEECH_API_KEY DOUBAO_SPEECH_VOICE_TYPE FISH_AUDIO_API_KEY SUNO_API_KEY AZURE_SPEECH_KEY AZURE_SPEECH_REGION AZURE_SPEECH_ENDPOINT AZURE_TTS_ENDPOINT MUSIC_LIBRARY_DIR"),
        ("素材与分析", "PEXELS_API_KEY PIXABAY_API_KEY UNSPLASH_ACCESS_KEY HF_TOKEN COVERR_API_KEY FREESOUND_API_KEY NARA_API_KEY POND5_API_KEY VIDEVO_API_KEY"),
        ("本地工具与缓存", "COMFYUI_SERVER_URL COMFYUI_VIDEO_SERVER_URL VIDEO_GEN_LOCAL_ENABLED VIDEO_GEN_LOCAL_MODEL MODAL_LTX2_ENDPOINT_URL WAV2LIP_PATH SADTALKER_PATH BLENDER_PATH OPENMONTAGE_CACHE_DIR OPENMONTAGE_CACHE_MAX_GB")
    ]
    static var all: [Self] { groups.flatMap { group, keys in keys.split(separator: " ").map { Self(id: String($0), group: group) } } }
    static func validate(_ values: [String: String]) throws {
        let allowed = Set(all.map(\.id)).union(["OPENMONTAGE_MODEL_API_KEY"])
        for (key, value) in values {
            guard allowed.contains(key), value.count <= 16_384, !value.contains("\0"), !value.contains("\n") else { throw configurationError("服务配置中包含不支持的字段或换行。") }
            if !value.isEmpty && (key.contains("URL") || key.hasSuffix("ENDPOINT") || key.hasSuffix("HOST")) {
                guard let url = URLComponents(string: value), let host = url.host, url.user == nil, url.password == nil,
                      url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else { throw configurationError("\(key) 需要 HTTPS 地址；本机服务可用 HTTP。凭据请填写到单独的密钥栏。") }
            }
        }
    }
}

// The App and its signed helper share only this dedicated Keychain item.
enum OpenMontageCredentials {
    static func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.gwlee.ImageAll.OpenMontage", kSecAttrAccount as String: "services.v1", kSecUseDataProtectionKeychain as String: true]
    }
    static func load() throws -> [String: String] {
        var q = query(); q[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return [:] }
        guard status == errSecSuccess, let data = item as? Data else { throw configurationError("无法读取 OpenMontage 钥匙串（\(status)）。") }
        return try JSONDecoder().decode([String: String].self, from: data)
    }
    static func save(_ values: [String: String]) throws {
        try OpenMontageServiceField.validate(values)
        let data = try JSONEncoder().encode(values.filter { !$0.value.isEmpty })
        let q = query()
        var status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = q; add[kSecValueData as String] = data; add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw configurationError("无法保存 OpenMontage 钥匙串（\(status)）。") }
    }
    static func clear() throws {
        let status = SecItemDelete(query() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw configurationError("无法清除 OpenMontage 凭据（\(status)）。") }
    }
}
