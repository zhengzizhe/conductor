import AppKit
import ConductorCore
import Foundation

/// AppCoordinator 的自动化操作面：CLI / socket 客户端的请求最终落到这里。
/// 引用解析约定：
/// - workspace：id、名称或路径（绝对/前缀）；省略 = 当前活动工作区
/// - tab：id 或 1 起的序号；省略 = 当前活动 tab
/// - pane：id；省略 = 当前活动 pane（CLI 在 pane 里跑时会带 $CONDUCTOR_PANE_ID）
extension AppCoordinator {
    // MARK: - 查找

    var automationActiveWorkspace: Workspace? {
        store.activeWorkspace.flatMap { id in store.workspaces.first { $0.id == id } }
    }

    func automationFindWorkspace(_ ref: String?) throws -> Workspace {
        guard let ref, !ref.isEmpty else {
            guard let active = automationActiveWorkspace else {
                throw AutomationError.notFound("没有活动工作区")
            }
            return active
        }
        let normalizedPath = (ref as NSString).expandingTildeInPath
        if let hit = store.workspaces.first(where: {
            $0.id.value == ref || $0.name == ref || $0.path == normalizedPath
        }) {
            return hit
        }
        throw AutomationError.notFound("找不到工作区：\(ref)")
    }

    func automationFindTab(_ ref: String?, in workspace: Workspace) throws -> ConductorCore.Tab {
        guard let ref, !ref.isEmpty else {
            guard let active = workspace.tabs.first(where: { $0.id == workspace.activeTab }) else {
                throw AutomationError.notFound("工作区没有活动标签")
            }
            return active
        }
        if let byID = workspace.tabs.first(where: { $0.id.value == ref }) { return byID }
        if let index = Int(ref), index >= 1, index <= workspace.tabs.count {
            return workspace.tabs[index - 1]
        }
        throw AutomationError.notFound("找不到标签：\(ref)")
    }

    func automationFindPane(_ ref: String?) throws -> PaneID {
        guard let ref, !ref.isEmpty else {
            guard let active = automationActiveWorkspace
                .flatMap({ ws in ws.tabs.first { $0.id == ws.activeTab } })?.activePane else {
                throw AutomationError.notFound("没有活动 pane")
            }
            return active
        }
        let pane = PaneID(ref)
        guard registry.surface(for: pane) != nil else {
            throw AutomationError.notFound("找不到 pane：\(ref)")
        }
        return pane
    }

    /// pane 所在的 (工作区, tab)；不在任何树里返回 nil（popup 等游离 pane）。
    func automationLocate(_ pane: PaneID) -> (Workspace, ConductorCore.Tab)? {
        for workspace in store.workspaces {
            for tab in workspace.tabs where tab.rootSplit.contains(pane) {
                return (workspace, tab)
            }
        }
        return nil
    }

    // MARK: - 工作区 / 标签操作

    func automationSelectWorkspace(_ ref: String) throws {
        let workspace = try automationFindWorkspace(ref)
        selectWorkspace(workspace.id)
    }

