import ConductorCore
import Foundation

/// 安装 / 检测「agent 完成 → conductor 通知」所需的 CLI hook：
/// - 写 `~/.conductor/bin/conductor-notify` 脚本：把通知请求写进 conductor 收件箱（HooksInbox 监听）；
/// - Claude：`~/.claude/settings.json` 的 `hooks.Stop` 加一条命令；
/// - Codex：`~/.codex/hooks.json` 的 `hooks.Stop` 加一条命令。
///
/// 命令带 `$CONDUCTOR_PANE_ID` 网关（只对 conductor 启动的 agent 触发）和 `#conductor:notify` 哨兵
/// （便于 Hook 管理面板识别与移除）。合并写入，保留配置里其它键（含敏感信息）。
enum HookInstaller {
    static let recipeID = "notify"

    struct Status {
        var scriptInstalled: Bool
        var codexConfigured: Bool
        var claudeConfigured: Bool
        var allDone: Bool { scriptInstalled && codexConfigured && claudeConfigured }
    }

    enum InstallError: LocalizedError {
        case write(String)
        var errorDescription: String? { switch self { case .write(let m): return m } }
    }

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    static var scriptURL: URL { home.appendingPathComponent(".conductor/bin/conductor-notify") }

    /// 写入 Stop hook 的命令（网关 + 哨兵）：完成通知 + 熄灭思考动效。
    static var stopCommand: String {
        "[ -n \"$CONDUCTOR_PANE_ID\" ] && '\(scriptURL.path)' >/dev/null 2>&1 || true #conductor:\(recipeID)"
    }

    /// 写入 UserPromptSubmit hook 的命令：发出「开始思考」信号（即时点亮转圈，不发通知）。
    static var busyCommand: String {
        "[ -n \"$CONDUCTOR_PANE_ID\" ] && '\(scriptURL.path)' busy >/dev/null 2>&1 || true #conductor:\(recipeID)"
    }

    /// 写入 SessionStart hook 的命令：尽早记录 agent 原生 session id（若该 CLI 在 stdin 里提供）。
    static var sessionStartCommand: String {
        "[ -n \"$CONDUCTOR_PANE_ID\" ] && '\(scriptURL.path)' session-start >/dev/null 2>&1 || true #conductor:\(recipeID)"
    }

    // MARK: - 状态

    static func status() -> Status {
        // 脚本内容不匹配视为未安装（旧版脚本没有 busy 信号，重装即升级）
        let scriptUpToDate = FileManager.default.isExecutableFile(atPath: scriptURL.path)
            && (try? String(contentsOf: scriptURL, encoding: .utf8)) == scriptBody
        return Status(
            scriptInstalled: scriptUpToDate,
            codexConfigured: configHasNotify(.codex),
            claudeConfigured: configHasNotify(.claude))
    }

    private static func configHasNotify(_ source: HookSource) -> Bool {
        let managed = HookConfigDocument(source: source).entries()
            .filter { $0.command.contains("#conductor:\(recipeID)") }
        // Stop（完成通知/熄灭）、UserPromptSubmit（点亮思考）与 SessionStart（记录 session）都在才算配置完整。
        return managed.contains { $0.event == HookEventName.stop }
            && managed.contains { $0.event == HookEventName.userPromptSubmit }
            && managed.contains { $0.event == HookEventName.sessionStart }
    }

    // MARK: - 安装

    @discardableResult
    static func installAll() throws -> Status {
        try installScript()
        do {
            for source in [HookSource.claude, .codex] {
                let doc = HookConfigDocument(source: source)
                // 改名迁移：清掉 cmux 时代的哨兵条目（指向已废弃的 ~/.cmux/bin/cmux-notify）。
                try doc.removeCommands(containing: "#cmux:")
                // 先清掉所有 #conductor:notify（含旧版残留在 Notification 事件上的 "blocked" 条——
                // 它会把"等待输入"误判成"完成"），再只装回该装的 3 个事件。幂等、顺带清残留。
                try doc.removeCommands(containing: "#conductor:\(recipeID)")
                try doc.addCommand(event: HookEventName.stop, command: stopCommand)
                try doc.addCommand(event: HookEventName.userPromptSubmit, command: busyCommand)
                try doc.addCommand(event: HookEventName.sessionStart, command: sessionStartCommand)
            }
        } catch {
            throw InstallError.write(L("写 hook 配置失败：%@", error.localizedDescription))
        }
        return status()
    }

