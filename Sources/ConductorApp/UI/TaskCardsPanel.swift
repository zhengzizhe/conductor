import AppKit
import ConductorCore
import SwiftUI

struct TaskCardsPanelView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var store: TaskCardStore
    let onClose: () -> Void

    @State private var selectedID: String?
    @State private var draftTitle = ""
    @State private var draftPrompt = ""
    @State private var draftWorkspaceID = ""
    @State private var draftExecutorID = "shell"
    @FocusState private var promptFocused: Bool

    private var selectedCard: TaskCard? {
        guard let selectedID else { return nil }
        return store.cards.first { $0.id == selectedID }
    }

    var body: some View {
        HStack(spacing: 0) {
            cardsColumn
                .frame(width: 238)
                .background(AppStyle.hoverFill.opacity(0.22))
            Divider().opacity(0.45)
            editorColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 720, height: 520)
        .taskCardPanelSurface(cornerRadius: Radius.xl)
        .onAppear {
            if selectedID == nil {
                if let first = store.cards.first {
                    select(first)
                } else {
                    clearDraft()
                }
            }
        }
    }

    private var cardsColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "checklist")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppStyle.accent)
                Text(L("任务卡片"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppStyle.textPrimary)
                Spacer()
                IconOnlyButton(
                    systemName: "plus",
                    help: L("新建任务"),
                    size: 24,
                    symbolSize: 11,
                    tint: AppStyle.accent,
                    action: createCard)
            }
            .padding(.horizontal, Space.md)
            .padding(.top, Space.md)
            .padding(.bottom, Space.sm)

            ScrollView {
                VStack(spacing: 6) {
                    if store.cards.isEmpty {
                        ToolEmptyState(
                            icon: "checklist",
                            title: L("还没有任务卡片"),
                            detail: L("新建一张卡片，选择工作区和执行方式。"),
                            compact: true)
                            .padding(.top, Space.md)
                    } else {
                        ForEach(store.cards) { card in
                            TaskCardRow(
                                card: card,
                                workspaceName: workspaceName(card.workspaceID),
                                executorName: executorName(card.executor),
                                selected: selectedID == card.id
                            ) {
                                saveDraft()
                                select(card)
                            }
                        }
                    }
                }
                .padding(.horizontal, Space.sm)
                .padding(.bottom, Space.md)
            }
            .scrollIndicators(.never)
        }
    }

    private var editorColumn: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(selectedCard?.displayTitle ?? L("新任务"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AppStyle.textPrimary)
                        .lineLimit(1)
                    Text(metaLine)
                        .font(.system(size: 10.5))
                        .foregroundStyle(AppStyle.textTertiary)
                        .lineLimit(1)
                }
                Spacer()
                IconOnlyButton(
                    systemName: "trash",
                    help: L("删除任务"),
                    size: 26,
                    symbolSize: 11,
                    tint: AppStyle.errorRed,
                    action: deleteSelected)
                .disabled(selectedCard == nil)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L("标题"))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(AppStyle.textTertiary)
                TextField(L("给这张卡片起个名字"), text: $draftTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(AppStyle.textPrimary)
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(AppStyle.activeFill))
            }

            HStack(spacing: Space.sm) {
                pickerGroup(title: L("工作区")) {
                    Picker("", selection: $draftWorkspaceID) {
                        Text(L("当前工作区")).tag("")
                        ForEach(coordinator.visibleWorkspaces, id: \.id) { workspace in
                            Text(workspace.name).tag(workspace.id.value)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                pickerGroup(title: L("执行方式")) {
                    Picker("", selection: $draftExecutorID) {
                        Text("Shell").tag("shell")
                        ForEach(coordinator.launchableAgents) { agent in
                            Text(agent.title).tag("agent:\(agent.id)")
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L("内容"))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(AppStyle.textTertiary)
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $draftPrompt)
                        .font(.system(size: 13))
                        .foregroundStyle(AppStyle.textPrimary)
                        .scrollContentBackground(.hidden)
                        .focused($promptFocused)
                        .padding(8)
                    if draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(L("写下要执行的 shell 命令，或交给 AI 的任务说明…"))
                            .font(.system(size: 13))
                            .foregroundStyle(AppStyle.textTertiary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(AppStyle.activeFill))
            }

            HStack(spacing: 8) {
                ToolBadge(
                    text: draftExecutorID == "shell" ? L("不用 AI") : L("AI 执行"),
                    icon: draftExecutorID == "shell" ? "terminal" : "sparkles",
                    color: draftExecutorID == "shell" ? AppStyle.textTertiary : AppStyle.accent)
                Spacer()
                ToolActionButton(
                    title: L("保存"),
                    systemImage: "checkmark",
                    role: .secondary,
                    action: { _ = saveDraft() })
                ToolActionButton(
                    title: L("执行"),
                    systemImage: "play.fill",
                    role: .primary,
                    action: runDraft)
                .disabled(!canRun)
            }
        }
        .padding(Space.md)
    }

    private var canRun: Bool {
        !draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var metaLine: String {
        guard let card = selectedCard else { return L("未保存") }
        if let lastRunAt = card.lastRunAt {
            return L("已执行 %ld 次 · %@", card.runCount, Self.relativeFormatter.localizedString(for: lastRunAt, relativeTo: Date()))
        }
        return L("尚未执行")
    }

    private func pickerGroup<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(AppStyle.textTertiary)
            content()
                .padding(.horizontal, 8)
                .frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(AppStyle.hoverFill.opacity(0.55)))
        }
    }

    private func createCard() {
        let workspaceID = coordinator.store.activeWorkspace?.value
        let card = store.create(workspaceID: workspaceID)
        select(card)
        promptFocused = true
    }

    @discardableResult
    private func saveDraft() -> TaskCard? {
        guard selectedCard != nil || hasDraftContent else { return nil }
        var card = selectedCard ?? store.create(workspaceID: draftWorkspaceID.isEmpty ? coordinator.store.activeWorkspace?.value : draftWorkspaceID)
        card.title = draftTitle
        card.prompt = draftPrompt
        card.workspaceID = draftWorkspaceID.isEmpty ? nil : draftWorkspaceID
        card.executor = TaskCardExecutor(selectionID: draftExecutorID)
        store.upsert(card)
        selectedID = card.id
        return store.cards.first { $0.id == card.id } ?? card
    }

    private var hasDraftContent: Bool {
        !draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func runDraft() {
        guard let card = saveDraft() else { return }
        coordinator.runTaskCard(card)
    }

    private func select(_ card: TaskCard) {
        selectedID = card.id
        draftTitle = card.title
        draftPrompt = card.prompt
        draftWorkspaceID = card.workspaceID ?? ""
        draftExecutorID = card.executor.selectionID
    }

    private func deleteSelected() {
        guard let selectedID else { return }
        store.delete(selectedID)
        if let next = store.cards.first {
            select(next)
        } else {
            self.selectedID = nil
            clearDraft()
        }
    }

    private func clearDraft() {
        draftTitle = ""
        draftPrompt = ""
        draftWorkspaceID = coordinator.store.activeWorkspace?.value ?? ""
        draftExecutorID = "shell"
    }

    private func workspaceName(_ id: String?) -> String {
        guard let id else { return L("当前工作区") }
        return coordinator.visibleWorkspaces.first { $0.id.value == id }?.name ?? L("已移除的工作区")
    }

    private func executorName(_ executor: TaskCardExecutor) -> String {
        switch executor {
        case .shell:
            return "Shell"
        case let .agent(id):
            return coordinator.launchableAgents.first { $0.id == id }?.title ?? id
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

private struct TaskCardRow: View {
    let card: TaskCard
    let workspaceName: String
    let executorName: String
    let selected: Bool
    let onSelect: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: card.executor.agentID == nil ? "terminal" : "sparkles")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(selected ? AppStyle.accent : AppStyle.textTertiary)
                    Text(card.displayTitle)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(AppStyle.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                Text(card.prompt.isEmpty ? L("空白任务") : card.prompt)
                    .font(.system(size: 10.5))
                    .foregroundStyle(AppStyle.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 5) {
                    tinyPill(workspaceName, icon: "folder")
                    tinyPill(executorName, icon: card.executor.agentID == nil ? "terminal" : "cpu")
                    Spacer(minLength: 0)
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? AppStyle.activeFill : hovering ? AppStyle.hoverFill : Color.clear))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(selected ? AppStyle.accent.opacity(0.36) : Color.clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .animation(Motion.snappy, value: selected)
    }

    private func tinyPill(_ text: String, icon: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 7.5, weight: .bold))
            Text(text)
                .font(.system(size: 9, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(AppStyle.textTertiary)
        .padding(.horizontal, 5)
        .frame(height: 17)
        .background(Capsule().fill(AppStyle.hoverFill.opacity(0.65)))
    }
}

private struct TaskCardPanelSurface: ViewModifier {
    @ObservedObject private var configStore = ConfigStore.shared
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(shape.fill(surfaceColor))
            .overlay(shape.strokeBorder(borderColor, lineWidth: 1))
            .clipShape(shape)
    }

    @MainActor
    private var surfaceColor: Color {
        AppStyle.theme.isDark
            ? Color(nsColor: AppStyle.cardBackground)
            : Color(red: 0.965, green: 0.967, blue: 0.972)
    }

    @MainActor
    private var borderColor: Color {
        AppStyle.theme.isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.08)
    }
}

