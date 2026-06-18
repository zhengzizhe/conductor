import AppKit
import ConductorCore
import SwiftUI

enum AgentToolsManagementModule: String, CaseIterable, Identifiable {
    case overview
    case cli
    case usage
    case skills
    case mcp
    case hooks
    case snippets
    case activity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return L("总览")
        case .cli: return "CLI"
        case .usage: return L("用量")
        case .skills: return "Skills"
        case .mcp: return "MCP"
        case .hooks: return "Hooks"
        case .snippets: return L("片段")
        case .activity: return L("活动")
        }
    }

    var subtitle: String {
        switch self {
        case .overview: return L("跨渠道能力、状态和入口")
        case .cli: return L("命令行工具、渠道和凭证")
        case .usage: return L("账号用量、成本和趋势")
        case .skills: return L("中央库、安装和分发")
        case .mcp: return L("服务器、工具和授权")
        case .hooks: return L("事件、通知和自动化")
        case .snippets: return L("片段、模板和快捷动作")
        case .activity: return L("日志、变更和任务轨迹")
        }
    }

    var icon: String {
        switch self {
        case .overview: return "rectangle.3.group"
        case .cli: return "terminal"
        case .usage: return "chart.bar.xaxis"
        case .skills: return "wand.and.stars"
        case .mcp: return "point.3.connected.trianglepath.dotted"
        case .hooks: return "link"
        case .snippets: return "text.badge.star"
        case .activity: return "waveform.path.ecg"
        }
    }

    /// 管理台左栏只展示已实现的模块。片段/活动仍走各自现成入口，不在这里摆空占位。
    static let railModules: [AgentToolsManagementModule] = [.overview, .cli, .usage, .skills, .mcp, .hooks]
}

enum AgentToolsConsoleLayout {
    static let horizontalPadding: CGFloat = 18
    static let bottomPadding: CGFloat = 18
    static let columnGap: CGFloat = 10
    static let railWidth: CGFloat = 174
    static let inspectorWidth: CGFloat = 248

    struct Columns {
        let sidePadding: CGFloat
        let gap: CGFloat
        let railWidth: CGFloat
        let workspaceWidth: CGFloat
        let inspectorWidth: CGFloat
    }

    static func modalSize() -> CGSize {
        let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1512, height: 982)
        let maxWidth = max(960, visible.width - 64)
        let maxHeight = max(680, visible.height - 64)
        let preferredWidth = min(1540, max(1180, visible.width * 0.90))
        let preferredHeight = min(920, max(760, visible.height * 0.86))
        return CGSize(
            width: min(preferredWidth, maxWidth),
            height: min(preferredHeight, maxHeight))
    }

    static func columns(for containerWidth: CGFloat) -> Columns {
        let sidePadding = min(horizontalPadding, max(10, containerWidth * 0.018))
        let contentWidth = max(0, containerWidth - (sidePadding * 2))
        let compact = contentWidth < 1180
        let rail = railWidth
        let inspector = inspectorWidth
        let gap = compact ? 8 : columnGap
        let workspace = max(520, contentWidth - rail - inspector - (gap * 2))
        return Columns(
            sidePadding: sidePadding,
            gap: gap,
            railWidth: rail,
            workspaceWidth: workspace,
            inspectorWidth: inspector)
    }

    static func columns(for containerWidth: CGFloat, module: AgentToolsManagementModule) -> Columns {
        let sidePadding = min(horizontalPadding, max(10, containerWidth * 0.018))
        let contentWidth = max(0, containerWidth - (sidePadding * 2))
        let compact = contentWidth < 1180
        let gap = compact ? 8 : columnGap
        if module == .skills {
            return Columns(
                sidePadding: sidePadding,
                gap: gap,
                railWidth: railWidth,
                workspaceWidth: max(620, contentWidth - railWidth - gap),
                inspectorWidth: 0)
        }
        return columns(for: containerWidth)
    }
}

