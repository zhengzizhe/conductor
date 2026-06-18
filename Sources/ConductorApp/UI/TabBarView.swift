import AppKit
import ConductorCore
import SwiftUI

/// 顶部 Tab 栏（自绘，深色 Craft 风）：当前工作区的 tab，胶囊样式；点击切换，`+` 新建，active 高亮。
/// 分屏后的 tab 自动呈现为"分组"胶囊（分屏图标 + 数量角标），悬停可看真实预览。
/// Tab 重排通过右键菜单完成，顶部保留干净的点击/重命名/窗口拖拽交互。
struct TabBarView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject private var configStore = ConfigStore.shared   // 主题变 → 重渲染（AppStyle 跟随）
    @State private var editingTab: TabID?
    @State private var draftTitle: String = ""
    @FocusState private var renameFocused: Bool
    /// 胶囊串的内容宽度：tab 少时滚动区收身到正好包住内容，把剩余宽度让给拖拽区。
    @State private var pillsWidth: CGFloat = 0
    @State private var showingAgentMenu = false
    @State private var isHoveringPlus = false
    @State private var isHoveringAgentMenu = false
    @State private var agentMenuOpenWorkItem: DispatchWorkItem?
    @State private var agentMenuCloseWorkItem: DispatchWorkItem?
    @State private var isFeedbackPresented = false

    var body: some View {
        let ws = coordinator.store.workspaces.first { $0.id == coordinator.store.activeWorkspace }
        let tabs = ws?.tabs ?? []
        let activeTab = ws?.activeTab
        HStack(spacing: 5) {
            // tab 多到放不下 → 胶囊串横向滚动（不出滚动条），切换时自动把活动标签滑入视野。
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                            TabPill(
                                tab: tab,
                                title: tab.customTitle ?? (coordinator.paneTitles[tab.activePane] ?? L("终端")),
                                selected: tab.id == activeTab,
                                index: index,
                                tabCount: tabs.count,
                                coordinator: coordinator,
                                isEditing: editingTab == tab.id,
                                draft: $draftTitle,
                                focused: $renameFocused,
                                onStartEdit: { beginRename(tab) },
                                onCommitEdit: { commitRename() }
                            ) { coordinator.selectTab(tab.id) }
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.8).combined(with: .opacity),
                                removal: .scale(scale: 0.8).combined(with: .opacity)))
                            .id(tab.id)
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pillsWidth = $0 }
                }
                .scrollBounceBehavior(.basedOnSize, axes: [.horizontal])
                .frame(maxWidth: tabs.isEmpty ? 0 : (pillsWidth > 0 ? pillsWidth : nil))
                .layoutPriority(2)
                .onChange(of: activeTab) { _, id in
                    guard let id else { return }
                    withAnimation(Motion.snappy) { proxy.scrollTo(id) }
                }
                .onAppear { if let activeTab { proxy.scrollTo(activeTab) } }
            }
            IconOnlyButton(
                systemName: "plus",
                help: L("新建标签"),
                size: 24,
                symbolSize: 12,
                tint: AppStyle.textTertiary) {
                    cancelAgentMenuTimers()
                    showingAgentMenu = false
                    coordinator.newTab()
                }
            .onHover { inside in
                isHoveringPlus = inside
                updateAgentMenuVisibility()
            }
            .popover(isPresented: $showingAgentMenu, arrowEdge: .top) {
                AIAgentSessionHoverMenu(
                    agents: coordinator.launchableAgents,
                    onLaunch: { agent in
                        cancelAgentMenuTimers()
                        showingAgentMenu = false
                        coordinator.launchAIAgentSession(agent)
                    },
                    onHover: { inside in
                        isHoveringAgentMenu = inside
                        updateAgentMenuVisibility()
                    }
                )
            }
            WindowDragZoomArea()
            .frame(minWidth: 56, maxWidth: .infinity)   // tab 再多也给窗口拖拽留一块
            .frame(height: WindowDragZoomRegion.preferredHeight)
            .layoutPriority(1)
            HStack(spacing: 6) {
                UpdateButton()

                // 右侧快捷按钮组（软圆角容器，对标 Craft 的按钮组）
                HStack(spacing: 2) {
                Button(action: { isFeedbackPresented = true }) {
                                        Image(systemName: "text.bubble")
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(AppStyle.textSecondary)
                                    }
                                    .buttonStyle(IconButtonStyle(size: 26))
                                    .help(L("反馈"))
                    IconOnlyButton(
                        systemName: AppStyle.theme.isDark ? "moon.stars.fill" : "sun.max.fill",
                        help: L("切换深/浅主题"),
                        size: 26,
                        symbolSize: 12) {
                            coordinator.toggleTheme()
                        }
                    IconOnlyButton(
                        systemName: "wand.and.stars",
                        help: L("检测命令行工具"),
                        size: 26,
                        symbolSize: 12,
                        tint: coordinator.cliToolsPresentation.isPresented ? AppStyle.accent : AppStyle.textSecondary) {
                            coordinator.toggleCLITools()
                        }
                    IconOnlyButton(
                        systemName: "checklist",
                        help: L("任务卡片"),
                        size: 26,
                        symbolSize: 12) {
                            coordinator.toggleTaskCards()
                        }
                    IconOnlyButton(
                        systemName: "rectangle.3.group",
                        help: L("打开工具管理台"),
                        size: 26,
                        symbolSize: 12,
                        tint: coordinator.agentToolsManagementPresentation.isPresented ? AppStyle.accent : AppStyle.textSecondary) {
                            coordinator.openAgentToolsManagement()
                        }
                    IconOnlyButton(
                        systemName: "gearshape",
                        help: L("设置"),
                        size: 26,
                        symbolSize: 12,
                        tint: coordinator.settingsPresentation.isPresented ? AppStyle.accent : AppStyle.textSecondary) {
                            coordinator.openSettings()
                        }
                }
                .padding(3)
                .background(
                    RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                        .fill(AppStyle.hoverFill))
            }
        }
        .animation(Motion.snappy, value: activeTab)   // 选中指示器滑动
        .animation(Motion.panel, value: tabs.count)   // 增删 tab 缩放淡入
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity)
        .background(.clear)   // 透明：用根底统一磨砂
        .sheet(isPresented: $isFeedbackPresented) {
            FeedbackSheetView {
                isFeedbackPresented = false
            }
        }
        .onChange(of: renameFocused) { _, focused in
            if !focused, editingTab != nil { commitRename() }
        }
    }

    private func beginRename(_ tab: ConductorCore.Tab) {
        draftTitle = tab.customTitle ?? (coordinator.paneTitles[tab.activePane] ?? "")
        editingTab = tab.id
        DispatchQueue.main.async { renameFocused = true }
    }

    private func commitRename() {
        if let id = editingTab { coordinator.renameTab(id, to: draftTitle) }
        editingTab = nil
        renameFocused = false
    }

    private func updateAgentMenuVisibility() {
        guard !coordinator.launchableAgents.isEmpty else {
            cancelAgentMenuTimers()
            showingAgentMenu = false
            return
        }

        if isHoveringAgentMenu {
            agentMenuCloseWorkItem?.cancel()
            agentMenuOpenWorkItem?.cancel()
            showingAgentMenu = true
        } else if isHoveringPlus {
            scheduleAgentMenuOpen()
        } else {
            scheduleAgentMenuClose()
        }
    }

    private func scheduleAgentMenuOpen() {
        agentMenuCloseWorkItem?.cancel()
        guard !showingAgentMenu else { return }
        agentMenuOpenWorkItem?.cancel()

        let workItem = DispatchWorkItem {
            if isHoveringPlus || isHoveringAgentMenu {
                showingAgentMenu = true
            }
        }
        agentMenuOpenWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: workItem)
    }

    private func scheduleAgentMenuClose() {
        agentMenuOpenWorkItem?.cancel()
        guard !isHoveringPlus && !isHoveringAgentMenu else { return }
        agentMenuCloseWorkItem?.cancel()

        let workItem = DispatchWorkItem {
            if !isHoveringPlus && !isHoveringAgentMenu {
                showingAgentMenu = false
            }
        }
        agentMenuCloseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: workItem)
    }

    private func cancelAgentMenuTimers() {
        agentMenuOpenWorkItem?.cancel()
        agentMenuCloseWorkItem?.cancel()
        agentMenuOpenWorkItem = nil
        agentMenuCloseWorkItem = nil
    }
}

