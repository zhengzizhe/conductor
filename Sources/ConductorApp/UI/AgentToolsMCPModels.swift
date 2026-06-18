import Foundation

enum AgentToolsMCPTransport: String, Sendable {
    case stdio
    case http
    case sse
    case unknown

    var title: String {
        switch self {
        case .stdio: return "stdio"
        case .http: return "HTTP"
        case .sse: return "SSE"
        case .unknown: return L("未知")
        }
    }
}

struct AgentToolsMCPServerRecord: Identifiable, Equatable, Sendable {
    let id: String
    let client: String
    let name: String
    let transport: AgentToolsMCPTransport
    let command: String?
    let args: [String]
    let url: String?
    let envKeyCount: Int
    let configPath: String
    let sourceKeyPath: String
    /// 是否启用。停用的 server 不在 client 配置文件里，仅存于 conductor 停用仓。
    var enabled: Bool = true

    var endpointLabel: String {
        if let url, !url.isEmpty { return url }
        if let command, !command.isEmpty {
            return ([command] + args).joined(separator: " ")
        }
        return "-"
    }
}

struct AgentToolsMCPScanResult: Sendable {
    var servers: [AgentToolsMCPServerRecord]
    var error: String?
}

struct AgentToolsMCPClientAdapter: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let path: String
    let keyPath: [String]

    var expandedPath: String {
        NSString(string: path).expandingTildeInPath
    }
}

struct AgentToolsMCPTemplate: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let description: String
    let transport: AgentToolsMCPTransport
    let command: String?
    let args: [String]
    let url: String?
    let envKeys: [String]
    let tags: [String]

    var requiresEnv: Bool { !envKeys.isEmpty }
}

enum AgentToolsMCPScanner {
    private struct Candidate {
        let client: String
        let path: String
        let keyPaths: [[String]]
    }

    static let writableClients: [AgentToolsMCPClientAdapter] = [
        AgentToolsMCPClientAdapter(
            id: "claude_desktop",
            displayName: "Claude Desktop",
            path: "~/Library/Application Support/Claude/claude_desktop_config.json",
            keyPath: ["mcpServers"]),
        AgentToolsMCPClientAdapter(
            id: "claude_code",
            displayName: "Claude Code",
            path: "~/.claude/mcp.json",
            keyPath: ["mcpServers"]),
        AgentToolsMCPClientAdapter(
            id: "codex",
            displayName: "Codex",
            path: "~/.codex/mcp.json",
            keyPath: ["mcpServers"]),
        AgentToolsMCPClientAdapter(
            id: "cursor",
            displayName: "Cursor",
            path: "~/.cursor/mcp.json",
            keyPath: ["mcpServers"]),
        AgentToolsMCPClientAdapter(
            id: "vscode",
            displayName: "VS Code",
            path: "~/Library/Application Support/Code/User/settings.json",
            keyPath: ["mcp", "servers"]),
        AgentToolsMCPClientAdapter(
            id: "windsurf",
            displayName: "Windsurf",
            path: "~/.codeium/windsurf/mcp_config.json",
            keyPath: ["mcpServers"]),
    ]

