import XCTest
@testable import ConductorApp

/// MCP 编辑/删除后端单测：updateServer / rawConfig / removeServer 在临时配置文件上的行为。
/// 覆盖：stdio 改写并保留 args、HTTP 带 env、SSE 写 type、改名删旧键、改名不误伤同文件兄弟、
/// removeServer 保留兄弟、rawConfig 对缺失 server 返回 nil。
/// 注意：本机若只装了 Command Line Tools（无 Xcode）跑不了 XCTest；需在 CI 或带 Xcode 的机器上跑。
final class AgentToolsMCPUpdateRemoveTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("conductor-mcp-edit-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - 临时配置 seeding 辅助（与 AgentToolsMCPManagementTests 不同的方法名）

    /// 在单个临时文件里写入一个或多个 server（root[keyPath...] = [name: config]），返回该文件路径。
    /// 支持 1 级或 2 级 keyPath。
    @discardableResult
    private func plantConfig(fileName: String,
                            servers: [String: [String: Any]],
                            keyPath: [String] = ["mcpServers"]) throws -> String {
        let path = tmp.appendingPathComponent(fileName).path
        var root: [String: Any] = [:]
        if keyPath.count == 1 {
            root[keyPath[0]] = servers
        } else {
            root[keyPath[0]] = [keyPath[1]: servers]
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted])
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    /// 为某个已落盘的 server 构造一个最小 record，供 updateServer/rawConfig/removeServer 使用。
    /// 这些 API 只用到 record 的 name / configPath / sourceKeyPath，所以其它字段可填占位值。
    private func recordFor(name: String,
                          configPath: String,
                          keyPath: [String] = ["mcpServers"]) -> AgentToolsMCPServerRecord {
        AgentToolsMCPServerRecord(
            id: "T:\(configPath):\(keyPath.joined(separator: ".")):\(name)",
            client: "T", name: name, transport: .unknown,
            command: nil, args: [], url: nil, envKeyCount: 0,
            configPath: configPath, sourceKeyPath: keyPath.joined(separator: "."))
    }

    /// 读出某文件 keyPath 下的 servers 字典。
    private func readServers(_ path: String, keyPath: [String] = ["mcpServers"]) throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        for key in keyPath {
            obj = obj[key] as? [String: Any] ?? [:]
        }
        return obj
    }

    /// 把 JSON 读回来的 args（可能是 NSArray / [Any]）规整成 [String]。
    private func stringArgs(_ raw: Any?) -> [String] {
        if let a = raw as? [String] { return a }
        if let a = raw as? [Any] { return a.compactMap { $0 as? String } }
        return []
    }

    // MARK: - updateServer: stdio with args preserved + rewritten

    func testUpdateStdioRewritesArgsAndPreservesUnknownKeys() throws {
        let path = try plantConfig(fileName: "stdio-args.json", servers: [
            "tool": [
                "command": "node",
                "args": ["old-server.js", "--port", "1"],
                "x-note": "keep-me",
            ],
        ])
        let record = recordFor(name: "tool", configPath: path)
        try AgentToolsMCPScanner.updateServer(
            original: record, newName: "tool", transport: .stdio,
            command: "node", args: ["new-server.js", "--port", "2", "--verbose"],
            url: nil, env: [:])

        let s = try XCTUnwrap(try readServers(path)["tool"] as? [String: Any])
        XCTAssertEqual(s["command"] as? String, "node")
        XCTAssertEqual(stringArgs(s["args"]), ["new-server.js", "--port", "2", "--verbose"],
                       "新 args 应整段替换旧 args")
        XCTAssertEqual(s["x-note"] as? String, "keep-me", "未知键应保留")
        XCTAssertNil(s["url"])
        XCTAssertNil(s["type"])
    }

    func testUpdateStdioWithEmptyArgsRemovesArgsKey() throws {
        let path = try plantConfig(fileName: "stdio-empty-args.json", servers: [
            "tool": ["command": "node", "args": ["x.js"]],
        ])
        let record = recordFor(name: "tool", configPath: path)
        try AgentToolsMCPScanner.updateServer(
            original: record, newName: "tool", transport: .stdio,
            command: "python", args: [], url: nil, env: [:])

        let s = try XCTUnwrap(try readServers(path)["tool"] as? [String: Any])
        XCTAssertEqual(s["command"] as? String, "python")
        XCTAssertNil(s["args"], "空 args 应移除 args 键")
    }

    // MARK: - updateServer: HTTP with env

    func testUpdateHTTPWritesTypeUrlAndEnv() throws {
        let path = try plantConfig(fileName: "http-env.json", servers: [
            "remote": ["command": "node", "args": ["legacy.js"]],
        ])
        let record = recordFor(name: "remote", configPath: path)
        try AgentToolsMCPScanner.updateServer(
            original: record, newName: "remote", transport: .http,
            command: nil, args: [],
            url: "https://api.example.com/mcp",
            env: ["TOKEN": "abc123", "REGION": "us"])

        let s = try XCTUnwrap(try readServers(path)["remote"] as? [String: Any])
        XCTAssertEqual(s["type"] as? String, "http")
        XCTAssertEqual(s["url"] as? String, "https://api.example.com/mcp")
        let env = try XCTUnwrap(s["env"] as? [String: Any])
        XCTAssertEqual(env["TOKEN"] as? String, "abc123")
        XCTAssertEqual(env["REGION"] as? String, "us")
        XCTAssertNil(s["command"], "切到 http 应清掉 stdio 的 command")
        XCTAssertNil(s["args"], "切到 http 应清掉 stdio 的 args")
    }

    func testUpdateHTTPEmptyEnvRemovesEnvKey() throws {
        let path = try plantConfig(fileName: "http-clear-env.json", servers: [
            "remote": ["type": "http", "url": "https://old/mcp", "env": ["A": "1"]],
        ])
        let record = recordFor(name: "remote", configPath: path)
        try AgentToolsMCPScanner.updateServer(
            original: record, newName: "remote", transport: .http,
            command: nil, args: [], url: "https://new/mcp", env: [:])

        let s = try XCTUnwrap(try readServers(path)["remote"] as? [String: Any])
        XCTAssertEqual(s["url"] as? String, "https://new/mcp")
        XCTAssertNil(s["env"], "清空 env 应移除 env 键")
    }

    // MARK: - updateServer: SSE type written

    func testUpdateSSEWritesTypeSSEAndClearsCommand() throws {
        let path = try plantConfig(fileName: "sse.json", servers: [
            "stream": ["command": "node", "args": ["x.js"], "x-keep": true],
        ])
        let record = recordFor(name: "stream", configPath: path)
        try AgentToolsMCPScanner.updateServer(
            original: record, newName: "stream", transport: .sse,
            command: nil, args: [], url: "https://events.example.com/sse", env: [:])

        let s = try XCTUnwrap(try readServers(path)["stream"] as? [String: Any])
        XCTAssertEqual(s["type"] as? String, "sse")
        XCTAssertEqual(s["url"] as? String, "https://events.example.com/sse")
        XCTAssertNil(s["command"], "切到 sse 应清掉 command")
        XCTAssertNil(s["args"], "切到 sse 应清掉 args")
        XCTAssertEqual(s["x-keep"] as? Bool, true, "未知键应保留")
    }

    // MARK: - rename: leaves no old key

    func testRenameRemovesOldKeyAndWritesNew() throws {
        let path = try plantConfig(fileName: "rename.json", servers: [
            "before": ["command": "node", "args": ["a.js"], "env": ["K": "v"], "x-tag": 7],
        ])
        let record = recordFor(name: "before", configPath: path)
        try AgentToolsMCPScanner.updateServer(
            original: record, newName: "after", transport: .stdio,
            command: "node", args: ["a.js"], url: nil, env: ["K": "v"])

        let servers = try readServers(path)
        XCTAssertNil(servers["before"], "改名后旧键应消失")
        let after = try XCTUnwrap(servers["after"] as? [String: Any])
        XCTAssertEqual(after["command"] as? String, "node")
        XCTAssertEqual(stringArgs(after["args"]), ["a.js"])
        XCTAssertEqual((after["env"] as? [String: Any])?["K"] as? String, "v")
        XCTAssertEqual(after["x-tag"] as? Int, 7, "改名应保留未知键")
    }

    // MARK: - rename does NOT clobber a sibling server in same file

    func testRenameDoesNotClobberSiblingInSameFile() throws {
        let path = try plantConfig(fileName: "rename-sibling.json", servers: [
            "alpha": ["command": "alpha-cmd", "args": ["a"]],
            "beta": ["command": "beta-cmd", "args": ["b"], "x-id": "BETA"],
        ])
        let record = recordFor(name: "alpha", configPath: path)
        // 把 alpha 改名成 gamma，绝不能动到 beta。
        try AgentToolsMCPScanner.updateServer(
            original: record, newName: "gamma", transport: .stdio,
            command: "gamma-cmd", args: ["g"], url: nil, env: [:])

        let servers = try readServers(path)
        XCTAssertNil(servers["alpha"], "alpha 旧键应消失")
        let gamma = try XCTUnwrap(servers["gamma"] as? [String: Any])
        XCTAssertEqual(gamma["command"] as? String, "gamma-cmd")

        let beta = try XCTUnwrap(servers["beta"] as? [String: Any], "兄弟 server beta 应原样保留")
        XCTAssertEqual(beta["command"] as? String, "beta-cmd")
        XCTAssertEqual(stringArgs(beta["args"]), ["b"])
        XCTAssertEqual(beta["x-id"] as? String, "BETA")
        XCTAssertEqual(servers.count, 2, "应仍是两台 server（gamma + beta）")
    }

    func testRenameToExistingSiblingNameOverwritesThatSibling() throws {
        // 边界：把 alpha 改成已存在的 beta —— servers[beta] 会被 alpha 的新配置覆盖，
        // 且 alpha 旧键被删，结果只剩一台名为 beta 的 server。
        let path = try plantConfig(fileName: "rename-onto-sibling.json", servers: [
            "alpha": ["command": "alpha-cmd"],
            "beta": ["command": "beta-cmd"],
        ])
        let record = recordFor(name: "alpha", configPath: path)
        try AgentToolsMCPScanner.updateServer(
            original: record, newName: "beta", transport: .stdio,
            command: "alpha-cmd", args: [], url: nil, env: [:])

        let servers = try readServers(path)
        XCTAssertNil(servers["alpha"])
        let beta = try XCTUnwrap(servers["beta"] as? [String: Any])
        XCTAssertEqual(beta["command"] as? String, "alpha-cmd", "同名目标应被新配置覆盖")
        XCTAssertEqual(servers.count, 1)
    }

    // MARK: - removeServer leaves sibling servers intact

    func testRemoveServerLeavesSiblingsIntact() throws {
        let path = try plantConfig(fileName: "remove-sibling.json", servers: [
            "one": ["command": "c1"],
            "two": ["command": "c2", "args": ["x"]],
            "three": ["type": "http", "url": "https://three/mcp"],
        ])
        let record = recordFor(name: "two", configPath: path)
        try AgentToolsMCPScanner.removeServer(record)

        let servers = try readServers(path)
        XCTAssertNil(servers["two"], "目标 server 应被删除")
        XCTAssertNotNil(servers["one"], "兄弟 one 应保留")
        XCTAssertNotNil(servers["three"], "兄弟 three 应保留")
        XCTAssertEqual((servers["one"] as? [String: Any])?["command"] as? String, "c1")
        XCTAssertEqual((servers["three"] as? [String: Any])?["url"] as? String, "https://three/mcp")
        XCTAssertEqual(servers.count, 2)
    }

    func testRemoveServerNestedKeyPathLeavesSiblingIntact() throws {
        let path = try plantConfig(fileName: "remove-nested.json", servers: [
            "keep": ["command": "k"],
            "drop": ["command": "d"],
        ], keyPath: ["mcp", "servers"])
        let record = recordFor(name: "drop", configPath: path, keyPath: ["mcp", "servers"])
        try AgentToolsMCPScanner.removeServer(record)

        let servers = try readServers(path, keyPath: ["mcp", "servers"])
        XCTAssertNil(servers["drop"])
        XCTAssertNotNil(servers["keep"], "嵌套 keyPath 下兄弟也应保留")
        XCTAssertEqual(servers.count, 1)
    }

    // MARK: - rawConfig

    func testRawConfigReturnsFullConfigForExistingServer() throws {
        let path = try plantConfig(fileName: "raw.json", servers: [
            "srv": ["command": "node", "args": ["s.js"], "env": ["K": "v"], "x-extra": true],
        ])
        let record = recordFor(name: "srv", configPath: path)
        let raw = try XCTUnwrap(AgentToolsMCPScanner.rawConfig(for: record))
        XCTAssertEqual(raw["command"] as? String, "node")
        XCTAssertEqual(stringArgs(raw["args"]), ["s.js"])
        XCTAssertEqual((raw["env"] as? [String: Any])?["K"] as? String, "v")
        XCTAssertEqual(raw["x-extra"] as? Bool, true)
    }

    func testRawConfigReturnsNilForMissingServer() throws {
        let path = try plantConfig(fileName: "raw-missing.json", servers: [
            "present": ["command": "node"],
        ])
        let record = recordFor(name: "absent", configPath: path)
        XCTAssertNil(AgentToolsMCPScanner.rawConfig(for: record),
                     "不存在的 server 应返回 nil")
    }

    func testRawConfigReturnsNilForMissingFile() {
        let missing = tmp.appendingPathComponent("does-not-exist.json").path
        let record = recordFor(name: "any", configPath: missing)
        XCTAssertNil(AgentToolsMCPScanner.rawConfig(for: record),
                     "文件不存在时应返回 nil")
    }
}
