import ConductorCore
import Foundation

/// 一条来自 CLI hook 的事件。`type`：
/// - "busy"：agent 开始思考（UserPromptSubmit），只更新状态不发通知；
/// - "done"/nil（旧脚本）：agent 完成（Stop），发系统通知并熄灭思考动效。
struct HookEvent {
    let paneID: String?
    let type: String?
    let agent: String?
    let sessionID: String?
    let cwd: String?
    let transcriptPath: String?
    let lifecycle: AgentSessionLifecycle?
    let title: String
    let message: String
}

/// 监听 hook 收件箱目录：CLI 的 hook 脚本（conductor-notify）往这里写 JSON 文件，
/// conductor 读到后发系统通知，然后删除该文件。文件名随意，内容形如：
/// `{"paneId":"p-...","title":"AI 已完成","message":"..."}`。
@MainActor
final class HooksInbox {
    /// 收件箱目录（与 conductor-notify 脚本约定一致）。
    static var directory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("conductor", isDirectory: true)
            .appendingPathComponent("hooks-inbox", isDirectory: true)
    }

    var onEvent: ((HookEvent) -> Void)?
    private var watcher: ConfigWatcher?

    func start() {
        let dir = Self.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let watcher = ConfigWatcher { [weak self] in self?.drain() }
        watcher.start(directory: dir)
        self.watcher = watcher
        drain()   // 处理启动前堆积的事件
    }

    func stop() { watcher?.stop(); watcher = nil }

    private func drain() {
        let dir = Self.directory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])
        else { return }
        let jsons = files.filter { $0.pathExtension == "json" }
            .sorted { ($0.path) < ($1.path) }
        for url in jsons {
            defer { try? FileManager.default.removeItem(at: url) }
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let paneRaw = (obj["paneId"] as? String) ?? (obj["paneID"] as? String)
            let pane = (paneRaw?.isEmpty == false) ? paneRaw : nil
            let title = (obj["title"] as? String)?.isEmpty == false
                ? (obj["title"] as! String) : L("AI 已完成")
            let message = (obj["message"] as? String) ?? ""
            let agent = Self.nonEmpty(obj["agent"] as? String)
            let sessionID = Self.nonEmpty((obj["sessionId"] as? String)
                                          ?? (obj["sessionID"] as? String)
                                          ?? (obj["session_id"] as? String))
            let cwd = Self.nonEmpty((obj["cwd"] as? String)
                                    ?? (obj["workingDirectory"] as? String)
                                    ?? (obj["working_directory"] as? String))
            let transcriptPath = Self.nonEmpty((obj["transcriptPath"] as? String)
                                               ?? (obj["transcript_path"] as? String))
            let lifecycle = Self.lifecycle(
                (obj["lifecycle"] as? String) ?? (obj["state"] as? String),
                eventType: obj["type"] as? String)
            onEvent?(HookEvent(
                paneID: pane,
                type: obj["type"] as? String,
                agent: agent,
                sessionID: sessionID,
                cwd: cwd,
                transcriptPath: transcriptPath,
                lifecycle: lifecycle,
                title: title,
                message: message))
        }
    }

    private static func nonEmpty(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func lifecycle(_ raw: String?, eventType: String?) -> AgentSessionLifecycle? {
        if let raw {
            switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "running", "busy", "thinking": return .running
            case "idle", "done", "stopped": return .idle
            case "needsinput", "needs_input", "waiting", "waitingforinput": return .needsInput
            case "unknown": return .unknown
            default: break
            }
        }
        switch eventType {
        case "busy", "sessionStart": return .running
        case "done": return .idle
        default: return nil
        }
    }
}
