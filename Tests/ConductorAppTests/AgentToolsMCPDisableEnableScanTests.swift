import XCTest
@testable import ConductorApp

/// MCP 停用 / 启用 / 扫描停用仓 的后端单测。
/// 全程只碰临时目录与临时停用仓：disable 把临时文件里的 server 挪进临时停用仓（磁盘消失），
/// enable 把原文(含 env + 未知键)一字不差写回并清空停用仓；停用幂等；scan(parking:) 把停用仓里的
/// 条目当成 enabled==false 的记录返回。绝不断言磁盘来源（环境相关）的 server。
/// 注意：本机若只装了 Command Line Tools（无 Xcode）跑不了 XCTest；需在 CI 或带 Xcode 的机器上跑。
final class AgentToolsMCPDisableEnableScanTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("conductor-mcp-de-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // 在临时路径写一个 client 配置（keyPath.<name> = config），返回 (configPath, record)。
    private func seedServer(name: String, config: [String: Any],
                            keyPath: [String] = ["mcpServers"]) throws -> (String, AgentToolsMCPServerRecord) {
        let path = tmp.appendingPathComponent("mcp-\(name)-\(UUID().uuidString).json").path
        var root: [String: Any] = [:]
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

    private func parkingStore() -> AgentToolsMCPParkingStore {
        AgentToolsMCPParkingStore(url: tmp.appendingPathComponent("park-\(UUID().uuidString).json"))
    }

    // MARK: - disableServer

    /// 停用：原文（含 env + 未知键）整段进停用仓，磁盘上该 server 消失。
    func testDisableMovesServerOffDiskIntoParking() throws {
        let (path, record) = try seedServer(name: "srv", config: [
            "command": "node", "args": ["s.js"], "env": ["TOKEN": "abc", "DEBUG": "1"], "x-extra": true,
        ])
        let parking = parkingStore()

        try AgentToolsMCPScanner.disableServer(record, parking: parking)

        // 磁盘上消失。
        XCTAssertNil(try loadServers(path)["srv"], "停用后应从 client 配置文件移除")

        // 原文整段进停用仓，含 env 的每个键和未知键。
        let parked = try XCTUnwrap(parking.find(configPath: path, keyPath: "mcpServers", name: "srv"))
        XCTAssertEqual(parked.client, "X")
        XCTAssertEqual(parked.name, "srv")
        XCTAssertEqual(parked.keyPath, "mcpServers")
        XCTAssertEqual(parked.configPath, path)
        XCTAssertEqual(parked.config["command"] as? String, "node")
        XCTAssertEqual(parked.config["args"] as? [String], ["s.js"])
        let env = try XCTUnwrap(parked.config["env"] as? [String: Any])
        XCTAssertEqual(env["TOKEN"] as? String, "abc")
        XCTAssertEqual(env["DEBUG"] as? String, "1")
        XCTAssertEqual(parked.config["x-extra"] as? Bool, true, "未知键应一并停放")
        XCTAssertEqual(parking.load().count, 1)
    }

    /// 已停用（record.enabled == false）的 server 再次停用是 no-op：不写停用仓、不动磁盘。
    func testDisableDisabledRecordIsNoop() throws {
        let (path, record) = try seedServer(name: "srv", config: ["command": "c"])
        let parking = parkingStore()
        // 构造一个 enabled == false 的记录（停用态记录）。
        let disabledRecord = AgentToolsMCPServerRecord(
            id: record.id, client: record.client, name: record.name, transport: .stdio,
            command: "c", args: [], url: nil, envKeyCount: 0,
            configPath: path, sourceKeyPath: "mcpServers", enabled: false)

        try AgentToolsMCPScanner.disableServer(disabledRecord, parking: parking)

        XCTAssertTrue(parking.load().isEmpty, "已停用记录不应再次入仓")
        XCTAssertNotNil(try loadServers(path)["srv"], "磁盘上的 server 不应被动到")
    }

    /// 停用两次安全：第二次（针对仍 enabled 的同一原始记录）磁盘里已无该 server，
    /// rawConfig 取不到 → 直接返回，不抛错；停用仓仍只保留第一次的原文。
    func testDisableTwiceIsSafe() throws {
        let (path, record) = try seedServer(name: "srv", config: [
            "command": "node", "env": ["A": "1"],
        ])
        let parking = parkingStore()

        try AgentToolsMCPScanner.disableServer(record, parking: parking)
        XCTAssertEqual(parking.load().count, 1)
        XCTAssertNil(try loadServers(path)["srv"])

        // 再用同一（enabled==true）记录停用：磁盘已无 srv，应安全 no-op。
        XCTAssertNoThrow(try AgentToolsMCPScanner.disableServer(record, parking: parking))
        XCTAssertEqual(parking.load().count, 1, "二次停用不应改变停用仓条数")
        let parked = try XCTUnwrap(parking.find(configPath: path, keyPath: "mcpServers", name: "srv"))
        XCTAssertEqual((parked.config["env"] as? [String: Any])?["A"] as? String, "1", "原文应保持第一次停用的内容")
    }

    // MARK: - enableServer

    /// 启用还原 EXACT 原文：env 的每个键值、unknown 键、嵌套 keyPath 全部一字不差回盘，
    /// 并清空停用仓。
    func testEnableRestoresExactOriginalConfigAndClearsParking() throws {
        let original: [String: Any] = [
            "command": "node",
            "args": ["server.js", "--flag"],
            "env": ["TOKEN": "secret-value", "REGION": "us-east"],
            "x-custom": "keep",
            "x-num": 7,
        ]
        let (path, record) = try seedServer(name: "srv", config: original)
        let parking = parkingStore()

        try AgentToolsMCPScanner.disableServer(record, parking: parking)
        XCTAssertNil(try loadServers(path)["srv"])

        try AgentToolsMCPScanner.enableServer(record, parking: parking)

        let restored = try XCTUnwrap(try loadServers(path)["srv"] as? [String: Any])
        XCTAssertEqual(restored["command"] as? String, "node")
        XCTAssertEqual(restored["args"] as? [String], ["server.js", "--flag"])
        let env = try XCTUnwrap(restored["env"] as? [String: Any])
        XCTAssertEqual(env["TOKEN"] as? String, "secret-value", "env 值应原样还原")
        XCTAssertEqual(env["REGION"] as? String, "us-east")
        XCTAssertEqual(env.count, 2, "env 不应多出键")
        XCTAssertEqual(restored["x-custom"] as? String, "keep", "未知键应还原")
        XCTAssertEqual(restored["x-num"] as? Int, 7)

        XCTAssertTrue(parking.load().isEmpty, "启用后应清出停用仓")
        XCTAssertNil(parking.find(configPath: path, keyPath: "mcpServers", name: "srv"))
    }

    /// HTTP 传输 server 的停用→启用往返：type/url/env 原样还原。
    func testDisableEnableRoundTripHTTP() throws {
        let original: [String: Any] = [
            "type": "http",
            "url": "https://api.example.com/mcp",
            "env": ["KEY": "v"],
            "x-meta": ["nested": true],
        ]
        let (path, record0) = try seedServer(name: "remote", config: original)
        // record 用 http 形态（更贴近真实扫描记录），但停用/启用只看 name/configPath/sourceKeyPath。
        let record = AgentToolsMCPServerRecord(
            id: record0.id, client: "X", name: "remote", transport: .http,
            command: nil, args: [], url: "https://api.example.com/mcp", envKeyCount: 1,
            configPath: path, sourceKeyPath: "mcpServers")
        let parking = parkingStore()

        try AgentToolsMCPScanner.disableServer(record, parking: parking)
        XCTAssertNil(try loadServers(path)["remote"])
        try AgentToolsMCPScanner.enableServer(record, parking: parking)

        let restored = try XCTUnwrap(try loadServers(path)["remote"] as? [String: Any])
        XCTAssertEqual(restored["type"] as? String, "http")
        XCTAssertEqual(restored["url"] as? String, "https://api.example.com/mcp")
        XCTAssertEqual((restored["env"] as? [String: Any])?["KEY"] as? String, "v")
        XCTAssertEqual((restored["x-meta"] as? [String: Any])?["nested"] as? Bool, true)
        XCTAssertTrue(parking.load().isEmpty)
    }

    /// 嵌套 keyPath（VS Code 的 mcp.servers）也能停用→启用回到原 keyPath。
    func testDisableEnableRoundTripNestedKeyPath() throws {
        let (path, record) = try seedServer(
            name: "vs", config: ["command": "c", "env": ["E": "1"]],
            keyPath: ["mcp", "servers"])
        let parking = parkingStore()

        try AgentToolsMCPScanner.disableServer(record, parking: parking)
        XCTAssertNil(try loadServers(path, keyPath: ["mcp", "servers"])["vs"])
        let parked = try XCTUnwrap(parking.find(configPath: path, keyPath: "mcp.servers", name: "vs"))
        XCTAssertEqual(parked.keyPath, "mcp.servers")

        try AgentToolsMCPScanner.enableServer(record, parking: parking)
        let restored = try XCTUnwrap(try loadServers(path, keyPath: ["mcp", "servers"])["vs"] as? [String: Any])
        XCTAssertEqual(restored["command"] as? String, "c")
        XCTAssertEqual((restored["env"] as? [String: Any])?["E"] as? String, "1")
        XCTAssertTrue(parking.load().isEmpty)
    }

    /// 停用仓里没有对应条目时，enableServer 是 no-op（不抛错，不动磁盘）。
    func testEnableWithoutParkedIsNoop() throws {
        let (path, record) = try seedServer(name: "srv", config: ["command": "c"])
        let parking = parkingStore()

        XCTAssertNoThrow(try AgentToolsMCPScanner.enableServer(record, parking: parking))

        XCTAssertNotNil(try loadServers(path)["srv"], "停用仓为空时启用不应动磁盘")
        XCTAssertTrue(parking.load().isEmpty)
    }

    // MARK: - scan(parking:)

    /// scan 注入带两条目的临时停用仓 → 这两条作为 enabled==false 的记录出现，名字 / 传输 / env 计数正确。
    /// 不断言磁盘来源 server（环境相关），只断言我们注入的这两台。
    func testScanReturnsParkedEntriesAsDisabledRecords() throws {
        let parking = parkingStore()
        // 两条不同形态：一台 stdio（带 env），一台 http。
        try parking.add(
            client: "Codex",
            configPath: tmp.appendingPathComponent("codex.json").path,
            keyPath: "mcpServers", name: "zeta",
            config: ["command": "node", "args": ["a.js"], "env": ["K1": "v1", "K2": "v2"]])
        try parking.add(
            client: "Cursor",
            configPath: tmp.appendingPathComponent("cursor.json").path,
            keyPath: "mcpServers", name: "alpha",
            config: ["type": "http", "url": "https://h/mcp"])
        XCTAssertEqual(parking.load().count, 2)

        let result = AgentToolsMCPScanner.scan(parking: parking)
        XCTAssertNil(result.error)

        // 只挑我们注入的两台（按名字）；磁盘来源的不管。
        let zeta = try XCTUnwrap(result.servers.first { $0.name == "zeta" })
        let alpha = try XCTUnwrap(result.servers.first { $0.name == "alpha" })

        XCTAssertFalse(zeta.enabled, "停用仓里的应为 enabled==false")
        XCTAssertFalse(alpha.enabled)

        XCTAssertEqual(zeta.client, "Codex")
        XCTAssertEqual(zeta.transport, .stdio)
        XCTAssertEqual(zeta.command, "node")
        XCTAssertEqual(zeta.args, ["a.js"])
        XCTAssertEqual(zeta.envKeyCount, 2, "env 键数应反映原文")

        XCTAssertEqual(alpha.client, "Cursor")
        XCTAssertEqual(alpha.transport, .http)
        XCTAssertEqual(alpha.url, "https://h/mcp")
        XCTAssertEqual(alpha.envKeyCount, 0)

        // 两台都能在结果里被找到。
        let disabledNames = Set(result.servers.filter { !$0.enabled }.map { $0.name })
        XCTAssertTrue(disabledNames.isSuperset(of: ["zeta", "alpha"]))
    }

    /// 停用后立刻 scan：磁盘已无该 server，但它以 enabled==false 出现在结果里（供重新启用）。
    func testScanShowsDisabledServerAfterDisable() throws {
        let (path, record) = try seedServer(name: "toggled", config: [
            "command": "node", "env": ["A": "1"],
        ])
        let parking = parkingStore()

        try AgentToolsMCPScanner.disableServer(record, parking: parking)
        XCTAssertNil(try loadServers(path)["toggled"])

        let result = AgentToolsMCPScanner.scan(parking: parking)
        let toggled = try XCTUnwrap(result.servers.first { $0.name == "toggled" && !$0.enabled })
        XCTAssertEqual(toggled.client, "X")
        XCTAssertEqual(toggled.configPath, path)
        XCTAssertEqual(toggled.sourceKeyPath, "mcpServers")
        XCTAssertEqual(toggled.command, "node")
        XCTAssertEqual(toggled.envKeyCount, 1)
    }

    /// 空停用仓的 scan 结果里没有任何我们的临时 server 名（且不抛错）。
    func testScanWithEmptyParkingHasNoInjectedNames() throws {
        let parking = parkingStore()
        XCTAssertTrue(parking.load().isEmpty)

        let result = AgentToolsMCPScanner.scan(parking: parking)
        XCTAssertFalse(result.servers.contains { $0.name == "zeta" || $0.name == "alpha" })
    }
}
