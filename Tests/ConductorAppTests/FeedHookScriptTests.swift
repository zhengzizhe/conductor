@testable import ConductorApp
import Foundation
import XCTest

/// 端到端验 conductor-approve 脚本：真 AutomationSocketServer + 真跑脚本，
/// 断言 allow/deny 映射、发出的请求 JSON 正确、socket 不可用时 fail-open。
final class FeedHookScriptTests: XCTestCase {
    private var tempDir: URL!
    private var python: String?

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("feed-hook-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        python = Self.locatePython3()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private static func locatePython3() -> String? {
        for path in ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    private func writeScript() throws -> URL {
        let url = tempDir.appendingPathComponent("conductor-approve")
        try FeedHookInstaller.scriptBody.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// 启动一个返回固定决策的 socket 服务器；返回 (server, socketURL, 捕获到的请求行)。
    private func startServer(decision: String, capture: RequestCapture? = nil)
        throws -> (AutomationSocketServer, URL) {
        // socket 路径要短（sun_path 限制；服务器对 >100 字符直接拒启）。
        let sockURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdr-\(UUID().uuidString.prefix(8)).sock")
        let body = "{\"id\":1,\"ok\":true,\"result\":{\"decision\":\"\(decision)\"}}"
        let server = AutomationSocketServer(socketURL: sockURL) { line in
            capture?.store(String(data: line, encoding: .utf8) ?? "")
            return Data(body.utf8)
        }
        guard server.start() else { throw XCTSkip("socket 启动失败") }
        return (server, sockURL)
    }

    /// 跑脚本，喂 stdin + 环境，返回 stdout。
    private func runScript(_ script: URL, socket: String?, stdin: String,
                           python: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [script.path]
        var env = ProcessInfo.processInfo.environment
        env["CONDUCTOR_PANE_ID"] = "p-test"
        env["CONDUCTOR_AGENT_ID"] = "claude"
        if let socket {
            env["CONDUCTOR_SOCKET_PATH"] = socket
            env["CONDUCTOR_SOCKET"] = socket
        } else {
            env["CONDUCTOR_SOCKET_PATH"] = nil
            env["CONDUCTOR_SOCKET"] = nil
        }
        process.environment = env
        let inPipe = Pipe(), outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        do { try process.run() } catch { return "" }
        inPipe.fileHandleForWriting.write(Data(stdin.utf8))
        try? inPipe.fileHandleForWriting.close()
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: out, encoding: .utf8) ?? ""
    }

    func testDenyMappingAndRequestShape() throws {
        let python = try XCTUnwrap(python, "未找到 python3，跳过").self
        let script = try writeScript()
        let capture = RequestCapture()
        let (server, sock) = try startServer(decision: "deny", capture: capture)
        defer { server.stop() }

        let out = runScript(script, socket: sock.path,
                            stdin: "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git push --force\"}}",
                            python: python)
        XCTAssertTrue(out.contains("\"permissionDecision\": \"deny\""), "应映射为 deny，实际：\(out)")

        let req = capture.value
        XCTAssertTrue(req.contains("\"method\": \"feed.request\"") || req.contains("\"method\":\"feed.request\""))
        XCTAssertTrue(req.contains("\"tool\": \"Bash\"") || req.contains("\"tool\":\"Bash\""))
        XCTAssertTrue(req.contains("git push --force"), "请求应带命令明细，实际：\(req)")
    }

    func testAllowMapping() throws {
        let python = try XCTUnwrap(python, "未找到 python3，跳过").self
        let script = try writeScript()
        let (server, sock) = try startServer(decision: "allow")
        defer { server.stop() }
        let out = runScript(script, socket: sock.path,
                            stdin: "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls -la\"}}",
                            python: python)
        XCTAssertTrue(out.contains("\"permissionDecision\": \"allow\""), "应映射为 allow，实际：\(out)")
    }

    /// 只拦命令类工具：读/搜/编辑等非命令工具应直接放行（exit 0、无输出、不连 socket）。
    func testNonCommandToolPassesThrough() throws {
        let python = try XCTUnwrap(python, "未找到 python3，跳过").self
        let script = try writeScript()
        let (server, sock) = try startServer(decision: "deny")   // 即便服务器要拒，也不该被问到
        defer { server.stop() }
        for tool in ["Read", "Grep", "Edit", "WebFetch"] {
            let out = runScript(script, socket: sock.path,
                                stdin: "{\"tool_name\":\"\(tool)\",\"tool_input\":{\"file_path\":\"/x\"}}",
                                python: python)
            XCTAssertTrue(out.isEmpty, "\(tool) 非命令类应放行（无输出），实际：\(out)")
        }
    }

    func testFailOpenWhenSocketMissing() throws {
        let python = try XCTUnwrap(python, "未找到 python3，跳过").self
        let script = try writeScript()
        // socket 指向不存在的路径 → 脚本应 fail-open：exit 0、无输出
        let out = runScript(script, socket: tempDir.appendingPathComponent("nope.sock").path,
                            stdin: "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"}}",
                            python: python)
        XCTAssertTrue(out.isEmpty, "socket 不可用应静默放行（无输出），实际：\(out)")
    }

    func testNoToolNameFailsOpen() throws {
        let python = try XCTUnwrap(python, "未找到 python3，跳过").self
        let script = try writeScript()
        let (server, sock) = try startServer(decision: "deny")
        defer { server.stop() }
        let out = runScript(script, socket: sock.path, stdin: "{}", python: python)
        XCTAssertTrue(out.isEmpty, "无工具名应放行（无输出），实际：\(out)")
    }
}

/// 线程安全地捕获 server handler 收到的请求行。
final class RequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = ""
    func store(_ s: String) { lock.lock(); stored = s; lock.unlock() }
    var value: String { lock.lock(); defer { lock.unlock() }; return stored }
}
