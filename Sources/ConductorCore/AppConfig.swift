import Foundation

/// 用户配置（来自 `~/.config/conductor/config.yaml`）。纯 Codable 模型，不含 YAML 解析（那在 App 层用 Yams）。
///
/// **容错**：每个结构都自定义 `init(from:)`，缺字段用默认、未知字段忽略——
/// 保证旧/新配置文件都能加载，单个坏字段不至于整份失效（高商用）。
/// `validated()` 进一步夹紧非法值（字号范围、枚举回退）。
public struct AppConfig: Codable, Equatable, Sendable {
    public var appearance: Appearance
    public var terminal: TerminalConfig
    public var behavior: Behavior
    public var keybindings: [String: String]
    public var ghosttyOverrides: [String: String]
    public var workspaceDefaults: WorkspaceDefaults
    public var usage: UsageConfig
    public var companion: CompanionConfig

    public init(appearance: Appearance = .init(),
                terminal: TerminalConfig = .init(),
                behavior: Behavior = .init(),
                keybindings: [String: String] = [:],
                ghosttyOverrides: [String: String] = [:],
                workspaceDefaults: WorkspaceDefaults = .init(),
                usage: UsageConfig = .init(),
                companion: CompanionConfig = .init()) {
        self.appearance = appearance
        self.terminal = terminal
        self.behavior = behavior
        self.keybindings = keybindings
        self.ghosttyOverrides = ghosttyOverrides
        self.workspaceDefaults = workspaceDefaults
        self.usage = usage
        self.companion = companion
    }

    public static let `default` = AppConfig()

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appearance = c.value(.appearance, AppConfig.default.appearance)
        terminal = c.value(.terminal, AppConfig.default.terminal)
        behavior = c.value(.behavior, AppConfig.default.behavior)
        keybindings = c.value(.keybindings, [:])
        ghosttyOverrides = c.value(.ghosttyOverrides, [:])
        workspaceDefaults = c.value(.workspaceDefaults, .init())
        usage = c.value(.usage, .init())
        companion = c.value(.companion, AppConfig.default.companion)
    }

    /// 夹紧非法值，返回修正后的副本。
    public func validated() -> AppConfig {
        var copy = self
        copy.appearance = appearance.validated()
        copy.terminal = terminal.validated()
        copy.behavior = behavior.validated()
        copy.usage = usage.validated()
        copy.companion = companion.validated()
        copy.ghosttyOverrides = ghosttyOverrides.compactMapValues { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return copy
    }
}

// MARK: - usage（账号用量 provider 的启用与凭证）

/// 用量 provider 配置：按 provider id 存「是否启用 + 凭证 + 来源偏好 + 高级字段」。
/// 应用内填的 key 会被注入进程环境变量（解决 GUI 不继承 shell env），fetcher 据此取数。
public struct UsageConfig: Codable, Equatable, Sendable {
    public var providers: [String: UsageProviderConfig]

    public init(providers: [String: UsageProviderConfig] = [:]) {
        self.providers = providers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        providers = c.value(.providers, [:])
    }

    func validated() -> UsageConfig {
        var copy = self
        copy.providers = providers.compactMapValues { $0.validated() }
        return copy
    }
}

