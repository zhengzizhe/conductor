import AppKit
import ConductorCore
import Foundation

/// 自动化方法分发：一行 JSON 请求 → 查表 → 调 coordinator → 一行 JSON 响应。
/// 全部在 MainActor 执行（与 UI 同一事实源，天然无竞态）。
@MainActor
final class AutomationService {
    private weak var coordinator: AppCoordinator?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    /// socket 服务器的行处理入口。
    nonisolated func handleLine(_ line: Data) async -> Data {
        let request: AutomationRequest
        do {
            request = try AutomationCodec.decodeRequest(line)
        } catch {
            return AutomationCodec.encode(AutomationResponse(
                id: nil, error: .badRequest("请求不是合法 JSON：\(error.localizedDescription)")))
        }
        let response = await dispatch(request)
        return AutomationCodec.encode(response)
    }

    private func dispatch(_ request: AutomationRequest) async -> AutomationResponse {
        guard let coordinator else {
            return AutomationResponse(id: request.id, error: .internalError("应用尚未就绪"))
        }
        do {
            let result = try await handle(method: request.method, params: request.parameters,
                                          coordinator: coordinator)
            return AutomationResponse(id: request.id, result: result)
        } catch let error as AutomationError {
            return AutomationResponse(id: request.id, error: error)
        } catch {
            return AutomationResponse(id: request.id, error: .internalError("\(error)"))
        }
    }

    // MARK: - 方法表

