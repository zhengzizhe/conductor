import Foundation

/// 内置 Agent 的工具审批桥：把 pi 桥接扩展发来的审批请求映射成 Conductor 的 `FeedRequest`，
/// 再把 `FeedDecision` 映射回扩展 UI 应答。
///
/// **桥接契约**（M2 的 `conductor-bridge.ts` 须遵守）：工具执行前，扩展 `tool_call` 钩子调
/// `ctx.ui.confirm(title, message)`，其中 `title == bridgeTag`、`message` 是 JSON 串
/// `{"tool": "<名>", "command": "<细节或省略>", "cwd": "<可选>"}`。审批结果 allow/deny 即够——
/// **记忆/作用域（once/tool/category）完全留在 Conductor 侧**（FeedPolicyStore），pi 只收最终布尔。
public enum ApprovalMapper {
    /// confirm 的 title 标记"这是一条要走 Feed 的工具审批"，把它和普通对话区分开。
    public static let bridgeTag = "conductor-feed"

    /// pi 工具名 → 动作类别。修正 `FeedActionCategory.infer` 对 pi **小写**名的盲区
    /// （尤其 `find`/`ls`：infer 会落 `.other`、只读却误弹 Feed）。未知名委托回 infer 的启发式。
    public static func category(forPiTool tool: String) -> FeedActionCategory {
        switch tool.lowercased() {
        case "bash", "shell", "sh": return .executeCommand
        case "read", "grep", "find", "ls", "glob", "tree": return .readFile
        case "write", "edit", "multiedit", "apply_patch", "applypatch": return .writeFile
        case "webfetch", "websearch", "fetch", "web_search", "web_fetch": return .network
        default: return FeedActionCategory.infer(toolName: tool)
        }
    }

    /// 把桥接扩展的 confirm 请求解析成 `FeedRequest`。只认带 `bridgeTag` 的工具审批；
    /// 其它对话（或解析失败）返回 nil——调用方按"未识别对话"处理（M3：回 cancelled 避免 pi 永久阻塞）。
    public static func feedRequest(for ui: ExtensionUIRequest,
                                   agent: String = "builtin",
                                   paneID: String? = nil,
                                   cwd: String? = nil) -> FeedRequest? {
        guard ui.method == .confirm,
              ui.title == bridgeTag,
              let message = ui.message,
              let object = (try? JSONDecoder().decode(JSONValue.self, from: Data(message.utf8)))?.objectValue,
              let tool = object["tool"]?.stringValue, !tool.isEmpty
        else { return nil }
        let rawDetail = object["command"]?.stringValue
        let detail = (rawDetail?.isEmpty ?? true) ? nil : rawDetail
        return FeedRequest(
            paneID: paneID,
            agent: agent,
            cwd: cwd ?? object["cwd"]?.stringValue,
            kind: .permission(tool: tool, category: category(forPiTool: tool), detail: detail))
    }

    /// `FeedDecision` → 回给 pi 的 `extension_ui_response`。confirm 语义：allow→`confirmed:true`、deny→`false`。
    public static func response(for decision: FeedDecision, requestID: String) -> ExtensionUIResponse {
        ExtensionUIResponse(id: requestID, confirmed: decision.isAllow)
    }

    /// 收到一条扩展 UI 请求后该怎么处置——把 session 的决策逻辑收成纯函数，可单测、不碰 Process。
    public enum DialogAction: Equatable, Sendable {
        /// 我们认得的工具审批：提交 Feed 拿决策后再回 `response(for:requestID:)`。
        case approveViaFeed(FeedRequest)
        /// 未识别的对话方法（select/input/editor 等）：回 cancelled，**别让 pi 永久阻塞**。
        case respondCancelled(id: String)
        /// fire-and-forget（notify/setStatus/setWidget…）：无需应答。
        case ignore
    }

    public static func dialogAction(for ui: ExtensionUIRequest,
                                    agent: String = "builtin",
                                    paneID: String? = nil,
                                    cwd: String? = nil) -> DialogAction {
        if let request = feedRequest(for: ui, agent: agent, paneID: paneID, cwd: cwd) {
            return .approveViaFeed(request)
        }
        // 带 bridgeTag 的 confirm 本就是"该走 Feed 的工具审批"，只是 message 解析失败（桥协议漂移/字段类型不对）：
        // 仍兜底提交一条审批 surface 给用户，而不是静默 respondCancelled(=拒) 掉每个工具调用、无任何痕迹。
        if ui.method == .confirm, ui.title == bridgeTag {
            return .approveViaFeed(FeedRequest(
                paneID: paneID, agent: agent, cwd: cwd,
                kind: .permission(tool: "unknown", category: .other, detail: ui.message)))
        }
        return ui.method.isDialog ? .respondCancelled(id: ui.id) : .ignore
    }
}
