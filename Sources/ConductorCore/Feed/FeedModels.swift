import Foundation

/// agent 请求的动作类别——审批策略按它做粒度。
public enum FeedActionCategory: String, Codable, Sendable, CaseIterable {
    case readFile         // 读文件
    case writeFile        // 写 / 改 / 删文件
    case executeCommand   // 执行 shell 命令
    case network          // 网络访问
    case other

    public var label: String {
        switch self {
        case .readFile: return "读文件"
        case .writeFile: return "写文件"
        case .executeCommand: return "执行命令"
        case .network: return "网络访问"
        case .other: return "其它"
        }
    }

    /// 由 agent 的工具名推断动作类别（hook 只传工具名，类别在服务端推断，便于统一测试）。
    /// 先匹配已知工具名（Claude Code / Codex），再退化到小写关键字启发。
    public static func infer(toolName raw: String) -> FeedActionCategory {
        let name = raw.lowercased()
        switch raw {
        case "Bash", "Shell", "Terminal", "Execute": return .executeCommand
        case "Read", "Glob", "Grep", "LS", "NotebookRead": return .readFile
        case "Write", "Edit", "MultiEdit", "NotebookEdit", "ApplyPatch": return .writeFile
        case "WebFetch", "WebSearch": return .network
        default: break
        }
        // 注意：只用够长、低碰撞的关键字（"cat"/"rm"/"net" 这类短串会误伤 Frobni·cat·e、pe·rm·ission 等）。
        if name.contains("bash") || name.contains("shell") || name.contains("exec")
            || name.contains("command") {
            return .executeCommand
        }
        if name.contains("write") || name.contains("edit") || name.contains("patch")
            || name.contains("create") || name.contains("delete") {
            return .writeFile
        }
        if name.contains("read") || name.contains("grep") || name.contains("glob")
            || name.contains("search") || name.contains("list") {
            return .readFile
        }
        if name.contains("web") || name.contains("fetch") || name.contains("http")
            || name.contains("browser") {
            return .network
        }
        return .other
    }
}

/// 一条待审批请求的内容。运行时类型，不持久化。
public enum FeedRequestKind: Equatable, Sendable {
    /// 工具 / 权限请求：工具名 + 动作类别 + 可选具体内容（executeCommand 时是命令行）。
    case permission(tool: String, category: FeedActionCategory, detail: String?)
    /// 退出计划模式：展示计划全文，等用户放行。
    case exitPlan(plan: String)
    /// 向用户提问：题干 + 选项。
    case question(prompt: String, options: [String])
}

/// 一条 agent 发来的待审批请求。运行时类型（socket 收到即建，GUI/规则处置后丢弃）。
public struct FeedRequest: Identifiable, Equatable, Sendable {
    public var id: String
    public var paneID: String?
    public var agent: String?       // claude / codex / …
    public var cwd: String?
    public var kind: FeedRequestKind
    public var createdAt: Date

    public init(id: String = UUID().uuidString,
                paneID: String? = nil,
                agent: String? = nil,
                cwd: String? = nil,
                kind: FeedRequestKind,
                createdAt: Date = Date()) {
        self.id = id
        self.paneID = paneID
        self.agent = agent
        self.cwd = cwd
        self.kind = kind
        self.createdAt = createdAt
    }

    /// 便捷取该请求的工具/类别（仅 permission 有）。
    public var tool: String? {
        if case let .permission(tool, _, _) = kind { return tool }
        return nil
    }
    public var category: FeedActionCategory? {
        if case let .permission(_, category, _) = kind { return category }
        return nil
    }
    public var detail: String? {
        if case let .permission(_, _, detail) = kind { return detail }
        return nil
    }

    /// 人读摘要（审计 / 日志用）。
    public var summary: String {
        switch kind {
        case let .permission(tool, category, detail):
            if let d = detail, !d.isEmpty { return "\(tool) · \(category.label) · \(d)" }
            return "\(tool) · \(category.label)"
        case let .exitPlan(plan):
            return "退出计划模式：\(plan.prefix(80))"
        case let .question(prompt, _):
            return "提问：\(prompt.prefix(80))"
        }
    }
}

/// 审批粒度。
public enum FeedScope: String, Codable, Sendable {
    case once       // 仅这一次，不记忆
    case tool       // 记住：以后这个 agent 的这个工具+类别自动同样处理
    case category   // 记住：以后这个 agent 的这一动作类别（不限工具）自动同样处理
}

/// 用户或规则给出的决策。
public enum FeedDecision: Equatable, Sendable {
    case allow(FeedScope)
    case deny(FeedScope)
    case answer(optionIndex: Int)   // 针对 question

    public var isAllow: Bool { if case .allow = self { return true }; return false }
    public var isDeny: Bool { if case .deny = self { return true }; return false }

    /// 审计字符串。
    public var auditString: String {
        switch self {
        case let .allow(scope): return "allow(\(scope.rawValue))"
        case let .deny(scope): return "deny(\(scope.rawValue))"
        case let .answer(index): return "answer:\(index)"
        }
    }
}

/// 一条审批审计记录（运行时环形缓冲，不持久化）。
public struct FeedAuditEntry: Identifiable, Equatable, Sendable {
    public var id: String
    public var time: Date
    public var summary: String       // 请求摘要
    public var agent: String?
    public var paneID: String?
    public var decision: String      // 决策的 auditString
    public var auto: Bool            // 是否规则/默认自动处置（非人工）
    public var note: String?         // timeout / disconnect 等附注

    public init(id: String = UUID().uuidString,
                time: Date = Date(),
                summary: String,
                agent: String? = nil,
                paneID: String? = nil,
                decision: String,
                auto: Bool,
                note: String? = nil) {
        self.id = id
        self.time = time
        self.summary = summary
        self.agent = agent
        self.paneID = paneID
        self.decision = decision
        self.auto = auto
        self.note = note
    }
}
