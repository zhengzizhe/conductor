import SwiftUI

/// 终端空状态。
/// 不再用「图标卡片 + 胶囊按钮」那套，而是把一行 **会话提示符** 当主角：
/// `<工作区> ❯ ▮`，等宽字体配一枚闪烁的块状光标，像一个正等待输入的终端。
/// 动作降格成下方的键位提示，整组无边框地浮在窗口背景上 —— 更安静，也更像终端本体。
struct QuickStartLaunchPanel: View {
    let title: String
    let subtitle: String
    let primaryActions: [QuickStartAction]
    let secondaryActions: [QuickStartAction]

    /// 块状光标的闪烁相位（在 1 与 ~0 之间往返）。
    @State private var caretLit = true

    private var actions: [QuickStartAction] { primaryActions + secondaryActions }

    var body: some View {
        VStack(spacing: 20) {
            prompt

            Text(subtitle)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(AppStyle.textTertiary)

            HStack(spacing: 10) {
                ForEach(actions) { action in
                    QuickStartActionButton(action: action)
                }
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 40)
        .onAppear {
            // 终端式硬闪烁：贴近真·光标的节奏，又不至于刺眼。
            withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                caretLit = false
            }
        }
    }

    /// 主角行：工作区名 + 提示符箭头 + 闪烁块光标，全部等宽对齐到基线。
    private var prompt: some View {
        HStack(alignment: .firstTextBaseline, spacing: 13) {
            Text(title)
                .foregroundStyle(AppStyle.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text("❯")
                    .foregroundStyle(AppStyle.accent)
                Text("▮")
                    .foregroundStyle(AppStyle.accent)
                    .opacity(caretLit ? 1 : 0.12)
            }
        }
        .font(.system(size: 33, weight: .semibold, design: .monospaced))
        .minimumScaleFactor(0.55)
        .frame(maxWidth: 520)
    }
}
