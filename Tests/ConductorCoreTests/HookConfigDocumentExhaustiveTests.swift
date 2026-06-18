import XCTest
@testable import ConductorCore

/// HookConfigDocument 的穷举式单测：addCommand（默认/自定义 timeout、去重、多事件）、
/// entries() 排序、removeExact（精确/事件作用域/子串兄弟安全/不存在返回 0）、
/// update（仅命令/改事件/改 timeout）、removeCommands(containing:)、所有变更下对无关键
/// （env/model/嵌套对象）的保留、load() 在缺失/空/垃圾文件返回 [:]、写回会创建父目录。
/// 注意：本机若只装了 Command Line Tools（无 Xcode）跑不了 XCTest；需在 CI 或带 Xcode 的机器上跑。
final class HookConfigDocumentExhaustiveTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("conductor-hookdoc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // 临时配置文件（父目录已存在）。
    private func tempFile(_ name: String = "settings.json") -> URL {
        tmp.appendingPathComponent("\(name)")
    }

    // 读取某事件下某命令的 timeout（直接从原始 JSON 取，绕开 entries 排序）。
    private func timeoutFor(_ doc: HookConfigDocument, event: String, command: String) -> Int? {
        let root = doc.load()
        guard let hooks = root["hooks"] as? [String: Any],
              let groups = hooks[event] as? [[String: Any]] else { return nil }
        for group in groups {
            let inner = group["hooks"] as? [[String: Any]] ?? []
            for h in inner where (h["command"] as? String) == command {
                return (h["timeout"] as? Int) ?? (h["timeout"] as? NSNumber)?.intValue
            }
        }
        return nil
    }

    // MARK: - addCommand

    func testAddCommandDefaultTimeoutIs5000() throws {
        let url = tempFile()
        let doc = HookConfigDocument(url: url, source: .claude)
        try doc.addCommand(event: "Stop", command: "echo a")
        XCTAssertEqual(doc.entries().count, 1)
        XCTAssertEqual(doc.entries().first?.timeout, 5000)
        XCTAssertEqual(timeoutFor(doc, event: "Stop", command: "echo a"), 5000)
    }

    func testAddCommandCustomTimeoutPersists() throws {
        let url = tempFile()
        let doc = HookConfigDocument(url: url, source: .codex)
        try doc.addCommand(event: "SessionStart", command: "boot", timeout: 250)
        XCTAssertEqual(doc.entries().first?.timeout, 250)
        XCTAssertEqual(timeoutFor(doc, event: "SessionStart", command: "boot"), 250)
    }

    func testAddCommandDedupsExactCommandPerEvent() throws {
        let url = tempFile()
        let doc = HookConfigDocument(url: url, source: .claude)
        try doc.addCommand(event: "Stop", command: "same", timeout: 1000)
        try doc.addCommand(event: "Stop", command: "same", timeout: 9999)
        XCTAssertEqual(doc.entries().count, 1)
        // 去重以已存在为准，第二次（含新 timeout）整条被跳过，保留首个 timeout。
        XCTAssertEqual(timeoutFor(doc, event: "Stop", command: "same"), 1000)
    }

    func testAddSameCommandUnderDifferentEventsAreDistinct() throws {
        let url = tempFile()
        let doc = HookConfigDocument(url: url, source: .claude)
        try doc.addCommand(event: "Stop", command: "shared")
        try doc.addCommand(event: "SessionStart", command: "shared")
        let entries = doc.entries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(Set(entries.map { $0.event }), ["Stop", "SessionStart"])
    }

    func testAddMultipleEventsAndCommands() throws {
        let url = tempFile()
        let doc = HookConfigDocument(url: url, source: .claude)
        try doc.addCommand(event: "Stop", command: "s1")
        try doc.addCommand(event: "Stop", command: "s2")
        try doc.addCommand(event: "SessionStart", command: "b1")
        try doc.addCommand(event: "UserPromptSubmit", command: "u1")
        XCTAssertEqual(doc.entries().count, 4)
        XCTAssertEqual(doc.entries().filter { $0.event == "Stop" }.count, 2)
    }

    // MARK: - entries() 排序

    func testEntriesSortedByEventThenCommand() throws {
        let url = tempFile()
        let doc = HookConfigDocument(url: url, source: .claude)
        // 故意乱序加入。
        try doc.addCommand(event: "Stop", command: "zeta")
        try doc.addCommand(event: "Stop", command: "alpha")
        try doc.addCommand(event: "Notification", command: "mid")
        try doc.addCommand(event: "SessionStart", command: "beta")

        let entries = doc.entries()
        let pairs = entries.map { [$0.event, $0.command] }
        // 先按 event 字典序（Notification < SessionStart < Stop），event 内再按 command。
        XCTAssertEqual(pairs, [
            ["Notification", "mid"],
            ["SessionStart", "beta"],
            ["Stop", "alpha"],
            ["Stop", "zeta"],
        ])
    }

    func testEntriesSourceMatchesDocumentSource() throws {
        let url = tempFile()
        let doc = HookConfigDocument(url: url, source: .codex)
        try doc.addCommand(event: "Stop", command: "x")
        XCTAssertEqual(doc.entries().first?.source, .codex)
        XCTAssertEqual(doc.entries().first?.id, "codex:Stop:x")
    }

    // MARK: - removeExact

    func testRemoveExactRemovesOnlyExactCommand() throws {
        let url = tempFile()
        let doc = HookConfigDocument(url: url, source: .claude)
        try doc.addCommand(event: "Stop", command: "echo hi")
        try doc.addCommand(event: "Stop", command: "echo hi there") // 含子串
        let removed = try doc.removeExact(event: "Stop", command: "echo hi")
        XCTAssertEqual(removed, 1)
        let after = doc.entries()
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after.first?.command, "echo hi there")
    }

    func testRemoveExactIsEventScoped() throws {
        let url = tempFile()
        let doc = HookConfigDocument(url: url, source: .claude)
        try doc.addCommand(event: "Stop", command: "shared")
        try doc.addCommand(event: "SessionStart", command: "shared")
        // 只删 Stop 下的；SessionStart 下同名命令不受影响。
        let removed = try doc.removeExact(event: "Stop", command: "shared")
        XCTAssertEqual(removed, 1)
        let after = doc.entries()
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after.first?.event, "SessionStart")
    }

    func testRemoveExactNonExistentReturnsZero() throws {
        let url = tempFile()
        let doc = HookConfigDocument(url: url, source: .claude)
        try doc.addCommand(event: "Stop", command: "real")
        XCTAssertEqual(try doc.removeExact(event: "Stop", command: "nope"), 0)
        XCTAssertEqual(try doc.removeExact(event: "MissingEvent", command: "real"), 0)
        XCTAssertEqual(doc.entries().count, 1)
    }

    func testRemoveExactEmptyEventKeyIsDropped() throws {
        let url = tempFile()
        let doc = HookConfigDocument(url: url, source: .claude)
        try doc.addCommand(event: "Stop", command: "only")
        _ = try doc.removeExact(event: "Stop", command: "only")
        XCTAssertTrue(doc.entries().isEmpty)
        // 空了的事件键应被移除，hooks 子树里不再含 Stop。
        let hooks = doc.load()["hooks"] as? [String: Any] ?? [:]
        XCTAssertNil(hooks["Stop"])
    }

    // MARK: - update

    func testUpdateCommandOnlyKeepsEvent() throws {
        let url = tempFile()
        let doc = HookConfigDocument(url: url, source: .claude)
        try doc.addCommand(event: "Stop", command: "old", timeout: 5000)
        try doc.update(event: "Stop", command: "old", newEvent: "Stop", newCommand: "new")
        let entries = doc.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.event, "Stop")
        XCTAssertEqual(entries.first?.command, "new")
        XCTAssertEqual(entries.first?.timeout, 5000) // 默认
    }

    func testUpdateChangesEvent() throws {
        let url = tempFile()
        let doc = HookConfigDocument(url: url, source: .claude)
        try doc.addCommand(event: "Stop", command: "cmd")
        try doc.update(event: "Stop", command: "cmd", newEvent: "SessionStart", newCommand: "cmd")
        let entries = doc.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.event, "SessionStart")
        // 旧事件被清空。
        XCTAssertNil((doc.load()["hooks"] as? [String: Any])?["Stop"])
    }

    func testUpdateChangesTimeout() throws {
        let url = tempFile()
        let doc = HookConfigDocument(url: url, source: .claude)
        try doc.addCommand(event: "Stop", command: "cmd", timeout: 1000)
        try doc.update(event: "Stop", command: "cmd", newEvent: "Stop", newCommand: "cmd", newTimeout: 7777)
        XCTAssertEqual(doc.entries().first?.timeout, 7777)
        XCTAssertEqual(timeoutFor(doc, event: "Stop", command: "cmd"), 7777)
    }

    // MARK: - removeCommands(containing:)

    func testRemoveCommandsContainingSentinel() throws {
        let url = tempFile()
        let doc = HookConfigDocument(url: url, source: .claude)
        try doc.addCommand(event: "Stop", command: "a #conductor:recipe1")
        try doc.addCommand(event: "SessionStart", command: "b #conductor:recipe1")
        try doc.addCommand(event: "Stop", command: "unrelated")
        let removed = try doc.removeCommands(containing: "#conductor:recipe1")
        XCTAssertEqual(removed, 2)
        let after = doc.entries()
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after.first?.command, "unrelated")
    }

    func testRemoveCommandsContainingNonMatchReturnsZero() throws {
        let url = tempFile()
        let doc = HookConfigDocument(url: url, source: .claude)
        try doc.addCommand(event: "Stop", command: "plain")
        XCTAssertEqual(try doc.removeCommands(containing: "#conductor:absent"), 0)
        XCTAssertEqual(doc.entries().count, 1)
    }

    // MARK: - 保留无关键

    func testAddPreservesEnvModelAndNestedKeys() throws {
        let url = tempFile()
        let initial = """
        {"env":{"SECRET":"keep-me","NESTED":{"deep":["a","b"]}},"model":"claude-x","permissions":{"allow":["Read"]}}
        """
        try initial.write(to: url, atomically: true, encoding: .utf8)
        let doc = HookConfigDocument(url: url, source: .claude)

        try doc.addCommand(event: "Stop", command: "hook #conductor:t")
        let r = doc.load()
        XCTAssertEqual((r["env"] as? [String: Any])?["SECRET"] as? String, "keep-me")
        XCTAssertEqual(((r["env"] as? [String: Any])?["NESTED"] as? [String: Any])?["deep"] as? [String], ["a", "b"])
        XCTAssertEqual(r["model"] as? String, "claude-x")
        XCTAssertEqual((r["permissions"] as? [String: Any])?["allow"] as? [String], ["Read"])
    }

    func testRemoveExactPreservesUnrelatedKeys() throws {
        let url = tempFile()
        let initial = """
        {"env":{"SECRET":"keep-me"},"model":"m","hooks":{"Stop":[{"hooks":[{"type":"command","command":"existing","timeout":5}]}]}}
        """
        try initial.write(to: url, atomically: true, encoding: .utf8)
        let doc = HookConfigDocument(url: url, source: .claude)

        XCTAssertEqual(try doc.removeExact(event: "Stop", command: "existing"), 1)
        let r = doc.load()
        XCTAssertEqual((r["env"] as? [String: Any])?["SECRET"] as? String, "keep-me")
        XCTAssertEqual(r["model"] as? String, "m")
    }

    func testUpdatePreservesUnrelatedKeys() throws {
        let url = tempFile()
        let initial = """
        {"env":{"SECRET":"keep-me"},"model":"m","hooks":{"Stop":[{"hooks":[{"type":"command","command":"old","timeout":5}]}]}}
        """
        try initial.write(to: url, atomically: true, encoding: .utf8)
        let doc = HookConfigDocument(url: url, source: .claude)

        try doc.update(event: "Stop", command: "old", newEvent: "SessionStart", newCommand: "new", newTimeout: 42)
        let r = doc.load()
        XCTAssertEqual((r["env"] as? [String: Any])?["SECRET"] as? String, "keep-me")
        XCTAssertEqual(r["model"] as? String, "m")
        XCTAssertEqual(doc.entries().first?.event, "SessionStart")
        XCTAssertEqual(doc.entries().first?.timeout, 42)
    }

    func testRemoveCommandsContainingPreservesUnrelatedKeys() throws {
        let url = tempFile()
        let initial = """
        {"env":{"SECRET":"keep-me"},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"x #conductor:r","timeout":5}]}]}}
        """
        try initial.write(to: url, atomically: true, encoding: .utf8)
        let doc = HookConfigDocument(url: url, source: .claude)

        XCTAssertEqual(try doc.removeCommands(containing: "#conductor:r"), 1)
        XCTAssertEqual((doc.load()["env"] as? [String: Any])?["SECRET"] as? String, "keep-me")
        XCTAssertTrue(doc.entries().isEmpty)
    }

    // MARK: - load() 边界

    func testLoadMissingFileReturnsEmpty() {
        let url = tempFile("does-not-exist.json")
        let doc = HookConfigDocument(url: url, source: .claude)
        XCTAssertTrue(doc.load().isEmpty)
        XCTAssertTrue(doc.entries().isEmpty)
    }

    func testLoadEmptyFileReturnsEmpty() throws {
        let url = tempFile("empty.json")
        try "".write(to: url, atomically: true, encoding: .utf8)
        let doc = HookConfigDocument(url: url, source: .claude)
        XCTAssertTrue(doc.load().isEmpty)
        XCTAssertTrue(doc.entries().isEmpty)
    }

    func testLoadGarbageFileReturnsEmpty() throws {
        let url = tempFile("garbage.json")
        try "not json at all {{{".write(to: url, atomically: true, encoding: .utf8)
        let doc = HookConfigDocument(url: url, source: .claude)
        XCTAssertTrue(doc.load().isEmpty)
        XCTAssertTrue(doc.entries().isEmpty)
    }

    func testLoadJSONArrayRootReturnsEmpty() throws {
        // 顶层是数组（非对象），强转 [String:Any] 失败应返回 [:]。
        let url = tempFile("array.json")
        try "[1,2,3]".write(to: url, atomically: true, encoding: .utf8)
        let doc = HookConfigDocument(url: url, source: .claude)
        XCTAssertTrue(doc.load().isEmpty)
    }

    // MARK: - 写回创建父目录

    func testWriteCreatesParentDirectory() throws {
        // url 指向尚不存在的多层子目录。
        let url = tmp
            .appendingPathComponent("a", isDirectory: true)
            .appendingPathComponent("b", isDirectory: true)
            .appendingPathComponent("settings.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))

        let doc = HookConfigDocument(url: url, source: .claude)
        try doc.addCommand(event: "Stop", command: "made-the-dir")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(doc.entries().first?.command, "made-the-dir")
    }
}
