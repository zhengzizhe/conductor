import AppKit
import SwiftUI

private let coCreateAccent = Color(red: 0.12, green: 0.63, blue: 0.55)

/// 「共创计划」面板：维护者的一封短信 + 怎么提、提什么、提了之后会怎样。
struct CoCreateView: View {
    /// GitHub 仓库与预填好模板的新 Issue 链接。
    static let repoURL = URL(string: "https://github.com/zhengzizhe/conductor")!
    static var newIssueURL: URL {
        var components = URLComponents(string: "https://github.com/zhengzizhe/conductor/issues/new")!
        components.queryItems = [
            URLQueryItem(name: "title", value: "\(L("[共创]")) "),
            URLQueryItem(name: "body", value: """
            ### 在做什么

            ### 卡在哪一步

            ### 现在怎么绕的

            ### 截图 / 日志 / 配置（可选）

            """),
        ]
        return components.url!
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                intro
                whatToWrite
                afterSubmit
                ideaList
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 20)
        }
        .scrollIndicators(.never)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("共创计划"))
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(AppStyle.textPrimary)
            Text(L("这个工具是一边用一边改出来的，大部分功能都始于「今天又被什么卡住了」。如果你也在用，把卡住你的那件事写下来，比任何建议都有用。"))
                .font(.system(size: 12))
                .lineSpacing(4.5)
                .foregroundStyle(AppStyle.textSecondary)
            HStack(spacing: 8) {
                // 主 CTA 保留品牌 teal（coCreateAccent），改用共享按钮组件去掉手搓的圆角矩形。
                ToolActionButton(
                    title: L("去提一条"),
                    role: .tinted(coCreateAccent),
                    height: 29,
                    horizontalPadding: 14,
                    help: L("打开 GitHub，新 Issue 已带上简短模板")) {
                        NSWorkspace.shared.open(Self.newIssueURL)
                    }
                ToolActionButton(
                    title: L("看看仓库"),
                    role: .secondary,
                    height: 29,
                    horizontalPadding: 12) {
                        NSWorkspace.shared.open(Self.repoURL)
                    }
            }
            .padding(.top, 4)
        }
    }

    private var whatToWrite: some View {
        section(L("写什么都行")) {
            bullet(L("在做什么、哪一步不顺、现在怎么绕过去的。"))
            bullet(L("一句话就够，有截图、日志或配置片段更好。"))
            bullet(L("想自己动手改的，先在 Issue 里说一声，把范围聊小一点更容易合并。"))
        }
    }

    private var afterSubmit: some View {
        section(L("提了之后")) {
            Text(L("会在 Issue 里直接回复和同步进展。做进去的东西出现在下一版的更新说明里，会写上是谁提的。"))
                .font(.system(size: 11.5))
                .lineSpacing(4)
                .foregroundStyle(AppStyle.textSecondary)
        }
    }

    private var ideaList: some View {
        section(L("最近在琢磨的方向")) {
            VStack(spacing: 2) {
                ideaRow(L("多 Agent 对照"), L("同一任务开多个 worktree，保留命令、diff 和结论，方便选一个继续。"))
                ideaRow(L("等待处理"), L("把需要确认、授权或补充信息的卡点收拢成一张清单。"))
                ideaRow(L("工作区记忆"), L("恢复布局时带回目录、Agent、分屏和最近上下文。"))
                ideaRow(L("成本与用量"), L("按任务查看 token、时长和大致成本，帮助判断一次探索值不值。"))
                ideaRow(L("移动确认"), L("离开电脑时也能处理关键确认，让长任务不中断。"))
                ideaRow(L("文档案例"), L("用真实项目写一段教程、录屏或故障排查记录。"))
            }
            Text(L("对哪个有想法，点开就是带标题的新 Issue。"))
                .font(.system(size: 10.5))
                .foregroundStyle(AppStyle.textTertiary)
                .padding(.top, 6)
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppStyle.textPrimary)
            content()
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(AppStyle.textTertiary)
                .frame(width: 3.5, height: 3.5)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            Text(text)
                .font(.system(size: 11.5))
                .lineSpacing(3.5)
                .foregroundStyle(AppStyle.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func ideaRow(_ title: String, _ detail: String) -> some View {
        IdeaRow(title: title, detail: detail)
    }
}

private struct IdeaRow: View {
    let title: String
    let detail: String
    @State private var hovering = false

    var body: some View {
        Button {
            var components = URLComponents(
                url: CoCreateView.newIssueURL,
                resolvingAgainstBaseURL: false
            )!
            components.queryItems = components.queryItems?.map {
                $0.name == "title" ? URLQueryItem(name: "title", value: "\(L("[共创]")) \(title)：") : $0
            }
            NSWorkspace.shared.open(components.url ?? CoCreateView.newIssueURL)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(AppStyle.textPrimary)
                    Text(detail)
                        .font(.system(size: 10.5))
                        .lineSpacing(2.5)
                        .foregroundStyle(AppStyle.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(hovering ? coCreateAccent : AppStyle.textTertiary.opacity(0.4))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .fill(hovering ? AppStyle.hoverFill : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(Motion.hover, value: hovering)
        .onHover { hovering = $0 }
    }
}
