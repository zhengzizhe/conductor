import Foundation

/// 某工具/类别的默认处置。
public enum FeedDisposition: String, Codable, Sendable {
    case ask     // 弹给用户决定
    case allow   // 自动放行
    case deny    // 自动拒绝
}

/// 一条审批规则：按 agent / 工具 / 类别 / 命令 glob 匹配，命中即按 disposition 处置。
/// 任一字段为 nil 表示"不限"。`deny` 规则优先于 `allow` 规则。
public struct FeedRule: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var agent: String?
    public var tool: String?
    public var category: FeedActionCategory?
    public var commandGlob: String?       // 对 request.detail 做 glob（支持 * ?）
    public var disposition: FeedDisposition   // allow / deny（ask 无意义，规则不用 ask）
    public var persisted: Bool            // true = 用户"always"记下来的；false = 项目/手填

    public init(id: String = UUID().uuidString,
                agent: String? = nil,
                tool: String? = nil,
                category: FeedActionCategory? = nil,
                commandGlob: String? = nil,
                disposition: FeedDisposition,
                persisted: Bool = false) {
        self.id = id
        self.agent = agent
        self.tool = tool
        self.category = category
        self.commandGlob = commandGlob
        self.disposition = disposition
        self.persisted = persisted
    }

    /// 这条规则是否匹配某请求（仅 permission 请求参与规则匹配）。
    public func matches(_ request: FeedRequest) -> Bool {
        guard case let .permission(tool, category, detail) = request.kind else { return false }
        if let a = agent, a != request.agent { return false }
        if let t = self.tool, t != tool { return false }
        if let c = self.category, c != category { return false }
        if let glob = commandGlob {
            guard FeedGlob.matches(pattern: glob, in: detail ?? "") else { return false }
        }
        return true
    }
}

/// 审批策略：类别默认处置 + 规则表。可持久化。
public struct FeedPolicy: Codable, Equatable, Sendable {
    /// 每个动作类别的默认处置；缺省视为 ask。
    public var categoryDefaults: [FeedActionCategory: FeedDisposition]
    public var rules: [FeedRule]

    public init(categoryDefaults: [FeedActionCategory: FeedDisposition] = [:],
                rules: [FeedRule] = []) {
        self.categoryDefaults = categoryDefaults
        self.rules = rules
    }

    public static let empty = FeedPolicy()
}

/// 评估结果。
public enum FeedResolution: Equatable, Sendable {
    case auto(FeedDecision)   // 命中规则/默认，自动处置（不打扰用户）
    case prompt               // 需要问用户
}

public struct FeedPolicyEngine: Sendable {
    public var policy: FeedPolicy

    public init(policy: FeedPolicy = .empty) {
        self.policy = policy
    }

    /// 评估一个请求该自动处置还是弹给用户。
    /// 顺序：deny 规则 → allow 规则 → 类别默认 → 否则 prompt。
    /// exitPlan / question 永远 prompt（不自动）。
    public func evaluate(_ request: FeedRequest) -> FeedResolution {
        guard case let .permission(_, category, _) = request.kind else {
            return .prompt
        }
        // deny 优先：任一 deny 规则命中即拒
        if policy.rules.contains(where: { $0.disposition == .deny && $0.matches(request) }) {
            return .auto(.deny(.once))
        }
        // allow 规则命中即放行
        if policy.rules.contains(where: { $0.disposition == .allow && $0.matches(request) }) {
            return .auto(.allow(.once))
        }
        // 类别默认
        switch policy.categoryDefaults[category] ?? .ask {
        case .allow: return .auto(.allow(.once))
        case .deny:  return .auto(.deny(.once))
        case .ask:   return .prompt
        }
    }

    /// 用户对某请求做了带记忆作用域的决策时，生成应追加进策略的规则。
    /// once（或 answer）不产生规则，返回 nil。
    public func rememberedRule(for request: FeedRequest, decision: FeedDecision) -> FeedRule? {
        guard case let .permission(tool, category, _) = request.kind else { return nil }
        let scope: FeedScope
        let disposition: FeedDisposition
        switch decision {
        case let .allow(s): scope = s; disposition = .allow
        case let .deny(s):  scope = s; disposition = .deny
        case .answer:       return nil
        }
        switch scope {
        case .once:
            return nil
        case .tool:
            return FeedRule(agent: request.agent, tool: tool, category: category,
                            disposition: disposition, persisted: true)
        case .category:
            return FeedRule(agent: request.agent, tool: nil, category: category,
                            disposition: disposition, persisted: true)
        }
    }

    /// 把记忆规则并入策略（去重：同 agent/tool/category 的旧规则被新决策替换）。
    public mutating func remember(_ rule: FeedRule) {
        policy.rules.removeAll {
            $0.persisted
                && $0.agent == rule.agent
                && $0.tool == rule.tool
                && $0.category == rule.category
                && $0.commandGlob == rule.commandGlob
        }
        policy.rules.append(rule)
    }
}

/// 极简 glob：支持 `*`（任意串，含空）与 `?`（任意单字符），其余字面匹配。整串匹配。
enum FeedGlob {
    static func matches(pattern: String, in text: String) -> Bool {
        let p = Array(pattern), s = Array(text)
        // 经典动态规划 / 双指针带回溯
        var pi = 0, si = 0
        var star = -1, mark = 0
        while si < s.count {
            if pi < p.count, p[pi] == "?" || p[pi] == s[si] {
                pi += 1; si += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi; mark = si; pi += 1
            } else if star != -1 {
                pi = star + 1; mark += 1; si = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