    static let templates: [AgentToolsMCPTemplate] = [
        AgentToolsMCPTemplate(
            id: "filesystem",
            name: "filesystem",
            description: L("给 Agent 授权访问指定本地目录，适合项目文件浏览和批量读写。"),
            transport: .stdio,
            command: "npx",
            args: ["-y", "@modelcontextprotocol/server-filesystem", "~"],
            url: nil,
            envKeys: [],
            tags: ["local", "files"]),
        AgentToolsMCPTemplate(
            id: "memory",
            name: "memory",
            description: L("本地长期记忆 server，用于跨会话保存实体和关系。"),
            transport: .stdio,
            command: "npx",
            args: ["-y", "@modelcontextprotocol/server-memory"],
            url: nil,
            envKeys: [],
            tags: ["local", "memory"]),
        AgentToolsMCPTemplate(
            id: "sequential-thinking",
            name: "sequential-thinking",
            description: L("结构化思考工具，适合复杂任务拆解和多步推理。"),
            transport: .stdio,
            command: "npx",
            args: ["-y", "@modelcontextprotocol/server-sequential-thinking"],
            url: nil,
            envKeys: [],
            tags: ["reasoning"]),
        AgentToolsMCPTemplate(
            id: "fetch",
            name: "fetch",
            description: L("通过 MCP 读取网页内容，适合资料抓取和摘要。"),
            transport: .stdio,
            command: "uvx",
            args: ["mcp-server-fetch"],
            url: nil,
            envKeys: [],
            tags: ["web"]),
        AgentToolsMCPTemplate(
            id: "git",
            name: "git",
            description: L("读取 Git 仓库状态、提交历史和 diff。"),
            transport: .stdio,
            command: "uvx",
            args: ["mcp-server-git"],
            url: nil,
            envKeys: [],
            tags: ["dev"]),
        AgentToolsMCPTemplate(
            id: "playwright",
            name: "playwright",
            description: L("浏览器自动化能力，用于页面检查、点击和截图。"),
            transport: .stdio,
            command: "npx",
            args: ["-y", "@playwright/mcp@latest"],
            url: nil,
            envKeys: [],
            tags: ["browser", "test"]),
        AgentToolsMCPTemplate(
            id: "github",
            name: "github",
            description: L("访问 GitHub issue、PR 和仓库数据；需要 GitHub token。"),
            transport: .stdio,
            command: "npx",
            args: ["-y", "@modelcontextprotocol/server-github"],
            url: nil,
            envKeys: ["GITHUB_PERSONAL_ACCESS_TOKEN"],
            tags: ["dev", "api"]),
    ]

