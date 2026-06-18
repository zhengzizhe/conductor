import XCTest
@testable import ConductorApp

/// 验证生成的 conductor-notify 脚本：跑一遍能写出可被 conductor 解析的合法 JSON，且带上 CONDUCTOR_PANE_ID。
final class HookInstallerScriptTests: XCTestCase {
    func testGeneratedScriptEmitsValidJSON() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("conductor-hook-test-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        // 写脚本
        let scriptURL = tmp.appendingPathComponent("conductor-notify")
        try HookInstaller.scriptBody.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        // 用一个隔离的 HOME 跑脚本（脚本写到 $HOME/Library/Application Support/conductor/hooks-inbox）
        let fakeHome = tmp.appendingPathComponent("home")
        try fm.createDirectory(at: fakeHome, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path]
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = fakeHome.path
        env["CONDUCTOR_PANE_ID"] = "p-test-123"
        process.environment = env
        let stdin = Pipe()
        process.standardInput = stdin
        try process.run()
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        // 检查收件箱里生成了合法 JSON
        let inbox = fakeHome
            .appendingPathComponent("Library/Application Support/conductor/hooks-inbox")
        let files = try fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        XCTAssertEqual(files.count, 1, "应恰好生成一个 JSON 文件")

        let data = try Data(contentsOf: files[0])
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["paneId"] as? String, "p-test-123")
        XCTAssertFalse((obj?["title"] as? String ?? "").isEmpty)
    }

    func testGeneratedScriptCapturesSessionBindingPayload() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("conductor-hook-test-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let scriptURL = tmp.appendingPathComponent("conductor-notify")
        try HookInstaller.scriptBody.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let fakeHome = tmp.appendingPathComponent("home")
        try fm.createDirectory(at: fakeHome, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path, "busy"]
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = fakeHome.path
        env["CONDUCTOR_PANE_ID"] = "p-test-456"
        env["CONDUCTOR_AGENT_ID"] = "codex"
        process.environment = env
        let stdin = Pipe()
        process.standardInput = stdin
        try process.run()
        let payload = #"{"session_id":"sess-456","cwd":"/tmp/project","transcript_path":"/tmp/project/rollout.jsonl","lifecycle":"running"}"#
        try stdin.fileHandleForWriting.write(contentsOf: Data(payload.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let inbox = fakeHome
            .appendingPathComponent("Library/Application Support/conductor/hooks-inbox")
        let files = try fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        XCTAssertEqual(files.count, 1, "应恰好生成一个 JSON 文件")

        let data = try Data(contentsOf: files[0])
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["type"] as? String, "busy")
        XCTAssertEqual(obj?["paneId"] as? String, "p-test-456")
        XCTAssertEqual(obj?["agent"] as? String, "codex")
        XCTAssertEqual(obj?["sessionId"] as? String, "sess-456")
        XCTAssertEqual(obj?["cwd"] as? String, "/tmp/project")
        XCTAssertEqual(obj?["transcriptPath"] as? String, "/tmp/project/rollout.jsonl")
        XCTAssertEqual(obj?["lifecycle"] as? String, "running")
    }

    /// 跑脚本，返回收件箱里生成的 json 文件。
    private func runScriptInbox(args: [String], payload: String = "") throws -> [URL] {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("conductor-hook-test-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let cleanupPath = tmp.path
        addTeardownBlock { try? FileManager.default.removeItem(atPath: cleanupPath) }
        let scriptURL = tmp.appendingPathComponent("conductor-notify")
        try HookInstaller.scriptBody.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        let fakeHome = tmp.appendingPathComponent("home")
        try fm.createDirectory(at: fakeHome, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path] + args
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = fakeHome.path
        env["CONDUCTOR_PANE_ID"] = "p-test"
        process.environment = env
        let stdin = Pipe()
        process.standardInput = stdin
        try process.run()
        if !payload.isEmpty { try stdin.fileHandleForWriting.write(contentsOf: Data(payload.utf8)) }
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let inbox = fakeHome.appendingPathComponent("Library/Application Support/conductor/hooks-inbox")
        guard fm.fileExists(atPath: inbox.path) else { return [] }
        return try fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
    }

    /// 回归：旧版 Notification hook 传的 "blocked"（及任何未知参数）必须 no-op——
    /// 不能写"完成"事件（否则误报通知 + 误灭转圈）。
    func testUnknownArgIsNoOp() throws {
        XCTAssertEqual(try runScriptInbox(args: ["blocked"]).count, 0)
        XCTAssertEqual(try runScriptInbox(args: ["whatever"]).count, 0)
    }

    func testNoArgEmitsDone() throws {
        let files = try runScriptInbox(args: [])
        XCTAssertEqual(files.count, 1)
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: files[0])) as? [String: Any]
        XCTAssertEqual(obj?["type"] as? String, "done")
    }
}