    /// 启动时自动迁移：用户已装过完成通知 hook 的话，重装一遍（幂等）——
    /// 既刷新脚本到新版（未知参数不再误报完成），又清掉旧版残留在 Notification 事件上的 "blocked" 条。
    /// 没装过的用户不动（不擅自给人塞 hook）。
    static func migrateIfInstalled() {
        let installed = HookSource.allCases.contains { source in
            HookConfigDocument(source: source).entries()
                .contains { $0.command.contains("#conductor:\(recipeID)") }
        }
        guard installed else { return }
        _ = try? installAll()
    }

    static func installScript() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try scriptBody.write(to: scriptURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        } catch {
            throw InstallError.write(L("写 conductor-notify 脚本失败：%@", error.localizedDescription))
        }
    }

    // MARK: - conductor-notify 脚本内容

    static var scriptBody: String {
        """
        #!/bin/sh
        # conductor-notify —— 由 conductor 自动生成。把一条事件写入 conductor 收件箱（conductor.app 监听该目录）。
        # 用法：
        #   conductor-notify          Stop hook：完成通知 + 熄灭思考动效（点击通知跳回对应 pane）
        #   conductor-notify busy     UserPromptSubmit hook：点亮思考动效，不发通知
        #   conductor-notify session-start  SessionStart hook：记录原生 session id，不发通知
        INBOX="$HOME/Library/Application Support/conductor/hooks-inbox"
        mkdir -p "$INBOX"
        PANE="${CONDUCTOR_PANE_ID:-}"
        AGENT="${CONDUCTOR_AGENT_ID:-}"
        PAYLOAD=""
        if [ ! -t 0 ]; then
          PAYLOAD="$(cat 2>/dev/null || true)"
        fi

        esc() { printf '%s' "$1" | tr '\\n\\r\\t' '   ' | sed 's/\\\\/\\\\\\\\/g; s/"/\\\\"/g'; }
        json_get() {
          key="$1"
          printf '%s' "$PAYLOAD" | sed -n "s/.*\\"$key\\"[[:space:]]*:[[:space:]]*\\"\\([^\\"]*\\)\\".*/\\1/p" | head -n 1
        }
        first_nonempty() {
          for value in "$@"; do
            if [ -n "$value" ]; then printf '%s' "$value"; return 0; fi
          done
          return 1
        }

        SESSION_ID="$(first_nonempty "${CONDUCTOR_SESSION_ID:-}" "${CLAUDE_SESSION_ID:-}" "${CODEX_SESSION_ID:-}" "${SESSION_ID:-}" "$(json_get session_id)" "$(json_get sessionId)" "$(json_get sessionID)")"
        CWD="$(first_nonempty "$(json_get cwd)" "$(json_get working_directory)" "$(json_get workingDirectory)" "${PWD:-}")"
        TRANSCRIPT_PATH="$(first_nonempty "$(json_get transcript_path)" "$(json_get transcriptPath)")"
        LIFECYCLE="$(first_nonempty "$(json_get lifecycle)" "$(json_get state)")"

        write_event() {
          typ="$1"
          title="$2"
          message="$3"
          {
            printf '{"type":"%s","paneId":"%s"' "$(esc "$typ")" "$(esc "$PANE")"
            [ -n "$AGENT" ] && printf ',"agent":"%s"' "$(esc "$AGENT")"
            [ -n "$SESSION_ID" ] && printf ',"sessionId":"%s"' "$(esc "$SESSION_ID")"
            [ -n "$CWD" ] && printf ',"cwd":"%s"' "$(esc "$CWD")"
            [ -n "$TRANSCRIPT_PATH" ] && printf ',"transcriptPath":"%s"' "$(esc "$TRANSCRIPT_PATH")"
            [ -n "$LIFECYCLE" ] && printf ',"lifecycle":"%s"' "$(esc "$LIFECYCLE")"
            [ -n "$title" ] && printf ',"title":"%s"' "$(esc "$title")"
            [ -n "$message" ] && printf ',"message":"%s"' "$(esc "$message")"
            printf '}\\n'
          } > "$F"
        }

        F="$INBOX/$(date +%s)-$$.json"
        if [ "$1" = "busy" ]; then
          write_event "busy" "" ""
        elif [ "$1" = "session-start" ]; then
          write_event "sessionStart" "" ""
        elif [ -z "$1" ]; then
          # 无参 = Stop（agent 答完）→ 完成通知 + 熄灭思考动效
          write_event "done" "AI 已完成" "可以查看结果了"
        fi
        # 其它参数（如旧版 Notification hook 传的 "blocked"）：不动作。
        # 关键：绝不把"等待输入/通知"误判成"完成"——那会误报完成并把仍在运行的转圈熄掉。
        exit 0
        """
    }
}
