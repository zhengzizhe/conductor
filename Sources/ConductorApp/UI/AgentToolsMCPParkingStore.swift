import Foundation

/// 一台被停用的 MCP server。停用＝把它从对应 client 的配置文件里移走、原样存到这里，
/// 重新启用时再写回原文件原 keyPath。不依赖各 host 是否支持 `disabled` 字段，且可逆。
struct ParkedMCPServer {
    let client: String
    let configPath: String
    let keyPath: String
    let name: String
    /// 原始 server 配置（command/args/url/type/env 等，含未知键），停用时整段保存。
    let config: [String: Any]

    /// 与磁盘扫描记录同款 id，启用回盘后 scan 能对上、选中态不丢。
    var recordID: String { "\(client):\(configPath):\(keyPath):\(name)" }
}

/// 停用 MCP server 的本地持久仓（conductor 自管，不碰 agent 配置文件）。
/// config 是任意 JSON，用 JSONSerialization 存取（不走 Codable）。
struct AgentToolsMCPParkingStore {
    let url: URL

    init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL
    }

    static var defaultURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("conductor", isDirectory: true)
            .appendingPathComponent("mcp-disabled.json", isDirectory: false)
    }

    func load() -> [ParkedMCPServer] {
        guard let data = try? Data(contentsOf: url),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return array.compactMap { entry in
            guard let client = entry["client"] as? String,
                  let configPath = entry["configPath"] as? String,
                  let keyPath = entry["keyPath"] as? String,
                  let name = entry["name"] as? String,
                  let config = entry["config"] as? [String: Any]
            else { return nil }
            return ParkedMCPServer(client: client, configPath: configPath,
                                   keyPath: keyPath, name: name, config: config)
        }
    }

    func add(client: String, configPath: String, keyPath: String,
             name: String, config: [String: Any]) throws {
        var all = load().filter { !($0.configPath == configPath && $0.keyPath == keyPath && $0.name == name) }
        all.append(ParkedMCPServer(client: client, configPath: configPath,
                                   keyPath: keyPath, name: name, config: config))
        try save(all)
    }

    @discardableResult
    func remove(configPath: String, keyPath: String, name: String) throws -> Bool {
        let all = load()
        let kept = all.filter { !($0.configPath == configPath && $0.keyPath == keyPath && $0.name == name) }
        guard kept.count != all.count else { return false }
        try save(kept)
        return true
    }

    func find(configPath: String, keyPath: String, name: String) -> ParkedMCPServer? {
        load().first { $0.configPath == configPath && $0.keyPath == keyPath && $0.name == name }
    }

    private func save(_ parked: [ParkedMCPServer]) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if parked.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let array: [[String: Any]] = parked.map {
            ["client": $0.client, "configPath": $0.configPath,
             "keyPath": $0.keyPath, "name": $0.name, "config": $0.config]
        }
        let data = try JSONSerialization.data(
            withJSONObject: array, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url)
    }
}
