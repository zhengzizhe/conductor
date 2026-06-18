import XCTest
@testable import ConductorCore

/// 纯模型层测试：HookEntry / HookSource / HookEventName，不触碰磁盘或真实配置路径。
final class HookModelTests: XCTestCase {

    // MARK: - HookEntry.id 稳定性

    func testEntryIdFormatMatchesSourceEventCommand() {
        let e = HookEntry(source: .claude, event: "Stop", command: "echo hi", timeout: nil)
        XCTAssertEqual(e.id, "claude:Stop:echo hi")

        let codexEntry = HookEntry(source: .codex, event: "SessionStart", command: "run", timeout: 10)
        XCTAssertEqual(codexEntry.id, "codex:SessionStart:run")
    }

    func testEntryIdStableAcrossInstancesWithSameInputs() {
        let a = HookEntry(source: .claude, event: "Stop", command: "do-thing", timeout: 5000)
        let b = HookEntry(source: .claude, event: "Stop", command: "do-thing", timeout: 999, enabled: false)
        // id 只取决于 source/event/command —— timeout、enabled 不参与。
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(a.id, "claude:Stop:do-thing")
    }

    func testEntryIdDiffersWhenSourceEventOrCommandDiffers() {
        let base = HookEntry(source: .claude, event: "Stop", command: "x", timeout: nil)
        let diffSource = HookEntry(source: .codex, event: "Stop", command: "x", timeout: nil)
        let diffEvent = HookEntry(source: .claude, event: "SessionStart", command: "x", timeout: nil)
        let diffCommand = HookEntry(source: .claude, event: "Stop", command: "y", timeout: nil)

        XCTAssertNotEqual(base.id, diffSource.id)
        XCTAssertNotEqual(base.id, diffEvent.id)
        XCTAssertNotEqual(base.id, diffCommand.id)
    }

    func testEntryIdUsesRawValueNotDisplayName() {
        // rawValue 是小写 "claude"，displayName 是 "Claude" —— id 必须用 rawValue。
        let e = HookEntry(source: .claude, event: "Stop", command: "c", timeout: nil)
        XCTAssertTrue(e.id.hasPrefix("claude:"))
        XCTAssertFalse(e.id.hasPrefix("Claude:"))
    }

    // MARK: - managedByConductor 哨兵

    func testManagedByConductorTrueWhenSentinelPresent() {
        let e = HookEntry(source: .claude, event: "Stop", command: "echo hi #conductor:abc", timeout: nil)
        XCTAssertTrue(e.managedByConductor)
    }

    func testManagedByConductorFalseWithoutSentinel() {
        let e = HookEntry(source: .claude, event: "Stop", command: "echo hi", timeout: nil)
        XCTAssertFalse(e.managedByConductor)
    }

    func testManagedByConductorSentinelAnywhereInCommand() {
        // 哨兵在命令任意位置都算 conductor 安装的。
        let prefix = HookEntry(source: .codex, event: "Stop", command: "#conductor:x run", timeout: nil)
        let middle = HookEntry(source: .codex, event: "Stop", command: "a #conductor:x b", timeout: nil)
        let suffix = HookEntry(source: .codex, event: "Stop", command: "run #conductor:x", timeout: nil)
        XCTAssertTrue(prefix.managedByConductor)
        XCTAssertTrue(middle.managedByConductor)
        XCTAssertTrue(suffix.managedByConductor)
    }

    func testManagedByConductorFalseForSimilarButWrongSentinel() {
        // 缺冒号、缺 # 前缀都不算。
        let noColon = HookEntry(source: .claude, event: "Stop", command: "echo #conductor done", timeout: nil)
        let noHash = HookEntry(source: .claude, event: "Stop", command: "echo conductor:x", timeout: nil)
        XCTAssertFalse(noColon.managedByConductor)
        XCTAssertFalse(noHash.managedByConductor)
    }

    // MARK: - enabled 默认与显式

    func testEnabledDefaultsToTrue() {
        let e = HookEntry(source: .claude, event: "Stop", command: "x", timeout: nil)
        XCTAssertTrue(e.enabled)
    }

    func testEnabledExplicitFalse() {
        let e = HookEntry(source: .codex, event: "Stop", command: "x", timeout: 3, enabled: false)
        XCTAssertFalse(e.enabled)
    }

    func testEnabledExplicitTrue() {
        let e = HookEntry(source: .codex, event: "Stop", command: "x", timeout: 3, enabled: true)
        XCTAssertTrue(e.enabled)
    }

    // MARK: - HookEntry Equatable / 字段透传

