import SwiftUI

/// 顶部瞬时确认横幅（写操作成功后给一句反馈，约 2.6s 自动消失）。
struct AgentToolsNoticeBanner: View {
    let text: String?
    let onDismiss: () -> Void

    var body: some View {
        Group {
            if let text {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppStyle.doneGreen)
                    Text(text)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppStyle.textPrimary)
                        .lineLimit(2)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    Capsule().fill(AppStyle.windowBackground)
                        .shadow(color: .black.opacity(0.18), radius: 10, y: 4))
                .overlay(Capsule().strokeBorder(AppStyle.doneGreen.opacity(0.35), lineWidth: 1))
                .padding(.top, 12)
                .transition(AgentToolsMotion.revealTransition)
                .task(id: text) {
                    try? await Task.sleep(nanoseconds: 2_600_000_000)
                    onDismiss()
                }
            }
        }
        .animation(AgentToolsMotion.reveal, value: text)
    }
}

/// 通用的原生 JSON 编辑器弹窗：等宽 TextEditor + 文件路径副标题 + 保存校验 + 行内报错。
/// MCP / Hooks 都用它——「给一片区域，用户自己贴」。
/// onSave 返回 nil 表示成功（自动关闭）；返回字符串表示校验失败，原地展示，不关闭。
struct AgentToolsJSONEditorSheet: View {
    let title: String
    let subtitle: String
    let hint: String
    let onSave: (String) -> String?
    let onClose: () -> Void

    @State private var text: String
    @State private var error: String?
    @State private var dirty = false

    init(title: String, subtitle: String, hint: String = "",
         initialText: String,
         onSave: @escaping (String) -> String?,
         onClose: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.hint = hint
        self.onSave = onSave
        self.onClose = onClose
        _text = State(initialValue: initialText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            editor
            if let error {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppStyle.errorRed)
                    Text(error)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppStyle.errorRed)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Space.lg)
                .padding(.vertical, 8)
                .background(AppStyle.errorRed.opacity(0.08))
            }
            footer
        }
        .frame(minWidth: 580, idealWidth: 680, minHeight: 460, idealHeight: 560)
        .background(AppStyle.windowBackground)
    }

    private var header: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "curlybraces")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppStyle.accent)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(AppStyle.accent.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(AppStyle.textPrimary)
                Text(subtitle)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppStyle.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
            IconOnlyButton(systemName: "xmark", help: L("关闭"), size: 28, symbolSize: 11, action: onClose)
        }
        .padding(.horizontal, Space.lg)
        .padding(.top, Space.lg)
        .padding(.bottom, Space.sm)
    }

    private var editor: some View {
        TextEditor(text: $text)
            .font(.system(size: 12, weight: .regular, design: .monospaced))
            .foregroundStyle(AppStyle.textPrimary)
            .scrollContentBackground(.hidden)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .fill(AppStyle.hoverFill.opacity(AppStyle.theme.isDark ? 0.4 : 0.6)))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .strokeBorder(AppStyle.separator.opacity(0.18), lineWidth: 1))
            .padding(.horizontal, Space.lg)
            .frame(maxHeight: .infinity)
            .onChange(of: text) { _, _ in
                dirty = true
                if error != nil { error = nil }
            }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if !hint.isEmpty {
                Text(hint)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(AppStyle.textTertiary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            ToolActionButton(title: L("取消"), height: 30, fontSize: 12, horizontalPadding: 14, action: onClose)
            ToolActionButton(
                title: L("保存"),
                systemImage: "checkmark",
                role: .primary,
                height: 30, fontSize: 12, horizontalPadding: 14
            ) {
                if let message = onSave(text) {
                    error = message
                } else {
                    onClose()
                }
            }
            .disabled(!dirty)
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
    }
}
