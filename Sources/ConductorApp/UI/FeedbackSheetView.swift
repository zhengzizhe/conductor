import AppKit
import SwiftUI

struct FeedbackSheetView: View {
    var onClose: () -> Void
    var onSubmitFinished: (_ succeeded: Bool, _ message: String) -> Void

    @ObservedObject private var configStore = ConfigStore.shared
    @State private var email = ""
    @State private var message = ""
    @State private var emailTouched = false
    @State private var isSubmitting = false
    @State private var statusText: String?

    private let client = FeedbackClient()

    private var trimmedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var emailIsValid: Bool {
        FeedbackEmailValidator.isValid(trimmedEmail)
    }

    private var canSubmit: Bool {
        emailIsValid && !trimmedMessage.isEmpty && !isSubmitting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(AppStyle.separator)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    appFeedback
                    Divider().overlay(AppStyle.separator)
                    githubIssue
                    releaseInfo
                }
                .padding(20)
            }
            footer
        }
        .frame(width: 480, height: 560)
        .background(AppStyle.windowBackground)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.bubble")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppStyle.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("反馈"))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(AppStyle.textPrimary)
                Text(L("应用内反馈和 GitHub Issue 是两个入口，请按场景选择。"))
                    .font(.system(size: 11))
                    .foregroundStyle(AppStyle.textTertiary)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AppStyle.textSecondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(AppStyle.hoverFill))
                    .contentShape(Circle())
            }
            .buttonStyle(PressScaleStyle())
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var appFeedback: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(L("应用内反馈"), icon: "paperplane")
            Text(L("用于留下邮箱和问题描述，方便后续功能上新或相关版本发布时通知你。提交会发送到应用内配置的反馈接口。"))
                .font(.system(size: 11.5))
                .lineSpacing(3)
                .foregroundStyle(AppStyle.textSecondary)

            VStack(alignment: .leading, spacing: 8) {
                Text(L("邮箱"))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(AppStyle.textPrimary)
                TextField("you@example.com", text: $email)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(AppStyle.textPrimary)
                    .padding(.horizontal, 11)
                    .frame(height: 34)
                    .background(fieldBackground)
                    .onChange(of: email) { _, _ in emailTouched = true }
                    .onSubmit { submit() }

                if emailTouched && !trimmedEmail.isEmpty && !emailIsValid {
                    Label(L("请输入有效邮箱；暂不支持手机号。"), systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color(red: 0.92, green: 0.34, blue: 0.34))
                } else {
                    Text(L("暂不支持手机号。"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(AppStyle.textTertiary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(L("问题描述"))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(AppStyle.textPrimary)
                TextEditor(text: $message)
                    .font(.system(size: 12.5))
                    .foregroundStyle(AppStyle.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 96)
                    .background(fieldBackground)
            }

            if let statusText {
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(AppStyle.textTertiary)
            }
        }
    }

    private var githubIssue: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(L("公开 GitHub Issue"), icon: "arrow.up.forward.square")
            Text(L("适合公开的 bug、需求讨论或带截图日志的问题。这个入口会打开浏览器，不会提交应用内反馈表单。"))
                .font(.system(size: 11.5))
                .lineSpacing(3)
                .foregroundStyle(AppStyle.textSecondary)
            Button {
                NSWorkspace.shared.open(CoCreateView.newIssueURL)
            } label: {
                Label(L("前往 GitHub 提 Issue"), systemImage: "arrow.up.forward")
            }
            .buttonStyle(SecondaryButtonStyle())
            .help(L("打开 GitHub，新 Issue 已带上简短模板"))
        }
    }

    private var releaseInfo: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle(L("版本与更新"), icon: "arrow.triangle.2.circlepath")
            infoRow(L("当前版本"), FeedbackMetadata.appVersion)
            infoRow(L("Release 链接"), FeedbackClient.releaseURL.absoluteString)
            infoRow(L("自动更新方式"), L("当前通过 GitHub Releases 下载更新；下载完成后可一键安装并重启。"))
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(L("取消"), action: onClose)
                .buttonStyle(SecondaryButtonStyle())
            Button(isSubmitting ? L("提交中…") : L("提交应用内反馈")) {
                submit()
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!canSubmit)
            .opacity(canSubmit ? 1 : 0.45)
        }
        .padding(16)
        .background(AppStyle.windowBackground)
        .overlay(alignment: .top) {
            Rectangle().fill(AppStyle.separator).frame(height: 1)
        }
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(AppStyle.theme.isDark ? Color.white.opacity(0.055) : Color.black.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(AppStyle.separator.opacity(0.8), lineWidth: 1)
            )
    }

    private func sectionTitle(_ title: String, icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppStyle.accent)
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(AppStyle.textPrimary)
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(AppStyle.textTertiary)
            Text(value)
                .font(.system(size: 11.5))
                .foregroundStyle(AppStyle.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func submit() {
        emailTouched = true
        guard canSubmit else { return }
        isSubmitting = true
        statusText = nil
        let request = FeedbackRequest(
            email: trimmedEmail,
            message: trimmedMessage,
            appVersion: FeedbackMetadata.appVersion,
            releaseURL: FeedbackClient.releaseURL,
            updateChannel: FeedbackClient.updateChannel
        )
        Task {
            do {
                try await client.submit(request)
                await MainActor.run {
                    isSubmitting = false
                    onClose()
                    onSubmitFinished(true, L("反馈提交成功"))
                }
            } catch {
                await MainActor.run {
                    isSubmitting = false
                    NSLog("[conductor] feedback submit failed: \(error.localizedDescription)")
                    let message = error.feedbackUserMessage
                    statusText = message
                    onSubmitFinished(false, message)
                }
            }
        }
    }
}
