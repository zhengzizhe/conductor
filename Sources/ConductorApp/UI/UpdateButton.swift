import SwiftUI

/// tab 栏的版本更新入口：有新版亮小圆点，点开弹窗里检查/下载/安装一条龙。
struct UpdateButton: View {
    @ObservedObject private var updater = UpdateManager.shared
    @State private var showPopover = false

    var body: some View {
        IconOnlyButton(
            systemName: "arrow.down.circle",
            help: updater.updateAvailable ? L("有新版本可用") : L("检查更新"),
            size: 26,
            symbolSize: 12,
            tint: updater.updateAvailable ? AppStyle.accent : AppStyle.textSecondary) {
                showPopover.toggle()
            }
        .overlay(alignment: .topTrailing) {
            if updater.updateAvailable {
                Circle()
                    .fill(AppStyle.accent)
                    .frame(width: 7, height: 7)
                .offset(x: -1, y: 1)
            }
        }
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            UpdatePopover(updater: updater)
        }
        .alert(item: $updater.installPrompt) { prompt in
            Alert(
                title: Text(L("v%@ 已下载完成", prompt.version)),
                message: Text(L("是否现在重启并安装？选择稍后时，Conductor 会在退出后安装，下次打开就是新版本。")),
                primaryButton: .default(Text(L("重启并安装"))) {
                    updater.installDownloadedAndRestart()
                },
                secondaryButton: .cancel(Text(L("稍后"))) {
                    updater.installDownloadedLater()
                })
        }
    }
}

private struct UpdatePopover: View {
    @ObservedObject var updater: UpdateManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("版本更新"))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(L("当前 v%@", updater.currentVersion))
                    .font(.system(size: 11))
                    .foregroundStyle(AppStyle.textTertiary)
            }

            statusSection

            HStack {
                Toggle(L("自动检查更新"), isOn: $updater.autoCheckEnabled)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11.5))
                Spacer()
                Link(L("Releases 页面"), destination: UpdateManager.releasesPageURL)
                    .font(.system(size: 11.5))
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    @ViewBuilder
    private var statusSection: some View {
        switch updater.phase {
        case .idle:
            checkRow(statusText: nil)
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("正在检查更新…"))
                    .font(.system(size: 12))
                    .foregroundStyle(AppStyle.textTertiary)
            }
        case .upToDate(let date):
            checkRow(statusText: L(
                "已是最新版（%@ 检查）",
                date.formatted(date: .omitted, time: .shortened)))
        case .available(let release):
            availableSection(release)
        case .downloading(let release):
            downloadingSection(release)
        case .downloaded(let release, _):
            downloadedSection(release)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text(message).font(.system(size: 11.5)).lineLimit(3)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppStyle.waitAmber)
                }
                ToolActionButton(
                    title: L("重试"),
                    role: .secondary,
                    height: 24,
                    fontSize: 11) { Task { await updater.check(manual: true) } }
            }
        }
    }

    private func checkRow(statusText: String?) -> some View {
        HStack(spacing: 8) {
            ToolActionButton(
                title: L("检查更新"),
                role: .secondary,
                height: 24,
                fontSize: 11) { Task { await updater.check(manual: true) } }
            if let statusText {
                Text(statusText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(AppStyle.textTertiary)
            }
        }
    }

    private func availableSection(_ release: UpdateManager.Release) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(L("发现新版 v%@", release.version))
                    .font(.system(size: 12, weight: .semibold))
            } icon: {
                Image(systemName: "sparkles").foregroundStyle(AppStyle.accent)
            }
            if !release.notes.isEmpty {
                ScrollView {
                    Text(release.notes)
                        .font(.system(size: 11))
                        .foregroundStyle(AppStyle.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }
            ToolActionButton(
                title: L("下载更新（%@）", Self.sizeText(release.assetSize)),
                systemImage: "arrow.down.circle.fill",
                role: .primary) {
                    updater.download(release)
                }
        }
    }

    private func downloadingSection(_ release: UpdateManager.Release) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("正在下载 v%@", release.version))
                .font(.system(size: 12, weight: .semibold))
            HStack(spacing: 8) {
                ProgressView(value: updater.downloadProgress)
                    .frame(maxWidth: .infinity)
                Text("\(Int(updater.downloadProgress * 100))%")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(AppStyle.textTertiary)
                    .frame(width: 36, alignment: .trailing)
            }
            ToolActionButton(
                title: L("取消下载"),
                role: .secondary,
                height: 24,
                fontSize: 11) { updater.cancelDownload() }
        }
    }

    private func downloadedSection(_ release: UpdateManager.Release) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(L("v%@ 已下载完成", release.version))
                    .font(.system(size: 12, weight: .semibold))
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(AppStyle.doneGreen)
            }
            Text(L("可以现在重启安装，也可以稍后退出时自动安装；未签名或权限受限时，macOS 可能仍会要求确认。"))
                .font(.system(size: 11))
                .foregroundStyle(AppStyle.textTertiary)
            HStack(spacing: 8) {
                ToolActionButton(
                    title: L("安装并重启"),
                    systemImage: "arrow.triangle.2.circlepath",
                    role: .primary,
                    height: 24,
                    fontSize: 11) { updater.installDownloadedAndRestart() }
                ToolActionButton(
                    title: L("打开安装包"),
                    role: .secondary,
                    height: 24,
                    fontSize: 11) { updater.openDownloaded() }
                ToolActionButton(
                    title: L("在访达中显示"),
                    role: .secondary,
                    height: 24,
                    fontSize: 11) { updater.revealDownloaded() }
            }
        }
    }

    private static func sizeText(_ bytes: Int64) -> String {
        guard bytes > 0 else { return L("未知大小") }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
