import ConductorCore
import SwiftUI

/// 底部状态栏（自绘，跟主题）：当前 pane 的 cwd 全路径 + git 分支 + 实时时间。
struct StatusBarView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var usageMonitor: UsageMonitor
    @ObservedObject private var configStore = ConfigStore.shared

    var body: some View {
        HStack(spacing: 12) {
            // 悬停链接时左侧切换成 URL 显示（浏览器式），移开还原 cwd/分支
            if let link = coordinator.hoveredLink {
                item("link", link, accent: true)
                    .transition(.opacity)
            } else {
                if let cwd = coordinator.activeCwd {
                    StatusCopyItem(icon: "folder", text: prettyPath(cwd),
                                   help: L("点击复制路径")) {
                        coordinator.copyToClipboard(cwd)
                        ToastHUD.shared.show(L("已复制路径"), icon: "doc.on.doc.fill",
                                             over: coordinator.window)
                    }
                }
                if let branch = coordinator.activeBranch {
                    StatusCopyItem(icon: "arrow.triangle.branch", text: branch, accent: true,
                                   help: L("点击复制分支名")) {
                        coordinator.copyToClipboard(branch)
                        ToastHUD.shared.show(L("已复制分支名"), icon: "doc.on.doc.fill",
                                             over: coordinator.window)
                    }
                }
            }
            Spacer(minLength: 8)
            CodexUsageChip(snapshot: usageMonitor.codex) { coordinator.openTools(.usage) }
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(ctx.date.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(AppStyle.textTertiary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 21)
        .frame(maxWidth: .infinity)
        .background(.clear)   // 透明：用根底统一磨砂
    }

    private func item(_ icon: String, _ text: String, accent: Bool = false) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(accent ? AppStyle.accent : AppStyle.textTertiary)
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(AppStyle.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .animation(.easeOut(duration: 0.12), value: text)
    }

    private func prettyPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// 可点击复制的状态栏条目（cwd / git 分支）：hover 提亮 + 浮现复制小图标，点击进剪贴板。
private struct StatusCopyItem: View {
    let icon: String
    let text: String
    var accent = false
    let help: String
    let onCopy: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onCopy) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(accent ? AppStyle.accent : AppStyle.textTertiary)
                Text(text)
                    .font(.system(size: 10.5))
                    .foregroundStyle(hovering ? AppStyle.textPrimary : AppStyle.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if hovering {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(AppStyle.textTertiary)
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                }
            }
            .animation(.easeOut(duration: 0.12), value: text)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// 状态栏里的 Codex 配额小条：logo + 最紧张窗口的剩余百分比，点击打开 CLI 面板。
private struct CodexUsageChip: View {
    let snapshot: CodexUsageSnapshot?
    let onTap: () -> Void

    /// 取剩余最少（最紧张）的窗口作为头条。
    private var headline: (label: String, window: CodexUsageSnapshot.Window)? {
        guard let snapshot else { return nil }
        let candidates: [(String, CodexUsageSnapshot.Window)] =
            [(L("会话"), snapshot.session), (L("本周"), snapshot.weekly)].compactMap { label, win in
                win.map { (label, $0) }
            }
        return candidates.min { $0.1.remainingPercent < $1.1.remainingPercent }
    }

    private func color(_ used: Int) -> Color {
        switch used {
        case ..<70: AppStyle.textSecondary
        case 70..<90: AppStyle.waitAmber
        default: AppStyle.errorRed
        }
    }

    var body: some View {
        if let headline {
            Button(action: onTap) {
                HStack(spacing: 5) {
                    if let logo = CLIToolLogo.image(named: "codex") {
                        Image(nsImage: logo).resizable().interpolation(.high).scaledToFit()
                            .frame(width: 13, height: 13)
                    }
                    Text(L("%1$@ 剩 %2$ld%%", headline.label, headline.window.remainingPercent))
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(color(headline.window.usedPercent))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tooltip)
        }
    }

    private var tooltip: String {
        guard let snapshot else { return "" }
        var lines: [String] = []
        if let s = snapshot.session {
            lines.append(L("会话：剩 %1$ld%% · %2$@", s.remainingPercent, UsageFormatting.resetText(s.resetAt)))
        }
        if let w = snapshot.weekly {
            lines.append(L("本周：剩 %1$ld%% · %2$@", w.remainingPercent, UsageFormatting.resetText(w.resetAt)))
        }
        return L("Codex 用量") + "\n" + lines.joined(separator: "\n")
    }
}