public struct UsageProviderConfig: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case enabled
        case apiKey
        case sourceMode
        case cookieSource
        case cookieHeader
        case projectID
        case baseURL
        case organizationID
        case flags
        case extra
    }

    /// 是否在用量区显示并抓取。nil = 未设置（回落到「检测到凭证才显示」）。
    public var enabled: Bool?
    /// 应用内填写的 API key / token；落盘到 config.yaml。
    public var apiKey: String?
    /// 用量来源偏好：auto / cli / oauth / api / browser / manual 等。具体 provider 自行解释。
    public var sourceMode: String?
    /// Cookie 来源偏好：auto / browser / manual / off 等。
    public var cookieSource: String?
    /// 手工粘贴的 Cookie 或 Authorization header。
    public var cookieHeader: String?
    /// 平台项目 ID（OpenAI project、Azure deployment/project 等）。
    public var projectID: String?
    /// 自定义 API base URL。
    public var baseURL: String?
    /// 组织 / workspace / account id。
    public var organizationID: String?
    /// provider 专属开关，如 historicalTracking、avoidKeychainPrompts。
    public var flags: [String: Bool]
    /// provider 专属字符串槽位，避免为了一个字段反复扩模型。
    public var extra: [String: String]

    public init(
        enabled: Bool? = nil,
        apiKey: String? = nil,
        sourceMode: String? = nil,
        cookieSource: String? = nil,
        cookieHeader: String? = nil,
        projectID: String? = nil,
        baseURL: String? = nil,
        organizationID: String? = nil,
        flags: [String: Bool] = [:],
        extra: [String: String] = [:])
    {
        self.enabled = enabled
        self.apiKey = apiKey
        self.sourceMode = sourceMode
        self.cookieSource = cookieSource
        self.cookieHeader = cookieHeader
        self.projectID = projectID
        self.baseURL = baseURL
        self.organizationID = organizationID
        self.flags = flags
        self.extra = extra
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try? c.decodeIfPresent(Bool.self, forKey: .enabled)
        let key = try? c.decodeIfPresent(String.self, forKey: .apiKey)
        apiKey = (key?.isEmpty == true) ? nil : key
        sourceMode = Self.nonEmpty(try? c.decodeIfPresent(String.self, forKey: .sourceMode))
        cookieSource = Self.nonEmpty(try? c.decodeIfPresent(String.self, forKey: .cookieSource))
        cookieHeader = Self.nonEmpty(try? c.decodeIfPresent(String.self, forKey: .cookieHeader))
        projectID = Self.nonEmpty(try? c.decodeIfPresent(String.self, forKey: .projectID))
        baseURL = Self.nonEmpty(try? c.decodeIfPresent(String.self, forKey: .baseURL))
        organizationID = Self.nonEmpty(try? c.decodeIfPresent(String.self, forKey: .organizationID))
        flags = (try? c.decodeIfPresent([String: Bool].self, forKey: .flags)) ?? [:]
        extra = (try? c.decodeIfPresent([String: String].self, forKey: .extra)) ?? [:]
        extra = extra.compactMapValues(Self.nonEmpty)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(enabled, forKey: .enabled)
        try c.encodeIfPresent(apiKey, forKey: .apiKey)
        try c.encodeIfPresent(sourceMode, forKey: .sourceMode)
        try c.encodeIfPresent(cookieSource, forKey: .cookieSource)
        try c.encodeIfPresent(cookieHeader, forKey: .cookieHeader)
        try c.encodeIfPresent(projectID, forKey: .projectID)
        try c.encodeIfPresent(baseURL, forKey: .baseURL)
        try c.encodeIfPresent(organizationID, forKey: .organizationID)
        if !flags.isEmpty { try c.encode(flags, forKey: .flags) }
        if !extra.isEmpty { try c.encode(extra, forKey: .extra) }
    }

    func validated() -> UsageProviderConfig {
        var copy = self
        copy.apiKey = Self.nonEmpty(apiKey)
        copy.sourceMode = Self.nonEmpty(sourceMode)
        copy.cookieSource = Self.nonEmpty(cookieSource)
        copy.cookieHeader = Self.nonEmpty(cookieHeader)
        copy.projectID = Self.nonEmpty(projectID)
        copy.baseURL = Self.nonEmpty(baseURL)
        copy.organizationID = Self.nonEmpty(organizationID)
        copy.extra = extra.compactMapValues(Self.nonEmpty)
        return copy
    }

    private static func nonEmpty(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

// MARK: - appearance

public struct Appearance: Codable, Equatable, Sendable {
    public var theme: String
    public var font: FontConfig
    public var padding: Padding
    public var cursorStyle: String       // bar | block | underline
    public var colors: Colors?

    public init(theme: String = "dark", font: FontConfig = .init(),
                padding: Padding = .init(), cursorStyle: String = "bar",
                colors: Colors? = nil) {
        self.theme = theme
        self.font = font
        self.padding = padding
        self.cursorStyle = cursorStyle
        self.colors = colors
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Appearance()
        theme = c.value(.theme, d.theme)
        font = c.value(.font, d.font)
        padding = c.value(.padding, d.padding)
        cursorStyle = c.value(.cursorStyle, d.cursorStyle)
        colors = (try? c.decodeIfPresent(Colors.self, forKey: .colors)) ?? nil
    }

    static let validCursorStyles: Set<String> = ["bar", "block", "underline"]

    func validated() -> Appearance {
        var copy = self
        copy.font = font.validated()
        if !Appearance.validCursorStyles.contains(cursorStyle) { copy.cursorStyle = "bar" }
        return copy
    }
}

public struct FontConfig: Codable, Equatable, Sendable {
    public var family: String
    public var size: Int

    public init(family: String = "SF Mono", size: Int = 13) {
        self.family = family
        self.size = size
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FontConfig()
        family = c.value(.family, d.family)
        size = c.value(.size, d.size)
    }

    func validated() -> FontConfig {
        var copy = self
        copy.size = min(max(size, 6), 72)     // 字号夹到 6...72
        if family.trimmingCharacters(in: .whitespaces).isEmpty { copy.family = "SF Mono" }
        return copy
    }
}

public struct Padding: Codable, Equatable, Sendable {
    public var x: Int
    public var y: Int

    public init(x: Int = 14, y: Int = 12) {
        self.x = x
        self.y = y
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Padding()
        x = c.value(.x, d.x)
        y = c.value(.y, d.y)
    }
}

public struct Colors: Codable, Equatable, Sendable {
    public var background: String?
    public var foreground: String?
    public var cursor: String?
    public var selection: String?
    public var ansi: [String]?

    public init(background: String? = nil, foreground: String? = nil,
                cursor: String? = nil, selection: String? = nil, ansi: [String]? = nil) {
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
        self.selection = selection
        self.ansi = ansi
    }
}

// MARK: - terminal

public struct TerminalConfig: Codable, Equatable, Sendable {
    public var shell: String?           // nil = 用户登录 shell
    public var scrollback: Int
    public var copyOnSelect: Bool
    public var confirmCloseRunning: Bool
    public var autoResumeAgentSessions: Bool
    public var aiAgents: [AIAgentConfig]

    public init(shell: String? = nil, scrollback: Int = 60000,
                copyOnSelect: Bool = false, confirmCloseRunning: Bool = true,
                autoResumeAgentSessions: Bool = true,
                aiAgents: [AIAgentConfig] = []) {
        self.shell = shell
        self.scrollback = scrollback
        self.copyOnSelect = copyOnSelect
        self.confirmCloseRunning = confirmCloseRunning
        self.autoResumeAgentSessions = autoResumeAgentSessions
        self.aiAgents = aiAgents
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TerminalConfig()
        shell = (try? c.decodeIfPresent(String.self, forKey: .shell)) ?? nil
        scrollback = c.value(.scrollback, d.scrollback)
        copyOnSelect = c.value(.copyOnSelect, d.copyOnSelect)
        confirmCloseRunning = c.value(.confirmCloseRunning, d.confirmCloseRunning)
        autoResumeAgentSessions = c.value(.autoResumeAgentSessions, d.autoResumeAgentSessions)
        aiAgents = c.value(.aiAgents, d.aiAgents)
    }

    func validated() -> TerminalConfig {
        var copy = self
        // 下限 6 万行：保证 agent 长输出可回看（旧配置里的小值也会被抬上来）
        copy.scrollback = min(max(scrollback, 60_000), 1_000_000)
        copy.aiAgents = AIAgentConfig.validatedList(aiAgents)
        return copy
    }
}

public struct AIAgentConfig: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var command: String
    public var enabled: Bool

    public init(id: String, title: String, command: String, enabled: Bool = true) {
        self.id = id
        self.title = title
        self.command = command
        self.enabled = enabled
    }

    func validated() -> AIAgentConfig? {
        let cleanID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanID.isEmpty, !cleanCommand.isEmpty else { return nil }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return AIAgentConfig(
            id: cleanID,
            title: cleanTitle.isEmpty ? cleanID : cleanTitle,
            command: cleanCommand,
            enabled: enabled)
    }

    public static func validatedList(_ agents: [AIAgentConfig]) -> [AIAgentConfig] {
        var seen: Set<String> = []
        var out: [AIAgentConfig] = []
        for agent in agents {
            guard let clean = agent.validated(), seen.insert(clean.id).inserted else { continue }
            out.append(clean)
        }
        return out
    }
}

