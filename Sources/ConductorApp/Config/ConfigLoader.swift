import ConductorCore
import Foundation
import Yams

/// 读写 `~/.config/conductor/config.yaml`：
/// - 不存在 → 写一份带注释的默认模板，返回默认配置；
/// - 解析失败 → 记日志 + 回退默认（**绝不崩**，高商用）；
/// - 成功 → `validated()` 夹紧非法值后返回。
struct ConfigLoader {
    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/conductor/config.yaml")
    }

    func load() -> AppConfig {
        let url = Self.configURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            writeDefaultTemplate(to: url)
            return .default
        }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let config = try YAMLDecoder().decode(AppConfig.self, from: text)
            return config.validated()
        } catch {
            NSLog("[conductor] config.yaml 解析失败，使用默认配置：\(error)")
            return .default
        }
    }

    /// 把配置写回 config.yaml（设置面板用）。YAMLEncoder 输出无注释，加一行头注释。
    func save(_ config: AppConfig) {
        let url = Self.configURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let yaml = try YAMLEncoder().encode(config)
            let header = "# conductor 配置（部分由设置面板写入，可手编，改完即生效）\n\n"
            try (header + yaml).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSLog("[conductor] 写 config.yaml 失败：\(error)")
        }
    }

    private func writeDefaultTemplate(to url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.defaultTemplate.write(to: url, atomically: true, encoding: .utf8)
            NSLog("[conductor] 已生成默认配置：\(url.path)")
        } catch {
            NSLog("[conductor] 写默认 config.yaml 失败：\(error)")
        }
    }

    /// 首启写入的带注释模板（手写，保留注释；不是 Yams 编码结果）。
    static let defaultTemplate = """
    # conductor 配置文件
    # 改完保存即生效。删掉本文件会重新生成这份默认模板。

    appearance:
      theme: dark               # dark | light（或 custom，用下面的 colors）
      font:
        family: "SF Mono"
        size: 13
      padding: { x: 14, y: 12 }
      cursorStyle: bar          # bar | block | underline
      # theme: custom 时启用自定义配色：
      # colors:
      #   background: "#1b1c22"
      #   foreground: "#d7d8e0"
      #   cursor: "#8aa9ff"
      #   selection: "#33406b"

    terminal:
      shell: null               # null = 你的登录 shell；或绝对路径如 "/bin/zsh"
      scrollback: 60000
      copyOnSelect: false
      confirmCloseRunning: true
      autoResumeAgentSessions: true
      # AI Agent 会话入口。留空 = 使用自动检测结果；也可以在设置里扫描/手动添加。
      aiAgents: []
      # - id: codex
      #   title: Codex CLI
      #   command: codex
      #   enabled: true

    behavior:
      restoreLayoutOnLaunch: true
      newTabCwd: workspace      # workspace | activePane | home

    # 快捷键：命令 id -> 键位（缺省用内置默认）
    keybindings:
      newTab: "cmd+t"
      splitRight: "cmd+d"
      splitDown: "cmd+shift+d"
      closePane: "cmd+w"
      focusNextPane: "cmd+alt+right"
      focusPrevPane: "cmd+alt+left"
      increaseFontSize: "cmd+="
      decreaseFontSize: "cmd+-"
      resetFontSize: "cmd+0"
      openSettings: "cmd+,"
      toggleZoom: "cmd+enter"
      commandPalette: "cmd+k"

    # Ghostty 高级配置覆盖：key -> value。留空或删除即回到 conductor 默认。
    # 示例：
    # ghosttyOverrides:
    #   cursor-style: block
    #   background-opacity: "0.92"
    ghosttyOverrides: {}

    workspaceDefaults:
      shell: null
      startupCommand: null

    # 账号用量 provider 设置。默认空配置；在 CLI 面板里启用、填 key 或调整来源后会写入。
    usage:
      providers: {}

    """
}
