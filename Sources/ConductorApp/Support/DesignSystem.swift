import AppKit
import SwiftUI

// 设计系统：统一的间距 / 圆角阶梯、毛玻璃材质、浮层质感与按钮层级。
// 目标是把散落的魔法数字收敛成一套有节奏的 token（对标 Craft 的「呼吸感 + 层次」）。

/// 间距阶梯（4 / 8 栅格）。优先用它，少写裸数字。
enum Space {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 20
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

/// 圆角阶梯（全部 continuous / squircle）。外层大、内层中、控件小，形成节奏。
enum Radius {
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
}

/// 动效节奏 token：散落的 spring/duration 收敛到几个语义档位。
/// 参数取向：快起步、克制回弹——120Hz 下高频微动效以「跟手」优先。
enum Motion {
    /// 面板/抽屉开合（侧栏、设置、会话面板滑入滑出）。
    static let panel = Animation.spring(response: 0.28, dampingFraction: 0.88)
    /// 列表/树的展开折叠与重排（文件夹树、transcript 展开、置顶移位）。
    static let expand = Animation.spring(response: 0.24, dampingFraction: 0.9)
    /// 小元素强调：选中指示器滑动、chip 出现、关闭钮浮现。
    static let snappy = Animation.spring(response: 0.22, dampingFraction: 0.85)
    /// hover/按压微反馈。
    static let hover = Animation.easeOut(duration: 0.12)
    /// CA 显式动画在 ProMotion 屏上的帧率区间（默认调度可能停在 60Hz）。
    static let frameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
}

extension CAAnimation {
    /// 嘱咐 CoreAnimation 这段动画值得跑满 120Hz（ProMotion）。
    @discardableResult
    func allowHighFrameRate() -> Self {
        preferredFrameRateRange = Motion.frameRateRange
        return self
    }
}

/// 把 AppKit 的 `NSVisualEffectView` 包成 SwiftUI 背景：真·毛玻璃（blur + 半透明）。
/// 关键：材质默认跟随**系统外观**；这里强制 `appearance` 跟随 app 自己的主题，否则
/// 系统深色 + app 浅色主题会渲染成深灰一片。
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    var isDark: Bool

    private var resolvedAppearance: NSAppearance? {
        NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        view.appearance = resolvedAppearance
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
        view.appearance = resolvedAppearance
    }
}

/// 浮层质感：毛玻璃底 + 半透明色调 + 顶部高光描边 + 细边框 + 双层柔阴影。
/// 这就是 Craft 那种「玻璃浮起」的来源——三件套：材质、顶部 1px 高光、双层扩散阴影。
struct ConductorFloatingPanel: ViewModifier {
    var cornerRadius: CGFloat = Radius.xl
    /// `behindWindow` 透出桌面（真浮层，如命令面板）；`withinWindow` 只融窗内（如停靠面板）。
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    @MainActor private var theme: Theme { AppStyle.theme }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background {
                ZStack {
                    VisualEffectBackground(
                        material: theme.isDark ? .hudWindow : .popover,
                        blending: blending,
                        isDark: theme.isDark)
                    theme.panelTint   // 半透明色调压在毛玻璃上，定调冷暖与明度
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(theme.panelHairline, lineWidth: 1))   // 细边
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [theme.panelHighlight, .clear],
                        startPoint: .top, endPoint: .center),
                    lineWidth: 1)                                              // 顶部高光（灵魂）
            )
            .shadow(color: .black.opacity(theme.isDark ? 0.55 : 0.18), radius: 30, y: 18)
            .shadow(color: .black.opacity(theme.isDark ? 0.30 : 0.07), radius: 6, y: 3)
    }
}

extension View {
    /// 真浮层（透出桌面）：命令面板、弹出菜单等。
    func conductorFloatingPanel(cornerRadius: CGFloat = Radius.xl) -> some View {
        modifier(ConductorFloatingPanel(cornerRadius: cornerRadius, blending: .behindWindow))
    }

    /// 窗内材质（融入主窗）：停靠的设置 / 检查器面板。
    func conductorInWindowPanel(cornerRadius: CGFloat = 0) -> some View {
        modifier(ConductorFloatingPanel(cornerRadius: cornerRadius, blending: .withinWindow))
    }
}

/// 工具面板卡片：抬起表面（浅色=白卡 + 柔阴影，深色=微亮面 + 细边），
/// 取代「灰描边空框」的老式卡片，让面板与外壳同一质感。
struct ToolsCard: ViewModifier {
    var cornerRadius: CGFloat = Radius.md
    /// 必须观察：modifier 是独立渲染节点，字段不变时 SwiftUI 会跳过 body，
    /// 切主题后卡片底色会停在旧配色（白卡压深底）。
    @ObservedObject private var configStore = ConfigStore.shared
    @MainActor private var theme: Theme { AppStyle.theme }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background(shape.fill(theme.isDark ? Color.white.opacity(0.045) : .white))
            .overlay(shape.strokeBorder(
                theme.isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.05),
                lineWidth: 1))
            .shadow(
                color: Color(nsColor: theme.cardShadowColor).opacity(theme.isDark ? 0 : 0.06),
                radius: 9, y: 3)
    }
}

extension View {
    /// 工具面板的标准卡片表面。
    func toolsCard(cornerRadius: CGFloat = Radius.md) -> some View {
        modifier(ToolsCard(cornerRadius: cornerRadius))
    }
}

