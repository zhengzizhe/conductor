import ConductorCore
import SwiftUI

/// 侧边栏会话行悬停时弹出的 transcript 预览（只读取尾部窗口，避免大 transcript 卡顿）。
struct SessionHoverPreviewPanel: View {
    let record: AgentSessionRecord
    var onResume: () -> Void

    @ObservedObject private var configStore = ConfigStore.shared
    @State private var messages: [AgentSessionMessage]?
    @State private var loading = false

    private let panelWidth: CGFloat = 360
    private let panelMaxHeight: CGFloat = 520

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            transcriptBody
            footer
        }
        .frame(width: panelWidth, height: panelHeight)
        .presentationBackground(AppStyle.elevated)   // popover 背景跟随 app 主题（含箭头）
        .onAppear { loadIfNeeded() }
        .onChange(of: record.id) { _, _ in
            messages = nil
            loadIfNeeded()
        }
    }

    private var panelHeight: CGFloat {
        guard let messages, !messages.isEmpty else { return 160 }
        return panelMaxHeight
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(record.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(AppStyle.textPrimary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(record.agent.capitalized)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(AppStyle.accent)
                    if let count = messages?.count {
                        Text(L("最近 %ld 条消息", count))
                            .font(.system(size: 10))
                            .foregroundStyle(AppStyle.textTertiary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var transcriptBody: some View {
        if loading, messages == nil {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("读取最近对话…"))
                    .font(.system(size: 11))
                    .foregroundStyle(AppStyle.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let messages, !messages.isEmpty {
            SessionTranscriptView(messages: messages, agent: record.agent,
                                  maxHeight: panelMaxHeight - 108, fontSize: 10.5)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        } else {
            Text(L("没有可预览的对话"))
                .font(.system(size: 11))
                .foregroundStyle(AppStyle.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack {
            Text(record.shortID)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(AppStyle.textTertiary)
            Spacer()
            Button(L("续聊"), action: onResume)
                .buttonStyle(PrimaryButtonStyle())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func loadIfNeeded() {
        guard messages == nil, !loading, record.filePath != nil else { return }
        loading = true
        Task {
            let loaded = await SessionPreviewCache.shared.messages(
                for: record,
                limit: SessionPreviewCache.hoverPreviewLimit,
                tailBytes: SessionPreviewCache.hoverTailBytes)
            messages = loaded
            loading = false
        }
    }
}