    private func handle(method: String, params: [String: JSONValue],
                        coordinator c: AppCoordinator) async throws -> JSONValue {
        func str(_ key: String) -> String? { params[key]?.stringValue }
        func requireStr(_ key: String) throws -> String {
            guard let value = str(key), !value.isEmpty else {
                throw AutomationError.badRequest("缺少参数：\(key)")
            }
            return value
        }

        switch method {
        // —— App ——
        case AutomationMethod.appPing:
            return .object([
                "pong": .bool(true),
                "protocol": .int(AutomationProtocol.version),
                "app": .string("Conductor"),
                "socket": .string(AutomationSocketServer.defaultSocketURL.path),
            ])
        case AutomationMethod.appStatus:
            return c.automationStatusJSON()
        case AutomationMethod.appMethods:
            return .array(AutomationMethod.all.map(JSONValue.string))
        case AutomationMethod.appOpenTools:
            let rawModule = str("module") ?? AgentToolsManagementModule.overview.rawValue
            guard let module = AgentToolsManagementModule(rawValue: rawModule) else {
                let supported = AgentToolsManagementModule.railModules.map(\.rawValue).joined(separator: ", ")
                throw AutomationError.badRequest("module 只支持：\(supported)")
            }
            c.openAgentToolsManagement(module)
            return .object([
                "module": .string(module.rawValue),
                "window": .string("agent-tools"),
            ])
        case AutomationMethod.appOpenTaskCards:
            c.openTaskCards()
            return .object([
                "window": .string("task-cards"),
                "panel": c.taskCardsPanel.automationSnapshot(),
            ])
        #if DEBUG
        case "debug-agent-tools-smoke-test":
            return try debugAgentToolsSmokeTest()
        case "debug-snapshot-window":
            return try debugSnapshotWindow(coordinator: c, params: params)
        case "debug-set-ui-section":
            if let s = str("mcp") { AgentToolsDebugUI.mcpSection = s }
            if let s = str("hooks") { AgentToolsDebugUI.hooksSection = s }
            return .object([
                "mcp": AgentToolsDebugUI.mcpSection.map(JSONValue.string) ?? .null,
                "hooks": AgentToolsDebugUI.hooksSection.map(JSONValue.string) ?? .null,
            ])
        #endif

        // —— 工作区 ——
        case AutomationMethod.workspaceList:
            return .array(c.store.workspaces.map { c.automationDescribe(workspace: $0) })
        case AutomationMethod.workspaceCurrent:
            return c.automationDescribe(workspace: try c.automationFindWorkspace(nil))
        case AutomationMethod.workspaceSelect:
            try c.automationSelectWorkspace(try requireStr("workspace"))
            return .bool(true)
        case AutomationMethod.workspaceCreate:
            let workspace = try c.automationNewWorkspace(path: try requireStr("path"),
                                                         name: str("name"))
            return c.automationDescribe(workspace: workspace)
        case AutomationMethod.workspaceRename:
            let workspace = try c.automationFindWorkspace(try requireStr("workspace"))
            c.renameWorkspace(workspace.id, to: try requireStr("name"))
            return .bool(true)
        case AutomationMethod.workspaceClose:
            let workspace = try c.automationFindWorkspace(try requireStr("workspace"))
            c.removeWorkspace(workspace.id)
            return .bool(true)
        case AutomationMethod.workspaceTree:
            return try c.automationTree(workspaceRef: str("workspace"))
        case AutomationMethod.workspaceStatusSet:
            let workspace = try c.automationFindWorkspace(str("workspace"))
            c.workspaceMetadata.setStatus(workspace: workspace.id,
                                          key: try requireStr("key"),
                                          text: try requireStr("text"),
                                          color: str("color"),
                                          icon: str("icon"))
            return .bool(true)
        case AutomationMethod.workspaceStatusList:
            let workspace = try c.automationFindWorkspace(str("workspace"))
            return .array(c.workspaceMetadata.statuses(for: workspace.id).map { status in
                .object([
                    "key": .string(status.key),
                    "text": .string(status.text),
                    "color": status.color.map(JSONValue.string) ?? .null,
                    "icon": status.icon.map(JSONValue.string) ?? .null,
                ])
            })
        case AutomationMethod.workspaceStatusClear:
            let workspace = try c.automationFindWorkspace(str("workspace"))
            c.workspaceMetadata.clearStatus(workspace: workspace.id, key: str("key"))
            return .bool(true)
        case AutomationMethod.workspaceProgressSet:
            let workspace = try c.automationFindWorkspace(str("workspace"))
            guard let value = params["value"]?.doubleValue, (0...1).contains(value) else {
                throw AutomationError.badRequest("value 需在 0-1 之间")
            }
            c.workspaceMetadata.setProgress(workspace: workspace.id, value: value,
                                            label: str("label"))
            return .bool(true)
        case AutomationMethod.workspaceProgressClear:
            let workspace = try c.automationFindWorkspace(str("workspace"))
            c.workspaceMetadata.clearProgress(workspace: workspace.id)
            return .bool(true)
        case AutomationMethod.workspaceLogAppend:
            let workspace = try c.automationFindWorkspace(str("workspace"))
            c.workspaceMetadata.appendLog(workspace: workspace.id,
                                          text: try requireStr("text"),
                                          level: str("level") ?? "info",
                                          source: str("source"))
            return .bool(true)
        case AutomationMethod.workspaceLogList:
            let workspace = try c.automationFindWorkspace(str("workspace"))
            let limit = params["limit"]?.intValue ?? 50
            return .array(c.workspaceMetadata.logs(for: workspace.id, limit: limit).map { entry in
                .object([
                    "time": .double(entry.time.timeIntervalSince1970),
                    "level": .string(entry.level),
                    "source": entry.source.map(JSONValue.string) ?? .null,
                    "text": .string(entry.text),
                ])
            })
        case AutomationMethod.workspaceLogClear:
            let workspace = try c.automationFindWorkspace(str("workspace"))
            c.workspaceMetadata.clearLog(workspace: workspace.id)
            return .bool(true)

        // —— 标签 ——
        case AutomationMethod.tabList:
            let workspace = try c.automationFindWorkspace(str("workspace"))
            return .array(workspace.tabs.map { c.automationDescribe(tab: $0, in: workspace) })
        case AutomationMethod.tabCreate:
            let (tab, pane) = try c.automationNewTab(workspaceRef: str("workspace"),
                                                     cwd: str("cwd"))
            return .object(["tab": .string(tab.value), "pane": .string(pane.value)])
        case AutomationMethod.tabSelect:
            try c.automationSelectTab(try requireStr("tab"), workspaceRef: str("workspace"))
            return .bool(true)
        case AutomationMethod.tabRename:
            let workspace = try c.automationFindWorkspace(str("workspace"))
            let tab = try c.automationFindTab(try requireStr("tab"), in: workspace)
            c.renameTab(tab.id, to: try requireStr("title"))
            return .bool(true)
        case AutomationMethod.tabClose:
            try c.automationCloseTab(try requireStr("tab"), workspaceRef: str("workspace"))
            return .bool(true)

        // —— pane ——
        case AutomationMethod.paneList:
            let workspace = try c.automationFindWorkspace(str("workspace"))
            let tab = try c.automationFindTab(str("tab"), in: workspace)
            return .array(tab.rootSplit.leaves().map { c.automationDescribe(pane: $0, in: tab) })
        case AutomationMethod.paneCreate:
            let (tab, pane) = try c.automationNewTab(workspaceRef: str("workspace"),
                                                     cwd: str("cwd"))
            return .object(["tab": .string(tab.value), "pane": .string(pane.value)])
        case AutomationMethod.paneSplit:
            let direction = str("direction") ?? "right"
            let axis: SplitAxis
            switch direction {
            case "right", "vertical": axis = .vertical
            case "down", "horizontal": axis = .horizontal
            default: throw AutomationError.badRequest("direction 只支持 right / down")
            }
            let pane = try c.automationSplit(paneRef: str("pane"), axis: axis, cwd: str("cwd"))
            return .object(["pane": .string(pane.value)])
        case AutomationMethod.paneFocus:
            try c.automationFocusPane(try requireStr("pane"))
            return .bool(true)
        case AutomationMethod.paneClose:
            try c.automationClosePane(str("pane"))
            return .bool(true)

        // —— 终端 I/O ——
        case AutomationMethod.agentSend:
            try c.automationSendText(paneRef: str("pane"),
                                     text: try requireStr("text"),
                                     submit: params["submit"]?.boolValue ?? true)
            return .bool(true)
        case AutomationMethod.paneKeys:
            let keys = (params["keys"]?.arrayValue ?? []).compactMap(\.stringValue)
            guard !keys.isEmpty else { throw AutomationError.badRequest("缺少参数：keys") }
            try c.automationSendKeys(paneRef: str("pane"), keys: keys)
            return .bool(true)
        case AutomationMethod.paneRead:
            let text = try c.automationReadScreen(paneRef: str("pane"),
                                                  scrollback: params["scrollback"]?.boolValue ?? false)
            return .object(["text": .string(text)])
        case AutomationMethod.paneResumeSet:
            let binding = try c.automationSetSurfaceResume(
                paneRef: str("pane"),
                kind: str("kind") ?? "shell",
                checkpoint: str("checkpoint"),
                command: try requireStr("command"),
                autoResume: params["autoResume"]?.boolValue ?? false,
                trusted: params["trusted"]?.boolValue ?? false)
            return c.automationDescribe(binding: binding)
        case AutomationMethod.paneResumeShow:
            guard let binding = try c.automationShowSurfaceResume(paneRef: str("pane")) else {
                return .null
            }
            return c.automationDescribe(binding: binding)
        case AutomationMethod.paneResumeClear:
            let removed = try c.automationClearSurfaceResume(paneRef: str("pane"))
            return removed.map { c.automationDescribe(binding: $0) } ?? .null

        // —— 通知 ——
        case AutomationMethod.paneNotify:
            c.automationNotify(paneRef: str("pane"),
                               title: str("title") ?? "",
                               body: try requireStr("message"))
            return .bool(true)

        // —— Agent jobs ——
        case AutomationMethod.agentRun:
            return try c.automationRunAgent(
                agent: try requireStr("agent"),
                command: str("command"),
                cwd: str("cwd"),
                prompt: str("prompt"),
                submit: params["submit"]?.boolValue ?? true)
        case AutomationMethod.agentStatus:
            return try c.automationAgentStatus(jobRef: str("job"))
        case AutomationMethod.agentResult:
            return try c.automationAgentResult(jobRef: str("job"))

        // —— Activity / events ——
        case AutomationMethod.activityList:
            return .array(c.automationActivityList(limit: params["limit"]?.intValue ?? 20))
        case AutomationMethod.eventsRecent:
            return .array(c.automationRecentEvents(limit: params["limit"]?.intValue ?? 20))

        // —— Feed 审批 ——
        // 阻塞式：命中规则/默认即刻返回，否则挂起等 GUI/CLI 决策（agent 的 hook 等这条回包）。
        case AutomationMethod.feedRequest:
            let request = try Self.parseFeedRequest(params: params, requireStr: requireStr, str: str)
            let decision = await c.feedCenter.submit(request)
            return Self.feedDecisionJSON(decision)
        case AutomationMethod.feedList:
            return .array(c.feedCenter.pendingRequests().map(Self.feedRequestJSON))
        case AutomationMethod.feedApprove:
            let scope = FeedScope(rawValue: str("scope") ?? "once") ?? .once
            return .bool(c.feedCenter.resolve(id: try requireStr("id"), decision: .allow(scope)))
        case AutomationMethod.feedDeny:
            let scope = FeedScope(rawValue: str("scope") ?? "once") ?? .once
            return .bool(c.feedCenter.resolve(id: try requireStr("id"), decision: .deny(scope)))
        case AutomationMethod.feedAnswer:
            guard let option = params["option"]?.intValue else {
                throw AutomationError.badRequest("缺少参数：option")
            }
            return .bool(c.feedCenter.resolve(id: try requireStr("id"),
                                              decision: .answer(optionIndex: option)))

        default:
            throw AutomationError.unknownMethod(method)
        }
    }

