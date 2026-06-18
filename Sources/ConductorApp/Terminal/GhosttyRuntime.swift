import AppKit
import ConductorCore
import Foundation
@preconcurrency import GhosttyKit

/// 最小 libghostty 运行时（单例，C 回调里只能引用全局）。
/// 相比 spike，action_cb 升级为按 surface 路由 title/pwd/child-exited 到对应 GhosttySurface。
@MainActor
final class GhosttyRuntime {
    static let shared = GhosttyRuntime()
    static let managedTerminalType = "xterm-256color"
    static let managedColorTerm = "truecolor"
    static let managedTerminalProgram = "ghostty"

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?
    private var tickScheduled = false

    private init() {}

    func ensureStarted() {
        guard app == nil else { return }

        Self.configureManagedTerminalEnvironment()

        let resources = "/Applications/Ghostty.app/Contents/Resources/ghostty"
        if FileManager.default.fileExists(atPath: resources + "/shell-integration/zsh/.zshenv") {
            setenv("GHOSTTY_RESOURCES_DIR", resources, 1)
        }

        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            NSLog("[conductor] ghostty_init failed")
            return
        }
        // 终端外观全部从用户配置(config.yaml)生成，不再硬编码。
        guard let config = Self.makeConfig(from: ConfigStore.shared.config) else {
            NSLog("[conductor] ghostty_config_new failed")
            return
        }

        var rc = ghostty_runtime_config_s()
        rc.userdata = nil
        rc.supports_selection_clipboard = true
        rc.wakeup_cb = { _ in
            Task { @MainActor in GhosttyRuntime.shared.scheduleTick() }
        }
        rc.action_cb = { _, target, action in
            GhosttyRuntime.routeAction(target: target, action: action)
        }
        // 剪贴板回调：缺这两个，libghostty 在「选中→复制」时会调空指针而崩溃。
        rc.write_clipboard_cb = { _, location, content, count, _ in
            guard let content, count > 0 else { return }
            let items = UnsafeBufferPointer(start: content, count: Int(count))
            var fallback: String?
            for item in items {
                guard let data = item.data else { continue }
                let value = String(cString: data)
                if let mime = item.mime, String(cString: mime).hasPrefix("text/plain") {
                    GhosttyClipboardBridge.shared.writeString(value, to: location)
                    return
                }
                if fallback == nil {
                    fallback = value
                }
            }
            if let fallback {
                GhosttyClipboardBridge.shared.writeString(fallback, to: location)
            }
        }
        rc.read_clipboard_cb = { userdata, _, state in
            guard let userdata, let state else { return false }
            let surface = Unmanaged<GhosttySurface>.fromOpaque(userdata).takeUnretainedValue()
            let retained = Unmanaged.passRetained(surface)
            Task { @MainActor in
                retained.takeRetainedValue().completeClipboardRequest(state: state)
            }
            return true
        }

