import ConductorCore
import Foundation

/// 一个可一键安装的 hook「配方」（hook 市场条目）。
struct HookRecipe: Identifiable, Sendable {
    let id: String
    let title: String
    let detail: String
    let icon: String
    /// 写入 Stop 的命令（已含 `$CONDUCTOR_PANE_ID` 网关 + `#conductor:<id>` 哨兵）。
    let command: String
    /// 安装前需要落地的脚本（如 conductor-notify）。
    let ensureScript: (@Sendable () throws -> Void)?
}

enum HookRecipes {
    /// 网关 + 哨兵：只对 conductor 启动的 agent 触发，且可被管理面板识别移除。
    static func gated(_ action: String, id: String) -> String {
        "[ -n \"$CONDUCTOR_PANE_ID\" ] && \(action) >/dev/null 2>&1 || true #conductor:\(id)"
    }

    static let all: [HookRecipe] = [
        HookRecipe(
            id: HookInstaller.recipeID,
            title: L("conductor 完成通知"),
            detail: L("agent 答完发系统通知，点击跳回对应 pane（推荐）"),
            icon: "bell.badge.fill",
            command: HookInstaller.stopCommand,
            ensureScript: { try HookInstaller.installScript() }),
        HookRecipe(
            id: "sound",
            title: L("完成提示音"),
            detail: L("agent 完成时播放系统提示音（Glass）"),
            icon: "speaker.wave.2.fill",
            command: gated("afplay /System/Library/Sounds/Glass.aiff", id: "sound"),
            ensureScript: nil),
        HookRecipe(
            id: "banner",
            title: L("系统横幅"),
            detail: L("用 osascript 弹系统横幅（不支持点击跳转）"),
            icon: "rectangle.badge.checkmark",
            command: gated("osascript -e 'display notification \"AI 已完成\" with title \"conductor\"'", id: "banner"),
            ensureScript: nil),
        HookRecipe(
            id: "log",
            title: L("完成日志"),
            detail: L("agent 完成时记录一条本机事件，方便之后排查节奏"),
            icon: "doc.append",
            command: gated(
                "mkdir -p \"$HOME/.conductor\" && printf '%s stop pane=%s\\n' \"$(date '+%Y-%m-%d %H:%M:%S')\" \"$CONDUCTOR_PANE_ID\" >> \"$HOME/.conductor/agent-events.log\"",
                id: "log"),
            ensureScript: nil),
    ]

    /// 某配方在各 agent 的安装状态。
    static func installedSources(_ recipe: HookRecipe) -> Set<HookSource> {
        var out = Set<HookSource>()
        for source in HookSource.allCases {
            let entries = HookConfigDocument(source: source).entries()
            if entries.contains(where: { $0.command.contains("#conductor:\(recipe.id)") }) {
                out.insert(source)
            }
        }
        return out
    }

    /// 安装一个配方到两个 agent 的 hook。内置通知配方会装齐 Stop/UserPromptSubmit/SessionStart。
    static func install(_ recipe: HookRecipe) throws {
        if recipe.id == HookInstaller.recipeID {
            _ = try HookInstaller.installAll()
            return
        }
        try recipe.ensureScript?()
        for source in HookSource.allCases {
            try HookConfigDocument(source: source).addCommand(
                event: HookEventName.stop, command: recipe.command)
        }
    }

    /// 从两个 agent 移除该配方（按哨兵）。
    @discardableResult
    static func uninstall(_ recipe: HookRecipe) throws -> Int {
        var removed = 0
        for source in HookSource.allCases {
            removed += try HookConfigDocument(source: source).removeCommands(containing: "#conductor:\(recipe.id)")
        }
        return removed
    }
}
