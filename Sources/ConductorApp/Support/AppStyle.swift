import AppKit
import SwiftUI

/// 设计令牌：现在从当前 `Theme`(主题派生)取色，外壳随 config.yaml 的主题切换。
/// 用法不变(`AppStyle.windowBackground` 等)，但值是计算属性、跟随主题。
enum AppStyle {
    @MainActor static var theme: Theme { Theme.current }

    // 面
    @MainActor static var windowBackground: Color { theme.windowBackground }
    @MainActor static var sidebarBackground: Color { theme.sidebarBackground }
    @MainActor static var chromeBackground: Color { theme.windowBackground }   // tab 栏=画布
    @MainActor static var cardBackground: NSColor { theme.cardBackground }
    @MainActor static var elevated: Color { theme.elevated }
    @MainActor static var activeFill: Color { theme.activeFill }
    @MainActor static var separator: Color { theme.separator }
    @MainActor static var hoverFill: Color { theme.hoverFill }
    /// 终端分屏线：跟随主题，但比普通 separator 更轻。
    /// 纯色主题贴近 pane 卡片底，避免两块终端之间出现硬暗缝；光晕主题只给一点 accent 色相。
    @MainActor static var splitDivider: NSColor {
        let t = theme
        if t.terminalTranslucent {
            return NSColor(t.accent).withAlphaComponent(0.07)
        }
        return t.cardBackground.withAlphaComponent(t.isDark ? 0.58 : 0.54)
    }
    /// 淡填充：胶囊/分段/计数等次级元素的底（主题感知）。此前各处裸写
    /// `isDark ? white.opacity(0.08) : black.opacity(0.07)`，收口到这里。
    @MainActor static var subtleFill: Color {
        theme.isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.07)
    }
    /// 外壳（侧栏 / Tab 栏 / 状态栏）毛玻璃 tint：压在窗口 NSVisualEffectView 上的半透明主题色，
    /// 让外壳透出模糊桌面又保留 app 自身色调。值越低越通透、越高越实——这一个数就是"玻璃浓淡"旋钮。
    @MainActor static var chromeFill: Color {
        windowBackground.opacity(theme.isDark ? 0.496 : 0.544)   // 比原 0.62 / 0.68 约透明 20%
    }

    // 文字
    @MainActor static var textPrimary: Color { theme.textPrimary }
    @MainActor static var textSecondary: Color { theme.textSecondary }
    @MainActor static var textTertiary: Color { theme.textTertiary }

    // 强调
    @MainActor static var accent: Color { theme.accent }
    /// 「完成未读」信号绿（tab 胶囊 / 侧栏工作区行的小绿点，深浅主题下都够亮）。
    static let doneGreen = Color(red: 0.28, green: 0.76, blue: 0.43)
    /// 警示信号琥珀（配额告警、命令待确认等需要注意的状态）。
    static let waitAmber = Color(red: 0.95, green: 0.62, blue: 0.20)
    /// 出错信号红（OSC 进度 error / PR 检查失败等，深浅主题下都够亮）。
    static let errorRed = Color(red: 0.92, green: 0.34, blue: 0.34)

    // 尺寸(与主题无关)
    static let sidebarWidth: CGFloat = 190
    static let sidebarCollapsedWidth: CGFloat = 48
    static let tabBarHeight: CGFloat = 34
}

/// 工具栏/导航里的纯图标按钮。只要没有可见文字，就走这个组件：tooltip 和可访问标签是必填语义。
struct IconOnlyButton: View {
    let systemName: String
    let help: String
    var size: CGFloat = 26
    var symbolSize: CGFloat = 12
    var weight: Font.Weight = .medium
    var tint: Color? = nil
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: symbolSize, weight: weight))
                .foregroundStyle(tint ?? AppStyle.textSecondary)
        }
        .buttonStyle(IconOnlyButtonChromeStyle(size: size))
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct IconOnlyButtonChromeStyle: ButtonStyle {
    var size: CGFloat
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let radius = max(7, min(9, size * 0.32))
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        configuration.label
            .frame(width: size, height: size)
            .background(
                shape.fill(hovering ? AppStyle.hoverFill : AppStyle.theme.isDark ? Color.white.opacity(0.025) : Color.black.opacity(0.018))
            )
            .overlay(
                shape.strokeBorder(
                    hovering ? AppStyle.accent.opacity(0.16) : Color.clear,
                    lineWidth: 1))
            .contentShape(shape)
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.74 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
            .animation(Motion.hover, value: hovering)
            .onHover { hovering = $0 }
    }
}
