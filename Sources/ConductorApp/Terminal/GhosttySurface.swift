import AppKit
import ConductorCore
import Foundation
@preconcurrency import GhosttyKit

private extension CGSize {
    var isFinitePositiveArea: Bool {
        width.isFinite && height.isFinite && width > 1 && height > 1
    }
}

/// 一个真 libghostty 终端。持有 `ghostty_surface_t` 和承载它的 `TerminalHostView`，
/// 实现 ConductorCore 的引擎无关 `TerminalSurface` 生命周期协议。几何/输入逻辑也在此（host view 只转发事件）。
@MainActor
final class GhosttySurface: TerminalSurface {
    let hostView: TerminalHostView

    private var surface: ghostty_surface_t?
    private var retainedUserdata: Unmanaged<GhosttySurface>?
    private var pendingCwd: String?
    /// 待执行命令（如一键启动 codex/claude）：surface 创建后稍候发出，等 shell 起好。
    private var pendingCommand: String?
    /// 待预输入文本（不带回车，如 resume 命令）：打到提示符上，用户按 Enter 才执行。
    private var pendingTypedText: String?
    /// 待回放的内容快照路径：attach 时换用 wrapper 脚本启动（cat 快照 → exec shell）。
    var restoreContentFile: String?
    /// 启动 shell 时注入的环境变量（pane 身份 / 自动化 socket 路径等），attach 前设置。
    var extraEnvironment: [(key: String, value: String)] = []
    private var lastScale: CGFloat = 0
    private var lastSize: CGSize = .zero
    private var lastCellSize: CGSize?
    private var appliedColorScheme: ghostty_color_scheme_e?
    private var paletteRefreshGeneration = 0

    // ConductorCore.TerminalSurface 回调（由 SessionRegistry 注入；运行时 action 路由触发）
    var onTitleChange: ((String) -> Void)?
    var onCwdChange: ((URL) -> Void)?
    var onExit: ((Int32) -> Void)?
    /// 终端被点击时请求把"当前活动 pane"切到自己（更新模型 + 焦点环）。
    var onRequestFocus: (() -> Void)?
    /// ⌘+拖 发起整块 pane 拖拽（由 PaneContainerView 接住起拖）。
    var onBeginPaneDrag: ((NSEvent) -> Void)?
    /// 滚动条状态（total 总行 / offset 视口顶偏移 / len 视口可见行），由 ghostty SCROLLBAR action 推送。
    var onScrollbar: ((_ total: UInt64, _ offset: UInt64, _ len: UInt64) -> Void)?
    /// 搜索（由 ghostty 搜索 actions 推送）：开始(初始 needle)/匹配总数/当前项/结束。
    var onSearchStart: ((String) -> Void)?
    var onSearchTotal: ((Int) -> Void)?
    var onSearchSelected: ((Int) -> Void)?
    var onSearchEnd: (() -> Void)?
    /// 鼠标悬停在链接上（nil = 移开）。⌘点击打开由 OPEN_URL 动作兜底处理。
    var onLinkHover: ((String?) -> Void)?
    /// OSC 9/99/777 桌面通知（终端程序主动上报，无需 hook）。
    var onDesktopNotification: ((_ title: String, _ body: String) -> Void)?
    /// OSC 9;4 进度上报（percent 为 nil 表示未给百分比）。
    var onProgressReport: ((_ state: PaneProgressState, _ percent: Int?) -> Void)?

    func requestFocus() { onRequestFocus?() }
    func beginPaneDrag(_ event: NSEvent) { onBeginPaneDrag?(event) }

    init() {
        hostView = TerminalHostView()
        hostView.owner = self
        TerminalResizeFreeze.shared.register(self)
    }

    static func fromGhosttySurface(_ handle: ghostty_surface_t?) -> GhosttySurface? {
        guard let handle, let userdata = ghostty_surface_userdata(handle) else { return nil }
        return Unmanaged<GhosttySurface>.fromOpaque(userdata).takeUnretainedValue()
    }

