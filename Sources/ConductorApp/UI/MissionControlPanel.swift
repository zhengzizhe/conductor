import AppKit
import Combine
import ConductorCore
import SwiftUI

/// Mission Control 任务总览（⌘⇧M）：所有工作区的 pane 实况卡片墙——
/// 思考计时 / 完成未读 / 屏幕预览，一眼定位当前任务状态。
struct MissionControlView: View {
    @ObservedObject var coordinator: AppCoordinator
    let onClose: () -> Void

    /// pane → 屏幕预览文本（开面板时抓一轮，之后每 2 秒刷新）。
    @State private var previews: [PaneID: String] = [:]
    private let refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private let columns = [GridItem(.adaptive(minimum: 232, maximum: 340), spacing: 10)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppStyle.accent)
                Text(L("任务总览"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppStyle.textPrimary)
                summaryChips
                Spacer()
            }
            .padding(.horizontal, Space.md)
            .padding(.top, Space.md)
            .padding(.bottom, Space.sm)

            ScrollView {
                VStack(alignment: .leading, spacing: Space.md) {
                    ForEach(coordinator.visibleWorkspaces, id: \.id) { workspace in
                        workspaceSection(workspace)
                    }
                }
                .padding(Space.md)
            }
            .scrollIndicators(.never)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .conductorFloatingPanel(cornerRadius: Radius.xl)
        .padding(Space.xl)
        .onAppear { refreshPreviews() }
        .onReceive(refreshTimer) { _ in refreshPreviews() }
    }

    /// 顶部小结：思考中 / 完成未读。
    @ViewBuilder
    private var summaryChips: some View {
        let thinking = coordinator.thinkingPanes.count
        let done = coordinator.unseenDonePanes.count
        HStack(spacing: 8) {
            if thinking > 0 {
                chip(count: thinking, label: L("思考中"), color: AppStyle.accent)
            }
            if done > 0 {
                chip(count: done, label: L("完成未读"), color: AppStyle.doneGreen)
            }
        }
        .padding(.leading, 6)
    }

    private func chip(count: Int, label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5.5, height: 5.5)
            Text("\(count) \(label)")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(AppStyle.hoverFill))
    }

    @ViewBuilder
    private func workspaceSection(_ workspace: Workspace) -> some View {
        let panes = workspace.tabs.flatMap { $0.rootSplit.leaves() }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppStyle.textTertiary)
                Text(workspace.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppStyle.textSecondary)
                Text(L("%ld 个终端", panes.count))
                    .font(.system(size: 9.5))
                    .monospacedDigit()
                    .foregroundStyle(AppStyle.textTertiary)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(panes, id: \.value) { pane in
                    MissionControlCard(
                        title: coordinator.paneTitles[pane] ?? L("终端"),
                        agentID: coordinator.paneAgents[pane],
                        thinkingSince: coordinator.thinkingSince(for: pane),
                        unseenDone: coordinator.unseenDonePanes.contains(pane),
                        queued: coordinator.paneQueues[pane]?.count ?? 0,
                        preview: previews[pane] ?? ""
                    ) {
                        onClose()
                        coordinator.revealPane(pane)
                    }
                }
            }
        }
    }

    private func refreshPreviews() {
        var out: [PaneID: String] = [:]
        for workspace in coordinator.visibleWorkspaces {
            for tab in workspace.tabs {
                for pane in tab.rootSplit.leaves() {
                    guard let text = coordinator.viewportPreview(for: pane) else { continue }
                    out[pane] = Self.previewTail(text)
                }
            }
        }
        previews = out
    }

    /// 取屏幕文本的最后几行非空内容（每行截断，防止超宽撑爆卡片）。
    static func previewTail(_ text: String, maxLines: Int = 7, maxLineLength: Int = 96) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var tail: [String] = []
        for line in lines.reversed() {
            if tail.isEmpty && line.isEmpty { continue }   // 跳过结尾空行
            tail.append(line.count > maxLineLength ? String(line.prefix(maxLineLength)) + "…" : line)
            if tail.count >= maxLines { break }
        }
        return tail.reversed().joined(separator: "\n")
    }
}

/// 一张 pane 实况卡片：头行（logo + 标题 + 状态徽标）+ 屏幕预览。
private struct MissionControlCard: View {
    let title: String
    let agentID: String?
    let thinkingSince: Date?
    let unseenDone: Bool
    let queued: Int
    let preview: String
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    if let agentID, let image = CLIToolLogo.image(named: agentID) {
                        Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "terminal")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(AppStyle.textTertiary)
                    }
                    Text(title)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(AppStyle.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    statusBadge
                }
                Group {
                    if preview.isEmpty {
                        Text(L("（空闲）"))
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(AppStyle.textTertiary)
                    } else {
                        Text(preview)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(AppStyle.textSecondary)
                            .lineSpacing(1.5)
                            .multilineTextAlignment(.leading)
                            .lineLimit(7, reservesSpace: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                if queued > 0 {
                    Text(L("队列 %ld", queued))
                        .font(.system(size: 9))
                        .monospacedDigit()
                        .foregroundStyle(AppStyle.textTertiary)
                }
            }
            .padding(Space.sm)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .fill(hovering ? AppStyle.activeFill : AppStyle.hoverFill))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(L("点击跳到该终端"))
    }

    /// 卡片边框透出状态色：思考 accent > 完成绿 > 默认。
    private var borderColor: Color {
        if thinkingSince != nil { return AppStyle.accent.opacity(0.45) }
        if unseenDone { return AppStyle.doneGreen.opacity(0.5) }
        return AppStyle.separator
    }

    @ViewBuilder
    private var statusBadge: some View {
        if let thinkingSince {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                HStack(spacing: 4) {
                    ThinkingIndicator(size: 7)
                    Text(PaneHeaderView.thinkingText(since: thinkingSince))
                        .font(.system(size: 9.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(AppStyle.accent)
                }
            }
        } else if unseenDone {
            HStack(spacing: 3) {
                Circle().fill(AppStyle.doneGreen).frame(width: 5, height: 5)
                Text(L("已完成"))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(AppStyle.doneGreen)
            }
        }
    }
}

/// 任务总览窗口：盖在主窗上方的大浮层（KeyPanel），Esc / 失焦 / 再按一次 ⌘⇧M 关闭。
@MainActor
final class MissionControlController: NSObject, NSWindowDelegate {
    private var panel: KeyPanel?
    private var escMonitor: Any?

    func toggle(coordinator: AppCoordinator, over parent: NSWindow?) {
        if let panel, panel.isVisible { hide(); return }
        show(coordinator: coordinator, over: parent)
    }

    func show(coordinator: AppCoordinator, over parent: NSWindow?) {
        let view = MissionControlView(coordinator: coordinator,
                                      onClose: { [weak self] in self?.hide() })
        // 盖住主窗大部分：跟随窗口大小，四周留出呼吸边
        let base = parent?.frame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1100, height: 720)
        let size = NSSize(width: max(640, base.width - 120), height: max(440, base.height - 130))
        let p = panel ?? makePanel(size: size)
        p.contentView = NSHostingView(rootView: view)

        let x = base.midX - size.width / 2
        let y = base.midY - size.height / 2
        p.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)

        p.alphaValue = 0
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
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
            ctx.duration = 0.12
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
        p.hasShadow = false
        p.level = .floating
        p.isMovableByWindowBackground = false
        p.hidesOnDeactivate = true
        p.delegate = self
        panel = p
        return p
    }

    func windowDidResignKey(_ notification: Notification) { hide() }
}
