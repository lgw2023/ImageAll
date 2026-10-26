import AppKit
import Darwin
import CryptoKit

// Launch Services delivers a URL to the separate local helper, never a shell command.
func verifyRuntime(_ installed: URL, resources: URL) throws {
    let data = try Data(contentsOf: resources.appendingPathComponent("runtime-integrity.json"))
    let files = try JSONDecoder().decode([String: String].self, from: data)
    for (relative, expected) in files {
        let file = installed.appendingPathComponent(relative)
        guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains(".."),
              file.resolvingSymlinksInPath().path.hasPrefix(installed.resolvingSymlinksInPath().path + "/") else {
            throw NSError(domain: "Unsafe runtime integrity path", code: 1)
        }
        let digest = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
        guard digest == expected else { throw NSError(domain: "制作组件缓存校验失败，请重新安装完整 App；未启动任务", code: 2) }
    }
}

func launch(rootPath: String, runtimePath: String, token: String) {
let taskRoot = URL(fileURLWithPath: rootPath, isDirectory: true)
let runtimeParent = URL(fileURLWithPath: runtimePath, isDirectory: true)
guard UUID(uuidString: token) != nil, taskRoot.path.hasPrefix("/"), runtimeParent.path.hasPrefix("/") else { exit(64) }
let fm = FileManager.default
// A URL alone cannot authorize a launch: the sandboxed App must first write a
// matching nonce into its selected task directory.
guard let requestData = try? Data(contentsOf: taskRoot.appendingPathComponent("launcher-request.json")),
      let request = try? JSONSerialization.jsonObject(with: requestData) as? [String: String],
      request["token"] == token, request["runtime"] == runtimePath else { return }
try? fm.removeItem(at: taskRoot.appendingPathComponent("launcher-request.json"))
var credentialFieldCount = 0
func report(_ message: String, success: Bool) {
    let value: [String: Any] = ["token": token, "success": success, "message": message, "configuredServiceCount": credentialFieldCount]
    if let data = try? JSONSerialization.data(withJSONObject: value) {
        try? data.write(to: taskRoot.appendingPathComponent("launcher-result.json"), options: .atomic)
    }
}
do {
    try fm.createDirectory(at: taskRoot, withIntermediateDirectories: true)
    let resources = Bundle.main.resourceURL!
    let version = try String(contentsOf: resources.appendingPathComponent("payload-version"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    guard version.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw NSError(domain: "Invalid bundled engine", code: 1) }
    try fm.createDirectory(at: runtimeParent, withIntermediateDirectories: true)
    let installed = runtimeParent.appendingPathComponent(version)
    if !fm.fileExists(atPath: installed.path) {
        let staging = runtimeParent.appendingPathComponent(".install-\(token)")
        try fm.copyItem(at: resources.appendingPathComponent("payload"), to: staging)
        do { try fm.moveItem(at: staging, to: installed) }
        catch { try? fm.removeItem(at: staging); if !fm.fileExists(atPath: installed.path) { throw error } }
    }
    try verifyRuntime(installed, resources: resources)
    let process = Process()
    process.executableURL = installed.appendingPathComponent("python/bin/python3.12")
    process.arguments = [installed.appendingPathComponent("engine/scripts/story_executor.py").path, "start", "--task-root", taskRoot.path, "--detach"]
    process.currentDirectoryURL = installed.appendingPathComponent("engine")
    process.environment = ["PATH": installed.appendingPathComponent("bin").path + ":/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "PYTHONHOME": installed.appendingPathComponent("python").path, "PYTHONDONTWRITEBYTECODE": "1", "PYTHONNOUSERSITE": "1"]
    // Reuse a running worker without mutating its configuration or credentials.
    process.arguments = [installed.appendingPathComponent("engine/scripts/story_executor.py").path, "status", "--task-root", taskRoot.path]
    let statusPipe = Pipe(); process.standardOutput = statusPipe; process.standardError = FileHandle.nullDevice
    try process.run()
    let statusData = statusPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    if let status = try? JSONSerialization.jsonObject(with: statusData) as? [String: Any], status["running"] as? Bool == true {
        let heartbeat = status["heartbeat"] as? [String: Any]
        let pid = (heartbeat?["pid"] as? Int) ?? (status["pid"] as? Int) ?? 0
        var buffer = [CChar](repeating: 0, count: 4096)
        let pathLength = pid > 0 ? proc_pidpath(Int32(pid), &buffer, UInt32(buffer.count)) : 0
        let runningPath = pathLength > 0 ? String(cString: buffer) : ""
        if runningPath.hasPrefix(installed.path + "/") {
            report("本地执行器版本已匹配，继续使用当前服务。", success: true)
            return
        }
        // Gracefully drain the old payload; never kill or cancel an in-flight render/model call.
        let stop = Process()
        stop.executableURL = process.executableURL
        stop.currentDirectoryURL = process.currentDirectoryURL
        stop.environment = process.environment
        stop.arguments = [installed.appendingPathComponent("engine/scripts/story_executor.py").path,
                          "stop", "--task-root", taskRoot.path, "--mode", "finish-current", "--wait", "--wait-seconds", "15"]
        stop.standardOutput = FileHandle.nullDevice
        stop.standardError = FileHandle.nullDevice
        try stop.run(); stop.waitUntilExit()
        guard stop.terminationStatus == 0 else {
            report("后台版本需要更新，已安排当前任务完成后退出。请等待当前任务结束再启动制作；本次未提交新创作。", success: false)
            return
        }
    }
    let configuration = try JSONDecoder().decode(OpenMontageConfiguration.self, from: Data((request["configuration"] ?? OpenMontageConfiguration().json).utf8))
    try configuration.validate()
    let configDirectory = taskRoot.appendingPathComponent("configurations")
    try fm.createDirectory(at: configDirectory, withIntermediateDirectories: true)
    let configFile = configDirectory.appendingPathComponent(token + ".json")
    try JSONEncoder().encode(configuration).write(to: configFile, options: .atomic)
    var environment = process.environment ?? [:]
    environment["OPENMONTAGE_CONFIG_PATH"] = configFile.path
    if request["localOnly"] != "true" {
        let stored = try OpenMontageCredentials.load()
        let credentials = request["servicesEnabled"] == "true" ? stored : stored.filter { $0.key == "OPENMONTAGE_MODEL_API_KEY" }
        try OpenMontageServiceField.validate(credentials)
        credentialFieldCount = credentials.filter { !$0.value.isEmpty }.count
        environment.merge(credentials.filter { !$0.value.isEmpty }, uniquingKeysWith: { _, new in new })
    }
    let worker = Process()
    worker.executableURL = process.executableURL
    worker.currentDirectoryURL = process.currentDirectoryURL
    worker.environment = environment
    worker.arguments = [installed.appendingPathComponent("engine/scripts/story_executor.py").path, "start", "--task-root", taskRoot.path, "--detach"]
    let log = taskRoot.appendingPathComponent("launcher.log")
    fm.createFile(atPath: log.path, contents: nil)
    let handle = try FileHandle(forWritingTo: log)
    worker.standardOutput = handle; worker.standardError = handle
    guard !fm.fileExists(atPath: taskRoot.appendingPathComponent("integration-disabled.json").path) else {
        try handle.close(); report("OpenMontage 已停用，未启动执行器。", success: false); return
    }
    try worker.run(); worker.waitUntilExit(); try handle.close()
    let output = (try? Data(contentsOf: log)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    let alreadyRunning = output?["code"] as? String == "EXECUTOR_ALREADY_RUNNING"
    let success = worker.terminationStatus == 0 || alreadyRunning
    report(success ? (alreadyRunning ? "本地执行器已在运行" : "本地执行器已启动") : "启动返回 \(worker.terminationStatus)，请检查任务目录中的 launcher.log", success: success)
} catch { report(error.localizedDescription, success: false); exit(1) }

}
final class Delegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first, url.scheme == "imageall-openmontage",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { application.terminate(nil); return }
        let values = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        if let root = values["taskRoot"], let runtime = values["runtime"], let token = values["token"] {
            launch(rootPath: root, runtimePath: runtime, token: token)
        }
        application.terminate(nil)
    }
}
// Headless service verification uses the same nonce-checked launch contract as the URL route.
if CommandLine.arguments.count == 5, CommandLine.arguments[1] == "--launch-request" {
    launch(rootPath: CommandLine.arguments[2], runtimePath: CommandLine.arguments[3], token: CommandLine.arguments[4])
    exit(0)
}
let delegate = Delegate()
let application = NSApplication.shared
application.delegate = delegate
application.setActivationPolicy(.prohibited)
application.run()
