import Foundation

/// hook 上报的一次 agent 原生会话绑定。按 pane 记账，优先于目录扫描启发式。
public struct AgentSessionHookPayload: Codable, Equatable, Sendable {
    public var paneID: String
    public var agent: String
    public var sessionID: String
    public var cwd: String?
    public var transcriptPath: String?
    public var isRunning: Bool?
    public var lifecycle: AgentSessionLifecycle?
    public var launchCommand: AgentLaunchCommandSnapshot?
    public var updatedAt: Date

    public init(
        paneID: String,
        agent: String,
        sessionID: String,
        cwd: String? = nil,
        transcriptPath: String? = nil,
        isRunning: Bool? = nil,
        lifecycle: AgentSessionLifecycle? = nil,
        launchCommand: AgentLaunchCommandSnapshot? = nil,
        updatedAt: Date = Date()
    ) {
        self.paneID = paneID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.agent = agent.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.cwd = Self.clean(cwd)
        self.transcriptPath = Self.clean(transcriptPath)
        self.isRunning = isRunning
        self.lifecycle = lifecycle
        self.launchCommand = launchCommand
        self.updatedAt = updatedAt
    }

    var isUsable: Bool {
        !paneID.isEmpty && !agent.isEmpty && !sessionID.isEmpty
    }

    private static func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

/// 持久化 pane -> agent session token。文件独立于 layout state，避免 hook 到达时频繁改大状态文件。
public struct AgentSessionBindingStore: Sendable {
    private struct Snapshot: Codable {
        var version: Int
        var sessions: [String: AgentSessionRef]
    }

    private static let currentVersion = 1
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() -> [String: AgentSessionRef] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        if let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            return snapshot.sessions
        }
        return (try? JSONDecoder().decode([String: AgentSessionRef].self, from: data)) ?? [:]
    }

    public func ref(for paneID: String) -> AgentSessionRef? {
        load()[paneID]
    }

    public func record(_ payload: AgentSessionHookPayload) throws {
        guard payload.isUsable else { return }
        var sessions = load()
        var ref = sessions[payload.paneID] ?? AgentSessionRef(
            agent: payload.agent,
            sessionID: payload.sessionID)
        ref.agent = payload.agent
        ref.sessionID = payload.sessionID
        ref.cwd = payload.cwd ?? ref.cwd
        ref.transcriptPath = payload.transcriptPath ?? ref.transcriptPath
        ref.updatedAt = payload.updatedAt
        ref.wasRunning = payload.isRunning ?? ref.wasRunning
        ref.lifecycle = payload.lifecycle ?? ref.lifecycle
        ref.launchCommand = payload.launchCommand ?? ref.launchCommand
        sessions[payload.paneID] = ref
        try save(sessions)
    }

    public func updateLaunchCommand(
        paneID: String,
        launchCommand: AgentLaunchCommandSnapshot,
        updatedAt: Date = Date()
    ) throws {
        var sessions = load()
        guard var ref = sessions[paneID] else { return }
        ref.launchCommand = launchCommand
        ref.updatedAt = updatedAt
        sessions[paneID] = ref
        try save(sessions)
    }

    public func cleanup(keeping paneIDs: Set<String>) throws {
        let filtered = load().filter { paneIDs.contains($0.key) }
        try save(filtered)
    }

    private func save(_ sessions: [String: AgentSessionRef]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let snapshot = Snapshot(version: Self.currentVersion, sessions: sessions)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: fileURL, options: [.atomic])
    }
}