struct AgentToolsManagementConsoleView: View {
    let initialModule: AgentToolsManagementModule
    var onLaunchCLI: (String) -> Void
    var onApplyConfig: (AppConfig) -> Void
    var onClose: () -> Void

    @StateObject private var store: AgentToolsConsoleStore
    @ObservedObject private var configStore = ConfigStore.shared
    @State private var selectedModule: AgentToolsManagementModule
    @State private var skillsInitialSection = "library"
    @State private var skillsReloadID = UUID()

    init(
        initialModule: AgentToolsManagementModule = .overview,
        onLaunchCLI: @escaping (String) -> Void = { _ in },
        onApplyConfig: @escaping (AppConfig) -> Void = { _ in },
        onClose: @escaping () -> Void
    ) {
        self.initialModule = initialModule
        self.onLaunchCLI = onLaunchCLI
        self.onApplyConfig = onApplyConfig
        self.onClose = onClose
        _selectedModule = State(initialValue: initialModule)
        _store = StateObject(wrappedValue: AgentToolsConsoleStore())
    }

    var body: some View {
        let preferredSize = AgentToolsConsoleLayout.modalSize()
        VStack(spacing: 0) {
            header
            GeometryReader { proxy in
                let columns = AgentToolsConsoleLayout.columns(for: proxy.size.width, module: selectedModule)
                let contentHeight = max(0, proxy.size.height - AgentToolsConsoleLayout.bottomPadding)
                let railX = columns.sidePadding
                let workspaceX = railX + columns.railWidth + columns.gap
                let inspectorX = workspaceX + columns.workspaceWidth + columns.gap
                ZStack(alignment: .topLeading) {
                    moduleRail
                        .frame(width: columns.railWidth)
                        .frame(height: contentHeight)
                        .clipped()
                        .offset(x: railX, y: 0)
                        .zIndex(3)

                    workspace
                        .id(selectedModule)
                        .transition(AgentToolsMotion.contentTransition)
                        .frame(width: columns.workspaceWidth)
                        .frame(height: contentHeight)
                        .clipped()
                        .offset(x: workspaceX, y: 0)
                        .zIndex(1)

                    if columns.inspectorWidth > 0 {
                        inspector
                            .id("inspector-\(selectedModule.rawValue)")
                            .transition(AgentToolsMotion.contentTransition)
                            .frame(width: columns.inspectorWidth)
                            .frame(height: contentHeight)
                            .clipped()
                            .offset(x: inspectorX, y: 0)
                            .zIndex(2)
                    }
                }
                .frame(width: proxy.size.width, height: contentHeight, alignment: .topLeading)
                .padding(.bottom, AgentToolsConsoleLayout.bottomPadding)
                .clipped()
                .animation(AgentToolsMotion.selection, value: selectedModule)
            }
        }
        .frame(
            minWidth: 1120,
            idealWidth: preferredSize.width,
            minHeight: 720,
            idealHeight: preferredSize.height)
        .background(AppStyle.windowBackground)   // 工作台用纯色底，不透出桌面；半透明只留给卡片本身
        .onAppear { store.start() }
        .onChange(of: initialModule) { _, module in
            withAnimation(AgentToolsMotion.selection) { selectedModule = module }
        }
    }

