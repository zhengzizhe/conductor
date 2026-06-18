import Foundation

/// 会话预览里的一条消息。
public struct AgentSessionMessage: Equatable, Sendable, Identifiable {
    public enum Role: String, Sendable {
        case user
        case assistant
    }

    public let id: Int
    public let role: Role
    public let text: String

    public init(id: Int, role: Role, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

/// 加载会话 transcript 的选项。
public struct AgentSessionLoadOptions: Sendable {
    /// 最多读取的字节数（防止超大日志拖垮内存）。
    public var maxFileBytes: Int
    /// 单条消息最大字符数；nil 表示不截断。
    public var maxMessageChars: Int?
    /// 连续同角色消息是否合并（assistant 分段输出时减少碎片）。
    public var mergeAdjacentSameRole: Bool
    /// 是否保留换行（完整 transcript 用 true）。
    public var preserveNewlines: Bool

    public init(
        maxFileBytes: Int = 64 * 1024 * 1024,
        maxMessageChars: Int? = nil,
        mergeAdjacentSameRole: Bool = true,
        preserveNewlines: Bool = true
    ) {
        self.maxFileBytes = maxFileBytes
        self.maxMessageChars = maxMessageChars
        self.mergeAdjacentSameRole = mergeAdjacentSameRole
        self.preserveNewlines = preserveNewlines
    }

    public static let snippet = AgentSessionLoadOptions(
        maxFileBytes: 786_432, maxMessageChars: 280,
        mergeAdjacentSameRole: true, preserveNewlines: false)
}

/// 从会话 jsonl 解析 user / assistant 消息。
public enum AgentSessionPreview {
    public static let defaultTailBytes = 786_432
    public static let maxMessageChars = 280

    /// 读完整 transcript（虚拟滚动用）：流式按行解析，默认不截断单条消息。
    public static func loadFull(
        agent: String, filePath: String,
        options: AgentSessionLoadOptions = AgentSessionLoadOptions()
    ) -> [AgentSessionMessage] {
        let texts = parseFile(agent: agent, filePath: filePath, maxBytes: options.maxFileBytes, options: options)
        return texts.enumerated().map { AgentSessionMessage(id: $0.offset, role: $0.element.0, text: $0.element.1) }
    }

    /// 读尾部最近几条（兼容旧调用 / 单测）。
    public static func load(
        agent: String, filePath: String,
        limit: Int = 8, tailBytes: Int = defaultTailBytes
    ) -> [AgentSessionMessage] {
        guard let lines = tailLines(filePath: filePath, tailBytes: tailBytes) else { return [] }
        var opts = AgentSessionLoadOptions.snippet
        opts.maxFileBytes = tailBytes
        let texts = parseLines(agent: agent, lines, options: opts)
        return texts.suffix(limit).enumerated().map {
            AgentSessionMessage(id: $0.offset, role: $0.element.0, text: $0.element.1)
        }
    }

    public typealias Role = AgentSessionMessage.Role

    // MARK: - File IO

    private static func parseFile(
        agent: String, filePath: String, maxBytes: Int, options: AgentSessionLoadOptions
    ) -> [(Role, String)] {
        var lines: [Data] = []
        forEachLine(filePath: filePath, maxBytes: maxBytes) { lines.append($0) }
        return parseLines(agent: agent, lines, options: options)
    }

    /// 按 agent 选解析器；**未知/空 agent 自动探测**：先试 claude（其行格式不命中 codex 会回空），
    /// 空了再试 codex。这样手动起的会话（没打 `CONDUCTOR_AGENT_ID` 标签）也能读到真实回复。
    static func parseLines(agent: String, _ lines: [Data], options: AgentSessionLoadOptions) -> [(Role, String)] {
        switch agent {
        case "claude": return parseClaude(lines, options: options)
        case "codex": return parseCodex(lines, options: options)
        default:
            let claude = parseClaude(lines, options: options)
            return claude.isEmpty ? parseCodex(lines, options: options) : claude
        }
    }

    /// 流式按行读文件，最多 maxBytes 字节。
    static func forEachLine(filePath: String, maxBytes: Int, _ body: (Data) -> Void) {
        guard let handle = FileHandle(forReadingAtPath: filePath) else { return }
        defer { try? handle.close() }
        var buffer = Data()
        var consumed = 0
        let chunkSize = 256 * 1024
        while consumed < maxBytes {
            let toRead = min(chunkSize, maxBytes - consumed)
            guard let chunk = try? handle.read(upToCount: toRead), !chunk.isEmpty else { break }
            consumed += chunk.count
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                if !line.isEmpty { body(Data(line)) }
            }
        }
        if !buffer.isEmpty { body(buffer) }
    }

    // MARK: - Claude

    static func parseClaude(_ lines: [Data], options: AgentSessionLoadOptions) -> [(Role, String)] {
        var out: [(Role, String)] = []
        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = obj["type"] as? String,
                  type == "user" || type == "assistant",
                  let message = obj["message"] as? [String: Any]
            else { continue }
            if obj["isSidechain"] as? Bool == true { continue }
            let role: Role = type == "user" ? .user : .assistant
            guard let text = extractClaudeText(message["content"], options: options) else { continue }
            appendMessage(&out, role: role, text: text, options: options)
        }
        return out
    }