    // MARK: - TerminalSurface

    func start(cwd: URL) {
        pendingCwd = cwd.path
        attachIfPossible()
    }

    /// 排入一条待执行命令：若 surface 已就绪则稍候发出，否则等 attach 后再发。
    func enqueueCommand(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingCommand = trimmed
        flushPendingCommandIfReady()
    }

    /// 排入一段预输入文本：只打字不回车（恢复 pane 时把 resume 命令摆在提示符上，按 Enter 续聊）。
    func enqueueTypedText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingTypedText = trimmed
        flushPendingCommandIfReady()
    }

    /// surface 存在时把待执行命令（粘贴 + 真回车键）和预输入文本（不回车）发出。
    /// 延迟一下让 shell 起好、画好首个提示符（内容回放的 cat 也在这窗口内完成）。
    /// 回车必须走按键通道：粘贴通道里的 "\r" 在 bracketed paste 下只是文本，
    /// zsh 会把命令留在缓冲区不执行（「resume 不自动发送」的根因）。
    private func flushPendingCommandIfReady() {
        guard surface != nil, pendingCommand != nil || pendingTypedText != nil else { return }
        let command = pendingCommand
        let typed = pendingTypedText
        pendingCommand = nil
        pendingTypedText = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
            if let command {
                self?.sendText(command)
                // 粘贴和按键是两条通道，稍等粘贴消化完再回车，避免乱序
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                    self?.sendEnterKey()
                }
            }
            if let typed { self?.sendText(typed) }
        }
    }

    /// 发送一次真实的回车按键（press + release）。
    /// TUI（claude/codex）在 raw 模式下只认按键事件；shell 的 bracketed paste 同理。
    func sendEnterKey() {
        sendBareKey(keycode: 36, codepoint: 13, text: "\r")   // kVK_Return
    }

    /// 发送一次真实的 Esc 按键（快捷回复里的「拒绝/取消」）。
    func sendEscapeKey() {
        sendBareKey(keycode: 53, codepoint: 27, text: "\u{1B}")   // kVK_Escape
    }

    private func sendBareKey(keycode: UInt32, codepoint: UInt32, text: String) {
        guard let surface else { return }
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.mods = GHOSTTY_MODS_NONE
        keyEvent.keycode = keycode
        keyEvent.composing = false
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.unshifted_codepoint = codepoint
        text.withCString {
            keyEvent.text = $0
            _ = ghostty_surface_key(surface, keyEvent)
        }
        keyEvent.action = GHOSTTY_ACTION_RELEASE
        keyEvent.text = nil
        keyEvent.unshifted_codepoint = 0
        _ = ghostty_surface_key(surface, keyEvent)
    }

    func focus() {
        if let surface { ghostty_surface_set_focus(surface, true) }
        hostView.window?.makeFirstResponder(hostView)
    }

    func close() {
        guard let surface else { return }
        self.surface = nil           // 立刻断开：后续 syncGeometry/输入都会 no-op
        hostView.owner = nil
        hostView.removeFromSuperview()
        let userdata = retainedUserdata
        retainedUserdata = nil
        // 延迟释放：先让当前渲染周期跑完，避免与 libghostty 渲染线程相撞（UAF）。
        DispatchQueue.main.async {
            ghostty_surface_free(surface)
            userdata?.release()
        }
    }

    // MARK: - Attach / geometry (host view 调用)

    /// host view 上墙后调用：若尚未创建则创建 libghostty surface。
    func attachIfPossible() {
        guard surface == nil, hostView.window != nil, let cwd = pendingCwd else { return }
        guard hostView.bounds.size.isFinitePositiveArea else { return }
        GhosttyRuntime.shared.ensureStarted()
        guard let app = GhosttyRuntime.shared.app else { return }

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(hostView).toOpaque())
        )
        let userdata = Unmanaged.passRetained(self)
        config.userdata = userdata.toOpaque()
        config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
        config.font_size = 14
        config.wait_after_command = false
        config.scale_factor = Double(hostView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)

        // shell：配置优先，否则用户登录 shell（$SHELL），再否则 /bin/zsh。
        let shell = ConfigStore.shared.config.terminal.shell
            ?? ProcessInfo.processInfo.environment["SHELL"]
            ?? "/bin/zsh"

        // 内容恢复：有待回放快照时换 wrapper 启动（cat 快照 → rm → exec 真 shell），
        // 路径与 shell 走 env 传参，避开引号/转义问题。
        var command = shell
        var envPairs = startupEnvironmentPairs(shell: shell)
        if let restoreFile = restoreContentFile,
           FileManager.default.fileExists(atPath: restoreFile),
           let wrapper = ScrollbackStore.ensureWrapperScript() {
            command = wrapper
            envPairs += [("CONDUCTOR_RESTORE_FILE", restoreFile), ("CONDUCTOR_RESTORE_SHELL", shell)]
        }
        restoreContentFile = nil

        // env_vars 要求 C 字符串在 surface_new 调用期间存活：strdup 后统一释放。
        let cStrings = envPairs.map { (strdup($0.key), strdup($0.value)) }
        defer { cStrings.forEach { free($0.0); free($0.1) } }
        var envVars = cStrings.map { ghostty_env_var_s(key: $0.0, value: $0.1) }
        func createSurface(commandPointer: UnsafePointer<CChar>?) {
            cwd.withCString { directoryPointer in
                envVars.withUnsafeMutableBufferPointer { envBuffer in
                    config.command = commandPointer
                    config.working_directory = directoryPointer
                    if !envBuffer.isEmpty {
                        config.env_vars = envBuffer.baseAddress
                        config.env_var_count = envBuffer.count
                    }
                    surface = ghostty_surface_new(app, &config)
                }
            }
        }
        command.withCString { createSurface(commandPointer: $0) }

        guard let surface else {
            userdata.release()
            NSLog("[conductor] ghostty_surface_new failed")
            return
        }
        retainedUserdata = userdata
        reassertDisplayID()
        syncGeometry(force: true)
        hostView.refreshThemeBackground()
        applyRuntimeColorScheme(force: true)
        if let runtimeConfig = GhosttyRuntime.shared.config {
            ghostty_surface_update_config(surface, runtimeConfig)
        }
        ghostty_surface_set_occlusion(surface, true)   // 可见（bool 实为 visible）
        ghostty_surface_set_focus(surface, false)
        ghostty_surface_refresh(surface)
        flushPendingCommandIfReady()
    }

    private func applyRuntimeColorScheme(force: Bool = false) {
        applyRuntimeColorScheme(for: ConfigStore.shared.config, force: force)
    }

    private func applyRuntimeColorScheme(for config: AppConfig, force: Bool = false) {
        guard let surface else { return }
        let scheme = GhosttyRuntime.colorScheme(for: config)
        guard force || appliedColorScheme != scheme else { return }
        ghostty_surface_set_color_scheme(surface, scheme)
        appliedColorScheme = scheme
    }

    func syncGeometry(force: Bool = false) {
        guard let surface, let window = hostView.window else { return }
        guard hostView.bounds.size.isFinitePositiveArea else { return }
        // 面板开合动画期间不做真实 resize（每帧网格重排 + drawable 重分配是动画卡顿主因）；
        // 解冻时 resizeFreezeDidEnd 会 force 补一次最终尺寸。
        if TerminalResizeFreeze.shared.isFrozen, !force { return }
        let scale = window.backingScaleFactor
        if force || scale != lastScale {
            ghostty_surface_set_content_scale(surface, Double(scale), Double(scale))
            lastScale = scale
        }
        let backing = hostView.convertToBacking(NSRect(origin: .zero, size: hostView.bounds.size)).size
        guard backing.isFinitePositiveArea else { return }
        let width = max(1, UInt32(backing.width.rounded(.toNearestOrAwayFromZero)))
        let height = max(1, UInt32(backing.height.rounded(.toNearestOrAwayFromZero)))
        let pixel = CGSize(width: CGFloat(width), height: CGFloat(height))
        if force || pixel != lastSize {
            ghostty_surface_set_size(surface, width, height)
            lastSize = pixel
        }
        ghostty_surface_refresh(surface)
    }

    /// 配置热更新：把最新 ghostty 配置应用到本 surface（字体/配色/padding 即时生效，不重建、不丢 scrollback）。
    func reloadConfig() {
        reloadConfig(for: ConfigStore.shared.config)
    }

    func refreshThemeBackground(for appConfig: AppConfig) {
        hostView.refreshThemeBackground(GhosttyRuntime.terminalBackgroundColor(for: appConfig))
    }

    /// 配置热更新：把指定配置应用到本 surface，确保调用方和 runtime 使用同一份快照。
    func reloadConfig(for appConfig: AppConfig) {
        guard let surface, let config = GhosttyRuntime.shared.config else { return }
        // macos-background-from-layer makes Ghostty sample this layer as the
        // terminal backdrop, so it must be current before update_config runs.
        refreshThemeBackground(for: appConfig)
        applyRuntimeColorScheme(for: appConfig, force: true)
        ghostty_surface_update_config(surface, config)
        forceRedraw()
    }

    func handleConfigChange() {
        applyRuntimeColorScheme(force: true)
        hostView.refreshThemeBackground()
        forceRedraw()
    }

    func handleColorChange(_ change: ghostty_action_color_change_s) {
        guard change.kind == GHOSTTY_ACTION_COLOR_KIND_BACKGROUND else { return }
        let color = GhosttyRuntime.color(from: change)
        hostView.refreshThemeBackground(color)
        if let surface {
            let scheme = GhosttyRuntime.colorScheme(forBackground: color)
            ghostty_surface_set_color_scheme(surface, scheme)
            appliedColorScheme = scheme
            ghostty_surface_refresh(surface)
            ghostty_surface_render_now(surface)
        }
    }

    func handleCellSize(width: UInt32, height: UInt32) {
        guard width > 0, height > 0 else { return }
        lastCellSize = CGSize(width: CGFloat(width), height: CGFloat(height))
    }

    private func startupEnvironmentPairs(shell: String) -> [(key: String, value: String)] {
        var env: [String: String] = [
            "TERM": GhosttyRuntime.managedTerminalType,
            "COLORTERM": GhosttyRuntime.managedColorTerm,
            "TERM_PROGRAM": GhosttyRuntime.managedTerminalProgram,
        ]
        let processEnv = ProcessInfo.processInfo.environment
        let loginPATH = LoginShellPathCache.shared.currentOrCapture(shell: shell)
        let effectivePATH = PathBuilder.effectivePATH(
            purposes: [.tty, .nodeTooling],
            env: processEnv,
            loginPATH: loginPATH)
        if !effectivePATH.isEmpty {
            env["PATH"] = effectivePATH
        }
        for (key, value) in extraEnvironment where !key.isEmpty {
            env[key] = value
        }
        return env.map { (key: $0.key, value: $0.value) }
    }

    /// 重挂视图层级后强制重画（避免变白）。
    func forceRedraw() {
        guard let surface else { return }
        reassertDisplayID()
        ghostty_surface_set_occlusion(surface, true)   // true = 可见
        syncGeometry(force: true)
        ghostty_surface_refresh(surface)
        ghostty_surface_render_now(surface)
    }

    /// 可见性同步：false 让 core 的渲染线程休眠（光标/动画停画），省 GPU/CPU。
    /// 离屏（切走的标签/工作区）与窗口被遮挡/最小化时调用；PTY 输出照常处理，回屏即新。
    func setOcclusion(_ visible: Bool) {
        guard let surface else { return }
        ghostty_surface_set_occlusion(surface, visible)
    }

    // MARK: - Input (host view 调用)

    func setFocused(_ focused: Bool) {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, focused)
        if focused { reassertDisplayID() }
    }

    /// Some TUIs re-query OSC 10/11 default colors on terminal focus gained.
    /// After a live theme change, pulse that path so cached palette-dependent
    /// UI refreshes without restart or a manual pane switch.
    func pulseForPaletteRefresh(includeResizeFallback: Bool = false) {
        guard let surface else { return }
        paletteRefreshGeneration &+= 1
        let generation = paletteRefreshGeneration
        let wasFirstResponder = hostView.window?.firstResponder === hostView
        ghostty_surface_set_focus(surface, false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, let surface = self.surface else { return }
            guard self.paletteRefreshGeneration == generation else { return }
            self.reassertDisplayID()
            ghostty_surface_set_focus(surface, true)
            ghostty_surface_refresh(surface)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                guard let self, let surface = self.surface else { return }
                guard self.paletteRefreshGeneration == generation else { return }
                if includeResizeFallback {
                    self.pulseResizeForPaletteRefresh(
                        generation: generation,
                        wasFirstResponder: wasFirstResponder
                    )
                } else {
                    ghostty_surface_refresh(surface)
                    ghostty_surface_render_now(surface)
                    self.restoreFocusAfterPalettePulse(surface, wasFirstResponder: wasFirstResponder)
                }
            }
        }
    }

    private func pulseResizeForPaletteRefresh(generation: Int, wasFirstResponder: Bool) {
        guard let surface else { return }
        guard paletteRefreshGeneration == generation else { return }
        let original = lastSize
        guard original.width > 1, original.height > 48 else {
            restoreFocusAfterPalettePulse(surface, wasFirstResponder: wasFirstResponder)
            return
        }
        let rowHeight = max(lastCellSize?.height ?? 28, 18)
        let shrink = min(max(rowHeight * 3, 96), max(1, original.height - rowHeight))
        let temporaryHeight = max(CGFloat(1), original.height - shrink)
        ghostty_surface_set_occlusion(surface, false)
        ghostty_surface_set_size(
            surface,
            UInt32(original.width.rounded(.toNearestOrAwayFromZero)),
            UInt32(temporaryHeight.rounded(.toNearestOrAwayFromZero)))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, let surface = self.surface else { return }
            guard self.paletteRefreshGeneration == generation else { return }
            ghostty_surface_set_size(
                surface,
                UInt32(original.width.rounded(.toNearestOrAwayFromZero)),
                UInt32(original.height.rounded(.toNearestOrAwayFromZero)))
            self.lastSize = original
            ghostty_surface_set_occlusion(surface, true)
            ghostty_surface_refresh(surface)
            ghostty_surface_render_now(surface)
            self.restoreFocusAfterPalettePulse(surface, wasFirstResponder: wasFirstResponder)
        }
    }

    private func restoreFocusAfterPalettePulse(_ surface: ghostty_surface_t, wasFirstResponder: Bool) {
        let isFirstResponderNow = hostView.window?.firstResponder === hostView
        ghostty_surface_set_focus(surface, wasFirstResponder || isFirstResponderNow)
    }

    private func reassertDisplayID() {
        guard let surface,
              let displayID = (hostView.window?.screen ?? NSScreen.main)?.displayID,
              displayID != 0 else { return }
        ghostty_surface_set_display_id(surface, displayID)
    }

    func sendMouseButton(_ button: ghostty_input_mouse_button_e, state: ghostty_input_mouse_state_e, event: NSEvent) {
        guard let surface else { return }
        updateMouse(event)
        _ = ghostty_surface_mouse_button(surface, state, button, GhosttyInput.ghosttyMods(event.modifierFlags))
    }

    func scroll(_ event: NSEvent) {
        guard let surface else { return }
        let precise = event.hasPreciseScrollingDeltas
        var x = Double(event.scrollingDeltaX)
        var y = Double(event.scrollingDeltaY)
        if precise { x *= 2; y *= 2 }
        let mods = ghostty_input_scroll_mods_t(precise ? 1 : 0)
        ghostty_surface_mouse_scroll(surface, x, y, mods)
    }

    func updateMouse(_ event: NSEvent) {
        guard let surface else { return }
        let point = hostView.convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, Double(point.x), Double(hostView.bounds.height - point.y), GhosttyInput.ghosttyMods(event.modifierFlags))
    }

    /// 把一次按键转发给 libghostty。逻辑对齐 Ghostty 的 keyAction：
    /// - mods / consumed_mods / unshifted_codepoint 由 `ghosttyKeyEvent` 统一构造；
    /// - text 取 translationEvent（出字事件，已处理 Option-as-Alt/死键后的字符）的
    ///   `ghosttyCharacters`，且仅当首字节 >= 0x20 时下发——控制字符让 ghostty 自己编码，
    ///   否则 ctrl+enter / ctrl+h 之类会被双重编码。
    /// translationEvent 为修饰键经 ghostty 翻译后重建的事件（无差异时传 nil / 原事件）。
    func forwardKey(
        _ event: NSEvent,
        action: ghostty_input_action_e,
        translationEvent: NSEvent? = nil,
        composing: Bool = false
    ) {
        guard let surface else { return }
        var keyEvent = event.ghosttyKeyEvent(action, translationMods: translationEvent?.modifierFlags)
        keyEvent.composing = composing

        // release 不带 text；其余取出字事件的可见字符。
        let text = action == GHOSTTY_ACTION_RELEASE
            ? nil
            : (translationEvent ?? event).ghosttyCharacters

        if let text, !text.isEmpty, let first = text.utf8.first, first >= 0x20 {
            text.withCString { pointer in
                keyEvent.text = pointer
                _ = ghostty_surface_key(surface, keyEvent)
            }
        } else {
            _ = ghostty_surface_key(surface, keyEvent)
        }
    }

    /// 按 ghostty 的字符翻译规则（Option-as-Alt、死键、异国布局）算出"出字时实际生效的
    /// 修饰键"。若与原事件不同则重建一个 NSEvent 供输入法/出字使用；相同则返回 nil，
    /// 调用方复用原事件——复用原事件对韩文等输入法的对象等价判定是必需的。
    func translationEvent(for event: NSEvent) -> NSEvent? {
        guard let surface else { return nil }
        let translated = GhosttyInput.eventModifierFlags(
            ghostty_surface_key_translation_mods(
                surface, GhosttyInput.ghosttyMods(event.modifierFlags)))
        // ghostty 只判断四个基本修饰键；逐个对齐，保留事件里其余隐藏位（部分死键依赖）。
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translated.contains(flag) { translationMods.insert(flag) } else { translationMods.remove(flag) }
        }
        guard translationMods != event.modifierFlags else { return nil }
        return NSEvent.keyEvent(
            with: event.type,
            location: event.locationInWindow,
            modifierFlags: translationMods,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: event.characters(byApplyingModifiers: translationMods) ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            isARepeat: event.isARepeat,
            keyCode: event.keyCode)
    }

    /// 由 read_clipboard_cb 回到主线程后调用：把系统剪贴板内容回填给 libghostty（用于 paste）。
    func completeClipboardRequest(state: UnsafeMutableRawPointer) {
        guard let surface else { return }
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        text.withCString {
            ghostty_surface_complete_clipboard_request(surface, $0, state, false)
        }
    }

    // MARK: - Runtime action routing 回调

    func handleSetTitle(_ title: String) { onTitleChange?(title) }
    func handlePwd(_ pwd: String) { onCwdChange?(URL(fileURLWithPath: pwd)) }
    func handleChildExited() { onExit?(0) }
    func handleScrollbar(total: UInt64, offset: UInt64, len: UInt64) { onScrollbar?(total, offset, len) }
    func handleSearchStart(_ needle: String) { onSearchStart?(needle) }
    func handleSearchTotal(_ total: Int) { onSearchTotal?(total) }
    func handleSearchSelected(_ selected: Int) { onSearchSelected?(selected) }
    func handleSearchEnd() { onSearchEnd?() }
    func handleMouseOverLink(_ url: String?) { onLinkHover?(url) }
    func handleDesktopNotification(title: String, body: String) { onDesktopNotification?(title, body) }
    func handleProgressReport(state: PaneProgressState, percent: Int?) { onProgressReport?(state, percent) }

    /// core 请求换鼠标指针（链接上 pointer、正文 text…）。只在鼠标确实悬在本终端时生效。
    func handleMouseShape(_ shape: ghostty_action_mouse_shape_e) {
        guard hostView.window != nil else { return }
        let mouseInside = hostView.window.map {
            hostView.isMousePoint(hostView.convert($0.mouseLocationOutsideOfEventStream, from: nil),
                                  in: hostView.bounds)
        } ?? false
        guard mouseInside else { return }
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_POINTER: NSCursor.pointingHand.set()
        case GHOSTTY_MOUSE_SHAPE_TEXT, GHOSTTY_MOUSE_SHAPE_CELL: NSCursor.iBeam.set()
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: NSCursor.crosshair.set()
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: NSCursor.iBeamCursorForVerticalLayout.set()
        default: NSCursor.arrow.set()
        }
    }

    /// 拖动滚动条时按像素滚动终端（drag thumb → 滚内容）。
    /// 必须带 precise 标志：否则 ghostty 把数值当滚轮「格数」（一格多行），
    /// 像素级数值会被放大成几千行，thumb 直接砸到顶/底。
    func scrollByPixels(_ dy: Double) {
        guard let surface else { return }
        ghostty_surface_mouse_scroll(surface, 0, dy, ghostty_input_scroll_mods_t(1))
    }

    /// 按名触发 ghostty 动作（如 copy_to_clipboard / paste_from_clipboard / select_all / clear_screen）。
    @discardableResult
    func performAction(_ name: String) -> Bool {
        guard let surface else { return false }
        return name.withCString { ghostty_surface_binding_action(surface, $0, UInt(name.utf8.count)) }
    }

    var hasSelection: Bool {
        guard let surface else { return false }
        return ghostty_surface_has_selection(surface)
    }

    /// 向 surface 发送文字（搜索模式下用于输入查询）。
    func sendText(_ text: String) {
        guard let surface else { return }
        text.withCString { ghostty_surface_text(surface, $0, UInt(text.utf8.count)) }
    }

    // MARK: - IME（输入法）

    /// IME 提交的整段文本（走「键入文本」通道，区别于粘贴语义的 sendText）。
    func sendTextInput(_ text: String) {
        guard let surface, !text.isEmpty else { return }
        text.withCString { ghostty_surface_text_input(surface, $0, UInt(text.utf8.count)) }
    }

    /// 设置/清除预编辑串（组合中的拼音内联显示在光标处）；传 nil 清除。
    func setPreedit(_ text: String?) {
        guard let surface else { return }
        if let text, !text.isEmpty {
            text.withCString { ghostty_surface_preedit(surface, $0, UInt(text.utf8.count)) }
        } else {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    /// 光标格子在 surface 内的位置与大小（点单位，原点左上）。IME 候选窗定位用。
    func imeCursorRect() -> CGRect? {
        guard let surface else { return nil }
        var x = 0.0, y = 0.0, width = 0.0, height = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// 读取整个屏幕 + 回滚缓冲的纯文本（内容快照用）。surface 未创建（pane 从未显示）返回 nil。
    func readAllText() -> String? {
        readText(tag: GHOSTTY_POINT_SCREEN)
    }

    /// 读取整个屏幕 + 回滚缓冲的 VT 回放流。用于 session restore，保留 SGR 颜色/粗体等 TUI 样式。
    func readAllVTText() -> String? {
        let scrollback = readVTExport(bindingAction: "write_scrollback_file:copy,vt")
        let screen = readVTExport(bindingAction: "write_screen_file:copy,vt")
        return Self.combinedVTExport(scrollback: scrollback, screen: screen)
    }

    /// 只读当前可见视口的纯文本（Mission Control 卡片预览用，按需调用、开销小）。
    func readViewportText() -> String? {
        readText(tag: GHOSTTY_POINT_VIEWPORT)
    }

    private func readVTExport(bindingAction: String) -> String? {
        guard surface != nil else { return nil }
        let exportedPath = GhosttyClipboardBridge.shared.captureNextStandardClipboardWrite {
            performAction(bindingAction)
        }
        guard let exportedPath = Self.normalizedExportedScreenPath(exportedPath) else {
            return nil
        }

        let fileURL = URL(fileURLWithPath: exportedPath)
        defer {
            if Self.shouldRemoveExportedScreenFile(fileURL) {
                try? FileManager.default.removeItem(at: fileURL)
                if Self.shouldRemoveExportedScreenDirectory(fileURL) {
                    try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
                }
            }
        }

        guard let data = try? Data(contentsOf: fileURL),
              let raw = String(data: data, encoding: .utf8) else {
            return nil
        }
        return Self.normalizedVTExportText(raw)
    }

    private func readText(tag: ghostty_point_tag_e) -> String? {
        guard let surface else { return nil }
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: tag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(
                tag: tag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let pointer = text.text, text.text_len > 0 else { return nil }
        return String(
            bytes: UnsafeRawBufferPointer(start: pointer, count: Int(text.text_len)),
            encoding: .utf8)
    }

    private nonisolated static func normalizedExportedScreenPath(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed),
           url.isFileURL,
           !url.path.isEmpty {
            return url.path
        }
        return trimmed.hasPrefix("/") ? trimmed : nil
    }

    private nonisolated static func normalizedVTExportText(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
    }

    private nonisolated static func combinedVTExport(scrollback: String?, screen: String?) -> String? {
        let scrollback = scrollback?.trimmingCharacters(in: .newlines)
        let screen = screen?.trimmingCharacters(in: .newlines)
        switch (scrollback?.isEmpty == false ? scrollback : nil,
                screen?.isEmpty == false ? screen : nil) {
        case let (history?, current?):
            if history.hasSuffix(current) { return history }
            return history + "\n" + current
        case let (history?, nil):
            return history
        case let (nil, current?):
            return current
        case (nil, nil):
            return nil
        }
    }

    private nonisolated static func shouldRemoveExportedScreenFile(_ fileURL: URL) -> Bool {
        let standardizedFile = fileURL.standardizedFileURL
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL
        return standardizedFile.path.hasPrefix(temporary.path + "/")
    }

    private nonisolated static func shouldRemoveExportedScreenDirectory(_ fileURL: URL) -> Bool {
        let directory = fileURL.deletingLastPathComponent().standardizedFileURL
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL
        return directory.path.hasPrefix(temporary.path + "/")
    }

    /// 当前 pane 前台进程 PID（用于识别在跑哪个 Agent）。无则 nil。
    func foregroundPID() -> Int32? {
        guard let surface else { return nil }
        let pid = ghostty_surface_foreground_pid(surface)
        return pid > 0 ? Int32(truncatingIfNeeded: pid) : nil
    }
}

// MARK: - TerminalResizeFreezeParticipant

extension GhosttySurface: TerminalResizeFreezeParticipant {
    /// 解冻：按动画结束后的最终 frame 补一次真实 resize + 重画（恢复清晰内容）。
    func resizeFreezeDidEnd() {
        syncGeometry(force: true)
    }
}

private extension NSScreen {
    var displayID: UInt32? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let value = deviceDescription[key] as? UInt32 { return value }
        if let value = deviceDescription[key] as? Int { return UInt32(value) }
        if let value = deviceDescription[key] as? NSNumber { return value.uint32Value }
        return nil
    }
}
