import XCTest
@testable import ConductorApp

/// MCP 纯模型单测：endpointLabel / transport.title&rawValue / recordID / enabled 默认值。
/// 不碰磁盘扫描（scan 读固定真实路径）；只用临时构造的值类型断言派生属性。
final class AgentToolsMCPModelTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("conductor-mcp-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // 构造一条记录（默认 enabled）；各字段可覆盖以驱动 endpointLabel 分支。
    private func makeRecord(
        transport: AgentToolsMCPTransport = .stdio,
        command: String? = nil,
        args: [String] = [],
        url: String? = nil,
        enabled: Bool = true
    ) -> AgentToolsMCPServerRecord {
        AgentToolsMCPServerRecord(
            id: "client:\(tmp.path):mcpServers:srv",
            client: "client",
            name: "srv",
            transport: transport,
            command: command,
            args: args,
            url: url,
            envKeyCount: 0,
            configPath: tmp.path,
            sourceKeyPath: "mcpServers",
            enabled: enabled)
    }

    // MARK: - endpointLabel: url 优先

    func testEndpointLabelPrefersURLWhenPresent() {
        // url 非空时直接返回 url，即便同时给了 command/args 也不拼命令。
        let record = makeRecord(
            transport: .http,
            command: "node", args: ["server.js"],
            url: "https://example.com/mcp")
        XCTAssertEqual(record.endpointLabel, "https://example.com/mcp")
    }

    func testEndpointLabelURLOnly() {
        let record = makeRecord(transport: .sse, url: "https://h/sse")
        XCTAssertEqual(record.endpointLabel, "https://h/sse")
    }

    func testEndpointLabelEmptyURLFallsThroughToCommand() {
        // 空字符串 url 视为缺失，应回退到命令拼接。
        let record = makeRecord(
            transport: .stdio,
            command: "node", args: ["x.js"],
            url: "")
        XCTAssertEqual(record.endpointLabel, "node x.js")
    }

    func testEndpointLabelEmptyURLEmptyCommandIsDash() {
        // url 与 command 都为空串 → "-"。
        let record = makeRecord(transport: .unknown, command: "", url: "")
        XCTAssertEqual(record.endpointLabel, "-")
    }

    // MARK: - endpointLabel: command + args 拼接

    func testEndpointLabelJoinsCommandAndArgs() {
        let record = makeRecord(
            transport: .stdio,
            command: "npx",
            args: ["-y", "@modelcontextprotocol/server-filesystem", "~"])
        XCTAssertEqual(record.endpointLabel, "npx -y @modelcontextprotocol/server-filesystem ~")
    }

    func testEndpointLabelCommandWithoutArgs() {
        let record = makeRecord(transport: .stdio, command: "uvx")
        XCTAssertEqual(record.endpointLabel, "uvx")
    }

    func testEndpointLabelCommandWithSingleArg() {
        let record = makeRecord(transport: .stdio, command: "uvx", args: ["mcp-server-fetch"])
        XCTAssertEqual(record.endpointLabel, "uvx mcp-server-fetch")
    }

    // MARK: - endpointLabel: 兜底 "-"

    func testEndpointLabelDashWhenNothingPresent() {
        // command/url 都为 nil → "-"。
        let record = makeRecord(transport: .unknown)
        XCTAssertEqual(record.endpointLabel, "-")
    }

    func testEndpointLabelNilCommandNilURLWithArgsStillDash() {
        // 只有 args、没有 command 时仍走兜底（command 为 nil 不进入拼接分支）。
        let record = makeRecord(transport: .unknown, command: nil, args: ["ignored"])
        XCTAssertEqual(record.endpointLabel, "-")
    }

    // MARK: - AgentToolsMCPTransport.title

    func testTransportTitleStdio() {
        XCTAssertEqual(AgentToolsMCPTransport.stdio.title, "stdio")
    }

    func testTransportTitleHTTP() {
        XCTAssertEqual(AgentToolsMCPTransport.http.title, "HTTP")
    }

    func testTransportTitleSSE() {
        XCTAssertEqual(AgentToolsMCPTransport.sse.title, "SSE")
    }

    func testTransportTitleUnknownIsNonEmpty() {
        // .unknown 走 L(...) 本地化，具体文案随语言变化，只断言非空即可。
        XCTAssertFalse(AgentToolsMCPTransport.unknown.title.isEmpty)
    }

    // MARK: - AgentToolsMCPTransport.rawValue

    func testTransportRawValues() {
        XCTAssertEqual(AgentToolsMCPTransport.stdio.rawValue, "stdio")
        XCTAssertEqual(AgentToolsMCPTransport.http.rawValue, "http")
        XCTAssertEqual(AgentToolsMCPTransport.sse.rawValue, "sse")
        XCTAssertEqual(AgentToolsMCPTransport.unknown.rawValue, "unknown")
    }

    func testTransportRoundTripsThroughRawValue() {
        for transport in [AgentToolsMCPTransport.stdio, .http, .sse, .unknown] {
            XCTAssertEqual(AgentToolsMCPTransport(rawValue: transport.rawValue), transport)
        }
    }

    // MARK: - ParkedMCPServer.recordID

    func testParkedRecordIDFormat() {
        let parked = ParkedMCPServer(
            client: "Claude Code",
            configPath: "/Users/x/.claude/mcp.json",
            keyPath: "mcpServers",
            name: "fs",
            config: [:])
        XCTAssertEqual(parked.recordID, "Claude Code:/Users/x/.claude/mcp.json:mcpServers:fs")
    }

    func testParkedRecordIDWithNestedKeyPath() {
        let parked = ParkedMCPServer(
            client: "VS Code",
            configPath: "/Users/x/settings.json",
            keyPath: "mcp.servers",
            name: "git",
            config: ["command": "uvx"])
        XCTAssertEqual(parked.recordID, "VS Code:/Users/x/settings.json:mcp.servers:git")
    }

    func testParkedRecordIDMatchesScanRecordIDFormat() {
        // recordID 必须与磁盘扫描记录的 id 同款（client:configPath:keyPath:name），
        // 否则启用回盘后选中态会对不上。
        let client = "Codex"
        let configPath = "/Users/x/.codex/mcp.json"
        let keyPath = "mcpServers"
        let name = "memory"
        let parked = ParkedMCPServer(
            client: client, configPath: configPath, keyPath: keyPath, name: name, config: [:])
        let record = AgentToolsMCPServerRecord(
            id: "\(client):\(configPath):\(keyPath):\(name)",
            client: client, name: name, transport: .stdio,
            command: "npx", args: [], url: nil, envKeyCount: 0,
            configPath: configPath, sourceKeyPath: keyPath)
        XCTAssertEqual(parked.recordID, record.id)
    }

    // MARK: - enabled 默认值

    func testRecordEnabledDefaultsToTrue() {
        // 不传 enabled 时应为 true。
        let record = AgentToolsMCPServerRecord(
            id: "x", client: "c", name: "n", transport: .stdio,
            command: "node", args: [], url: nil, envKeyCount: 0,
            configPath: tmp.path, sourceKeyPath: "mcpServers")
        XCTAssertTrue(record.enabled)
    }

    func testRecordEnabledCanBeSetFalse() {
        let record = makeRecord(transport: .stdio, command: "node", enabled: false)
        XCTAssertFalse(record.enabled)
    }
}
