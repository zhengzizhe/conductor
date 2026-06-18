import XCTest
@testable import ConductorCore

final class AIAgentConfigValidationTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("conductor-aiagentcfg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
    }

    // MARK: - 空输入

    func testEmptyListReturnsEmpty() {
        XCTAssertTrue(AIAgentConfig.validatedList([]).isEmpty)
    }

    // MARK: - 丢弃非法项（空 id / 空 command）

    func testDropsEntriesWithEmptyID() {
        let agents = [
            AIAgentConfig(id: "", title: "Nope", command: "run"),
            AIAgentConfig(id: "valid", title: "OK", command: "go"),
        ]
        let result = AIAgentConfig.validatedList(agents)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.id, "valid")
    }

    func testDropsEntriesWithEmptyCommand() {
        let agents = [
            AIAgentConfig(id: "claude", title: "Claude", command: ""),
            AIAgentConfig(id: "codex", title: "Codex", command: "codex"),
        ]
        let result = AIAgentConfig.validatedList(agents)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.id, "codex")
        XCTAssertEqual(result.first?.command, "codex")
    }

    /// 仅由空白构成的 id / command 在 trim 后视为空，应被丢弃。
    func testDropsWhitespaceOnlyIDAndCommand() {
        let agents = [
            AIAgentConfig(id: "   ", title: "Spaces", command: "run"),
            AIAgentConfig(id: "tabnewline", title: "Bad cmd", command: " \t\n "),
            AIAgentConfig(id: "good", title: "Good", command: "do-it"),
        ]
        let result = AIAgentConfig.validatedList(agents)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.id, "good")
    }

    func testAllInvalidProducesEmpty() {
        let agents = [
            AIAgentConfig(id: "", title: "a", command: ""),
            AIAgentConfig(id: "  ", title: "b", command: "x"),
            AIAgentConfig(id: "z", title: "c", command: "   "),
        ]
        XCTAssertTrue(AIAgentConfig.validatedList(agents).isEmpty)
    }

    // MARK: - 去重（按清洗后的 id，保留首次出现）

    func testDedupsByIDKeepingFirstOccurrence() {
        let agents = [
            AIAgentConfig(id: "claude", title: "First", command: "cmd-1"),
            AIAgentConfig(id: "claude", title: "Second", command: "cmd-2"),
        ]
        let result = AIAgentConfig.validatedList(agents)
        XCTAssertEqual(result.count, 1)
        // 首次出现胜出：title 与 command 都来自第一条
        XCTAssertEqual(result.first?.title, "First")
        XCTAssertEqual(result.first?.command, "cmd-1")
    }

    /// 去重发生在 trim 之后：" claude " 与 "claude" 视为同一 id。
    func testDedupUsesTrimmedID() {
        let agents = [
            AIAgentConfig(id: "  claude  ", title: "Padded", command: "cmd-a"),
            AIAgentConfig(id: "claude", title: "Tight", command: "cmd-b"),
        ]
        let result = AIAgentConfig.validatedList(agents)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.id, "claude")
        XCTAssertEqual(result.first?.command, "cmd-a")  // 第一条（padded）胜出
    }

    /// 去重对 id 大小写敏感（Set<String> 区分大小写）。
    func testDedupIsCaseSensitive() {
        let agents = [
            AIAgentConfig(id: "Claude", title: "Upper", command: "u"),
            AIAgentConfig(id: "claude", title: "Lower", command: "l"),
        ]
        let result = AIAgentConfig.validatedList(agents)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.map(\.id), ["Claude", "claude"])
    }

    // MARK: - 保序

    func testPreservesOrderOfFirstOccurrence() {
        let agents = [
            AIAgentConfig(id: "c", title: "C", command: "cc"),
            AIAgentConfig(id: "a", title: "A", command: "aa"),
            AIAgentConfig(id: "b", title: "B", command: "bb"),
            AIAgentConfig(id: "a", title: "A-dup", command: "aa2"),
            AIAgentConfig(id: "c", title: "C-dup", command: "cc2"),
        ]
        let result = AIAgentConfig.validatedList(agents)
        // 顺序为首次出现顺序：c, a, b；不是字母序，不被重复项打乱
        XCTAssertEqual(result.map(\.id), ["c", "a", "b"])
        XCTAssertEqual(result.map(\.command), ["cc", "aa", "bb"])
    }

    /// 非法项被丢弃后，剩余有效项仍按首次出现保序。
    func testOrderPreservedAcrossDroppedInvalids() {
        let agents = [
            AIAgentConfig(id: "first", title: "1", command: "f"),
            AIAgentConfig(id: "", title: "bad", command: "skip"),       // 丢弃
            AIAgentConfig(id: "second", title: "2", command: "s"),
            AIAgentConfig(id: "third", title: "3", command: "   "),     // 丢弃
            AIAgentConfig(id: "fourth", title: "4", command: "fo"),
        ]
        let result = AIAgentConfig.validatedList(agents)
        XCTAssertEqual(result.map(\.id), ["first", "second", "fourth"])
    }

    // MARK: - 清洗细节

    /// validated() 会 trim id / title / command，并在 title 为空时回落到 id。
    func testTrimsFieldsAndFallsBackTitleToID() {
        let agents = [
            AIAgentConfig(id: "  agentid  ", title: "   ", command: "  run-me  "),
        ]
        let result = AIAgentConfig.validatedList(agents)
        XCTAssertEqual(result.count, 1)
        let only = result[0]
        XCTAssertEqual(only.id, "agentid")
        XCTAssertEqual(only.command, "run-me")
        XCTAssertEqual(only.title, "agentid")  // 空 title 回落到清洗后的 id
    }

    func testNonEmptyTitleIsTrimmedButKept() {
        let agents = [
            AIAgentConfig(id: "x", title: "  Pretty Name  ", command: "x-cmd"),
        ]
        let result = AIAgentConfig.validatedList(agents)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.title, "Pretty Name")
    }

    /// enabled 标志在清洗中被原样保留。
    func testEnabledFlagPreserved() {
        let agents = [
            AIAgentConfig(id: "on", title: "On", command: "c1", enabled: true),
            AIAgentConfig(id: "off", title: "Off", command: "c2", enabled: false),
        ]
        let result = AIAgentConfig.validatedList(agents)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.first { $0.id == "on" }?.enabled, true)
        XCTAssertEqual(result.first { $0.id == "off" }?.enabled, false)
    }

    // MARK: - 经由 TerminalConfig.validated 的解码 + 验证路径

    /// AppConfig 解码后 validated() 会对 aiAgents 跑 validatedList：
    /// 去重 + 丢非法 + 保序在端到端路径上同样成立。
    func testValidationAppliedThroughAppConfigDecode() throws {
        let json = """
        {
          "terminal": {
            "aiAgents": [
              {"id": "claude", "title": "Claude", "command": "claude", "enabled": true},
              {"id": "claude", "title": "Dup", "command": "claude --resume", "enabled": false},
              {"id": "", "title": "Bad", "command": "nope", "enabled": true},
              {"id": "codex", "title": "Codex", "command": "codex", "enabled": true}
            ]
          }
        }
        """
        let url = tempDir.appendingPathComponent("config-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        let agents = decoded.validated().terminal.aiAgents

        XCTAssertEqual(agents.map(\.id), ["claude", "codex"])
        // 首次出现胜出：claude 的 command/enabled 来自第一条
        XCTAssertEqual(agents.first?.command, "claude")
        XCTAssertEqual(agents.first?.enabled, true)
    }

    /// 直接构造 TerminalConfig 再 validated()，验证 aiAgents 被清洗。
    func testTerminalConfigValidatedCleansAgents() {
        let cfg = TerminalConfig(aiAgents: [
            AIAgentConfig(id: "  dupe  ", title: "First", command: "a"),
            AIAgentConfig(id: "dupe", title: "Second", command: "b"),
            AIAgentConfig(id: "keep", title: "", command: "  k  "),
        ])
        let agents = cfg.validated().aiAgents
        XCTAssertEqual(agents.map(\.id), ["dupe", "keep"])
        XCTAssertEqual(agents.first?.command, "a")
        XCTAssertEqual(agents.last?.title, "keep")  // 空 title 回落到 id
        XCTAssertEqual(agents.last?.command, "k")   // command 被 trim
    }
}
