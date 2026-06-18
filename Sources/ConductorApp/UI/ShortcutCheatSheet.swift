import AppKit
import ConductorCore
import SwiftUI

/// 速查表一行：命令标题 + 当前有效键位（已符号化）。
struct ShortcutCheatItem: Identifiable {
    let id: String
    let title: String
    /// 符号化键位，如「⌘⇧D」；nil = 未绑定。
    let display: String?
    /// config.yaml 覆盖过内置默认 → 标小点提示。
    let customized: Bool
}

/// 把键位串渲染成 macOS 惯例符号：`"cmd+shift+d"` → 「⌘⇧D」。
enum ShortcutSymbolizer {
    static func symbolize(_ spec: String) -> String {
        guard let chord = KeyChord(parsing: spec) else { return spec }
        var out = ""
        if chord.modifiers.contains(.control) { out += "⌃" }
        if chord.modifiers.contains(.option) { out += "⌥" }
        if chord.modifiers.contains(.shift) { out += "⇧" }
        if chord.modifiers.contains(.command) { out += "⌘" }
        return out + keyGlyph(chord.key)
    }

    private static func keyGlyph(_ key: String) -> String {
        switch key {
        case "enter": return "⏎"
        case "esc": return "⎋"
        case "tab": return "⇥"
        case "space": return "␣"
        case "delete": return "⌫"
        case "left": return "←"
        case "right": return "→"
        case "up": return "↑"
        case "down": return "↓"
        default: return key.uppercased()
        }
    }
}

/// ⌘/ 键位速查：命令表全量展示当前有效键位（含 config 覆盖后的），两列扫一眼。
struct ShortcutCheatSheetView: View {
    let items: [ShortcutCheatItem]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "keyboard")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppStyle.accent)
                Text(L("键位速查"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppStyle.textPrimary)
                Spacer()
                Text(L("Esc 关闭"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(AppStyle.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)

            // 两列竖排（按注册顺序上下接续），一屏读完不滚动；列间用间距分隔，不画线
            let mid = (items.count + 1) / 2
            HStack(alignment: .top, spacing: 16) {
                column(Array(items.prefix(mid)))
                column(Array(items.dropFirst(mid)))
            }
            .padding(.vertical, 6)
            .padding(.bottom, 4)

            HStack(spacing: 5) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 9, weight: .medium))
                Text(L("键位可在设置里自定义"))
                    .font(.system(size: 10))
            }
            .foregroundStyle(AppStyle.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
        }
        .frame(width: 600)
        .conductorFloatingPanel(cornerRadius: Radius.xl)
        .padding(Space.xl)   // 给阴影留出扩散空间，不被窗口裁掉
    }

    private func column(_ items: [ShortcutCheatItem]) -> some View {
        VStack(spacing: 1) {
            ForEach(items) { item in row(item) }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
    }

    private func row(_ item: ShortcutCheatItem) -> some View {
        HStack(spacing: 6) {
            Text(item.title)
                .font(.system(size: 11.5))
                .foregroundStyle(AppStyle.textSecondary)
                .lineLimit(1)
            if item.customized {
                Circle()
                    .fill(AppStyle.accent)
                    .frame(width: 4, height: 4)
                    .help(L("已使用自定义键位"))
            }
            Spacer(minLength: 10)
            if let display = item.display {
                Text(display)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(AppStyle.textPrimary.opacity(0.85))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(AppStyle.hoverFill))
            } else {
                Text(L("未绑定"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(AppStyle.textTertiary.opacity(0.8))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

/// 速查面板窗口：复用命令面板的浮动 KeyPanel 形态；⌘/ 再按一次或 Esc/失焦关闭。
@MainActor
final class ShortcutCheatSheetController: NSObject, NSWindowDelegate {
    private var panel: KeyPanel?
    /// 面板没有可聚焦控件，Esc 用本地按键监听接（面板可见期间才挂）。
    private var escMonitor: Any?

    func toggle(items: [ShortcutCheatItem], over parent: NSWindow?) {
        if let panel, panel.isVisible { hide(); return }
        show(items: items, over: parent)
    }

    func show(items: [ShortcutCheatItem], over parent: NSWindow?) {
        let view = ShortcutCheatSheetView(items: items)
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize   // 高度随命令条数自适应
        let p = panel ?? makePanel(size: size)
        p.contentView = host

        let frame = parent?.frame ?? NSScreen.main?.visibleFrame ?? .zero
        let x = frame.midX - size.width / 2
        let y = frame.maxY - size.height - max(80, frame.height * 0.12)
        p.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)

        p.alphaValue = 0
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            p.animator().alphaValue = 1
        }
        if escMonitor == nil {
            escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53, event.window === self?.panel else { return event }
                self?.hide()
                return nil
            }
        }
    }

    func hide() {
        if let escMonitor {
            NSEvent.removeMonitor(escMonitor)
            self.escMonitor = nil
        }
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak panel] in panel?.orderOut(nil) })
    }

    private func makePanel(size: NSSize) -> KeyPanel {
        let p = KeyPanel(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.borderless, .titled, .fullSizeContentView],
                         backing: .buffered, defer: true)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false   // 用 SwiftUI 自绘柔阴影，关掉系统硬阴影
        p.level = .floating
        p.isMovableByWindowBackground = false
        p.hidesOnDeactivate = true
        p.delegate = self
        panel = p
        return p
    }

    func windowDidResignKey(_ notification: Notification) { hide() }
}
