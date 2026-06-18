import AppKit
import SwiftUI

// 自绘、跟随主题、带微交互的设置控件集。替代原生 Form（不跟主题、太朴素）。

extension Color {
    /// 从 "1b1c22" / "#1b1c22" 解析。
    init?(hex: String) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(.sRGB,
                  red: Double((v >> 16) & 0xff) / 255,
                  green: Double((v >> 8) & 0xff) / 255,
                  blue: Double(v & 0xff) / 255)
    }
    /// 转 6 位十六进制（不带 #）。
    var hexString: String {
        let ns = (NSColor(self).usingColorSpace(.sRGB)) ?? .black
        return String(format: "%02X%02X%02X",
                      Int((ns.redComponent * 255).rounded()),
                      Int((ns.greenComponent * 255).rounded()),
                      Int((ns.blueComponent * 255).rounded()))
    }
}

/// 系统等宽字体族（缓存）。
enum SystemFonts {
    static let monospaced: [String] = {
        var names = NSFontManager.shared.availableFontFamilies.filter { family in
            guard let f = NSFont(name: family, size: 12) else { return false }
            return f.isFixedPitch
        }
        if !names.contains("SF Mono") { names.insert("SF Mono", at: 0) }
        return names.sorted()
    }()
}

/// 轻量分组：用标题、留白和控件自身层级分隔内容，不再使用大卡片外框。
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(AppStyle.textTertiary)
                .padding(.leading, 2)
            VStack(spacing: 3) { content }
        }
    }
}

/// 一行：左标签 + 右控件，用留白而不是分隔线组织。
struct SettingsRow<Control: View>: View {
    let label: String
    var first: Bool = false
    @ViewBuilder var control: Control

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(AppStyle.textPrimary)
            Spacer(minLength: Space.sm)
            control
        }
        .padding(.horizontal, 2)
        .frame(height: 44)
    }
}

/// 主题化开关：胶囊轨 + 弹簧滑块。
struct ThemedToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Capsule()
            .fill(isOn ? AnyShapeStyle(AppStyle.accent)
                       : AnyShapeStyle(AppStyle.theme.isDark ? Color.white.opacity(0.15) : Color.black.opacity(0.13)))
            .frame(width: 40, height: 23)
            .overlay(
                Circle()
                    .fill(.white)
                    .frame(width: 19, height: 19)
                    .shadow(color: .black.opacity(0.22), radius: 1.5, y: 0.5)
                    .offset(x: isOn ? 8.5 : -8.5))
            .animation(.spring(response: 0.32, dampingFraction: 0.68), value: isOn)
            .contentShape(Capsule())
            .onTapGesture { isOn.toggle() }
    }
}

/// 主题化分段控件：滑动指示器（matchedGeometry）+ 弹簧动画。
struct ThemedSegmented: View {
    let options: [(label: String, value: String)]
    @Binding var selection: String
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { opt in
                let isSel = opt.value == selection
                Text(opt.label)
                    .font(.system(size: 12, weight: isSel ? .semibold : .regular))
                    .foregroundStyle(isSel ? AppStyle.textPrimary : AppStyle.textSecondary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background {
                        if isSel {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(AppStyle.elevated)
                                .shadow(color: .black.opacity(AppStyle.theme.isDark ? 0.0 : 0.10), radius: 2, y: 1)
                                .matchedGeometryEffect(id: "seg", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { selection = opt.value }
                    }
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(AppStyle.theme.isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.04)))
    }
}

/// 主题化步进器：- 值 +，按下有反馈。
struct ThemedStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step: Int = 1

    var body: some View {
        HStack(spacing: 0) {
            button("minus") { set(value - step) }
            Text("\(value)")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(AppStyle.textPrimary)
                .frame(minWidth: 48)
            button("plus") { set(value + step) }
        }
        .background(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .fill(AppStyle.theme.isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.04)))
    }

    private func set(_ v: Int) {
        withAnimation(.easeOut(duration: 0.12)) { value = min(max(v, range.lowerBound), range.upperBound) }
    }

    private func button(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(AppStyle.textSecondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .help(icon == "minus" ? L("减少") : L("增加"))
    }
}

/// 主题化输入框。
struct ThemedTextField: View {
    let placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void = {}

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .foregroundStyle(AppStyle.textPrimary)
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: 180)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .fill(AppStyle.theme.isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.04)))
            .onSubmit(onSubmit)
    }
}

/// 按下反馈的按钮样式。
///
/// 早期默认做 0.94 缩放，但管理台/Skills 列表里大量文字按钮会在点击时进入缩放合成层，
/// macOS 上小字号文本容易发糊。默认改成不缩放，只用透明度做反馈；需要缩放的少数场景可显式传值。
struct PressScaleStyle: ButtonStyle {
    var pressedScale: CGFloat = 1
    var pressedOpacity: Double = 0.82

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .opacity(configuration.isPressed ? pressedOpacity : 1)
            .animation(Motion.hover, value: configuration.isPressed)
    }
}
