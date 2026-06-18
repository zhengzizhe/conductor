import AppKit
import ConductorCore
import SwiftUI

/// Agent 会话管理面板：浏览 / 筛选 / 续聊 claude & codex 会话。
struct SessionManagerView: View {
    let coordinator: AppCoordinator
    var onClose: () -> Void = {}

    @ObservedObject private var configStore = ConfigStore.shared
    @ObservedObject private var store = SessionManagerStore.shared
    @State private var agentFilter: String? = nil
    @State private var query = ""

    private var scopePath: String? { coordinator.sessionScopePath }
    private var scopeLabel: String {
        if let path = scopePath {
            return PathDisplay.tilde(path)
        }
        return L("全部目录")
    }

    private var filtered: [AgentSessionRecord] {
        var list = store.records
        if let scopePath {
            list = list.filter { $0.belongsToWorkspace(scopePath) || $0.belongsToDirectory(scopePath) }
        }
        if let agentFilter { list = list.filter { $0.agent == agentFilter } }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            list = list.filter {
                $0.title.lowercased().contains(q)
                    || $0.sessionID.lowercased().contains(q)
                    || ($0.cwd?.lowercased().contains(q) ?? false)
            }
        }
        // 收藏的浮到最上面，组内保持原有的时间序
        let pinned = store.pinnedIDs
        guard !pinned.isEmpty else { return list }
        return list.filter { pinned.contains($0.id) } + list.filter { !pinned.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            filterBar
            content
        }
        .frame(maxHeight: .infinity)
        .background(.clear)   // 透明：用根底统一磨砂
        .onAppear { store.refresh() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L("Agent 会话"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppStyle.textPrimary)
                Text(scopeLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(AppStyle.textTertiary)
                    .lineLimit(1)
                if let scanned = store.lastScannedAt {
                    // .relative(.named) 自带“前/ago”，locale 跟随语言热切换
                    Text(L("更新于 %@", scanned.formatted(
                        .relative(presentation: .named).locale(AppLanguage.activeLocale))))
                        .font(.system(size: 10))
                        .foregroundStyle(AppStyle.textTertiary)
                }
            }
            Spacer(minLength: 8)
            IconOnlyButton(
                systemName: "arrow.clockwise",
                help: L("刷新会话"),
                size: 28,
                symbolSize: 11,
                weight: .semibold) {
                    store.refresh(force: true)
                }
            .disabled(store.isLoading)
            IconOnlyButton(
                systemName: "xmark",
                help: L("关闭"),
                size: 28,
                symbolSize: 11,
                weight: .bold,
                action: onClose)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var filterBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                filterChip(L("全部"), agent: nil)
                filterChip("Claude", agent: "claude")
                filterChip("Codex", agent: "codex")
                Spacer()
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(AppStyle.textTertiary)
                TextField(L("搜索标题、目录或 ID"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(AppStyle.textPrimary)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .fill(AppStyle.hoverFill))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func filterChip(_ label: String, agent: String?) -> some View {
        let selected = agentFilter == agent
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { agentFilter = agent }
        } label: {
            Text(label)
                .font(.system(size: 11, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? AppStyle.accent : AppStyle.textSecondary)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(
                    Capsule().fill(selected ? AppStyle.accent.opacity(0.12) : AppStyle.hoverFill))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var content: some View {
        if store.isLoading, store.records.isEmpty {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(L("正在扫描会话…"))
                    .font(.system(size: 12))
                    .foregroundStyle(AppStyle.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = store.scanError {
            emptyState(L("扫描失败"), err)
        } else if filtered.isEmpty {
            emptyState(L("暂无会话"), store.records.isEmpty
                ? L("本机还没找到 Claude / Codex 会话记录")
                : L("当前筛选条件下没有匹配的会话"))
        } else {
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(filtered) { record in
                        SessionRow(record: record,
                                   isPinned: store.pinnedIDs.contains(record.id),
                                   coordinator: coordinator)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .animation(.easeOut(duration: 0.18), value: filtered.map(\.id))
            }
            .scrollIndicators(.hidden)
        }
    }

    private func emptyState(_ title: String, _ detail: String) -> some View {
        ToolEmptyState(
            icon: "bubble.left.and.text.bubble.right",
            title: title,
            detail: detail,
            compact: true)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SessionRow: View {
    let record: AgentSessionRecord
    let isPinned: Bool
    let coordinator: AppCoordinator
    @State private var hovering = false
    @State private var expanded = false
    @State private var preview: [AgentSessionMessage]?
    @State private var loadingPreview = false
    @State private var usage: AgentSessionUsage?

    private var logoName: String {
        record.agent == "claude" ? "claude" : "codex"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggleExpanded) {
                HStack(alignment: .top, spacing: 8) {
                    logo
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AppStyle.textPrimary)
                            .lineLimit(1)
                            .multilineTextAlignment(.leading)
                        if let cwd = record.cwd {
                            Text(PathDisplay.tilde(cwd))
                                .font(.system(size: 10.5))
                                .foregroundStyle(AppStyle.textTertiary)
                                .lineLimit(1)
                        }
                        HStack(spacing: 6) {
                            Text(record.agent.capitalized)
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(AppStyle.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(AppStyle.accent.opacity(0.10)))
                            Text(record.shortID)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(AppStyle.textTertiary)
                            Text(record.modifiedAt, style: .relative)
                                .font(.system(size: 10))
                                .foregroundStyle(AppStyle.textTertiary)
                            if let usage {
                                usageChip(usage)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 4) {
                        pinButton
                        if record.filePath != nil {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(AppStyle.textTertiary)
                                .rotationEffect(.degrees(expanded ? 180 : 0))
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded { previewSection }

            // 操作行只在展开时出现，收着的行保持紧凑（点行即展开）。
            if expanded {
                HStack(spacing: 8) {
                    Button(L("当前面板")) { coordinator.resumeSession(record, inPane: coordinator.sessionTargetPane) }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(coordinator.sessionTargetPane == nil)
                    Button(L("新标签")) { coordinator.resumeSession(record, inPane: nil) }
                        .buttonStyle(PrimaryButtonStyle())
                    Menu {
                        Button { coordinator.copyToClipboard(record.sessionID) } label: {
                            Label(L("复制会话 ID"), systemImage: "number")
                        }
                        if let cmd = record.resumeCommand {
                            Button { coordinator.copyToClipboard(cmd) } label: {
                                Label(L("复制续聊命令"), systemImage: "terminal")
                            }
                        }
                        Divider()
                        Button(role: .destructive) { confirmDelete() } label: {
                            Label(L("删除会话…"), systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(AppStyle.textSecondary)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(AppStyle.hoverFill))
                    }
                    .menuStyle(.borderlessButton)
                    .help(L("更多操作"))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .toolsCard()
        .onHover { hovering = $0 }
        .task(id: "\(record.filePath ?? "")#\(record.modifiedAt.timeIntervalSince1970)") {
            usage = await SessionUsageCache.shared.usage(for: record)
        }
    }

    /// 收藏星标：收藏后常驻显示，未收藏只在 hover 时浮现。
    @ViewBuilder
    private var pinButton: some View {
        if isPinned || hovering {
            Button {
                SessionManagerStore.shared.togglePin(record)
            } label: {
                Image(systemName: isPinned ? "star.fill" : "star")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(isPinned ? AppStyle.waitAmber : AppStyle.textTertiary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isPinned ? L("取消置顶") : L("收藏置顶"))
            .transition(.opacity)
        } else {
            Color.clear.frame(width: 20, height: 20)
        }
    }

    /// token / 成本 chip：tooltip 里给输入/输出/缓存的细分。
    private func usageChip(_ usage: AgentSessionUsage) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "number")
                .font(.system(size: 8, weight: .semibold))
            Text(Self.tokenText(usage.totalTokens))
                .font(.system(size: 9.5, weight: .medium))
                .monospacedDigit()
            if let cost = usage.estimatedCostUSD {
                Text("≈" + Self.costText(cost))
                    .font(.system(size: 9.5, weight: .medium))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(AppStyle.textTertiary)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Capsule().fill(AppStyle.hoverFill))
        .help(usageTooltip(usage))
    }

    private func usageTooltip(_ usage: AgentSessionUsage) -> String {
        var parts = [
            L("输入 %@", Self.tokenText(usage.inputTokens)),
            L("输出 %@", Self.tokenText(usage.outputTokens)),
        ]
        if usage.cacheReadTokens > 0 {
            parts.append(L("缓存读 %@", Self.tokenText(usage.cacheReadTokens)))
        }
        if usage.cacheCreationTokens > 0 {
            parts.append(L("缓存写 %@", Self.tokenText(usage.cacheCreationTokens)))
        }
        if let model = usage.model {
            parts.append(model)
        }
        if usage.estimatedCostUSD != nil {
            parts.append(L("成本为等价 API 价估算"))
        }
        return parts.joined(separator: " · ")
    }

    static func tokenText(_ count: Int) -> String {
        switch count {
        case ..<1000: return "\(count)"
        case ..<1_000_000: return String(format: "%.1fK", Double(count) / 1000)
        default: return String(format: "%.2fM", Double(count) / 1_000_000)
        }
    }

    static func costText(_ usd: Double) -> String {
        usd < 0.01 ? "<$0.01" : String(format: "$%.2f", usd)
    }

    private func confirmDelete() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("删除会话「%@」？", String(record.title.prefix(40)))
        alert.informativeText = L("会删除这条本机会话记录，无法撤销。")
        alert.addButton(withTitle: L("删除"))
        alert.addButton(withTitle: L("取消"))
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn {
            SessionManagerStore.shared.delete(record)
        }
    }

    private func toggleExpanded() {
        guard record.filePath != nil else { return }
        withAnimation(Motion.expand) { expanded.toggle() }
        if expanded, preview == nil, !loadingPreview { loadPreview() }
    }

    private func loadPreview() {
        guard record.filePath != nil else { return }
        loadingPreview = true
        Task {
            let messages = await SessionPreviewCache.shared.messages(
                for: record,
                limit: SessionPreviewCache.expandedPreviewLimit,
                tailBytes: SessionPreviewCache.expandedTailBytes)
            preview = messages
            loadingPreview = false
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if loadingPreview, preview == nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).scaleEffect(0.65)
                    Text(L("读取最近对话…"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(AppStyle.textTertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else if let preview, !preview.isEmpty {
                HStack {
                    Text(L("最近 %ld 条消息", preview.count))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(AppStyle.textTertiary)
                    Spacer()
                }
                SessionTranscriptView(messages: preview, agent: record.agent, maxHeight: 420)
            } else {
                Text(L("没有可预览的对话内容"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(AppStyle.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .fill(AppStyle.theme.isDark ? Color.white.opacity(0.04) : Color.black.opacity(0.03)))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    @ViewBuilder
    private var logo: some View {
        if let image = CLIToolLogo.image(named: logoName) {
            if CLIToolLogo.isMonochrome(logoName) {
                Image(nsImage: image)
                    .resizable().scaledToFit()
                    .frame(width: 18, height: 18)
                    .foregroundStyle(AppStyle.textSecondary)
            } else {
                Image(nsImage: image)
                    .resizable().scaledToFit()
                    .frame(width: 18, height: 18)
            }
        } else {
            Image(systemName: record.agent == "claude" ? "sparkles" : "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 12))
                .foregroundStyle(AppStyle.textSecondary)
                .frame(width: 18, height: 18)
        }
    }
}
