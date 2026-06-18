/// 落盘的顶层状态：带 schema 版本号，便于将来迁移。
public struct PersistedState: Codable, Equatable {
    /// 当前 schema 版本。结构不兼容变更时递增。
    /// v2：新增 paneCwds（恢复时每个 pane 回到原目录）。
    public static let currentVersion = 2

    public var version: Int
    public var store: WorkspaceStore
    /// 每个 pane 最后的工作目录（pane.value → 绝对路径）。
    /// 重启恢复时让 pane 回到原目录，而不是一律回工作区根目录。
    public var paneCwds: [String: String]
    /// 退出时各 pane 里 agent 的可恢复会话（pane.value → 引用）。
    /// 重启恢复时把 `claude --resume` / `codex resume` 预输入到提示符。可加字段，版本号不变。
    public var paneSessions: [String: AgentSessionRef]

    public init(
        version: Int = PersistedState.currentVersion,
        store: WorkspaceStore,
        paneCwds: [String: String] = [:],
        paneSessions: [String: AgentSessionRef] = [:]
    ) {
        self.version = version
        self.store = store
        self.paneCwds = paneCwds
        self.paneSessions = paneSessions
    }

}