/// 工具面板分组标签：小号大写、加字距，弱化存在感、强化节奏。
struct ToolsSectionLabel: View {
    let text: String
    /// 主题变 → 重渲染（字段不变时 SwiftUI 会跳过 body）。
    @ObservedObject private var configStore = ConfigStore.shared

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.9)
            .textCase(.uppercase)
            .foregroundStyle(AppStyle.textTertiary)
    }
}

enum ToolBadgeStyle {
    case soft
    case solid
    case muted
}

struct ToolBadge: View {
    let text: String
    var icon: String?
    var color: Color = AppStyle.textTertiary
    var style: ToolBadgeStyle = .soft
    var height: CGFloat = 20

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .bold))
            }
            Text(text)
                .font(.system(size: 9.5, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 6)
        .frame(height: height)
        .background(Capsule().fill(background))
    }

    private var foreground: Color {
        switch style {
        case .solid: .white
        case .soft: color
        case .muted: AppStyle.textTertiary
        }
    }

    private var background: Color {
        switch style {
        case .solid: color
        case .soft: color.opacity(0.13)
        case .muted: AppStyle.hoverFill.opacity(0.7)
        }
    }
}

enum ToolActionRole {
    case primary
    case secondary
    case tinted(Color)
    case destructive
}

struct ToolActionButton: View {
    let title: String
    var systemImage: String?
    var role: ToolActionRole = .secondary
    var height: CGFloat = 27
    var fontSize: CGFloat = 11.5
    var horizontalPadding: CGFloat = 12
    var help: String?
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: systemImage == nil ? 0 : 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: fontSize - 1, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: fontSize, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background(Capsule().fill(background))
            .overlay(Capsule().strokeBorder(border, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
        .help(help ?? title)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
    }

    private var foreground: Color {
        switch role {
        case .primary:
            AppStyle.theme.primarySolidText
        case .secondary:
            AppStyle.textSecondary
        case let .tinted(color):
            color
        case .destructive:
            AppStyle.errorRed
        }
    }

    private var background: Color {
        switch role {
        case .primary:
            AppStyle.theme.primarySolid
        case .secondary:
            AppStyle.hoverFill.opacity(hovering ? 1 : 0.82)
        case let .tinted(color):
            color.opacity(hovering ? 0.16 : 0.11)
        case .destructive:
            AppStyle.errorRed.opacity(hovering ? 0.16 : 0.10)
        }
    }

    private var border: Color {
        switch role {
        case .primary:
            Color.white.opacity(AppStyle.theme.isDark ? 0.14 : 0)
        case .secondary:
            AppStyle.separator.opacity(hovering ? 0.8 : 0.45)
        case let .tinted(color):
            color.opacity(hovering ? 0.22 : 0)
        case .destructive:
            AppStyle.errorRed.opacity(hovering ? 0.22 : 0)
        }
    }
}

struct ToolEmptyState: View {
    let icon: String
    let title: String
    var detail: String?
    var compact = false

    var body: some View {
        VStack(alignment: compact ? .center : .leading, spacing: compact ? 8 : 8) {
            Image(systemName: icon)
                .font(.system(size: compact ? 17 : 18, weight: .semibold))
                .foregroundStyle(AppStyle.textTertiary)
            Text(title)
                .font(.system(size: compact ? 11.5 : 12.5, weight: .semibold))
                .foregroundStyle(compact ? AppStyle.textSecondary : AppStyle.textPrimary)
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(AppStyle.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
        .padding(compact ? 0 : 14)
        .frame(minHeight: compact ? 92 : nil)
        .background {
            if compact {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AppStyle.hoverFill.opacity(0.45))
            }
        }
    }
}

struct ToolStatusLine: View {
    let icon: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .frame(minHeight: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color.opacity(0.10)))
    }
}

/// 工具面板卡片内部的轻分组。用于替代硬 Divider，让详情信息像同一块面板里的延展层。
struct ToolSoftGroup<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppStyle.hoverFill.opacity(0.36)))
    }
}

/// 主操作按钮：高对比石墨实心胶囊（深色→近白，浅色→近黑）。全屏只该有一个。
struct PrimaryButtonStyle: ButtonStyle {
    var height: CGFloat = 32
    var horizontalPadding: CGFloat = Space.md
    var fontSize: CGFloat = 13
    var weight: Font.Weight = .semibold
    @MainActor private var theme: Theme { AppStyle.theme }

    func makeBody(configuration: Configuration) -> some View {
        let shape = Capsule()
        configuration.label
            .font(.system(size: fontSize, weight: weight))
            .foregroundStyle(theme.primarySolidText)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background(shape.fill(theme.primarySolid))
            .contentShape(shape)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(Motion.hover, value: configuration.isPressed)
    }
}

/// 次操作按钮：低对比描边胶囊，让位给主操作。
struct SecondaryButtonStyle: ButtonStyle {
    var height: CGFloat = 32
    var horizontalPadding: CGFloat = Space.md
    var fontSize: CGFloat = 13
    var weight: Font.Weight = .medium
    @MainActor private var theme: Theme { AppStyle.theme }

    func makeBody(configuration: Configuration) -> some View {
        let shape = Capsule()
        configuration.label
            .font(.system(size: fontSize, weight: weight))
            .foregroundStyle(theme.textPrimary)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background(shape.fill(theme.isDark ? Color.white.opacity(0.065) : Color.black.opacity(0.045)))
            .overlay(shape.strokeBorder(theme.isDark ? Color.white.opacity(0.09) : Color.black.opacity(0.07), lineWidth: 1))
            .contentShape(shape)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(Motion.hover, value: configuration.isPressed)
    }
}