private struct AIAgentSessionHoverMenu: View {
    let agents: [LaunchableAgent]
    let onLaunch: (LaunchableAgent) -> Void
    let onHover: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(agents) { agent in
                Button { onLaunch(agent) } label: {
                    HStack(spacing: 8) {
                        LaunchableAgentIcon(agent: agent, size: 15)
                        Text(AIAgentMenuPresentation.sessionTitle(for: agent))
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(AppStyle.textPrimary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 9)
                    .frame(width: 190, height: 30, alignment: .leading)
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(AppStyle.windowBackground)
        .onHover(perform: onHover)
    }
}

enum TabPillLayout {
    static let maxTitleWidth: CGFloat = 128
    static let minTitleWidth: CGFloat = 64
    static let minGroupTitleWidth: CGFloat = 72
}

private struct TabPill: View {
    let tab: ConductorCore.Tab
    let title: String
    let selected: Bool
    let index: Int
    let tabCount: Int
    @ObservedObject var coordinator: AppCoordinator
    let isEditing: Bool
    @Binding var draft: String
    var focused: FocusState<Bool>.Binding
    let onStartEdit: () -> Void
    let onCommitEdit: () -> Void
    let onSelect: () -> Void

    @State private var hovering = false
    @State private var closeHovering = false

    private var isGroup: Bool { tab.isGroup }
    private var showClose: Bool { (hovering || selected) && !isEditing }

    /// 悬停提示：⌘N 直达键位 + 完成未读说明（有则附）。
    private var pillHelp: String {
        var parts: [String] = []
        if index < 9 { parts.append("⌘\(index + 1)") }
        if hasUnseenDone { parts.append(L("有 Agent 已完成，点击查看")) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Group {
            if isEditing {
                pillContent   // 编辑态不是 Button，让 TextField 可交互
            } else {
                Button(action: onSelect) { pillContent }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture(count: 2).onEnded { onStartEdit() })   // 双击重命名
            }
        }
        .overlay(alignment: .trailing) {
            closeButton
                .opacity(showClose ? 1 : 0)
                .scaleEffect(showClose ? 1 : 0.6)
                .allowsHitTesting(showClose)
                .padding(.trailing, 7)
                .animation(Motion.snappy, value: showClose)
        }
        .animation(Motion.hover, value: hovering)
        .help(pillHelp)
        .contextMenu {
            Button { onStartEdit() } label: { Label(L("重命名"), systemImage: "pencil") }
            Divider()
            Button { coordinator.moveTab(tab.id, toIndex: index - 1) } label: {
                Label(L("向左移动"), systemImage: "arrow.left")
            }
            .disabled(index <= 0)
            Button { coordinator.moveTab(tab.id, toIndex: index + 1) } label: {
                Label(L("向右移动"), systemImage: "arrow.right")
            }
            .disabled(index >= tabCount - 1)
            Divider()
            Button { coordinator.newTab() } label: { Label(L("新建标签"), systemImage: "plus") }
            Button { coordinator.reopenClosed() } label: {
                Label(L("恢复最近关闭"), systemImage: "arrow.uturn.backward")
            }
            .disabled(!coordinator.hasRecentlyClosed)
            Button(role: .destructive) { coordinator.closeTab(tab.id) } label: {
                Label(L("关闭标签"), systemImage: "xmark")
            }
        }
        .onHover { hovering = $0 }
    }

    /// 该 tab 里在跑的 Agent（优先看活动 pane，否则取任一 pane）。
    private var tabAgentID: String? {
        if let active = coordinator.paneAgents[tab.activePane] { return active }
        return tab.rootSplit.leaves().compactMap { coordinator.paneAgents[$0] }.first
    }

    /// 该 tab（含分组里任一 pane）是否有 AI 正在思考。
    private var isThinking: Bool {
        tab.rootSplit.leaves().contains { coordinator.thinkingPanes.contains($0) }
    }

    /// 后台跑完还没被看过的 pane → 胶囊亮绿点（切过去看一眼即消）。
    private var hasUnseenDone: Bool {
        coordinator.tabHasUnseenDone(tab)
    }

    private var pillContent: some View {
        HStack(spacing: 6) {
            leadingIcon
                .frame(width: 13, height: 13)
                .overlay(alignment: .topTrailing) {
                    if isThinking {
                        ThinkingIndicator(size: 7)
                            .offset(x: 4, y: -4)
                            .transition(.scale.combined(with: .opacity))
                    } else if hasUnseenDone {
                        Circle()
                            .fill(AppStyle.doneGreen)
                            .frame(width: 7, height: 7)
                            .shadow(color: AppStyle.doneGreen.opacity(0.55), radius: 2.5)
                            .offset(x: 4, y: -4)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.2), value: isThinking)
                .animation(.easeOut(duration: 0.2), value: hasUnseenDone)
            if isEditing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(AppStyle.textPrimary)
                    .focused(focused)
                    .onSubmit { onCommitEdit() }
                    .frame(minWidth: 44, maxWidth: TabPillLayout.maxTitleWidth, alignment: .leading)
            } else {
                Text(title)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(
                        minWidth: isGroup ? TabPillLayout.minGroupTitleWidth : TabPillLayout.minTitleWidth,
                        maxWidth: TabPillLayout.maxTitleWidth,
                        alignment: .leading
                    )
                    .foregroundStyle(selected ? AppStyle.textPrimary : AppStyle.textSecondary)
            }
            if isGroup, !isEditing {
                Text("\(tab.paneCount)")
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .foregroundStyle(AppStyle.theme.primarySolidText)
                    .contentTransition(.numericText())
                    .frame(minWidth: 16, minHeight: 16)
                    .background(Circle().fill(Color(AppStyle.accent).opacity(selected ? 1 : 0.7)))
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            }
            Color.clear.frame(width: 15, height: 15)   // 预留 X 位
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.62), value: tab.paneCount)
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .fill(selected ? AnyShapeStyle(AppStyle.accent.opacity(0.14))
                               : (hovering ? AnyShapeStyle(AppStyle.hoverFill) : AnyShapeStyle(Color.clear)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .strokeBorder(selected ? AppStyle.accent.opacity(0.38) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var leadingIcon: some View {
        if let agentID = tabAgentID,
           let agent = AgentCatalog.all.first(where: { $0.id == agentID }) {
            if let logo = CLIToolLogo.image(named: agent.logo) {
                if CLIToolLogo.isMonochrome(agent.logo) {
                    Image(nsImage: logo)
                        .resizable().renderingMode(.template).interpolation(.high).scaledToFit()
                        .foregroundStyle(selected ? AppStyle.textPrimary : AppStyle.textSecondary)
                } else {
                    Image(nsImage: logo).resizable().interpolation(.high).scaledToFit()
                }
            } else {
                Image(systemName: agent.fallbackSystemImage)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(selected ? AppStyle.accent : AppStyle.textTertiary)
            }
        } else {
            Image(systemName: isGroup ? "rectangle.split.2x1" : "terminal")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(selected ? AppStyle.accent : AppStyle.textTertiary)
        }
    }

    private var closeButton: some View {
        Button(action: { coordinator.closeTab(tab.id) }) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(closeHovering ? AppStyle.theme.primarySolidText : AppStyle.textSecondary)
                .frame(width: 16, height: 16)
                .background(Circle().fill(closeHovering ? AppStyle.accent.opacity(0.9) : AppStyle.hoverFill))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(.easeOut(duration: 0.14)) { closeHovering = inside } }
        .help(L("关闭标签"))
    }
}
