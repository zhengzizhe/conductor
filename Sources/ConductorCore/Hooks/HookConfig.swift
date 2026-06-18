import Foundation

/// 一条已配置的 hook。
public struct HookEntry: Sendable, Identifiable, Equatable {
    /// 稳定 id：同一 source 下、同一 event 里 command 唯一（addCommand 去重保证），
    /// 故 source:event:command 可作稳定标识——比 command.hashValue（进程内随机）更可靠，
    /// SwiftUI 选中态、停用切换都依赖它。
    public var id: String { "\(source.rawValue):\(event):\(command)" }
    public let source: HookSource
    public let event: String
    public let command: String
    public let timeout: Int?
    /// 是否处于启用状态。停用的 hook 不在 settings.json 里，仅存于 conductor 停用仓。
    public let enabled: Bool
    /// 是否由 conductor 安装（命令里带 `#conductor:` 哨兵）。
    public var managedByConductor: Bool { command.contains("#conductor:") }

    public init(source: HookSource, event: String, command: String, timeout: Int?, enabled: Bool = true) {
        self.source = source
        self.event = event
        self.command = command
        self.timeout = timeout
        self.enabled = enabled
    }
}

public enum HookSource: String, Sendable, CaseIterable, Codable, Identifiable {
    case claude
    case codex

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    /// 该 agent 的 hook 配置文件路径。
    public var configURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .claude: return home.appendingPathComponent(".claude/settings.json")
        case .codex: return home.appendingPathComponent(".codex/hooks.json")
        }
    }
}

/// 常见 hook 事件名。
public enum HookEventName {
    public static let stop = "Stop"
    public static let sessionStart = "SessionStart"
    public static let userPromptSubmit = "UserPromptSubmit"
    public static let subagentStop = "SubagentStop"
    /// agent 需要用户确认/输入时触发（Claude Code：权限请求、空闲等输入）。
    public static let notification = "Notification"
    /// 工具调用前触发（Claude Code：可返回决策放行/拦截，用于 Feed 内联审批）。
    public static let preToolUse = "PreToolUse"
}

/// 对 `hooks.<Event>[].hooks[]{type,command,timeout}` 这种 schema 的读写器。
/// Claude 的 settings.json 还含其它键（env / model 等），本类型只动 `hooks` 子树，
/// 其余键原样保留（含敏感信息），不读不改不打印。
public struct HookConfigDocument: Sendable {
    public let url: URL
    public let source: HookSource

    public init(url: URL, source: HookSource) {
        self.url = url
        self.source = source
    }

    public init(source: HookSource) {
        self.url = source.configURL
        self.source = source
    }

