import SwiftUI

enum AgentToolsChrome {
    // 几何常量收敛到统一阶梯（Radius / Space），保留符号名供 SkillsManagerView 等调用方编译。
    static let pagePadding: CGFloat = Space.md      // 16
    static let pageSpacing: CGFloat = Space.sm      // 12
    static let controlHeight: CGFloat = 34
    static let metricHeight: CGFloat = 48
    static let rowHeight: CGFloat = 48
    static let rowRadius: CGFloat = Radius.sm       // 8
    static let panelRadius: CGFloat = Radius.lg     // 16
    static let inspectorRadius: CGFloat = Radius.lg // 16
    // 去卡片后，原来的一堆柔填充（panelFill/tableFill/metricFill/rowFill/sectionFill）已无人使用，删除。
}

enum AgentToolsMotion {
    // 全工作台只用一种动画：统一的 easeOut(0.15)——不分档、不回弹、不缩放、不位移。
    // 各语义名都指向同一条 standard，让切 tab / 切视图 / 选中 / 开检视器 / hover 手感完全一致。
    static let standard = Animation.easeOut(duration: 0.15)
    static let route = standard
    static let selection = standard
    static let reveal = standard
    static let hover = standard
    static let loading = Animation.linear(duration: 0.85).repeatForever(autoreverses: false)

    // 过场：一律纯淡入淡出（无滑入 / 无缩放）。
    static let contentTransition = AnyTransition.opacity
    static let revealTransition = AnyTransition.opacity
}

struct AgentToolsModuleHeader<Actions: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    var color: Color?
    let actions: Actions

    init(title: String,
         subtitle: String,
         icon: String,
         color: Color? = nil,
         @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.color = color
        self.actions = actions()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                identity
                Spacer(minLength: 12)
                actions
            }

            VStack(alignment: .leading, spacing: 10) {
                identity
                actions
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var identity: some View {
        let tint = color ?? AppStyle.accent
        return HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.12)))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(AppStyle.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppStyle.textTertiary)
                    .lineLimit(2)
            }
        }
    }
}

struct AgentToolsSearchField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppStyle.textTertiary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(AppStyle.textPrimary)
            if !text.isEmpty {
                IconOnlyButton(
                    systemName: "xmark.circle.fill",
                    help: L("清空搜索"),
                    size: 20,
                    symbolSize: 10,
                    tint: AppStyle.textTertiary) {
                        withAnimation(AgentToolsMotion.selection) { text = "" }
                    }
                    .transition(AgentToolsMotion.revealTransition)
            }
        }
        .padding(.horizontal, 11)
        .frame(height: AgentToolsChrome.controlHeight)
        .background(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .fill(AppStyle.hoverFill.opacity(0.92)))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .strokeBorder(AppStyle.separator.opacity(0.18), lineWidth: 1))
        .animation(AgentToolsMotion.selection, value: text.isEmpty)
    }
}

struct AgentToolsMenuButton<Content: View>: View {
    let title: String
    let icon: String
    let content: Content

    init(title: String,
         icon: String,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        Menu {
            content
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
            }
            .foregroundStyle(AppStyle.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: AgentToolsChrome.controlHeight)
            .background(Capsule().fill(AppStyle.hoverFill.opacity(0.92)))
            .overlay(Capsule().strokeBorder(AppStyle.separator.opacity(0.18), lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .help(title)
    }
}

struct AgentToolsInspectorShell<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AgentToolsChrome.pageSpacing) {
            ToolsSectionLabel(L("检查器"))
            content
            Spacer(minLength: 0)
        }
        .padding(Space.sm)
        .frame(width: AgentToolsConsoleLayout.inspectorWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .agentToolsGlass()   // 半透明玻璃面板（透出工作台底纹）
    }
}

// MARK: - 编辑化构件（去卡片）：大号数字、分区、详情行、文字链接。
// 替代旧的 AgentToolsMetricCard / AgentToolsTableSurface / 各文件重复的 inspectorSection。

/// 大号数值块：值 + 标签 +（可选）副文，直接坐画布，不套卡片。
struct AgentToolsStat: View {
    let value: String
    let title: String
    var sub: String?
    var valueColor: Color = AppStyle.textPrimary
    var action: (() -> Void)?

    var body: some View {
        if let action {
            Button(action: action) { content }.buttonStyle(PressScaleStyle())
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 6) {
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(valueColor)
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(AppStyle.textSecondary)
        }
        .contentShape(Rectangle())
        .help(sub ?? title)
    }
}

/// 编辑化分区：小号大写区标题 + 内容，靠间距分组，不套盒子。
struct AgentToolsSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(AppStyle.textTertiary)
            content
        }
    }
}

/// label … value 详情行。
struct AgentToolsInfoRow: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(AppStyle.textTertiary)
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: 10.5, weight: monospaced ? .regular : .semibold, design: monospaced ? .monospaced : .default))
                .foregroundStyle(AppStyle.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// 轻量文字链接动作（替代填充按钮汤）。
struct AgentToolsLinkButton: View {
    let title: String
    var icon: String?
    var tint: Color = AppStyle.textSecondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 10.5, weight: .semibold))
                }
                Text(title).font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(tint)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
    }
}

struct AgentToolsWorkbenchBrand: View {
    let icon: String
    let title: String
    let subtitle: String
    var tint: Color = AppStyle.accent

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: Radius.sm + 1, style: .continuous).fill(tint.opacity(0.12)))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(AppStyle.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(AppStyle.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }
}

struct AgentToolsWorkbenchRailSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(AppStyle.textTertiary)
                .padding(.horizontal, 9)
                .textCase(.uppercase)
            content
        }
    }
}

struct AgentToolsWorkbenchRailButton: View {
    let icon: String
    let title: String
    let subtitle: String
    var badge: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(selected ? AppStyle.accent : AppStyle.textTertiary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 11.5, weight: selected ? .bold : .semibold))
                        .foregroundStyle(selected ? AppStyle.textPrimary : AppStyle.textSecondary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 8.8, weight: .medium))
                        .foregroundStyle(AppStyle.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if let badge {
                    Text(badge)
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(selected ? AppStyle.accent : AppStyle.textTertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .fill(selected ? AppStyle.accent.opacity(0.12) : Color.clear))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .stroke(selected ? AppStyle.accent.opacity(0.28) : Color.clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .help(subtitle)
    }
}

private struct AgentToolsPageModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(AgentToolsChrome.pagePadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

extension View {
    func agentToolsPage() -> some View {
        modifier(AgentToolsPageModifier())
    }

    /// Agent Tools 内容面。这里不用系统 material：内容层叠 material 在深色主题下会压成黑块，
    /// 看起来像另一个嵌入式应用。改为主题内的轻量 surface，让所有模块保持同一画布语言。
    func agentToolsGlass(cornerRadius: CGFloat = Radius.lg) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let theme = AppStyle.theme
        let fill: AnyShapeStyle = AppStyle.theme.isDark
            ? AnyShapeStyle(theme.elevated.opacity(0.34))
            : AnyShapeStyle(Color.black.opacity(0.022))
        // 边缘高光 rim：顶亮→底暗的 1px 渐变描边，比平描边更像玻璃（调研结论：玻璃质感主要来自 rim）。
        let rim = LinearGradient(
            colors: theme.isDark
                ? [Color.white.opacity(0.22), Color.white.opacity(0.05)]
                : [Color.white.opacity(0.7), Color.black.opacity(0.06)],
            startPoint: .top, endPoint: .bottom)
        return background(shape.fill(fill))
            .overlay(shape.strokeBorder(rim, lineWidth: 1))
    }
}