private extension View {
    func taskCardPanelSurface(cornerRadius: CGFloat) -> some View {
        modifier(TaskCardPanelSurface(cornerRadius: cornerRadius))
    }
}

@MainActor
final class TaskCardsPanelController: NSObject, NSWindowDelegate {
    private var panel: KeyPanel?
    private var escMonitor: Any?

    func toggle(coordinator: AppCoordinator, over parent: NSWindow?) {
        if let panel, panel.isVisible {
            hide()
            return
        }
        show(coordinator: coordinator, over: parent)
    }

    func show(coordinator: AppCoordinator, over parent: NSWindow?) {
        let view = TaskCardsPanelView(
            coordinator: coordinator,
            store: coordinator.taskCardStore,
            onClose: { [weak self] in self?.hide() })
        let host = NSHostingView(rootView: view)
        let size = NSSize(width: 720, height: 520)
        let p = panel ?? makePanel(size: size)
        p.contentView = host
        p.setContentSize(size)

        let mousePoint = NSEvent.mouseLocation
        let mouseScreen = NSScreen.screens.first { NSMouseInRect(mousePoint, $0.frame, false) }
        let targetScreen = mouseScreen ?? parent?.screen ?? NSScreen.main
        let screenFrame = targetScreen?.visibleFrame ?? parent?.frame ?? .zero
        let parentFrame: NSRect = if parent?.screen === targetScreen {
            parent?.frame ?? screenFrame
        } else {
            screenFrame
        }
        let preferredX = parentFrame.maxX - size.width - 42
        let preferredY = parentFrame.maxY - size.height - 70
        let x = min(max(preferredX, screenFrame.minX + 20), screenFrame.maxX - size.width - 20)
        let y = min(max(preferredY, screenFrame.minY + 20), screenFrame.maxY - size.height - 20)
        p.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)

        p.alphaValue = 0
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            p.animator().alphaValue = 1
        }
        if escMonitor == nil {
            escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53, event.window === self?.panel else { return event }
                self?.hide()
                return nil
            }
        }
    }

    func hide() {
        if let escMonitor {
            NSEvent.removeMonitor(escMonitor)
            self.escMonitor = nil
        }
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak panel] in panel?.orderOut(nil) })
    }

    func automationSnapshot() -> JSONValue {
        guard let panel else {
            return .object(["visible": .bool(false)])
        }
        return .object([
            "visible": .bool(panel.isVisible),
            "title": .string(panel.title),
            "frame": .object([
                "x": .double(panel.frame.origin.x),
                "y": .double(panel.frame.origin.y),
                "width": .double(panel.frame.width),
                "height": .double(panel.frame.height),
            ]),
        ])
    }

    private func makePanel(size: NSSize) -> KeyPanel {
        let panel = KeyPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true)
        panel.title = "Task Cards"
        panel.identifier = NSUserInterfaceItemIdentifier("TaskCardsPanel")
        panel.setAccessibilityTitle("Task Cards")
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.delegate = self
        self.panel = panel
        return panel
    }
}