    static func scan(fileManager: FileManager = .default,
                     parking: AgentToolsMCPParkingStore = .init()) -> AgentToolsMCPScanResult {
        var records: [AgentToolsMCPServerRecord] = []
        var errors: [String] = []
        // 停用仓里的 server 已不在磁盘上，单独合进列表（enabled = false），供重新启用。
        for parked in parking.load() {
            records.append(record(
                client: parked.client,
                name: parked.name,
                config: parked.config,
                configPath: parked.configPath,
                keyPath: parked.keyPath,
                enabled: false))
        }
        for candidate in candidates() {
            let expanded = NSString(string: candidate.path).expandingTildeInPath
            guard fileManager.fileExists(atPath: expanded) else { continue }
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: expanded))
                let object = try parseJSONLike(data)
                guard let root = object as? [String: Any] else { continue }
                for keyPath in candidate.keyPaths {
                    guard let servers = dictionary(at: keyPath, in: root) else { continue }
                    for (name, raw) in servers {
                        guard let config = raw as? [String: Any] else { continue }
                        records.append(record(
                            client: candidate.client,
                            name: name,
                            config: config,
                            configPath: expanded,
                            keyPath: keyPath.joined(separator: ".")))
                    }
                }
            } catch {
                errors.append("\(candidate.client): \(error.localizedDescription)")
            }
        }
        let sorted = records.sorted {
            if $0.client != $1.client {
                return $0.client.localizedCaseInsensitiveCompare($1.client) == .orderedAscending
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return AgentToolsMCPScanResult(
            servers: sorted,
            error: errors.isEmpty ? nil : errors.joined(separator: "\n"))
    }

    static func installTemplate(_ template: AgentToolsMCPTemplate,
                                to clientIDs: Set<String>,
                                fileManager: FileManager = .default) throws {
        let targets = writableClients.filter { clientIDs.contains($0.id) }
        guard !targets.isEmpty else { return }
        for adapter in targets {
            try writeServer(
                name: template.name,
                config: config(for: template),
                to: adapter,
                fileManager: fileManager)
        }
    }

    static func installCustomServer(name: String,
                                    transport: AgentToolsMCPTransport,
                                    command: String?,
                                    args: [String],
                                    url: String?,
                                    env: [String: String],
                                    to clientIDs: Set<String>,
                                    fileManager: FileManager = .default) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let targets = writableClients.filter { clientIDs.contains($0.id) }
        guard !targets.isEmpty else { return }
        var config: [String: Any] = [:]
        switch transport {
        case .stdio:
            guard let command = nonEmpty(command) else { return }
            config["command"] = command
            if !args.isEmpty { config["args"] = args }
        case .http:
            guard let url = nonEmpty(url) else { return }
            config["type"] = "http"
            config["url"] = url
        case .sse:
            guard let url = nonEmpty(url) else { return }
            config["type"] = "sse"
            config["url"] = url
        case .unknown:
            return
        }
        if !env.isEmpty { config["env"] = env }
        for adapter in targets {
            try writeServer(
                name: trimmedName,
                config: config,
                to: adapter,
                fileManager: fileManager)
        }
    }

    static func removeServer(_ server: AgentToolsMCPServerRecord,
                             fileManager: FileManager = .default) throws {
        let keyPath = server.sourceKeyPath.split(separator: ".").map(String.init)
        try removeServer(
            name: server.name,
            configPath: server.configPath,
            keyPath: keyPath,
            fileManager: fileManager)
    }

    /// 读回某 server 的原始配置字典（含 env 值和未知键）。record 只带解析后的少量字段，
    /// 编辑前需要原文才能不丢 env 值/自定义键。
    static func rawConfig(for server: AgentToolsMCPServerRecord,
                          fileManager: FileManager = .default) -> [String: Any]? {
        let keyPath = server.sourceKeyPath.split(separator: ".").map(String.init)
        guard let root = try? loadRoot(url: URL(fileURLWithPath: server.configPath)),
              let servers = dictionary(at: keyPath, in: root),
              let config = servers[server.name] as? [String: Any]
        else { return nil }
        return config
    }

    /// 编辑一台已有 server：以原始配置为底，覆盖 transport/命令/URL/env，保留未知键。
    /// 改名时删掉旧键再写新键。原地写回 server 所在文件与 keyPath。
    static func updateServer(original: AgentToolsMCPServerRecord,
                             newName: String,
                             transport: AgentToolsMCPTransport,
                             command: String?,
                             args: [String],
                             url: String?,
                             env: [String: String],
                             fileManager: FileManager = .default) throws {
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let keyPath = original.sourceKeyPath.split(separator: ".").map(String.init)
        let url0 = URL(fileURLWithPath: original.configPath)
        var root = try loadRoot(url: url0)
        var servers = dictionary(at: keyPath, in: root) ?? [:]
        // 以原文为底，保留未知键；只重置 transport 决定的几个键。
        var config = (servers[original.name] as? [String: Any]) ?? [:]
        for key in ["command", "args", "url", "type", "transport"] { config.removeValue(forKey: key) }
        switch transport {
        case .stdio:
            guard let command = nonEmpty(command) else { return }
            config["command"] = command
            if args.isEmpty { config.removeValue(forKey: "args") } else { config["args"] = args }
        case .http:
            guard let url = nonEmpty(url) else { return }
            config["type"] = "http"
            config["url"] = url
        case .sse:
            guard let url = nonEmpty(url) else { return }
            config["type"] = "sse"
            config["url"] = url
        case .unknown:
            return
        }
        if env.isEmpty { config.removeValue(forKey: "env") } else { config["env"] = env }
        if trimmedName != original.name { servers.removeValue(forKey: original.name) }
        servers[trimmedName] = config
        setDictionary(servers, at: keyPath, in: &root)
        try writeRoot(root, to: url0, fileManager: fileManager)
    }

    /// 停用：把 server 原文存进停用仓，再从 client 配置文件移除。可逆。
    static func disableServer(_ server: AgentToolsMCPServerRecord,
                              parking: AgentToolsMCPParkingStore = .init(),
                              fileManager: FileManager = .default) throws {
        guard server.enabled else { return }
        guard let config = rawConfig(for: server, fileManager: fileManager) else { return }
        try parking.add(
            client: server.client, configPath: server.configPath,
            keyPath: server.sourceKeyPath, name: server.name, config: config)
        try removeServer(server, fileManager: fileManager)
    }

    // MARK: - 原生 JSON 编辑（每个 client 的 mcpServers 子树）

    /// 读出某 client 配置文件里 mcpServers 子树的 JSON 文本（漂亮打印）。无则返回 "{}"。
    static func currentServersJSON(for adapter: AgentToolsMCPClientAdapter) -> String {
        let root = (try? loadRoot(url: URL(fileURLWithPath: adapter.expandedPath))) ?? [:]
        let servers = dictionary(at: adapter.keyPath, in: root) ?? [:]
        return prettyJSON(servers)
    }

    /// 把用户编辑的 JSON 文本写回某 client 的 mcpServers 子树。
    /// 宽容解析（容注释/尾逗号）；自动解开 { "mcpServers": {...} } / { "servers": {...} } 外壳；
    /// 保留文件里其它顶层键。非法 JSON 抛错（文本带行号信息）。
    static func saveServersJSON(_ text: String, for adapter: AgentToolsMCPClientAdapter,
                                fileManager: FileManager = .default) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var servers: [String: Any] = [:]
        if !trimmed.isEmpty {
            let parsed: Any
            do { parsed = try parseJSONLike(Data(trimmed.utf8)) }
            catch { throw editError(L("JSON 解析失败：%@", error.localizedDescription)) }
            guard var object = parsed as? [String: Any] else {
                throw editError(L("顶层必须是一个 JSON 对象，形如 { \"server-name\": { ... } }"))
            }
            if let wrapped = object["mcpServers"] as? [String: Any] { object = wrapped }
            else if let wrapped = object["servers"] as? [String: Any] { object = wrapped }
            servers = object
        }
        var root = try loadRoot(url: URL(fileURLWithPath: adapter.expandedPath))
        setDictionary(servers, at: adapter.keyPath, in: &root)
        try writeRoot(root, to: URL(fileURLWithPath: adapter.expandedPath), fileManager: fileManager)
    }

    static func prettyJSON(_ object: Any) -> String {
        if let dict = object as? [String: Any], dict.isEmpty { return "{}" }
        if let array = object as? [Any], array.isEmpty { return "[]" }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private static func editError(_ message: String) -> Error {
        NSError(domain: "AgentToolsMCPEditor", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// 启用：把停用仓里的原文写回原文件原 keyPath，再清出停用仓。
    static func enableServer(_ server: AgentToolsMCPServerRecord,
                             parking: AgentToolsMCPParkingStore = .init(),
                             fileManager: FileManager = .default) throws {
        guard let parked = parking.find(
            configPath: server.configPath, keyPath: server.sourceKeyPath, name: server.name)
        else { return }
        let keyPath = parked.keyPath.split(separator: ".").map(String.init)
        try writeServerRaw(
            name: parked.name, config: parked.config,
            configPath: parked.configPath, keyPath: keyPath,
            fileManager: fileManager)
        try parking.remove(
            configPath: parked.configPath, keyPath: parked.keyPath, name: parked.name)
    }

    private static func candidates() -> [Candidate] {
        [
            Candidate(
                client: "Claude Desktop",
                path: "~/Library/Application Support/Claude/claude_desktop_config.json",
                keyPaths: [["mcpServers"], ["mcp", "servers"]]),
            Candidate(
                client: "Claude Code",
                path: "~/.claude.json",
                keyPaths: [["mcpServers"], ["mcp", "servers"]]),
            Candidate(
                client: "Claude Code",
                path: "~/.claude/mcp.json",
                keyPaths: [["mcpServers"], ["servers"], ["mcp", "servers"]]),
            Candidate(
                client: "Codex",
                path: "~/.codex/mcp.json",
                keyPaths: [["mcpServers"], ["servers"], ["mcp", "servers"]]),
            Candidate(
                client: "Cursor",
                path: "~/.cursor/mcp.json",
                keyPaths: [["mcpServers"], ["servers"], ["mcp", "servers"]]),
            Candidate(
                client: "VS Code",
                path: "~/Library/Application Support/Code/User/settings.json",
                keyPaths: [["mcp", "servers"], ["mcp.servers"], ["mcpServers"]]),
            Candidate(
                client: "Windsurf",
                path: "~/.codeium/windsurf/mcp_config.json",
                keyPaths: [["mcpServers"], ["servers"], ["mcp", "servers"]]),
        ]
    }

    private static func config(for template: AgentToolsMCPTemplate) -> [String: Any] {
        var config: [String: Any] = [:]
        switch template.transport {
        case .stdio:
            if let command = template.command { config["command"] = command }
            if !template.args.isEmpty { config["args"] = template.args }
        case .http:
            config["type"] = "http"
            if let url = template.url { config["url"] = url }
        case .sse:
            config["type"] = "sse"
            if let url = template.url { config["url"] = url }
        case .unknown:
            break
        }
        if !template.envKeys.isEmpty {
            config["env"] = Dictionary(uniqueKeysWithValues: template.envKeys.map { ($0, "$\($0)") })
        }
        return config
    }

    private static func writeServer(name: String,
                                    config: [String: Any],
                                    to adapter: AgentToolsMCPClientAdapter,
                                    fileManager: FileManager) throws {
        try writeServerRaw(
            name: name, config: config,
            configPath: adapter.expandedPath, keyPath: adapter.keyPath,
            fileManager: fileManager)
    }

    /// 按 configPath + keyPath 直接 upsert 一台 server（不依赖 adapter）。供编辑/启用回盘用。
    private static func writeServerRaw(name: String,
                                       config: [String: Any],
                                       configPath: String,
                                       keyPath: [String],
                                       fileManager: FileManager) throws {
        let url = URL(fileURLWithPath: configPath)
        var root = try loadRoot(url: url)
        var servers = dictionary(at: keyPath, in: root) ?? [:]
        servers[name] = config
        setDictionary(servers, at: keyPath, in: &root)
        try writeRoot(root, to: url, fileManager: fileManager)
    }

    private static func removeServer(name: String,
                                     configPath: String,
                                     keyPath: [String],
                                     fileManager: FileManager) throws {
        let url = URL(fileURLWithPath: configPath)
        var root = try loadRoot(url: url)
        guard var servers = dictionary(at: keyPath, in: root) else { return }
        servers.removeValue(forKey: name)
        setDictionary(servers, at: keyPath, in: &root)
        try writeRoot(root, to: url, fileManager: fileManager)
    }

    private static func loadRoot(url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        return try parseJSONLike(data) as? [String: Any] ?? [:]
    }

    private static func writeRoot(_ root: [String: Any], to url: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url)
    }

    private static func setDictionary(_ value: [String: Any],
                                      at keyPath: [String],
                                      in root: inout [String: Any]) {
        guard let first = keyPath.first else { return }
        if keyPath.count == 1 {
            root[first] = value
            return
        }
        var child = root[first] as? [String: Any] ?? [:]
        setDictionary(value, at: Array(keyPath.dropFirst()), in: &child)
        root[first] = child
    }

    private static func record(
        client: String,
        name: String,
        config: [String: Any],
        configPath: String,
        keyPath: String,
        enabled: Bool = true
    ) -> AgentToolsMCPServerRecord {
        let command = nonEmpty(config["command"] as? String)
        let url = nonEmpty(config["url"] as? String) ?? nonEmpty(config["endpoint"] as? String)
        let type = nonEmpty(config["type"] as? String) ?? nonEmpty(config["transport"] as? String)
        let args = (config["args"] as? [String]) ?? (config["args"] as? [Any])?.compactMap { $0 as? String } ?? []
        let env = config["env"] as? [String: Any] ?? [:]
        let transport: AgentToolsMCPTransport
        switch type?.lowercased() {
        case "stdio": transport = .stdio
        case "http", "streamable-http", "streamable_http": transport = .http
        case "sse": transport = .sse
        default:
            if command != nil { transport = .stdio }
            else if url?.lowercased().contains("sse") == true { transport = .sse }
            else if url != nil { transport = .http }
            else { transport = .unknown }
        }
        return AgentToolsMCPServerRecord(
            id: "\(client):\(configPath):\(keyPath):\(name)",
            client: client,
            name: name,
            transport: transport,
            command: command,
            args: args,
            url: url,
            envKeyCount: env.count,
            configPath: configPath,
            sourceKeyPath: keyPath,
            enabled: enabled)
    }

    private static func dictionary(at keyPath: [String], in root: [String: Any]) -> [String: Any]? {
        var current: Any = root
        for key in keyPath {
            guard let dictionary = current as? [String: Any],
                  let next = dictionary[key] else { return nil }
            current = next
        }
        return current as? [String: Any]
    }

    private static func parseJSONLike(_ data: Data) throws -> Any {
        if let object = try? JSONSerialization.jsonObject(with: data) {
            return object
        }
        let text = String(decoding: data, as: UTF8.self)
        let cleaned = removeTrailingCommas(from: stripJSONComments(text))
        return try JSONSerialization.jsonObject(with: Data(cleaned.utf8))
    }

    private static func stripJSONComments(_ text: String) -> String {
        var output = ""
        var index = text.startIndex
        var inString = false
        var escaped = false
        while index < text.endIndex {
            let char = text[index]
            let next = text.index(after: index)
            if inString {
                output.append(char)
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    inString = false
                }
                index = next
                continue
            }
            if char == "\"" {
                inString = true
                output.append(char)
                index = next
                continue
            }
            if char == "/", next < text.endIndex {
                let lookahead = text[next]
                if lookahead == "/" {
                    index = next
                    while index < text.endIndex, text[index] != "\n" {
                        index = text.index(after: index)
                    }
                    continue
                }
                if lookahead == "*" {
                    index = text.index(after: next)
                    while index < text.endIndex {
                        let after = text.index(after: index)
                        if text[index] == "*", after < text.endIndex, text[after] == "/" {
                            index = text.index(after: after)
                            break
                        }
                        index = after
                    }
                    continue
                }
            }
            output.append(char)
            index = next
        }
        return output
    }

    private static func removeTrailingCommas(from text: String) -> String {
        var output = ""
        let chars = Array(text)
        var index = 0
        var inString = false
        var escaped = false
        while index < chars.count {
            let char = chars[index]
            if inString {
                output.append(char)
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    inString = false
                }
                index += 1
                continue
            }
            if char == "\"" {
                inString = true
                output.append(char)
                index += 1
                continue
            }
            if char == "," {
                var probe = index + 1
                while probe < chars.count, chars[probe].isWhitespace {
                    probe += 1
                }
                if probe < chars.count, chars[probe] == "}" || chars[probe] == "]" {
                    index += 1
                    continue
                }
            }
            output.append(char)
            index += 1
        }
        return output
    }

    private static func nonEmpty(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    #if DEBUG
    static func debugSmokeTest() throws -> [String] {
        func fail(_ message: String) throws -> Never {
            throw NSError(
                domain: "AgentToolsMCPScanner.debugSmokeTest",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
        }

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conductor-mcp-smoke-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let adapter = AgentToolsMCPClientAdapter(
            id: "smoke",
            displayName: "Smoke",
            path: root.appendingPathComponent("mcp.json").path,
            keyPath: ["mcpServers"])
        let url = URL(fileURLWithPath: adapter.expandedPath)
        guard let template = templates.first(where: { $0.id == "filesystem" }) else {
            try fail("filesystem template missing")
        }

        try writeServer(
            name: template.name,
            config: config(for: template),
            to: adapter,
            fileManager: .default)
        var loaded = try loadRoot(url: url)
        guard let servers = dictionary(at: adapter.keyPath, in: loaded),
              servers[template.name] != nil else {
            try fail("template server was not written")
        }

        try writeServer(
            name: "remote-smoke",
            config: ["type": "http", "url": "https://example.com/mcp"],
            to: adapter,
            fileManager: .default)
        loaded = try loadRoot(url: url)
        guard let servers = dictionary(at: adapter.keyPath, in: loaded),
              let remote = servers["remote-smoke"] as? [String: Any],
              remote["url"] as? String == "https://example.com/mcp" else {
            try fail("custom remote server was not written")
        }

        // 编辑：把 remote-smoke 改名 + 换 URL，原 env/未知键应保留。
        try writeServerRaw(
            name: "edit-smoke",
            config: ["type": "http", "url": "https://old.example/mcp", "env": ["A": "1"], "x-custom": true],
            configPath: adapter.expandedPath, keyPath: adapter.keyPath, fileManager: .default)
        let editTarget = record(client: "smoke", name: "edit-smoke",
                                config: ["type": "http", "url": "https://old.example/mcp"],
                                configPath: adapter.expandedPath, keyPath: "mcpServers")
        try updateServer(original: editTarget, newName: "edit-smoke2",
                         transport: .http, command: nil, args: [],
                         url: "https://new.example/mcp", env: ["A": "1"])
        loaded = try loadRoot(url: url)
        guard let servers = dictionary(at: adapter.keyPath, in: loaded),
              servers["edit-smoke"] == nil,
              let edited = servers["edit-smoke2"] as? [String: Any],
              edited["url"] as? String == "https://new.example/mcp",
              edited["x-custom"] as? Bool == true else {
            try fail("updateServer did not rename/preserve correctly")
        }

        // 停用 / 启用：用临时停用仓，停用后磁盘消失、scan 标 disabled，启用后回盘。
        let parkURL = root.appendingPathComponent("mcp-disabled.json")
        let parking = AgentToolsMCPParkingStore(url: parkURL)
        let disableTarget = record(client: "smoke", name: "edit-smoke2",
                                   config: edited, configPath: adapter.expandedPath, keyPath: "mcpServers")
        try disableServer(disableTarget, parking: parking, fileManager: .default)
        loaded = try loadRoot(url: url)
        if let servers = dictionary(at: adapter.keyPath, in: loaded), servers["edit-smoke2"] != nil {
            try fail("disableServer left server on disk")
        }
        guard parking.find(configPath: adapter.expandedPath, keyPath: "mcpServers", name: "edit-smoke2") != nil else {
            try fail("disableServer did not park config")
        }
        try enableServer(disableTarget, parking: parking, fileManager: .default)
        loaded = try loadRoot(url: url)
        guard let servers = dictionary(at: adapter.keyPath, in: loaded),
              servers["edit-smoke2"] != nil,
              parking.load().isEmpty else {
            try fail("enableServer did not restore from park")
        }

        // 编辑切换 transport：http → stdio，url 应被清掉、command 写入。
        try updateServer(original: disableTarget, newName: "edit-smoke2",
                         transport: .stdio, command: "node", args: ["server.js"], url: nil, env: [:])
        loaded = try loadRoot(url: url)
        guard let servers = dictionary(at: adapter.keyPath, in: loaded),
              let switched = servers["edit-smoke2"] as? [String: Any],
              switched["command"] as? String == "node",
              (switched["args"] as? [Any])?.count == 1,
              switched["url"] == nil, switched["type"] == nil, switched["env"] == nil else {
            try fail("updateServer transport switch (http→stdio) failed")
        }

        // transport 推断：无 type 时按字段猜。
        let inferStdio = record(client: "x", name: "s", config: ["command": "foo"], configPath: "/p", keyPath: "mcpServers")
        let inferHTTP = record(client: "x", name: "s", config: ["url": "https://h/mcp"], configPath: "/p", keyPath: "mcpServers")
        let inferSSE = record(client: "x", name: "s", config: ["url": "https://h/sse"], configPath: "/p", keyPath: "mcpServers")
        let inferEnv = record(client: "x", name: "s", config: ["command": "f", "env": ["K": "v"]], configPath: "/p", keyPath: "mcpServers")
        guard inferStdio.transport == .stdio, inferHTTP.transport == .http,
              inferSSE.transport == .sse, inferEnv.envKeyCount == 1 else {
            try fail("transport/env inference wrong")
        }

        // 容错解析：注释 + 尾逗号。
        let messy = Data("""
        { // line comment
          "mcpServers": { "a": { "command": "x", }, }, /* block */
        }
        """.utf8)
        guard let parsed = try parseJSONLike(messy) as? [String: Any],
              dictionary(at: ["mcpServers"], in: parsed)?["a"] != nil else {
            try fail("lenient JSON parse (comments/trailing commas) failed")
        }

        // 嵌套 keyPath（VS Code 的 mcp.servers）写读往返。
        try writeServerRaw(name: "vs", config: ["command": "c"],
                           configPath: adapter.expandedPath, keyPath: ["mcp", "servers"], fileManager: .default)
        loaded = try loadRoot(url: url)
        guard dictionary(at: ["mcp", "servers"], in: loaded)?["vs"] != nil else {
            try fail("nested keyPath (mcp.servers) round-trip failed")
        }

        // 停用仓去重：同 key 重复 add 只留一条。
        let p2 = AgentToolsMCPParkingStore(url: root.appendingPathComponent("p2.json"))
        try p2.add(client: "c", configPath: "/p", keyPath: "mcpServers", name: "n", config: ["command": "a"])
        try p2.add(client: "c", configPath: "/p", keyPath: "mcpServers", name: "n", config: ["command": "b"])
        guard p2.load().count == 1,
              (p2.find(configPath: "/p", keyPath: "mcpServers", name: "n")?.config["command"] as? String) == "b" else {
            try fail("MCP parking dedup/overwrite failed")
        }

        try removeServer(
            name: template.name,
            configPath: adapter.expandedPath,
            keyPath: adapter.keyPath,
            fileManager: .default)
        loaded = try loadRoot(url: url)
        if let servers = dictionary(at: adapter.keyPath, in: loaded),
           servers[template.name] != nil {
            try fail("template server was not removed")
        }

        return [
            "wrote template server",
            "wrote custom remote server",
            "edited server (rename + preserve keys)",
            "edited server (transport switch http→stdio clears url)",
            "transport/env inference",
            "lenient JSON parse (comments + trailing commas)",
            "nested keyPath mcp.servers round-trip",
            "disabled + re-enabled server via park",
            "MCP parking dedup/overwrite",
            "removed template server",
        ]
    }
    #endif
}
