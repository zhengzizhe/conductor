import AppKit
import ConductorCore

@MainActor
extension AppCoordinator {
    func openTaskCards() {
        taskCardsPanel.show(coordinator: self, over: window)
    }

    func toggleTaskCards() {
        taskCardsPanel.toggle(coordinator: self, over: window)
    }

    func runTaskCard(_ card: TaskCard) {
        guard let workspace = taskCardWorkspace(for: card) else {
            ToastHUD.shared.show(L("没有可用工作区"), icon: "exclamationmark.triangle.fill", over: window)
            return
        }

        switch card.executor {
        case .shell:
            runShellTaskCard(card, in: workspace)
        case let .agent(agentID):
            runAgentTaskCard(card, agentID: agentID, in: workspace)
        }
    }

    private func taskCardWorkspace(for card: TaskCard) -> Workspace? {
        if let id = card.workspaceID,
           let workspace = visibleWorkspaces.first(where: { $0.id.value == id }) {
            return workspace
        }
        if let active = store.activeWorkspace,
           let workspace = visibleWorkspaces.first(where: { $0.id == active }) {
            return workspace
        }
        return visibleWorkspaces.first
    }

    private func runShellTaskCard(_ card: TaskCard, in workspace: Workspace) {
        if store.activeWorkspace != workspace.id {
            selectWorkspace(workspace.id)
        }
        let pane = PaneID(nextID("p"))
        run(.newTab(newTabID: TabID(nextID("t")), newPaneID: pane, cwd: workspace.path))

        let command = card.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !command.isEmpty {
            (registry.surface(for: pane) as? GhosttySurface)?.enqueueCommand(command)
        }
        taskCardStore.markRan(card.id)
        ToastHUD.shared.show(L("任务已在 Shell 中执行"), icon: "terminal.fill", over: window)
    }

    private func runAgentTaskCard(_ card: TaskCard, agentID: String, in workspace: Workspace) {
        if store.activeWorkspace != workspace.id {
            selectWorkspace(workspace.id)
        }
        let prompt = card.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try automationRunAgent(
                agent: agentID,
                command: nil,
                cwd: workspace.path,
                prompt: prompt,
                submit: true)
            taskCardStore.markRan(card.id)
            ToastHUD.shared.show(
                L("任务已交给 %@", taskCardAgentTitle(agentID)),
                icon: "sparkles",
                over: window)
        } catch {
            ToastHUD.shared.show(
                L("任务启动失败：%@", error.localizedDescription),
                icon: "exclamationmark.triangle.fill",
                over: window)
        }
    }

    private func taskCardAgentTitle(_ agentID: String) -> String {
        launchableAgents.first { $0.id == agentID }?.title
            ?? AgentCatalog.all.first { $0.id == agentID }?.name
            ?? agentID
    }
}
