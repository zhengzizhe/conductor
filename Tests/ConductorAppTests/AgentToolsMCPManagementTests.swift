import XCTest
@testable import ConductorApp

/// MCP 管理后端单测：编辑 / 停用 / 启用 / 停用仓。
/// 注意：本机若只装了 Command Line Tools（无 Xcode）跑不了 XCTest；需在 CI 或带 Xcode 的机器上跑。
final class AgentToolsMCPManagementTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("conductor-mcp-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // 在临时路径写一个 client 配置（mcpServers.<name> = config），返回 (configPath, record)。
    private func seedServer(name: String, config: [String: Any],
                            keyPath: [String] = ["mcpServers"]) throws -> (String, AgentToolsMCPServerRecord) {
        let path = tmp.appendingPathComponent("mcp-\(name).json").path
        var root: [String: Any] = [:]
        // 支持嵌套 keyPath
        if keyPath.count == 1 {
            root[keyPath[0]] = [name: config]
        } else {
            root[keyPath[0]] = [keyPath[1]: [name: config]]
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted])
        try data.write(to: URL(fileURLWithPath: path))
        let record = AgentToolsMCPServerRecord(
            id: "X:\(path):\(keyPath.joined(separator: ".")):\(name)",
            client: "X", name: name, transport: .stdio,
            command: config["command"] as? String, args: [],
            url: config["url"] as? String, envKeyCount: 0,
            configPath: path, sourceKeyPath: keyPath.joined(separator: "."))
        return (path, record)
    }

    private func loadServers(_ path: String, keyPath: [String] = ["mcpServers"]) throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        for key in keyPath {
            obj = obj[key] as? [String: Any] ?? [:]
        }
        return obj
    }

    // MARK: - rawConfig

    func testRawConfigReadsEnvAndUnknownKeys() throws {
        let (_, record) = try seedServer(name: "a", config: [
            "command": "node", "args": ["s.js"], "env": ["K": "v"], "x-extra": true,
        ])
        let raw = try XCTUnwrap(AgentToolsMCPScanner.rawConfig(for: record))
        XCTAssertEqual(raw["command"] as? String, "node")
        XCTAssertEqual((raw["env"] as? [String: Any])?["K"] as? String, "v")
        XCTAssertEqual(raw["x-extra"] as? Bool, true)
    }

    // MARK: - updateServer

    func testUpdateRenamePreservesUnknownKeys() throws {
        let (path, record) = try seedServer(name: "old", config: [
            "type": "http", "url": "https://old/mcp", "env": ["A": "1"], "x-keep": "yes",
        ])
        try AgentToolsMCPScanner.updateServer(
            original: record, newName: "new", transport: .http,
            command: nil, args: [], url: "https://new/mcp", env: ["A": "1"])
        let servers = try loadServers(path)
        XCTAssertNil(servers["old"], "旧名应被删除")
        let new = try XCTUnwrap(servers["new"] as? [String: Any])
        XCTAssertEqual(new["url"] as? String, "https://new/mcp")
        XCTAssertEqual(new["x-keep"] as? String, "yes", "未知键应保留")
    }

    func testUpdateTransportSwitchClearsUrl() throws {
        let (path, record) = try seedServer(name: "s", config: ["type": "http", "url": "https://h/mcp"])
        try AgentToolsMCPScanner.updateServer(
            original: record, newName: "s", transport: .stdio,
            command: "node", args: ["x.js"], url: nil, env: [:])
        let s = try XCTUnwrap(try loadServers(path)["s"] as? [String: Any])
        XCTAssertEqual(s["command"] as? String, "node")
        XCTAssertNil(s["url"], "切到 stdio 应清掉 url")
        XCTAssertNil(s["type"])
    }

    func testUpdateEmptyEnvRemovesEnvKey() throws {
        let (path, record) = try seedServer(name: "s", config: ["command": "c", "env": ["A": "1"]])
        try AgentToolsMCPScanner.updateServer(
            original: record, newName: "s", transport: .stdio,
            command: "c", args: [], url: nil, env: [:])
        let s = try XCTUnwrap(try loadServers(path)["s"] as? [String: Any])
        XCTAssertNil(s["env"], "清空 env 应移除 env 键")
    }

    func testUpdateNestedKeyPath() throws {
        let (path, record) = try seedServer(name: "s", config: ["command": "c"], keyPath: ["mcp", "servers"])
        try AgentToolsMCPScanner.updateServer(
            original: record, newName: "s2", transport: .stdio,
            command: "c2", args: [], url: nil, env: [:])
        let servers = try loadServers(path, keyPath: ["mcp", "servers"])
        XCTAssertNil(servers["s"])
        XCTAssertEqual((servers["s2"] as? [String: Any])?["command"] as? String, "c2")
    }

    // MARK: - disable / enable

    func testDisableThenEnableRoundTrip() throws {
        let (path, record) = try seedServer(name: "srv", config: ["command": "node", "env": ["A": "1"]])
        let parking = AgentToolsMCPParkingStore(url: tmp.appendingPathComponent("park.json"))

        try AgentToolsMCPScanner.disableServer(record, parking: parking)
        XCTAssertNil(try loadServers(path)["srv"], "停用后应从磁盘移除")
        let parked = try XCTUnwrap(parking.find(configPath: path, keyPath: "mcpServers", name: "srv"))
        XCTAssertEqual((parked.config["env"] as? [String: Any])?["A"] as? String, "1", "原文(含 env)应进停用仓")

        try AgentToolsMCPScanner.enableServer(record, parking: parking)
        let restored = try XCTUnwrap(try loadServers(path)["srv"] as? [String: Any])
        XCTAssertEqual(restored["command"] as? String, "node")
        XCTAssertTrue(parking.load().isEmpty, "启用后应清出停用仓")
    }

    func testEnableWithoutParkedIsNoop() throws {
        let (path, record) = try seedServer(name: "srv", config: ["command": "c"])
        let parking = AgentToolsMCPParkingStore(url: tmp.appendingPathComponent("park.json"))
        try AgentToolsMCPScanner.enableServer(record, parking: parking)  // 停用仓里没有 → 无操作
        XCTAssertNotNil(try loadServers(path)["srv"])
    }

    // MARK: - removeServer

    func testRemoveServerDeletesEntry() throws {
        let (path, record) = try seedServer(name: "gone", config: ["command": "c"])
        try AgentToolsMCPScanner.removeServer(record)
        XCTAssertNil(try loadServers(path)["gone"])
    }

    // MARK: - parking store

    func testParkingAddFindRemoveDedup() throws {
        let store = AgentToolsMCPParkingStore(url: tmp.appendingPathComponent("p.json"))
        XCTAssertTrue(store.load().isEmpty)

        try store.add(client: "c", configPath: "/p", keyPath: "mcpServers", name: "n", config: ["command": "a"])
        XCTAssertEqual(store.load().count, 1)
        XCTAssertEqual(store.find(configPath: "/p", keyPath: "mcpServers", name: "n")?.config["command"] as? String, "a")

        // 同 key 覆盖
        try store.add(client: "c", configPath: "/p", keyPath: "mcpServers", name: "n", config: ["command": "b"])
        XCTAssertEqual(store.load().count, 1)
        XCTAssertEqual(store.find(configPath: "/p", keyPath: "mcpServers", name: "n")?.config["command"] as? String, "b")

        XCTAssertTrue(try store.remove(configPath: "/p", keyPath: "mcpServers", name: "n"))
        XCTAssertTrue(store.load().isEmpty)
        XCTAssertFalse(try store.remove(configPath: "/p", keyPath: "mcpServers", name: "n"))
    }

    // MARK: - 原生 JSON 编辑

    func testClientJSONReadEditPreserveUnwrapInvalidEmpty() throws {
        let path = tmp.appendingPathComponent("client.json").path
        // 预置含其它顶层键的文件
        try Data("{\"someOtherKey\":123,\"mcpServers\":{}}".utf8).write(to: URL(fileURLWithPath: path))
        let adapter = AgentToolsMCPClientAdapter(id: "t", displayName: "T", path: path, keyPath: ["mcpServers"])

        // 直接编辑 servers JSON
        try AgentToolsMCPScanner.saveServersJSON("{ \"fs\": { \"command\": \"npx\", \"args\": [\"-y\",\"x\"] } }", for: adapter)
        let servers = try loadServers(path)
        XCTAssertNotNil(servers["fs"])
        XCTAssertEqual((servers["fs"] as? [String: Any])?["command"] as? String, "npx")
        // 其它顶层键保留
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any]
        XCTAssertEqual(root?["someOtherKey"] as? Int, 123)

        // 读回的 JSON 文本包含刚写的 server
        let text = AgentToolsMCPScanner.currentServersJSON(for: adapter)
        XCTAssertTrue(text.contains("fs"))

        // 解开 { "mcpServers": {...} } 外壳
        try AgentToolsMCPScanner.saveServersJSON("{ \"mcpServers\": { \"a\": { \"command\": \"c\" } } }", for: adapter)
        XCTAssertNotNil(try loadServers(path)["a"])
        XCTAssertNil(try loadServers(path)["fs"])

        // 非法 JSON 抛错
        XCTAssertThrowsError(try AgentToolsMCPScanner.saveServersJSON("{ broken", for: adapter))

        // 容注释 + 尾逗号
        try AgentToolsMCPScanner.saveServersJSON("{ \"b\": { \"command\": \"c\", }, } // ok", for: adapter)
        XCTAssertNotNil(try loadServers(path)["b"])

        // 空文本＝清空 servers
        try AgentToolsMCPScanner.saveServersJSON("", for: adapter)
        XCTAssertTrue(try loadServers(path).isEmpty)
    }

    func testCurrentServersJSONMissingFileIsEmptyObject() {
        let adapter = AgentToolsMCPClientAdapter(
            id: "t", displayName: "T",
            path: tmp.appendingPathComponent("nope.json").path, keyPath: ["mcpServers"])
        XCTAssertEqual(AgentToolsMCPScanner.currentServersJSON(for: adapter), "{}")
    }

    func testParkingRecordIDMatchesScanFormat() {
        let parked = ParkedMCPServer(client: "Claude Code",
                                     configPath: "/Users/x/.claude/mcp.json",
                                     keyPath: "mcpServers", name: "fs", config: [:])
        XCTAssertEqual(parked.recordID, "Claude Code:/Users/x/.claude/mcp.json:mcpServers:fs")
    }
}