    // MARK: - Feed 编解码

    private static func parseFeedRequest(
        params: [String: JSONValue],
        requireStr: (String) throws -> String,
        str: (String) -> String?
    ) throws -> FeedRequest {
        let kind: FeedRequestKind
        switch str("kind") ?? "permission" {
        case "permission":
            let tool = try requireStr("tool")
            let category = str("category").flatMap(FeedActionCategory.init(rawValue:))
                ?? FeedActionCategory.infer(toolName: tool)
            kind = .permission(tool: tool, category: category, detail: str("detail"))
        case "exitPlan", "exit-plan":
            kind = .exitPlan(plan: try requireStr("plan"))
        case "question":
            let options = (params["options"]?.arrayValue ?? []).compactMap(\.stringValue)
            kind = .question(prompt: try requireStr("prompt"), options: options)
        default:
            throw AutomationError.badRequest("kind 只支持 permission / exitPlan / question")
        }
        return FeedRequest(paneID: str("pane"), agent: str("agent"), cwd: str("cwd"), kind: kind)
    }

    private static func feedDecisionJSON(_ decision: FeedDecision) -> JSONValue {
        switch decision {
        case .allow: return .object(["decision": .string("allow")])
        case .deny: return .object(["decision": .string("deny")])
        case let .answer(index): return .object(["decision": .string("answer"), "option": .int(index)])
        }
    }

