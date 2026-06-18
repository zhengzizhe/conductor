import XCTest
@testable import ConductorCore

final class HookConfigTests: XCTestCase {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("conductor-hookcfg-\(UUID().uuidString).json")
    }

    func testAddReadRemovePreservesOtherKeys() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        // 预置一个含敏感键 + 已有 hook 的配置
        let initial = """
        {"env":{"SECRET":"keep-me"},"model":"x","hooks":{"Stop":[{"hooks":[{"type":"command","command":"existing","timeout":5}]}]}}
        """
        try initial.write(to: url, atomically: true, encoding: .utf8)

        let doc = HookConfigDocument(url: url, source: .claude)
        XCTAssertEqual(doc.entries().count, 1)

        try doc.addCommand(event: "Stop", command: "echo hi #conductor:test", timeout: 5000)
        let entries = doc.entries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries.contains { $0.command == "echo hi #conductor:test" && $0.managedByConductor })
        XCTAssertTrue(entries.contains { $0.command == "existing" && !$0.managedByConductor })

        // 敏感键保留
        let reloaded = doc.load()
        XCTAssertEqual((reloaded["env"] as? [String: Any])?["SECRET"] as? String, "keep-me")

        // 重复添加不增加
        try doc.addCommand(event: "Stop", command: "echo hi #conductor:test")
        XCTAssertEqual(doc.entries().count, 2)

        // 按哨兵移除，只移我们的
        let removed = try doc.removeCommands(containing: "#conductor:test")
        XCTAssertEqual(removed, 1)
        let after = doc.entries()
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after.first?.command, "existing")
        XCTAssertEqual((doc.load()["env"] as? [String: Any])?["SECRET"] as? String, "keep-me")
    }

    /// timeout == nil → **不写** timeout 字段；给了值才写。
    /// （回归：重启用一个原本没 timeout 的 hook 不该被静默塞进 5000ms。）
    func testAddCommandNilTimeoutOmitsField() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = HookConfigDocument(url: url, source: .claude)
        try doc.addCommand(event: "Stop", command: "no-timeout-hook", timeout: nil)
        try doc.addCommand(event: "Stop", command: "with-timeout-hook", timeout: 5000)

        func raw(_ cmd: String) -> [String: Any]? {
            guard let hooks = doc.load()["hooks"] as? [String: Any],
                  let groups = hooks["Stop"] as? [[String: Any]] else { return nil }
            for g in groups {
                for h in (g["hooks"] as? [[String: Any]] ?? []) where (h["command"] as? String) == cmd { return h }
            }
            return nil
        }
        XCTAssertNil(raw("no-timeout-hook")?["timeout"])               // 没写 timeout
        XCTAssertEqual(raw("with-timeout-hook")?["timeout"] as? Int, 5000)
    }

    func testAddToFreshFile() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = HookConfigDocument(url: url, source: .codex)
        try doc.addCommand(event: "Stop", command: "do-thing #conductor:x")
        XCTAssertEqual(doc.entries().count, 1)
        XCTAssertEqual(doc.entries().first?.event, "Stop")
    }

    /// removeExact 只删命令完全相等的那条，不误伤共享子串的其它 hook。
    func testRemoveExactDoesNotTouchSubstringSiblings() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = HookConfigDocument(url: url, source: .claude)
        try doc.addCommand(event: "Stop", command: "echo hi")
        try doc.addCommand(event: "Stop", command: "echo hi there")   // 含 "echo hi" 子串
        XCTAssertEqual(doc.entries().count, 2)

        // 旧的 removeCommands(containing:) 会把两条都删掉；removeExact 只删一条。
        let removed = try doc.removeExact(event: "Stop", command: "echo hi")
        XCTAssertEqual(removed, 1)
        let after = doc.entries()
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after.first?.command, "echo hi there")
    }

    func testUpdateReplacesCommandAndEvent() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = HookConfigDocument(url: url, source: .claude)
        try doc.addCommand(event: "Stop", command: "old-cmd", timeout: 5000)

        try doc.update(event: "Stop", command: "old-cmd",
                       newEvent: "SessionStart", newCommand: "new-cmd", newTimeout: 1234)
        let entries = doc.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.event, "SessionStart")
        XCTAssertEqual(entries.first?.command, "new-cmd")
        XCTAssertEqual(entries.first?.timeout, 1234)
    }

    func testStableIdMatchesSourceEventCommand() {
        let e = HookEntry(source: .claude, event: "Stop", command: "x", timeout: nil)
        XCTAssertEqual(e.id, "claude:Stop:x")
        XCTAssertTrue(e.enabled)
        let disabled = HookEntry(source: .codex, event: "Stop", command: "y", timeout: 3, enabled: false)
        XCTAssertFalse(disabled.enabled)
    }

    func testRawHooksJSONReadEditPreserveAndClear() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        // 预置含敏感键的文件
        try "{\"env\":{\"K\":\"v\"},\"model\":\"x\"}".write(to: url, atomically: true, encoding: .utf8)
        let doc = HookConfigDocument(url: url, source: .claude)
        XCTAssertEqual(doc.rawHooksJSON(), "{}")

        // 直接编辑 hooks JSON 写入
        try doc.saveHooksJSON("""
        { "Stop": [ { "hooks": [ { "type": "command", "command": "echo hi", "timeout": 4321 } ] } ] }
        """)
        XCTAssertEqual(doc.entries().count, 1)
        XCTAssertEqual(doc.entries().first?.command, "echo hi")
        XCTAssertEqual(doc.entries().first?.timeout, 4321)
        // 其它键保留
        XCTAssertEqual((doc.load()["env"] as? [String: Any])?["K"] as? String, "v")
        XCTAssertEqual(doc.load()["model"] as? String, "x")

        // 解开 { "hooks": {...} } 外壳
        try doc.saveHooksJSON("""
        { "hooks": { "SessionStart": [ { "hooks": [ { "type": "command", "command": "boot" } ] } ] } }
        """)
        XCTAssertEqual(doc.entries().first?.event, "SessionStart")

        // 非法 JSON 抛错，且不改动文件
        XCTAssertThrowsError(try doc.saveHooksJSON("{ not valid"))
        XCTAssertEqual(doc.entries().first?.event, "SessionStart")

        // 空文本＝清空 hooks，其它键仍在
        try doc.saveHooksJSON("")
        XCTAssertTrue(doc.entries().isEmpty)
        XCTAssertEqual((doc.load()["env"] as? [String: Any])?["K"] as? String, "v")
    }

    func testHookParkingRoundTrip() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HookParkingStore(url: url)
        XCTAssertTrue(store.load().isEmpty)

        try store.add(ParkedHook(source: .claude, event: "Stop", command: "parked-cmd", timeout: 42))
        XCTAssertEqual(store.parked(for: .claude).count, 1)
        XCTAssertEqual(store.parked(for: .codex).count, 0)
        XCTAssertEqual(store.find(source: .claude, event: "Stop", command: "parked-cmd")?.timeout, 42)

        // 覆盖式 add（同 key）不重复
        try store.add(ParkedHook(source: .claude, event: "Stop", command: "parked-cmd", timeout: 99))
        XCTAssertEqual(store.parked(for: .claude).count, 1)
        XCTAssertEqual(store.find(source: .claude, event: "Stop", command: "parked-cmd")?.timeout, 99)

        XCTAssertTrue(try store.remove(source: .claude, event: "Stop", command: "parked-cmd"))
        XCTAssertTrue(store.load().isEmpty)
        XCTAssertFalse(try store.remove(source: .claude, event: "Stop", command: "parked-cmd"))
    }
}