    func automationNewWorkspace(path: String, name: String?) throws -> Workspace {
        let expanded = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw AutomationError.badRequest("目录不存在：\(expanded)")
        }
        addWorkspace(path: expanded)   // 已有同路径会直接切过去
        guard var workspace = store.workspaces.first(where: { $0.path == expanded }) else {
            throw AutomationError.internalError("创建工作区失败")
        }
        if let name, !name.isEmpty {
            renameWorkspace(workspace.id, to: name)
            workspace.name = name
        }
        return workspace
    }

    func automationNewTab(workspaceRef: String?, cwd: String?) throws -> (TabID, PaneID) {
        let workspace = try automationFindWorkspace(workspaceRef)
        if store.activeWorkspace != workspace.id { selectWorkspace(workspace.id) }
        let tabID = TabID(nextID("t"))
        let paneID = PaneID(nextID("p"))
        let resolvedCwd = cwd.map { ($0 as NSString).expandingTildeInPath }
        run(.newTab(newTabID: tabID, newPaneID: paneID, cwd: resolvedCwd))
        return (tabID, paneID)
    }

    func automationSelectTab(_ ref: String, workspaceRef: String?) throws {
        let workspace = try automationFindWorkspace(workspaceRef)
        let tab = try automationFindTab(ref, in: workspace)
        if store.activeWorkspace != workspace.id { selectWorkspace(workspace.id) }
        selectTab(tab.id)
    }

    /// 自动化关标签：不弹「思考中」确认框（脚本自己负责），但保留误关恢复记录。
    func automationCloseTab(_ ref: String, workspaceRef: String?) throws {
        let workspace = try automationFindWorkspace(workspaceRef)
        let tab = try automationFindTab(ref, in: workspace)
        if store.activeWorkspace != workspace.id { selectWorkspace(workspace.id) }
        pushClosedTabRecord(tab.id)   // 与 UI 关闭同款：内容快照 + 误关恢复
        run(.closeTab(tab.id))
    }

    // MARK: - pane 操作

    func automationSplit(paneRef: String?, axis: SplitAxis, cwd: String?) throws -> PaneID {
        let pane = try automationFindPane(paneRef)
        revealPane(pane)   // reducer 的 split 作用于活动 pane：先把目标 pane 转正
        let newPane = PaneID(nextID("p"))
        let splitID = SplitID(nextID("s"))
        let resolvedCwd = cwd.map { ($0 as NSString).expandingTildeInPath } ?? paneCwds[pane]
        run(.split(axis: axis, newPaneID: newPane, splitID: splitID, cwd: resolvedCwd))
        return newPane
    }

    func automationFocusPane(_ ref: String) throws {
        let pane = try automationFindPane(ref)
        revealPane(pane)
    }

    func automationClosePane(_ ref: String?) throws {
        let pane = try automationFindPane(ref)
        revealPane(pane)
        // 不走 closeActivePane()：那条路径在 agent 思考中会弹确认框，脚本场景不该有模态
        pushClosedRecordForActivePane()
        run(.closeActivePane)
    }

    // MARK: - 终端 I/O

    private func automationSurface(_ pane: PaneID) throws -> GhosttySurface {
        guard let surface = registry.surface(for: pane) as? GhosttySurface else {
            throw AutomationError.notFound("pane 没有终端实例：\(pane.value)")
        }
        return surface
    }

    func automationSendText(paneRef: String?, text: String, submit: Bool) throws {
        let pane = try automationFindPane(paneRef)
        let surface = try automationSurface(pane)
        guard !text.isEmpty else { return }
        surface.sendTextInput(text)
        if submit {
            // 文本走输入通道、回车走按键通道（TUI 在 raw 模式下只认按键）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak surface] in
                surface?.sendEnterKey()
            }
        }
    }

    func automationSendKeys(paneRef: String?, keys: [String]) throws {
        let pane = try automationFindPane(paneRef)
        let surface = try automationSurface(pane)
        for key in keys {
            try automationSend(key: key, to: surface)
        }
    }

    private func automationSend(key: String, to surface: GhosttySurface) throws {
        switch key.lowercased() {
        case "enter", "return", "cr": surface.sendEnterKey()
        case "esc", "escape": surface.sendEscapeKey()
        case "tab": surface.sendTextInput("\t")
        case "space": surface.sendTextInput(" ")
        case "backspace", "bs": surface.sendTextInput("\u{7F}")
        case "up": surface.sendTextInput("\u{1B}[A")
        case "down": surface.sendTextInput("\u{1B}[B")
        case "right": surface.sendTextInput("\u{1B}[C")
        case "left": surface.sendTextInput("\u{1B}[D")
        case let value where value.hasPrefix("ctrl-") || value.hasPrefix("c-"):
            let letter = value.split(separator: "-", maxSplits: 1)[1]
            guard letter.count == 1,
                  let scalar = letter.unicodeScalars.first,
                  scalar.value >= 97, scalar.value <= 122 else {
                throw AutomationError.badRequest("不支持的按键：\(key)")
            }
            surface.sendTextInput(String(UnicodeScalar(scalar.value - 96)!))
        default:
            // 其余按字面文本输入（单字符或整段）
            surface.sendTextInput(key)
        }
    }

    func automationReadScreen(paneRef: String?, scrollback: Bool) throws -> String {
        let pane = try automationFindPane(paneRef)
        let surface = try automationSurface(pane)
        let text = scrollback ? surface.readAllText() : surface.readViewportText()
        return text ?? ""
    }

    // MARK: - surface resume

    func automationSetSurfaceResume(
        paneRef: String?,
        kind: String,
        checkpoint: String?,
        command: String,
        autoResume: Bool,
        trusted: Bool
    ) throws -> SurfaceResumeBinding {
        let pane = try automationFindPane(paneRef)
        let binding = SurfaceResumeBinding(
            paneID: pane.value,
            kind: kind.isEmpty ? "shell" : kind,
            checkpoint: checkpoint,
            command: command,
            cwd: paneCwds[pane],
            autoResume: autoResume && trusted,
            trusted: trusted)
        guard binding.isUsable else {
            throw AutomationError.badRequest("resume command 不能为空")
        }
        try surfaceResumeBindings.set(binding)
        return binding
    }

    func automationShowSurfaceResume(paneRef: String?) throws -> SurfaceResumeBinding? {
        let pane = try automationFindPane(paneRef)
        return surfaceResumeBindings.binding(for: pane.value)
    }

    @discardableResult
    func automationClearSurfaceResume(paneRef: String?) throws -> SurfaceResumeBinding? {
        let pane = try automationFindPane(paneRef)
        return try surfaceResumeBindings.clear(paneID: pane.value)
    }

    func automationDescribe(binding: SurfaceResumeBinding) -> JSONValue {
        .object([
            "pane": .string(binding.paneID),
            "kind": .string(binding.kind),
            "checkpoint": binding.checkpoint.map(JSONValue.string) ?? .null,
            "command": .string(binding.command),
            "restoreCommand": .string(binding.restoreCommand),
            "cwd": binding.cwd.map(JSONValue.string) ?? .null,
            "autoResume": .bool(binding.autoResume),
            "trusted": .bool(binding.trusted),
            "updatedAt": .double(binding.updatedAt.timeIntervalSince1970),
        ])
    }

    // MARK: - 通知

    func automationNotify(paneRef: String?, title: String, body: String) {
        if let paneRef, let pane = try? automationFindPane(paneRef) {
            handleDesktopNotification(pane, title: title, body: body)
        } else {
            activityLog.record(paneID: nil, agentID: nil,
                               title: title.isEmpty ? L("自动化通知") : title,
                               message: body, duration: nil)
            NotificationManager.shared.notify(paneID: nil,
                                              title: title.isEmpty ? "Conductor" : title,
                                              body: body)
        }
    }

    // MARK: - App / jobs / events

    func automationStatusJSON() -> JSONValue {
        let activeWorkspace = automationActiveWorkspace
        let activeTab = activeWorkspace?.tabs.first { $0.id == activeWorkspace?.activeTab }
        let tabCount = store.workspaces.reduce(0) { $0 + $1.tabs.count }
        let paneCount = store.workspaces.reduce(0) { total, workspace in
            total + workspace.tabs.reduce(0) { $0 + $1.rootSplit.leaves().count }
        }
        return .object([
            "app": .string("Conductor"),
            "version": .string(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""),
            "protocol": .int(AutomationProtocol.version),
            "socket": .string(AutomationSocketServer.defaultSocketURL.path),
            "active": .object([
                "workspace": activeWorkspace.map { .string($0.id.value) } ?? .null,
                "tab": activeTab.map { .string($0.id.value) } ?? .null,
                "pane": activeTab.map { .string($0.activePane.value) } ?? .null,
            ]),
            "counts": .object([
                "workspaces": .int(store.workspaces.count),
                "tabs": .int(tabCount),
                "panes": .int(paneCount),
                "runningAgents": .int(thinkingPanes.count),
                "activities": .int(activityLog.entries.count),
            ]),
            "methods": .array(AutomationMethod.all.map(JSONValue.string)),
        ])
    }

    func automationRunAgent(
        agent agentRef: String,
        command commandOverride: String?,
        cwd: String?,
        prompt: String?,
        submit: Bool
    ) throws -> JSONValue {
        let agent = automationLaunchableAgent(agentRef: agentRef, commandOverride: commandOverride)
        let pane = launchAIAgentSession(agent, cwd: cwd.map { ($0 as NSString).expandingTildeInPath })
        if let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            automationSendPrompt(prompt, to: pane, submit: submit)
        }

        let job = AutomationAgentJob(
            id: pane.value,
            pane: pane,
            agent: agent.id,
            command: agent.command,
            startedAt: Date())
        automationAgentJobs[job.id] = job
        return .object([
            "jobId": .string(job.id),
            "pane": .string(pane.value),
            "agent": .string(agent.id),
            "command": .string(agent.command),
            "status": .string("running"),
        ])
    }

    private func automationLaunchableAgent(agentRef: String, commandOverride: String?) -> LaunchableAgent {
        let trimmedAgent = agentRef.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCommand = commandOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = launchableAgents.first { $0.id == trimmedAgent || $0.command == trimmedAgent }
            ?? AgentCatalog.all.first { $0.id == trimmedAgent || $0.command == trimmedAgent }.map {
                LaunchableAgent(
                    id: $0.id,
                    title: $0.name,
                    command: $0.command,
                    logo: $0.logo,
                    fallbackSystemImage: $0.fallbackSystemImage)
            }
        if let base {
            guard let trimmedCommand, !trimmedCommand.isEmpty else { return base }
            return LaunchableAgent(
                id: base.id,
                title: base.title,
                command: trimmedCommand,
                logo: base.logo,
                fallbackSystemImage: base.fallbackSystemImage)
        }

        let command = (trimmedCommand?.isEmpty == false ? trimmedCommand! : trimmedAgent)
        let firstToken = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init)
        if let descriptor = AgentCatalog.all.first(where: { $0.command == firstToken || $0.id == firstToken }) {
            return LaunchableAgent(
                id: descriptor.id,
                title: descriptor.name,
                command: command,
                logo: descriptor.logo,
                fallbackSystemImage: descriptor.fallbackSystemImage)
        }

        return LaunchableAgent(
            id: trimmedAgent.isEmpty ? command : trimmedAgent,
            title: trimmedAgent.isEmpty ? command : trimmedAgent,
            command: command,
            logo: trimmedAgent.isEmpty ? "terminal" : trimmedAgent,
            fallbackSystemImage: "terminal")
    }

    private func automationSendPrompt(_ prompt: String, to pane: PaneID, submit: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let surface = self?.registry.surface(for: pane) as? GhosttySurface else { return }
            surface.sendTextInput(prompt)
            guard submit else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak surface] in
                surface?.sendEnterKey()
            }
        }
    }

    func automationAgentStatus(jobRef: String?) throws -> JSONValue {
        let job = try automationResolveAgentJob(jobRef)
        return automationAgentStatusJSON(job: job, completion: automationCompletion(for: job))
    }

    func automationAgentResult(jobRef: String?) throws -> JSONValue {
        let job = try automationResolveAgentJob(jobRef)
        guard let completion = automationCompletion(for: job) else {
            return automationAgentStatusJSON(job: job, completion: nil)
        }
        var result = automationAgentStatusObject(job: job, completion: completion)
        result["title"] = .string(completion.title)
        result["summary"] = .string(completion.message)
        result["markdown"] = .string(completion.message)
        if let duration = completion.duration {
            result["duration"] = .double(duration)
        }
        if let session = agentSessionBindings.ref(for: job.pane.value) {
            result["transcriptPath"] = session.transcriptPath.map(JSONValue.string) ?? .null
            result["restorableSession"] = automationDescribe(session: session)
        }
        return .object(result)
    }

    private func automationResolveAgentJob(_ ref: String?) throws -> AutomationAgentJob {
        if let ref, let job = automationAgentJobs[ref] { return job }
        let pane = try automationFindPane(ref)
        if let job = automationAgentJobs.values.first(where: { $0.pane == pane }) { return job }
        let agent = paneAgents[pane] ?? "shell"
        return AutomationAgentJob(
            id: pane.value,
            pane: pane,
            agent: agent,
            command: paneLaunchCommands[pane]?.shellCommand ?? agent,
            startedAt: .distantPast)
    }

    private func automationCompletion(for job: AutomationAgentJob) -> AgentActivityEntry? {
        activityLog.entries.first { entry in
            entry.paneID == job.pane && entry.date >= job.startedAt
        }
    }

    private func automationAgentStatusJSON(
        job: AutomationAgentJob,
        completion: AgentActivityEntry?
    ) -> JSONValue {
        .object(automationAgentStatusObject(job: job, completion: completion))
    }

    private func automationAgentStatusObject(
        job: AutomationAgentJob,
        completion: AgentActivityEntry?
    ) -> [String: JSONValue] {
        let status: String
        if completion != nil {
            status = "completed"
        } else if paneExists(job.pane) {
            status = "running"
        } else {
            status = "closed"
        }
        return [
            "jobId": .string(job.id),
            "pane": .string(job.pane.value),
            "agent": .string(job.agent),
            "command": .string(job.command),
            "status": .string(status),
            "thinking": .bool(thinkingPanes.contains(job.pane)),
            "startedAt": .double(job.startedAt.timeIntervalSince1970),
        ]
    }

    func automationActivityList(limit: Int) -> [JSONValue] {
        let limit = max(1, min(limit, 200))
        return activityLog.entries.prefix(limit).map(automationDescribe(activity:))
    }

    func automationRecentEvents(limit: Int) -> [JSONValue] {
        let limit = max(1, min(limit, 500))
        return activityLog.entries.prefix(limit).map { entry in
            let payload = automationActivityObject(entry)
            return .object([
                "id": .string(entry.id.uuidString),
                "type": .string("agent.completed"),
                "topic": .string("agent.completed"),
                "time": .double(entry.date.timeIntervalSince1970),
                "pane": entry.paneID.map { .string($0.value) } ?? .null,
                "agent": entry.agentID.map(JSONValue.string) ?? .null,
                "payload": .object(payload),
            ])
        }
    }

    private func automationDescribe(activity entry: AgentActivityEntry) -> JSONValue {
        .object(automationActivityObject(entry))
    }

    private func automationActivityObject(_ entry: AgentActivityEntry) -> [String: JSONValue] {
        var object: [String: JSONValue] = [
            "id": .string(entry.id.uuidString),
            "time": .double(entry.date.timeIntervalSince1970),
            "title": .string(entry.title),
            "message": .string(entry.message),
            "pane": entry.paneID.map { .string($0.value) } ?? .null,
            "agent": entry.agentID.map(JSONValue.string) ?? .null,
        ]
        if let duration = entry.duration {
            object["duration"] = .double(duration)
        }
        return object
    }

    // MARK: - 描述（list-* / tree 的数据源）

    func automationDescribe(workspace: Workspace) -> JSONValue {
        .object([
            "id": .string(workspace.id.value),
            "name": .string(workspace.name),
            "path": .string(workspace.path),
            "active": .bool(store.activeWorkspace == workspace.id),
            "tabs": .int(workspace.tabs.count),
        ])
    }

    func automationDescribe(tab: ConductorCore.Tab, in workspace: Workspace) -> JSONValue {
        let index = workspace.tabs.firstIndex(where: { $0.id == tab.id }).map { $0 + 1 } ?? 0
        return .object([
            "id": .string(tab.id.value),
            "index": .int(index),
            "title": .string(tab.customTitle ?? tab.title),
            "active": .bool(workspace.activeTab == tab.id),
            "panes": .array(tab.rootSplit.leaves().map { automationDescribe(pane: $0, in: tab) }),
        ])
    }

    func automationDescribe(pane: PaneID, in tab: ConductorCore.Tab?) -> JSONValue {
        var fields: [String: JSONValue] = [
            "id": .string(pane.value),
            "title": .string(paneTitles[pane] ?? ""),
            "cwd": .string(paneCwds[pane] ?? ""),
            "thinking": .bool(thinkingPanes.contains(pane)),
        ]
        if let branch = paneBranches[pane] { fields["branch"] = .string(branch) }
        if let agent = paneAgents[pane] { fields["agent"] = .string(agent) }
        if let session = agentSessionBindings.ref(for: pane.value) {
            fields["restorableSession"] = automationDescribe(session: session)
        }
        if let binding = surfaceResumeBindings.binding(for: pane.value) {
            fields["resumeBinding"] = automationDescribe(binding: binding)
        }
        if let tab { fields["active"] = .bool(tab.activePane == pane) }
        return .object(fields)
    }

    func automationDescribe(session: AgentSessionRef) -> JSONValue {
        .object([
            "agent": .string(session.agent),
            "sessionId": .string(session.sessionID),
            "cwd": session.cwd.map(JSONValue.string) ?? .null,
            "transcriptPath": session.transcriptPath.map(JSONValue.string) ?? .null,
            "updatedAt": session.updatedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
            "wasRunning": session.wasRunning.map(JSONValue.bool) ?? .null,
            "lifecycle": session.lifecycle.map { .string($0.rawValue) } ?? .null,
            "resumeCommand": session.resumeCommand.map(JSONValue.string) ?? .null,
            "launchCommand": session.launchCommand.map { .string($0.shellCommand) } ?? .null,
        ])
    }

    func automationTree(workspaceRef: String?) throws -> JSONValue {
        let workspace = try automationFindWorkspace(workspaceRef)
        return .object([
            "id": .string(workspace.id.value),
            "name": .string(workspace.name),
            "path": .string(workspace.path),
            "tabs": .array(workspace.tabs.map { tab in
                .object([
                    "id": .string(tab.id.value),
                    "title": .string(tab.customTitle ?? tab.title),
                    "active": .bool(workspace.activeTab == tab.id),
                    "layout": automationTreeNode(tab.rootSplit, tab: tab),
                ])
            }),
        ])
    }

    private func automationTreeNode(_ node: SplitNode, tab: ConductorCore.Tab) -> JSONValue {
        switch node {
        case .leaf(let pane):
            return automationDescribe(pane: pane, in: tab)
        case .split(_, let axis, let ratio, let first, let second):
            return .object([
                "split": .string(axis == .vertical ? "vertical" : "horizontal"),
                "ratio": .double((ratio * 1000).rounded() / 1000),
                "first": automationTreeNode(first, tab: tab),
                "second": automationTreeNode(second, tab: tab),
            ])
        }
    }
}
