import Foundation

/// 系统通知文案清洗：通知横幅是"扫一眼"的提醒，不是内容阅读器。
///
/// agent（codex / claude）经 OSC 通道发的桌面通知，body 里常是整段回复——
/// 多行长文塞进横幅既难看也读不完，真正的内容在终端和活动账本里都有。
/// 规则：短消息（一两行、不超长）原样保留；像"内容转储"的（多行长文）
/// 整体换成通用提示，由调用方给兜底文案。标题统一折叠空白并截断。
enum NotificationText {
    /// 整理后正文仍可上横幅的上限；超过即视为内容转储。
    static let bodyLimit = 100
    /// 标题上限（pane 标题可能是很长的命令行/路径）。
    static let titleLimit = 60
    /// 保留原文的最大行数；更多行说明是成段内容。
    static let bodyLineLimit = 2

    /// 标题：折叠空白 + 截断。
    static func title(_ raw: String) -> String {
        truncate(collapseWhitespace(raw), limit: titleLimit)
    }

    /// 正文：短消息整理后返回；内容转储返回 `fallback`。
    static func body(_ raw: String, fallback: String) -> String {
        let lines = raw
            .components(separatedBy: .newlines)
            .map { collapseWhitespace($0) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return fallback }
        guard lines.count <= bodyLineLimit else { return fallback }
        let joined = lines.joined(separator: " · ")
        guard joined.count <= bodyLimit else { return fallback }
        return joined
    }

    private static func collapseWhitespace(_ s: String) -> String {
        s.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func truncate(_ s: String, limit: Int) -> String {
        guard s.count > limit else { return s }
        return String(s.prefix(limit - 1)) + "…"
    }
}
