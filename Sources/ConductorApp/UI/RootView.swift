import AppKit
import SwiftUI

/// 整体布局：左侧工作区栏 | (顶部 Tab 栏 + 终端分屏区)。
struct RootView: View {
    @ObservedObject var coordinator: AppCoordinator
    /// 观察配置：主题变化时整棵外壳重渲染(AppStyle 跟随)。
    @ObservedObject private var configStore = ConfigStore.shared
    /// 语言热切换：revision 变 → `.id()` 强制整棵树重建，所有 L() 文案按新语言重新求值。
    @ObservedObject private var localization = AppLanguage.revision
    /// 侧栏与右侧面板宽度（分隔条可拖拽，持久化）。
    @ObservedObject private var panelWidths = PanelWidthStore.shared

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(coordinator: coordinator)
                .frame(width: coordinator.sidebarPresentation.isCollapsed ? AppStyle.sidebarCollapsedWidth : panelWidths.sidebar)
                .overlay(alignment: .trailing) {
                    if !coordinator.sidebarPresentation.isCollapsed {
                        PanelResizeHandle(
                            edge: .trailing, width: $panelWidths.sidebar,
                            range: PanelWidthStore.sidebarRange, defaultWidth: AppStyle.sidebarWidth)
                    }
                }
            VStack(spacing: 0) {
                TabBarView(coordinator: coordinator)
                ZStack(alignment: .center) {
                    TerminalAreaView(container: coordinator.containerView)
                    if showsQuickStartEmptyState {
                        QuickStartLaunchPanel(
                            title: activeWorkspaceName,
                            subtitle: L("选择下一步开始工作"),
                            primaryActions: terminalPrimaryActions,
                            secondaryActions: terminalSecondaryActions
                        )
                        .padding(.horizontal, 32)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.96).combined(with: .opacity),
                            removal: .scale(scale: 0.96).combined(with: .opacity)))
                    }
                }
                // 空状态插图的出现/消失就地动画；不放在根上——根级按 pane 数
                // 触发动画会让整个 HStack 布局跟着 diff，殃及无关部分。
                .animation(Motion.panel, value: showsQuickStartEmptyState)
                StatusBarView(coordinator: coordinator, usageMonitor: coordinator.usageMonitor)
            }
            if coordinator.settingsPresentation.isPresented {
                SettingsView(coordinator: coordinator, onClose: { coordinator.closeSettings() })
                    .frame(width: panelWidths.settings)
                    .overlay(alignment: .leading) {
                        PanelResizeHandle(
                            edge: .leading, width: $panelWidths.settings,
                            range: PanelWidthStore.settingsRange, defaultWidth: PanelWidthStore.settingsDefault)
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            if coordinator.cliToolsPresentation.isPresented {
                ToolsPanelView(coordinator: coordinator, onClose: { coordinator.closeCLITools() })
                    .frame(width: panelWidths.tools)
                    .overlay(alignment: .leading) {
                        PanelResizeHandle(
                            edge: .leading, width: $panelWidths.tools,
                            range: PanelWidthStore.toolsRange, defaultWidth: PanelWidthStore.toolsDefault)
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            if coordinator.sessionPresentation.isPresented {
                SessionManagerView(coordinator: coordinator, onClose: { coordinator.closeSessionManager() })
                    .frame(width: panelWidths.session)
                    .overlay(alignment: .leading) {
                        PanelResizeHandle(
                            edge: .leading, width: $panelWidths.session,
                            range: PanelWidthStore.sessionRange, defaultWidth: PanelWidthStore.sessionDefault)
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .id(localization.value)   // 语言切换 → 重建子树（TerminalAreaView 复用同一 NSView，终端不受影响）
        .background {
            // 光晕主题 → 暗底 + 彩色 radial 光晕（不透桌面）；纯色/玻璃主题 → 统一磨砂基底（露出背衬模糊）。
            ThemeBackdrop(theme: AppStyle.theme)
        }
        .ignoresSafeArea()
        .animation(Motion.panel, value: coordinator.sidebarPresentation.isCollapsed)
        .animation(Motion.panel, value: coordinator.settingsPresentation.isPresented)
        .animation(Motion.panel, value: coordinator.cliToolsPresentation.isPresented)
        .animation(Motion.panel, value: coordinator.sessionPresentation.isPresented)
        // Agent Tools 管理台改为独立 NSWindow（见 AppCoordinator+AgentToolsWindow），不再用模态 sheet。
        // 这些动画会逐帧改终端区宽度；冻结期间终端只随层拉伸，结束后一次性 resize。
        .onChange(of: coordinator.sidebarPresentation.isCollapsed) { freezeTerminalResizeForPanelAnimation() }
        .onChange(of: coordinator.settingsPresentation.isPresented) { freezeTerminalResizeForPanelAnimation() }
        .onChange(of: coordinator.cliToolsPresentation.isPresented) { freezeTerminalResizeForPanelAnimation() }
        .onChange(of: coordinator.sessionPresentation.isPresented) { freezeTerminalResizeForPanelAnimation() }
    }

    /// Motion.panel（spring response 0.28）视觉上约 0.4s 收敛；冻结到动画结束再统一 resize。
    private func freezeTerminalResizeForPanelAnimation() {
        TerminalResizeFreeze.shared.freeze(for: 0.45)
    }

    private var showsQuickStartEmptyState: Bool {
        QuickStartAvailability.showsEmptyIllustration(
            tabCount: activeWorkspaceMetrics?.tabCount,
            totalPaneCount: activeWorkspaceMetrics?.totalPaneCount,
            isPanelPresented: coordinator.isSidePanelPresented
        )
    }

    private var activeWorkspaceMetrics: (tabCount: Int, totalPaneCount: Int)? {
        guard let workspace = coordinator.store.workspaces.first(where: { $0.id == coordinator.store.activeWorkspace }) else {
            return nil
        }
        return (
            tabCount: workspace.tabs.count,
            totalPaneCount: workspace.tabs.reduce(0) { $0 + $1.paneCount }
        )
    }

    private var activeWorkspaceName: String {
        coordinator.store.workspaces.first { $0.id == coordinator.store.activeWorkspace }?.name ?? L("工作区")
    }

    private var terminalPrimaryActions: [QuickStartAction] {
        [
            QuickStartAction(id: "newTab", title: L("新标签"), systemImage: "plus", shortcut: shortcut("newTab"), isPrimary: true) {
                coordinator.newTab()
            },
        ]
    }

    private var terminalSecondaryActions: [QuickStartAction] {
        [
            QuickStartAction(id: "commandPalette", title: L("命令"), systemImage: "command", shortcut: shortcut("commandPalette")) {
                coordinator.openCommandPalette()
            },
            QuickStartAction(id: "openSettings", title: L("设置"), systemImage: "gearshape", shortcut: shortcut("openSettings")) {
                coordinator.openSettings()
            },
        ]
    }

    /// 取命令当前有效键位并符号化（如「⌘T」），供空状态键帽展示；未绑定则回退到图标。
    private func shortcut(_ id: String) -> String? {
        coordinator.commandRegistry.effectiveKeybinding(for: id).map(ShortcutSymbolizer.symbolize)
    }
}

/// 把 AppKit 的终端分屏容器（承载 libghostty 视图）嵌入 SwiftUI 布局。
struct TerminalAreaView: NSViewRepresentable {
    let container: NSView
    func makeNSView(context: Context) -> NSView { container }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// 主题背景：暗底 + 若干彩色 radial 光晕（screen 叠加，像有光打进来）。
/// 比线性渐变更有空间感——深→深的线性扫光跨整窗几乎看不出，等于一块闷死的纯色。
/// 无光晕的主题（纯色/玻璃）回落到统一磨砂基底，露出窗口背衬模糊。
struct ThemeBackdrop: View {
    let theme: Theme

    var body: some View {
        if let glows = theme.backgroundGlows {
            GeometryReader { geo in
                let maxDim = max(geo.size.width, geo.size.height)
                ZStack {
                    theme.windowBackground
                    ForEach(Array(glows.enumerated()), id: \.offset) { _, g in
                        RadialGradient(
                            gradient: Gradient(colors: [g.color.opacity(g.intensity), g.color.opacity(0)]),
                            center: g.center,
                            startRadius: 0,
                            endRadius: maxDim * g.radius)
                        .blendMode(.screen)
                    }
                }
                .compositingGroup()   // 隔离 screen 叠加：只在暗底 + 光晕之间合成，不影响背衬
            }
        } else {
            AppStyle.chromeFill
        }
    }
}