    func testEntryStoresFields() {
        let e = HookEntry(source: .codex, event: "Notification", command: "cmd", timeout: 7, enabled: false)
        XCTAssertEqual(e.source, .codex)
        XCTAssertEqual(e.event, "Notification")
        XCTAssertEqual(e.command, "cmd")
        XCTAssertEqual(e.timeout, 7)
        XCTAssertFalse(e.enabled)
    }

    func testEntryNilTimeoutPreserved() {
        let e = HookEntry(source: .claude, event: "Stop", command: "x", timeout: nil)
        XCTAssertNil(e.timeout)
    }

    func testEntryEquatable() {
        let a = HookEntry(source: .claude, event: "Stop", command: "x", timeout: 5, enabled: true)
        let b = HookEntry(source: .claude, event: "Stop", command: "x", timeout: 5, enabled: true)
        let c = HookEntry(source: .claude, event: "Stop", command: "x", timeout: 6, enabled: true)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - HookSource rawValue / displayName

    func testSourceRawValues() {
        XCTAssertEqual(HookSource.claude.rawValue, "claude")
        XCTAssertEqual(HookSource.codex.rawValue, "codex")
    }

    func testSourceDisplayNames() {
        XCTAssertEqual(HookSource.claude.displayName, "Claude")
        XCTAssertEqual(HookSource.codex.displayName, "Codex")
    }

    func testSourceInitFromRawValue() {
        XCTAssertEqual(HookSource(rawValue: "claude"), .claude)
        XCTAssertEqual(HookSource(rawValue: "codex"), .codex)
        XCTAssertNil(HookSource(rawValue: "unknown"))
    }

    // MARK: - HookSource configURL 路径后缀

    func testSourceConfigURLSuffixes() {
        XCTAssertTrue(HookSource.claude.configURL.path.hasSuffix(".claude/settings.json"),
                      "claude configURL = \(HookSource.claude.configURL.path)")
        XCTAssertTrue(HookSource.codex.configURL.path.hasSuffix(".codex/hooks.json"),
                      "codex configURL = \(HookSource.codex.configURL.path)")
    }

    func testSourceConfigURLUnderHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertTrue(HookSource.claude.configURL.path.hasPrefix(home))
        XCTAssertTrue(HookSource.codex.configURL.path.hasPrefix(home))
    }

    func testSourceConfigURLFileNames() {
        XCTAssertEqual(HookSource.claude.configURL.lastPathComponent, "settings.json")
        XCTAssertEqual(HookSource.codex.configURL.lastPathComponent, "hooks.json")
    }

    // MARK: - HookSource allCases

    func testSourceAllCasesCountAndMembers() {
        XCTAssertEqual(HookSource.allCases.count, 2)
        XCTAssertTrue(HookSource.allCases.contains(.claude))
        XCTAssertTrue(HookSource.allCases.contains(.codex))
    }

    // MARK: - HookSource Codable round-trip

    func testSourceCodableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for source in HookSource.allCases {
            let data = try encoder.encode(source)
            let decoded = try decoder.decode(HookSource.self, from: data)
            XCTAssertEqual(decoded, source)
        }
    }

    func testSourceEncodesAsRawValueString() throws {
        let data = try JSONEncoder().encode(HookSource.claude)
        let json = String(data: data, encoding: .utf8)
        // String-raw enum 编码为带引号的 rawValue。
        XCTAssertEqual(json, "\"claude\"")
    }

    func testSourceDecodesFromRawValueString() throws {
        let data = Data("\"codex\"".utf8)
        let decoded = try JSONDecoder().decode(HookSource.self, from: data)
        XCTAssertEqual(decoded, .codex)
    }

    func testSourceArrayCodableRoundTrip() throws {
        let original = HookSource.allCases
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([HookSource].self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - HookEventName 常量

    func testEventNameConstants() {
        XCTAssertEqual(HookEventName.stop, "Stop")
        XCTAssertEqual(HookEventName.sessionStart, "SessionStart")
        XCTAssertEqual(HookEventName.userPromptSubmit, "UserPromptSubmit")
        XCTAssertEqual(HookEventName.subagentStop, "SubagentStop")
        XCTAssertEqual(HookEventName.notification, "Notification")
    }

    func testEventNameConstantsAreDistinct() {
        let all = [
            HookEventName.stop,
            HookEventName.sessionStart,
            HookEventName.userPromptSubmit,
            HookEventName.subagentStop,
            HookEventName.notification,
        ]
        XCTAssertEqual(Set(all).count, all.count)
    }

    func testEventNameUsableInEntryId() {
        // 常量直接喂给 HookEntry 应得到预期 id。
        let e = HookEntry(source: .claude, event: HookEventName.subagentStop, command: "x", timeout: nil)
        XCTAssertEqual(e.id, "claude:SubagentStop:x")
    }
}
