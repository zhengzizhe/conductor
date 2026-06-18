import SwiftUI

/// 工具面板分段。
enum ToolsTab: String, CaseIterable, Identifiable {
    case cli
    case usage
    case skills
    case hooks
    case snippets
    case coCreate

    var id: String { rawValue }
    /// 右侧只保留快速查看/轻量工具；大型管理对象进入 Agent Tools 管理台。
    static var panelTabs: [ToolsTab] { [.cli, .usage, .snippets] }

    var managementModule: AgentToolsManagementModule? {
        switch self {
        case .skills: return .skills
        case .hooks: return .hooks
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .cli: return "CLI"
        case .usage: return L("用量")
        case .skills: return "Skills"
        case .hooks: return "Hooks"
        case .snippets: return L("片段")
        case .coCreate: return L("共创")
        }
    }
    var icon: String {
        switch self {
        case .cli: return "terminal"
        case .usage: return "chart.bar.xaxis"
        case .skills: return "wand.and.stars"
        case .hooks: return "link"
        case .snippets: return "text.badge.star"
        case .coCreate: return "text.bubble"
        }
    }
}

/// 右侧快速工具面板：只放 CLI、用量和片段；Skills / Agents / Hooks 走完整管理台。
struct ToolsPanelView: View {
    let coordinator: AppCoordinator
    var onClose: () -> Void = {}
    /// 主题变 → 重渲染（AppStyle 跟随）。不观察的话切主题后面板会停在旧配色。
    @ObservedObject private var configStore = ConfigStore.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .frame(maxHeight: .infinity)
        .background(.clear)   // 透明：用根底统一磨砂
    }

    private var header: some View {
        HStack(spacing: 10) {
            segmented
            Spacer(minLength: 8)
            IconOnlyButton(
                systemName: "xmark",
                help: L("关闭"),
                size: 28,
                symbolSize: 11,
                weight: .bold,
                action: onClose)
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    /// 分段控件：凹槽容器 + 选中片「抬起」（白片/亮片 + 柔阴影），对标系统分段而非彩色按钮。
    private var segmented: some View {
        let theme = AppStyle.theme
        return ScrollView(.horizontal) {
            HStack(spacing: 2) {
                ForEach(ToolsTab.panelTabs) { tab in
                    let selected = coordinator.toolsTab == tab
                    Button {
                        withAnimation(Motion.snappy) {
                            coordinator.toolsTab = tab
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(selected ? AppStyle.accent : AppStyle.textTertiary)
                            Text(tab.title)
                                .font(.system(size: 11, weight: selected ? .semibold : .medium))
                                .foregroundStyle(selected ? AppStyle.textPrimary : AppStyle.textSecondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }
                        .padding(.horizontal, 7)
                        .frame(height: 24)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(theme.elevated)
                                    .shadow(color: .black.opacity(theme.isDark ? 0.35 : 0.10), radius: 3, y: 1)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
        }
        .scrollIndicators(.never)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(AppStyle.hoverFill))
    }

    @ViewBuilder
    private var content: some View {
        switch coordinator.toolsTab {
        case .cli:
            CLIToolsView(coordinator: coordinator, onClose: onClose)
        case .usage:
            UsageStatsView {
                coordinator.openAgentToolsManagement(.usage)
            }
        case .skills, .hooks:
            Color.clear
                .onAppear {
                    if let module = coordinator.toolsTab.managementModule {
                        coordinator.openAgentToolsManagement(module)
                    }
                    coordinator.toolsTab = .cli
                }
        case .snippets:
            SnippetsManagerView(coordinator: coordinator)
        case .coCreate:
            CoCreateView()
        }
    }
}