    private static func feedRequestJSON(_ request: FeedRequest) -> JSONValue {
        var obj: [String: JSONValue] = [
            "id": .string(request.id),
            "summary": .string(request.summary),
            "createdAt": .double(request.createdAt.timeIntervalSince1970),
            "pane": request.paneID.map(JSONValue.string) ?? .null,
            "agent": request.agent.map(JSONValue.string) ?? .null,
        ]
        switch request.kind {
        case let .permission(tool, category, detail):
            obj["kind"] = .string("permission")
            obj["tool"] = .string(tool)
            obj["category"] = .string(category.rawValue)
            obj["detail"] = detail.map(JSONValue.string) ?? .null
        case let .exitPlan(plan):
            obj["kind"] = .string("exitPlan")
            obj["plan"] = .string(plan)
        case let .question(prompt, options):
            obj["kind"] = .string("question")
            obj["prompt"] = .string(prompt)
            obj["options"] = .array(options.map(JSONValue.string))
        }
        return .object(obj)
    }

    #if DEBUG
    /// 把已打开的 AgentTools 窗口内容渲染成 PNG（NSView 自快照，不需要屏幕录制权限）。
    /// 需先用 app.open-tools 打开窗口并留出一帧布局时间。返回写出的文件路径。
    private func debugSnapshotWindow(coordinator c: AppCoordinator,
                                     params: [String: JSONValue]) throws -> JSONValue {
        guard let window = c.agentToolsWindowController?.window,
              let view = window.contentView else {
            throw AutomationError.internalError("AgentTools 窗口未打开（先调用 app.open-tools）")
        }
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw AutomationError.internalError("无法为窗口建立位图（bounds=\(bounds)）")
        }
        view.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw AutomationError.internalError("PNG 编码失败")
        }
        let name = (params["name"]?.stringValue ?? "agent-tools")
            .replacingOccurrences(of: "/", with: "_")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conductor-ui", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).png")
        try png.write(to: url)
        return .object([
            "path": .string(url.path),
            "width": .int(Int(rep.pixelsWide)),
            "height": .int(Int(rep.pixelsHigh)),
        ])
    }

    private func debugAgentToolsSmokeTest() throws -> JSONValue {
        func fail(_ message: String) throws -> Never {
            throw AutomationError.internalError(message)
        }

        let mcpSteps = try AgentToolsMCPScanner.debugSmokeTest()

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conductor-hooks-smoke-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent("settings.json")
        let doc = HookConfigDocument(url: url, source: .claude)
        let command = "printf smoke #conductor:smoke"
        try doc.addCommand(event: HookEventName.stop, command: command, timeout: 3210)

        var entries = doc.entries()
        guard entries.count == 1,
              entries[0].event == HookEventName.stop,
              entries[0].command == command,
              entries[0].timeout == 3210,
              entries[0].managedByConductor else {
            try fail("hook command was not written correctly")
        }

        try doc.addCommand(event: HookEventName.stop, command: command, timeout: 3210)
        entries = doc.entries()
        guard entries.count == 1 else {
            try fail("duplicate hook command was written")
        }

        let removed = try doc.removeCommands(containing: "#conductor:smoke")
        guard removed == 1, doc.entries().isEmpty else {
            try fail("hook command was not removed")
        }

        // removeExact 精确删除：不误伤共享子串的兄弟 hook。
        try doc.addCommand(event: HookEventName.stop, command: "echo hi")
        try doc.addCommand(event: HookEventName.stop, command: "echo hi there")
        let removedExact = try doc.removeExact(event: HookEventName.stop, command: "echo hi")
        guard removedExact == 1,
              doc.entries().count == 1,
              doc.entries().first?.command == "echo hi there" else {
            try fail("removeExact deleted the wrong hook(s)")
        }

        // update：精确替换命令与事件。
        try doc.update(event: HookEventName.stop, command: "echo hi there",
                       newEvent: HookEventName.sessionStart, newCommand: "echo edited", newTimeout: 1234)
        let updated = doc.entries()
        guard updated.count == 1,
              updated.first?.event == HookEventName.sessionStart,
              updated.first?.command == "echo edited",
              updated.first?.timeout == 1234 else {
            try fail("update did not replace hook correctly")
        }

        // removeExact 限定事件：同命令在不同事件下，只删指定事件的那条。
        try doc.addCommand(event: HookEventName.stop, command: "same-cmd")
        try doc.addCommand(event: HookEventName.sessionStart, command: "same-cmd")
        let removedScoped = try doc.removeExact(event: HookEventName.stop, command: "same-cmd")
        let scoped = doc.entries()
        guard removedScoped == 1,
              !scoped.contains(where: { $0.event == HookEventName.stop && $0.command == "same-cmd" }),
              scoped.contains(where: { $0.event == HookEventName.sessionStart && $0.command == "same-cmd" }) else {
            try fail("removeExact was not event-scoped")
        }
        _ = try doc.removeExact(event: HookEventName.sessionStart, command: "same-cmd")

        // 停用仓（HookParkingStore）往返。
        let parkURL = root.appendingPathComponent("hooks-disabled.json")
        let parking = HookParkingStore(url: parkURL)
        try parking.add(ParkedHook(source: .claude, event: "Stop", command: "parked", timeout: 7))
        guard parking.parked(for: .claude).count == 1,
              parking.find(source: .claude, event: "Stop", command: "parked")?.timeout == 7,
              try parking.remove(source: .claude, event: "Stop", command: "parked"),
              parking.load().isEmpty else {
            try fail("hook parking store round-trip failed")
        }

        return .object([
            "mcp": .array(mcpSteps.map(JSONValue.string)),
            "hooks": .array([
                .string("wrote command hook"),
                .string("deduplicated command hook"),
                .string("removed command hook"),
                .string("removeExact spared substring sibling"),
                .string("update replaced command + event"),
                .string("removeExact is event-scoped"),
                .string("parking store round-trip"),
            ]),
        ])
    }
    #endif
}