    private static func extractClaudeText(_ content: Any?, options: AgentSessionLoadOptions) -> String? {
        var pieces: [String] = []
        if let s = content as? String {
            pieces.append(s)
        } else if let items = content as? [[String: Any]] {
            for item in items {
                guard item["type"] as? String == "text",
                      let t = item["text"] as? String else { continue }
                pieces.append(t)
            }
        }
        let joined = options.preserveNewlines ? pieces.joined(separator: "\n") : pieces.joined(separator: " ")
        return cleanText(joined, options: options)
    }

    // MARK: - Codex

    static func parseCodex(_ lines: [Data], options: AgentSessionLoadOptions) -> [(Role, String)] {
        var out: [(Role, String)] = []
        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  obj["type"] as? String == "event_msg",
                  let payload = obj["payload"] as? [String: Any],
                  let kind = payload["type"] as? String
            else { continue }
            let role: Role
            switch kind {
            case "user_message": role = .user
            case "agent_message": role = .assistant
            default: continue
            }
            guard let text = cleanText(payload["message"] as? String ?? "", options: options) else { continue }
            appendMessage(&out, role: role, text: text, options: options)
        }
        return out
    }

    // MARK: - Helpers

    private static func appendMessage(
        _ out: inout [(Role, String)], role: Role, text: String, options: AgentSessionLoadOptions
    ) {
        if options.mergeAdjacentSameRole, let last = out.last, last.0 == role {
            let sep = options.preserveNewlines ? "\n" : " "
            let merged = last.1 + sep + text
            out[out.count - 1] = (role, cap(merged, options: options))
        } else {
            out.append((role, cap(text, options: options)))
        }
    }

    private static func cap(_ text: String, options: AgentSessionLoadOptions) -> String {
        guard let max = options.maxMessageChars, text.count > max else { return text }
        return String(text.prefix(max - 1)) + "…"
    }

    static func cleanText(_ raw: String, options: AgentSessionLoadOptions = .snippet) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let noisePrefixes = [
            "<command-name>", "<local-command", "<system_reminder", "<user_info", "<task>",
            "Caveat:",
        ]
        for prefix in noisePrefixes where text.hasPrefix(prefix) { return nil }
        if !options.preserveNewlines {
            text = text.replacingOccurrences(of: "\n", with: " ")
            while text.contains("  ") { text = text.replacingOccurrences(of: "  ", with: " ") }
        }
        return text.isEmpty ? nil : text
    }

    static func tailLines(filePath: String, tailBytes: Int) -> [Data]? {
        guard let handle = FileHandle(forReadingAtPath: filePath) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            .map { Data($0) }
        if offset > 0, !lines.isEmpty { lines.removeFirst() }
        return lines
    }
}
