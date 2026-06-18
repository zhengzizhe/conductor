import SwiftUI

/// 空状态里的「键位提示」动作：一枚键帽（⌘T）+ 文案，整体无填充地贴在背景上，
/// 仅 hover 时浮起一层极淡底色 —— 比胶囊按钮更轻、更像「随手可按的快捷键」。
struct QuickStartActionButton: View {
    let action: QuickStartAction
    var compact = false

    @State private var hovering = false

    private let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)

    var body: some View {
        Button(action: action.run) {
            HStack(spacing: 8) {
                keycap
                Text(action.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(hovering ? AppStyle.textPrimary : AppStyle.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(shape.fill(AppStyle.hoverFill.opacity(hovering ? 0.85 : 0)))
            .contentShape(shape)
            .offset(y: hovering ? -1 : 0)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .help(action.title)
    }

    /// 键帽：主动作走强调色底，次动作走中性底；无键位时退化为图标。
    private var keycap: some View {
        let cap = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return Group {
            if let shortcut = action.shortcut {
                Text(shortcut)
                    .font(.system(size: 11.5, weight: .semibold))
            } else {
                Image(systemName: action.systemImage)
                    .font(.system(size: 11, weight: .semibold))
            }
        }
        .foregroundStyle(action.isPrimary ? AppStyle.accent : AppStyle.textSecondary)
        .frame(minWidth: 24, minHeight: 22)
        .padding(.horizontal, 5)
        .background(cap.fill(action.isPrimary
            ? AppStyle.accent.opacity(0.13)
            : AppStyle.hoverFill.opacity(hovering ? 0.95 : 0.7)))
        .overlay(cap.strokeBorder(action.isPrimary
            ? AppStyle.accent.opacity(0.28)
            : AppStyle.separator.opacity(0.7), lineWidth: 1))
    }
}