    public func load() -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    /// 读出所有 hook 条目。
    public func entries() -> [HookEntry] {
        let root = load()
        guard let hooks = root["hooks"] as? [String: Any] else { return [] }
        var out: [HookEntry] = []
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            for group in groups {
                let inner = group["hooks"] as? [[String: Any]] ?? []
                for h in inner {
                    guard let command = h["command"] as? String else { continue }
                    let timeout = (h["timeout"] as? Int) ?? (h["timeout"] as? NSNumber)?.intValue
                    out.append(HookEntry(source: source, event: event, command: command, timeout: timeout))
                }
            }
        }
        return out.sorted { ($0.event, $0.command) < ($1.event, $1.command) }
    }

    /// 往某事件加一条 command hook（已存在完全相同命令则跳过）。写回，保留其它键。
    /// `timeout == nil` → **不写** timeout 字段（原本没设 timeout 的 hook 重启用时不该被强塞默认值）。
    public func addCommand(event: String, command: String, timeout: Int? = 5000) throws {
        var root = load()
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var groups = hooks[event] as? [[String: Any]] ?? []

        let exists = groups.contains { group in
            let inner = group["hooks"] as? [[String: Any]] ?? []
            return inner.contains { ($0["command"] as? String) == command }
        }
        if !exists {
            var entry: [String: Any] = ["type": "command", "command": command]
            if let timeout { entry["timeout"] = timeout }
            groups.append(["hooks": [entry]])
            hooks[event] = groups
            root["hooks"] = hooks
            try write(root)
        }
    }

    /// 精确移除某事件下命令完全相等的 hook（不是子串匹配，避免误删共享标记串的其它 hook）。
    /// 空了的事件/分组一并清掉。返回移除条数。
    @discardableResult
    public func removeExact(event: String, command: String) throws -> Int {
        var root = load()
        guard var hooks = root["hooks"] as? [String: Any],
              var groups = hooks[event] as? [[String: Any]] else { return 0 }
        var removed = 0
        groups = groups.compactMap { group -> [String: Any]? in
            var inner = group["hooks"] as? [[String: Any]] ?? []
            let before = inner.count
            inner = inner.filter { ($0["command"] as? String) != command }
            removed += before - inner.count
            if inner.isEmpty { return nil }
            var g = group
            g["hooks"] = inner
            return g
        }
        guard removed > 0 else { return 0 }
        if groups.isEmpty { hooks.removeValue(forKey: event) }
        else { hooks[event] = groups }
        root["hooks"] = hooks
        try write(root)
        return removed
    }

    /// 编辑一条已有 hook：精确删掉旧的，再按新值写入（事件可改）。timeout 透传。
    public func update(event: String, command: String,
                       newEvent: String, newCommand: String, newTimeout: Int = 5000) throws {
        _ = try removeExact(event: event, command: command)
        try addCommand(event: newEvent, command: newCommand, timeout: newTimeout)
    }

    /// 移除满足条件（命令包含某子串）的 hook。空了的事件/分组一并清掉。
    /// 仅供 recipe 卸载用——recipe 命令带唯一 `#conductor:<id>` 哨兵，子串匹配安全。
    /// 任意单条 hook 的删除请用 `removeExact(event:command:)`。
    @discardableResult
    public func removeCommands(containing needle: String) throws -> Int {
        var root = load()
        guard var hooks = root["hooks"] as? [String: Any] else { return 0 }
        var removed = 0
        for (event, value) in hooks {
            guard var groups = value as? [[String: Any]] else { continue }
            groups = groups.compactMap { group -> [String: Any]? in
                var inner = group["hooks"] as? [[String: Any]] ?? []
                let before = inner.count
                inner = inner.filter { !(($0["command"] as? String)?.contains(needle) ?? false) }
                removed += before - inner.count
                if inner.isEmpty { return nil }
                var g = group
                g["hooks"] = inner
                return g
            }
            if groups.isEmpty { hooks.removeValue(forKey: event) }
            else { hooks[event] = groups }
        }
        if removed > 0 {
            root["hooks"] = hooks
            try write(root)
        }
        return removed
    }

    /// 读出 hooks 子树的 JSON 文本（漂亮打印）。无则返回 "{}"。供原生编辑器回填。
    public func rawHooksJSON() -> String {
        let hooks = load()["hooks"] as? [String: Any] ?? [:]
        if hooks.isEmpty { return "{}" }
        guard JSONSerialization.isValidJSONObject(hooks),
              let data = try? JSONSerialization.data(
                withJSONObject: hooks,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// 把用户编辑的 JSON 文本写回 hooks 子树。自动解开 { "hooks": {...} } 外壳；
    /// 保留文件里其它顶层键（env/model 等）。非法 JSON 抛错。
    public func saveHooksJSON(_ text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var hooks: [String: Any] = [:]
        if !trimmed.isEmpty {
            let parsed: Any
            do { parsed = try JSONSerialization.jsonObject(with: Data(trimmed.utf8)) }
            catch {
                throw NSError(domain: "ConductorHooksEditor", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "JSON 解析失败：\(error.localizedDescription)"])
            }
            guard var object = parsed as? [String: Any] else {
                throw NSError(domain: "ConductorHooksEditor", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "顶层必须是一个 JSON 对象，形如 { \"Stop\": [ ... ] }"])
            }
            if let wrapped = object["hooks"] as? [String: Any] { object = wrapped }
            hooks = object
        }
        var root = load()
        root["hooks"] = hooks
        try write(root)
    }

    private func write(_ root: [String: Any]) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url)
    }
}
