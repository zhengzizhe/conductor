import ConductorCore
import Foundation

/// 安装「agent 工具调用 → Conductor 审批」所需的 hook：
/// - 写 `~/.conductor/bin/conductor-approve`（python）：读 Claude 的 PreToolUse JSON，
///   经 `$CONDUCTOR_SOCKET_PATH` 调 `feed.request` 阻塞等决策，再按 Claude hook 契约返回 allow/deny；
/// - Claude：`~/.claude/settings.json` 的 `hooks.PreToolUse` 加一条命令。
///
/// 安全：socket 不可用 / 解析失败一律 **fail-open（exit 0、不输出）**——退回 Claude 自己的权限流程，
/// 绝不因 Conductor 没开就卡死 agent。命令带 `$CONDUCTOR_PANE_ID` 网关 + `#conductor:approve` 哨兵。
///
/// 注：脚本依赖 `python3`（开发机普遍有）。面向无 CLT 的终端用户分发时，后续可换成随包的小型 helper。
enum FeedHookInstaller {
    static let recipeID = "approve"

    struct Status {
        var scriptInstalled: Bool
        var claudeConfigured: Bool
        var allDone: Bool { scriptInstalled && claudeConfigured }
    }

    enum InstallError: LocalizedError {
        case write(String)
        var errorDescription: String? { switch self { case .write(let m): return m } }
    }

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    static var scriptURL: URL { home.appendingPathComponent(".conductor/bin/conductor-approve") }

    /// PreToolUse hook 命令：网关 + 脚本 + 哨兵。非 Conductor 启动的 agent（无 PANE_ID）走 `true` 放行。
    static var preToolUseCommand: String {
        "[ -n \"$CONDUCTOR_PANE_ID\" ] && '\(scriptURL.path)' || true #conductor:\(recipeID)"
    }

    static func status() -> Status {
        let scriptUpToDate = FileManager.default.isExecutableFile(atPath: scriptURL.path)
            && (try? String(contentsOf: scriptURL, encoding: .utf8)) == scriptBody
        let claudeConfigured = HookConfigDocument(source: .claude).entries()
            .contains { $0.command.contains("#conductor:\(recipeID)") && $0.event == HookEventName.preToolUse }
        return Status(scriptInstalled: scriptUpToDate, claudeConfigured: claudeConfigured)
    }

    @discardableResult
    static func installAll() throws -> Status {
        try installScript()
        do {
            let doc = HookConfigDocument(source: .claude)
            try doc.addCommand(event: HookEventName.preToolUse, command: preToolUseCommand)
        } catch {
            throw InstallError.write(L("写 hook 配置失败：%@", error.localizedDescription))
        }
        return status()
    }

    static func uninstall() throws {
        _ = try HookConfigDocument(source: .claude).removeCommands(containing: "#conductor:\(recipeID)")
    }

    static func installScript() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try scriptBody.write(to: scriptURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        } catch {
            throw InstallError.write(L("写 conductor-approve 脚本失败：%@", error.localizedDescription))
        }
    }

    // MARK: - conductor-approve 脚本内容（python3）

    static var scriptBody: String {
        """
        #!/usr/bin/env python3
        # conductor-approve —— 由 Conductor 自动生成。Claude Code PreToolUse hook：
        # 把工具调用经 Unix socket 交给 Conductor 审批，阻塞等决策，再按 hook 契约放行/拦截。
        # 任何异常或 socket 不可用都 fail-open（exit 0、不输出）→ 退回 Claude 自身权限流程。
        import sys, os, json, socket

        def main():
            raw = ""
            try:
                if not sys.stdin.isatty():
                    raw = sys.stdin.read()
            except Exception:
                raw = ""
            try:
                data = json.loads(raw) if raw.strip() else {}
            except Exception:
                data = {}

            tool = data.get("tool_name") or data.get("tool") or ""
            tool_input = data.get("tool_input") or {}
            detail = ""
            if isinstance(tool_input, dict):
                for k in ("command", "file_path", "path", "url", "pattern", "query"):
                    v = tool_input.get(k)
                    if isinstance(v, str) and v:
                        detail = v
                        break

            # 只拦「命令执行」类工具（最高价值、最低噪声，与 Codex 终端审批同口径）：
            # 读/搜/编辑等不打扰，直接放行走 Claude 自身流程，避免每个工具都弹宠物。
            tl = tool.lower()
            gated = (tool in ("Bash", "Shell", "Terminal", "Execute")
                     or "bash" in tl or "shell" in tl or "exec" in tl or "command" in tl)
            if not gated:
                sys.exit(0)

            sock_path = os.environ.get("CONDUCTOR_SOCKET_PATH") or os.environ.get("CONDUCTOR_SOCKET", "")
            pane = os.environ.get("CONDUCTOR_PANE_ID", "")
            agent = os.environ.get("CONDUCTOR_AGENT_ID", "")
            if not sock_path or not tool:
                sys.exit(0)  # 缺 socket / 工具名：放行

            req = {"id": 1, "method": "feed.request", "params": {
                "kind": "permission", "tool": tool, "detail": detail,
                "pane": pane, "agent": agent}}

            try:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.connect(sock_path)
                s.sendall((json.dumps(req) + "\\n").encode("utf-8"))
                buf = b""
                while b"\\n" not in buf:
                    chunk = s.recv(4096)
                    if not chunk:
                        break
                    buf += chunk
                s.close()
                line = buf.split(b"\\n")[0].decode("utf-8")
                resp = json.loads(line)
                decision = (resp.get("result") or {}).get("decision", "allow")
            except Exception:
                sys.exit(0)  # socket 不可用 / 协议异常：放行，绝不卡死 agent

            if decision == "deny":
                out = {"hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": "在 Conductor 审批中被拒绝"}}
            else:
                out = {"hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "allow",
                    "permissionDecisionReason": "在 Conductor 审批中已批准"}}
            sys.stdout.write(json.dumps(out))
            sys.exit(0)

        main()
        """
    }
}