    private var header: some View {
        HStack(spacing: Space.sm) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L("Agent Tools 管理台"))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(AppStyle.textPrimary)
                Text(L("统一管理 CLI、用量、Skills、MCP、Hooks 和自动化能力"))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(AppStyle.textTertiary)
            }

            Spacer()

            IconOnlyButton(
                systemName: "xmark",
                help: L("关闭"),
                size: 30,
                symbolSize: 11,
                weight: .bold,
                action: onClose)
        }
        .padding(.horizontal, Space.lg)
        .padding(.top, Space.lg)
        .padding(.bottom, Space.sm)
    }

    private var moduleRail: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(L("模块"))
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(AppStyle.textTertiary)
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 6)

            ForEach(AgentToolsManagementModule.railModules) { module in
                moduleButton(module)
            }

            Spacer(minLength: 0)
        }
        .frame(width: AgentToolsConsoleLayout.railWidth)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func moduleButton(_ module: AgentToolsManagementModule) -> some View {
        let selected = selectedModule == module
        return Button {
            withAnimation(AgentToolsMotion.selection) { selectedModule = module }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: module.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected ? AppStyle.accent : AppStyle.textTertiary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(module.title)
                        .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? AppStyle.textPrimary : AppStyle.textSecondary)
                    Text(module.subtitle)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(AppStyle.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .fill(selected ? AppStyle.accent.opacity(0.12) : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .help(module.subtitle)
        .animation(AgentToolsMotion.selection, value: selected)
    }

    private var workspace: some View {
        Group {
            switch selectedModule {
            case .overview:
                AgentToolsOverviewView(store: store, onOpenModule: openModule)
            case .cli:
                AgentToolsCLIView(store: store, onLaunch: onLaunchCLI, onOpenModule: openModule)
            case .usage:
                AgentToolsUsageView(
                    store: store,
                    onApplyConfig: onApplyConfig,
                    onOpenModule: openModule)
            case .skills:
                AgentToolsSkillsView(
                    store: store,
                    initialSection: skillsInitialSection,
                    reloadID: skillsReloadID,
                    onOpenModule: openModule)
            case .mcp:
                AgentToolsMCPWorkbenchView(store: store)
            case .hooks:
                AgentToolsHooksWorkbenchView(store: store)
            default:
                placeholderWorkspace
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var placeholderWorkspace: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: selectedModule.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AppStyle.accent)
                    .frame(width: 42, height: 42)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppStyle.accent.opacity(0.12)))

                VStack(alignment: .leading, spacing: 3) {
                    Text(selectedModule.title)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(AppStyle.textPrimary)
                    Text(selectedModule.subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppStyle.textTertiary)
                }

                Spacer()
            }

            VStack(spacing: 14) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(AppStyle.textTertiary.opacity(0.65))
                Text(L("管理台内容暂空"))
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(AppStyle.textPrimary)
                Text(L("这里先保留完整管理台容器，后续把各模块的真实列表、详情、右键菜单和批量操作接进来。"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppStyle.textTertiary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                    .fill(AppStyle.hoverFill.opacity(AppStyle.theme.isDark ? 0.36 : 0.52)))
        }
        .padding(AgentToolsChrome.pagePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var inspector: some View {
        Group {
            switch selectedModule {
            case .overview:
                AgentToolsOverviewInspector(store: store, onOpenModule: openModule)
            case .cli:
                AgentToolsCLIInspector(store: store, onLaunch: onLaunchCLI, onOpenModule: openModule)
            case .usage:
                AgentToolsUsageInspector(store: store)
            case .skills:
                AgentToolsSkillsInspector(
                    store: store,
                    onOpenModule: openModule,
                    onOpenSection: openSkillsSection)
            case .mcp:
                AgentToolsMCPInspector(store: store)
            case .hooks:
                AgentToolsHooksInspector(store: store)
            default:
                placeholderInspector
            }
        }
    }

    private var placeholderInspector: some View {
        AgentToolsInspectorShell {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("当前模块"))
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(AppStyle.textTertiary)
                inspectorRow(L("模块"), selectedModule.title)
                inspectorRow(L("状态"), L("待接入"))
                inspectorRow(L("入口"), L("顶部按钮 / 右侧面板"))
            }

            Text(L("这个区域后续承载选中对象详情、标签、危险操作和上下文动作。"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppStyle.textTertiary)
                .lineSpacing(3)
        }
    }

    private func inspectorRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(AppStyle.textTertiary)
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(AppStyle.textSecondary)
                .lineLimit(1)
        }
    }

    private func openModule(_ module: AgentToolsManagementModule) {
        withAnimation(AgentToolsMotion.selection) { selectedModule = module }
    }

    private func openSkillsSection(_ section: String) {
        withAnimation(AgentToolsMotion.selection) {
            selectedModule = .skills
            skillsInitialSection = section
            skillsReloadID = UUID()
        }
    }
}
