import AppKit
import SwiftUI

/// 轻量提示浮层（toast）：字号调节、已复制路径等一闪而过的操作反馈。
/// 用独立 NSPanel 而不是 SwiftUI overlay——终端区是 AppKit/Metal 视图，
/// 窗口内 overlay 会被盖住；浮窗永远在最上且不抢键盘/鼠标。
@MainActor
final class ToastHUD {
    static let shared = ToastHUD()

    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    /// 在主窗口顶部居中弹出一条提示，`duration` 后自动淡出。
    func show(_ text: String, icon: String = "checkmark.circle.fill",
              over parent: NSWindow?, duration: TimeInterval = 1.6) {
        hideWork?.cancel()

        let host = NSHostingView(rootView: ToastBubble(text: text, icon: icon))
        let size = host.fittingSize
        let p = panel ?? makePanel()
        p.contentView = host

        let frame = parent?.frame ?? NSScreen.main?.visibleFrame ?? .zero
        let x = frame.midX - size.width / 2
        let y = frame.maxY - size.height - max(64, frame.height * 0.1)
        p.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)

        if !p.isVisible {
            p.alphaValue = 0
            p.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1
        }

        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak panel] in panel?.orderOut(nil) })
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .transient]
        panel = p
        return p
    }
}

/// toast 气泡本体：毛玻璃胶囊 + 图标 + 文字。
private struct ToastBubble: View {
    let text: String
    let icon: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(AppStyle.accent)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppStyle.textPrimary)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule().fill(AppStyle.elevated)
                .overlay(Capsule().strokeBorder(AppStyle.textPrimary.opacity(0.08), lineWidth: 1))
                .shadow(color: .black.opacity(AppStyle.theme.isDark ? 0.45 : 0.18), radius: 12, y: 4)
        )
        .padding(10)
    }
}