// MARK: - behavior

public struct Behavior: Codable, Equatable, Sendable {
    public var restoreLayoutOnLaunch: Bool
    public var newTabCwd: String        // workspace | activePane | home

    public init(restoreLayoutOnLaunch: Bool = true, newTabCwd: String = "workspace") {
        self.restoreLayoutOnLaunch = restoreLayoutOnLaunch
        self.newTabCwd = newTabCwd
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Behavior()
        restoreLayoutOnLaunch = c.value(.restoreLayoutOnLaunch, d.restoreLayoutOnLaunch)
        newTabCwd = c.value(.newTabCwd, d.newTabCwd)
    }

    static let validNewTabCwd: Set<String> = ["workspace", "activePane", "home"]

    func validated() -> Behavior {
        var copy = self
        if !Behavior.validNewTabCwd.contains(newTabCwd) { copy.newTabCwd = "workspace" }
        return copy
    }
}

// MARK: - workspace defaults

public struct WorkspaceDefaults: Codable, Equatable, Sendable {
    public var shell: String?
    public var startupCommand: String?

    public init(shell: String? = nil, startupCommand: String? = nil) {
        self.shell = shell
        self.startupCommand = startupCommand
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shell = (try? c.decodeIfPresent(String.self, forKey: .shell)) ?? nil
        startupCommand = (try? c.decodeIfPresent(String.self, forKey: .startupCommand)) ?? nil
    }
}

// MARK: - 容错解码助手

extension KeyedDecodingContainer {
    /// 取 key 的值，缺失/类型错都回退到 `def`（不抛）。
    func value<T: Decodable>(_ key: Key, _ def: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? def
    }
}