        guard let created = ghostty_app_new(&rc, config) else {
            NSLog("[conductor] ghostty_app_new failed")
            ghostty_config_free(config)
            return
        }
        self.app = created
        self.config = config
        applyColorScheme(for: ConfigStore.shared.config)
        ghostty_app_set_focus(created, true)
        NSLog("[conductor] ghostty runtime started")
    }

    static func configureManagedTerminalEnvironment() {
        // The Codex/dev parent environment can carry NO_COLOR=1. Terminal UIs
        // such as Claude Code and Codex honor it and intentionally render in
        // monochrome, even though the terminal palette itself supports color.
        unsetenv("NO_COLOR")
        if getenv("TERM") == nil {
            setenv("TERM", managedTerminalType, 1)
        }
        if getenv("COLORTERM") == nil {
            setenv("COLORTERM", managedColorTerm, 1)
        }
        if getenv("TERM_PROGRAM") == nil {
            setenv("TERM_PROGRAM", managedTerminalProgram, 1)
        }
    }

    /// 用 AppConfig 造一个 ghostty 配置对象(load string + finalize)。
    static func makeConfig(from appConfig: AppConfig) -> ghostty_config_t? {
        guard let config = ghostty_config_new() else { return nil }
        let text = ghosttyConfigText(from: appConfig)
        text.withCString {
            ghostty_config_load_string(config, $0, UInt(text.utf8.count), "conductor")
        }
        ghostty_config_finalize(config)
        return config
    }

    /// 热更新:用新配置重建 ghostty 配置并应用到 app(各 surface 由 GhosttySurface.reloadConfig 各自更新)。
    func applyConfig(_ appConfig: AppConfig) {
        guard let app, let newConfig = Self.makeConfig(from: appConfig) else { return }
        ghostty_app_update_config(app, newConfig)
        applyColorScheme(for: appConfig)
        let old = config
        config = newConfig
        if let old { ghostty_config_free(old) }
    }

    func applyColorScheme(for appConfig: AppConfig) {
        guard let app else { return }
        ghostty_app_set_color_scheme(app, Self.colorScheme(for: appConfig))
    }

    static func colorScheme(for appConfig: AppConfig) -> ghostty_color_scheme_e {
        ThemePalette.resolve(appConfig.appearance).isDark
            ? GHOSTTY_COLOR_SCHEME_DARK
            : GHOSTTY_COLOR_SCHEME_LIGHT
    }

    /// 把 `AppConfig` 翻译成 libghostty 的 `key = value` 配置串(高扩展:数据驱动)。
    static func ghosttyConfigText(from config: AppConfig) -> String {
        let a = config.appearance
        let theme = ThemePalette.resolve(a)
        var lines: [(key: String, value: String)] = []
        func set(_ key: String, _ value: String) {
            if let index = lines.firstIndex(where: { $0.key == key }) {
                lines[index].value = value
            } else {
                lines.append((key, value))
            }
        }
        func append(_ key: String, _ value: String) {
            lines.append((key, value))
        }
        // libghostty 默认 TERM=xterm-ghostty，其 terminfo 只有装了 Ghostty.app 的机器才有；
        // 缺失时 ls/TUI 都探测不到颜色能力，输出全灰。改用系统自带的 xterm-256color。
        // （用户仍可在 ghosttyOverrides 里改回 xterm-ghostty。）
        set("term", managedTerminalType)
        set("background", theme.background)
        // 终端透明仅限光晕主题（透出后方光晕暗底，黑不至于太死）；纯色主题保持实底，
        // 否则透出的是半透磨砂 + 模糊桌面，终端文字对比度会掉。用户仍可在 ghosttyOverrides 覆盖。
        set("background-opacity", Theme.resolve(a).terminalTranslucent ? "0.8" : "1")
        set("foreground", theme.foreground)
        set("cursor-color", theme.cursor)
        set("selection-background", theme.selection)
        set("selection-foreground", theme.selectionForeground)
        // 不开 macos-background-from-layer：codex 这类「只用 default 前景/背景色」渲染的 TUI，
        // 输入框背景就是终端 default bg。若 default bg 取自 NSView layer，切主题只改了 layer 颜色、
        // ghostty 不会重绘已画好的 default-bg 单元格 → codex 输入框卡在旧色不跟随（暗色主题下显白看不清）。
        // 让 default bg 直接由 config `background` 渲染：切主题 → update_config 改 background → 重绘即跟随。
        for (index, color) in theme.ansi.enumerated() {
            append("palette", "\(index)=#\(color)")
        }
        set("font-size", "\(a.font.size)")
        // 渲染质量（macOS）：ghostty 默认笔画偏细、且在 sRGB/P3 里混合会在彩色文字边缘
        // 产生暗边毛刺（似锯齿）。加粗贴近 Terminal.app 的系统级平滑；linear-corrected
        // 在线性空间混合并做文字校正，观感同 native 但没有暗边。两者都可被下方 overrides 覆盖。
        set("font-thicken", "true")
        set("alpha-blending", "linear-corrected")
        set("adjust-cell-height", "12%")
        set("window-padding-x", "\(a.padding.x)")
        set("window-padding-y", "\(a.padding.y)")
        set("window-padding-balance", "true")
        set("cursor-style", a.cursorStyle)
        // ghostty 的 scrollback-limit 单位是字节（按需分配，设大无固定开销）。
        // 行数 → 字节按 512B/行 保守折算（约 160 列 × UTF-8 中文 3B），确保至少能存下配置的行数。
        set("scrollback-limit", "\(config.terminal.scrollback * 512)")
        let family = a.font.family.trimmingCharacters(in: .whitespaces)
        if !family.isEmpty { set("font-family", family) }
        for (key, rawValue) in config.ghosttyOverrides.sorted(by: { $0.key < $1.key }) {
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard ConductorGhosttyConfigCatalog.knownKeySet.contains(key), !value.isEmpty else { continue }
            set(key, value)
        }
        return lines.map { "\($0.key) = \($0.value)" }
        .joined(separator: "\n")
    }

    private func scheduleTick() {
        guard !tickScheduled else { return }
        tickScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.tickScheduled = false
            if let app = self.app { ghostty_app_tick(app) }
        }
    }

    // C 回调是 nonisolated；取出原始值后跳回主线程分派。
    private nonisolated static func routeAction(
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        guard target.tag == GHOSTTY_TARGET_SURFACE else {
            switch action.tag {
            case GHOSTTY_ACTION_COLOR_CHANGE:
                let change = action.action.color_change
                Task { @MainActor in
                    GhosttyRuntime.shared.handleAppColorChange(change)
                }
                return true
            case GHOSTTY_ACTION_CONFIG_CHANGE:
                Task { @MainActor in
                    GhosttyRuntime.shared.applyColorScheme(for: ConfigStore.shared.config)
                }
                return true
            case GHOSTTY_ACTION_RELOAD_CONFIG:
                Task { @MainActor in
                    GhosttyRuntime.shared.applyConfig(ConfigStore.shared.config)
                }
                return true
            default:
                return false
            }
        }
        let surfaceHandle = target.target.surface

        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            guard let titlePointer = action.action.set_title.title else { return false }
            let title = String(cString: titlePointer)
            Task { @MainActor in
                GhosttySurface.fromGhosttySurface(surfaceHandle)?.handleSetTitle(title)
            }
            return true
        case GHOSTTY_ACTION_SCROLLBAR:
            let sb = action.action.scrollbar
            Task { @MainActor in
                GhosttySurface.fromGhosttySurface(surfaceHandle)?
                    .handleScrollbar(total: sb.total, offset: sb.offset, len: sb.len)
            }
            return true
        case GHOSTTY_ACTION_PWD:
            guard let pwdPointer = action.action.pwd.pwd else { return true }
            let pwd = String(cString: pwdPointer)
            Task { @MainActor in
                GhosttySurface.fromGhosttySurface(surfaceHandle)?.handlePwd(pwd)
            }
            return true
        case GHOSTTY_ACTION_START_SEARCH:
            let needle = action.action.start_search.needle.map { String(cString: $0) } ?? ""
            Task { @MainActor in GhosttySurface.fromGhosttySurface(surfaceHandle)?.handleSearchStart(needle) }
            return true
        case GHOSTTY_ACTION_END_SEARCH:
            Task { @MainActor in GhosttySurface.fromGhosttySurface(surfaceHandle)?.handleSearchEnd() }
            return true
        case GHOSTTY_ACTION_SEARCH_TOTAL:
            let total = Int(action.action.search_total.total)
            Task { @MainActor in GhosttySurface.fromGhosttySurface(surfaceHandle)?.handleSearchTotal(total) }
            return true
        case GHOSTTY_ACTION_SEARCH_SELECTED:
            let sel = Int(action.action.search_selected.selected)
            Task { @MainActor in GhosttySurface.fromGhosttySurface(surfaceHandle)?.handleSearchSelected(sel) }
            return true
        case GHOSTTY_ACTION_OPEN_URL:
            guard let urlPointer = action.action.open_url.url else { return false }
            let urlString = String(cString: urlPointer)
            Task { @MainActor in
                if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
            }
            return true
        case GHOSTTY_ACTION_MOUSE_OVER_LINK:
            // url 非 nul 结尾，按 len 取；len == 0 表示移出链接
            let link = action.action.mouse_over_link
            let url: String?
            if let base = link.url, link.len > 0 {
                url = String(bytes: UnsafeRawBufferPointer(start: base, count: Int(link.len)),
                             encoding: .utf8)
            } else {
                url = nil
            }
            Task { @MainActor in
                GhosttySurface.fromGhosttySurface(surfaceHandle)?.handleMouseOverLink(url)
            }
            return true
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            let shape = action.action.mouse_shape
            Task { @MainActor in
                GhosttySurface.fromGhosttySurface(surfaceHandle)?.handleMouseShape(shape)
            }
            return true
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            Task { @MainActor in
                GhosttySurface.fromGhosttySurface(surfaceHandle)?.handleChildExited()
            }
            return true
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            // OSC 9 / 99 / 777：任何 CLI printf 一条转义序列即可触达通知中枢，无需安装 hook。
            let notification = action.action.desktop_notification
            let title = notification.title.map { String(cString: $0) } ?? ""
            let body = notification.body.map { String(cString: $0) } ?? ""
            guard !(title.isEmpty && body.isEmpty) else { return true }
            Task { @MainActor in
                GhosttySurface.fromGhosttySurface(surfaceHandle)?
                    .handleDesktopNotification(title: title, body: body)
            }
            return true
        case GHOSTTY_ACTION_PROGRESS_REPORT:
            // ConEmu OSC 9;4 进度（npm/cargo/自定义脚本都在用）：pane 头条亮进度徽标。
            let report = action.action.progress_report
            let percent = report.progress >= 0 ? Int(report.progress) : nil
            let state = PaneProgressState(report.state)
            Task { @MainActor in
                GhosttySurface.fromGhosttySurface(surfaceHandle)?
                    .handleProgressReport(state: state, percent: percent)
            }
            return true
        case GHOSTTY_ACTION_COLOR_CHANGE:
            let change = action.action.color_change
            Task { @MainActor in
                GhosttySurface.fromGhosttySurface(surfaceHandle)?.handleColorChange(change)
            }
            return true
        case GHOSTTY_ACTION_CONFIG_CHANGE:
            Task { @MainActor in
                GhosttySurface.fromGhosttySurface(surfaceHandle)?.handleConfigChange()
            }
            return true
        case GHOSTTY_ACTION_RELOAD_CONFIG:
            Task { @MainActor in
                GhosttySurface.fromGhosttySurface(surfaceHandle)?.reloadConfig()
            }
            return true
        default:
            return false
        }
    }

    @MainActor
    private func handleAppColorChange(_ change: ghostty_action_color_change_s) {
        if change.kind == GHOSTTY_ACTION_COLOR_KIND_BACKGROUND {
            let color = Self.color(from: change)
            ghostty_app_set_color_scheme(app, Self.colorScheme(forBackground: color))
        }
    }

    @MainActor
    static func terminalBackgroundColor(for appConfig: AppConfig) -> NSColor {
        color(hex: ThemePalette.resolve(appConfig.appearance).background)
    }

    nonisolated static func color(from change: ghostty_action_color_change_s) -> NSColor {
        NSColor(
            red: CGFloat(change.r) / 255,
            green: CGFloat(change.g) / 255,
            blue: CGFloat(change.b) / 255,
            alpha: 1)
    }

    private static func color(hex: String) -> NSColor {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard value.count >= 6,
              let r = UInt8(value.prefix(2), radix: 16),
              let g = UInt8(value.dropFirst(2).prefix(2), radix: 16),
              let b = UInt8(value.dropFirst(4).prefix(2), radix: 16)
        else { return .windowBackgroundColor }
        return NSColor(
            red: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: 1)
    }

    static func colorScheme(forBackground color: NSColor) -> ghostty_color_scheme_e {
        let converted = color.usingColorSpace(.sRGB) ?? color
        let luma = 0.299 * Double(converted.redComponent * 255)
            + 0.587 * Double(converted.greenComponent * 255)
            + 0.114 * Double(converted.blueComponent * 255)
        return luma < 128 ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
    }
}

/// OSC 9;4 进度状态（engine 无关的 Swift 侧表示）。
enum PaneProgressState: Equatable {
    case remove          // 清除进度
    case set             // 正常进度（0–100）
    case error           // 出错（红）
    case indeterminate   // 忙碌但无百分比
    case pause           // 暂停（黄）

    init(_ raw: ghostty_action_progress_report_state_e) {
        switch raw {
        case GHOSTTY_PROGRESS_STATE_SET: self = .set
        case GHOSTTY_PROGRESS_STATE_ERROR: self = .error
        case GHOSTTY_PROGRESS_STATE_INDETERMINATE: self = .indeterminate
        case GHOSTTY_PROGRESS_STATE_PAUSE: self = .pause
        default: self = .remove
        }
    }
}

/// 一个 pane 的当前进度（OSC 9;4），头条徽标用。
struct PaneProgressInfo: Equatable {
    var state: PaneProgressState
    var percent: Int?
}
