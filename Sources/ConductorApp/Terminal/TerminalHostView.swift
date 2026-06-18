import AppKit
import QuartzCore
@preconcurrency import GhosttyKit

private extension CGSize {
    var isFinitePositiveArea: Bool {
        width.isFinite && height.isFinite && width > 1 && height > 1
    }
}

/// 承载一个 libghostty surface 的 NSView：CAMetalLayer 背衬。
/// 自身不直接调 libghostty——把生命周期/几何/输入都委托给 `owner`（GhosttySurface）。
@MainActor
final class TerminalHostView: NSView {
    weak var owner: GhosttySurface?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        clipsToBounds = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        configureLayer(layer)
        // 右键菜单由 PaneContainerView 统一构建（复制/粘贴/分屏/路径/清屏…），这里不再各自维护。
        // 接收文件/文件夹拖放（侧栏树或 Finder 拖进来）→ 粘贴转义后的路径
        registerForDraggedTypes([.fileURL, .string])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    override var acceptsFirstResponder: Bool { true }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.framebufferOnly = false
        layer.isOpaque = true
        layer.backgroundColor = GhosttyRuntime.terminalBackgroundColor(for: ConfigStore.shared.config).cgColor
        layer.masksToBounds = true
        layer.cornerRadius = Radius.md       // 与卡片圆角一致
        layer.cornerCurve = .continuous
        configureLayer(layer)
        return layer
    }

    func refreshThemeBackground() {
        refreshThemeBackground(GhosttyRuntime.terminalBackgroundColor(for: ConfigStore.shared.config))
    }

    func refreshThemeBackground(_ color: NSColor) {
        layer?.backgroundColor = color.cgColor
    }

    /// 禁用图层隐式动画：resize 时 Metal 层立即呈现，不被动画过渡。
    private func configureLayer(_ layer: CALayer?) {
        layer?.actions = [
            "bounds": NSNull(), "position": NSNull(), "frame": NSNull(),
            "contentsScale": NSNull(), "backgroundColor": NSNull(),
        ]
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            // 离屏（切到别的标签/工作区）：渲染线程休眠省 GPU/CPU；PTY 照常跑，回屏即新。
            owner?.setOcclusion(false)
            return
        }
        owner?.setOcclusion(true)
        owner?.attachIfPossible()
        owner?.syncGeometry(force: true)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        owner?.attachIfPossible()
        owner?.syncGeometry()
    }

    // MARK: - Live resize（窗口缩放 / 分隔条拖动期间的呈现同步）

    /// 窗口 live resize 期间让 Metal 呈现与 CA 事务同步提交：终端内容和周围
    /// chrome 同帧更新，消除缩放时内容滞后一帧的"果冻"错位。
    /// 常态保持 false——异步呈现吞吐更好，正常输出滚动不受影响。
    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        setSynchronousPresentation(true)
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        setSynchronousPresentation(false)
        owner?.syncGeometry(force: true)
    }

    /// 分隔条拖动（RatioSplitView 的 tracking loop）也复用此开关。
    func setSynchronousPresentation(_ on: Bool) {
        (layer as? CAMetalLayer)?.presentsWithTransaction = on
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        owner?.syncGeometry(force: true)
    }

    // MARK: - First responder

    override func becomeFirstResponder() -> Bool {
        // 必须走 super：输入法的 NSTextInputContext 随 responder 切换激活/停用
        let ok = super.becomeFirstResponder()
        owner?.setFocused(true)
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        // 失焦时丢弃未完成的组合，避免残留预编辑串
        if hasMarkedText() {
            inputContext?.discardMarkedText()
            markedText = NSMutableAttributedString()
            owner?.setPreedit(nil)
        }
        owner?.setFocused(false)
        return ok
    }

    // MARK: - Keyboard（含输入法）

    /// 组合中的预编辑串（拼音等）。
    private var markedText = NSMutableAttributedString()
    /// 本轮 keyDown 经 IME `insertText` 提交的文本；nil 表示当前不在 keyDown 流程里。
    private var keyDownCommittedText: [String]?

    /// 按键必须先交给 `inputContext.handleEvent`（输入法的官方介入点；
    /// `interpretKeyEvents` 只走按键绑定管线，IME 介入不可靠）。流程结束后按三种结果分发：
    /// 1. IME 提交了文本：合成结果（中文等）走 text_input 通道；与按键等同的单字符
    ///    （英文直敲）仍走原始按键通道，保留终端 keybinding / 转义序列语义；
    /// 2. 组合中（候选窗开着）：按键已被输入法消费，吞掉；
    /// 3. 其余（方向键/Ctrl 组合等）：照旧转发原始事件。
    override func keyDown(with event: NSEvent) {
        guard let owner else { return }
        // 出字修饰键翻译（Option-as-Alt / 死键 / 异国布局）：翻译后的事件喂给输入法，
        // 并随原始事件一起带给 forwardKey 校正 consumed_mods / text。无差异时即原事件，
        // 复用原事件对韩文等输入法的对象等价判定是必需的。
        let translationEvent = owner.translationEvent(for: event) ?? event
        let hadMarked = hasMarkedText()
        keyDownCommittedText = []
        _ = inputContext?.handleEvent(translationEvent)
        let committed = keyDownCommittedText ?? []
        keyDownCommittedText = nil

        let composing = hasMarkedText()
        owner.setPreedit(composing ? markedText.string : nil)
        let action: ghostty_input_action_e = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        if !committed.isEmpty {
            let text = committed.joined()
            if !hadMarked, !composing, text == event.characters {
                owner.forwardKey(event, action: action, translationEvent: translationEvent)
            } else {
                owner.sendTextInput(text)
            }
        } else if !composing, !hadMarked {
            owner.forwardKey(event, action: action, translationEvent: translationEvent)
        }
    }

    override func keyUp(with event: NSEvent) {
        guard !hasMarkedText() else { return }   // 组合中的按键没发 press，release 也不发
        owner?.forwardKey(event, action: GHOSTTY_ACTION_RELEASE)
    }

    // MARK: - Drag & Drop（文件/文件夹路径粘贴进终端）

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedText(from: sender) != nil ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let text = droppedText(from: sender) else { return false }
        window?.makeFirstResponder(self)
        owner?.requestFocus()
        owner?.sendTextInput(text)
        return true
    }

    /// 文件 URL → shell 转义路径（多个空格相连）；纯文本原样。
    private func droppedText(from sender: NSDraggingInfo) -> String? {
        let pasteboard = sender.draggingPasteboard
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls.map { ShellQuoting.quote($0.path) }.joined(separator: " ")
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            return text
        }
        return nil
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        owner?.requestFocus()
        owner?.setFocused(true)
        owner?.sendMouseButton(GHOSTTY_MOUSE_LEFT, state: GHOSTTY_MOUSE_PRESS, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        owner?.sendMouseButton(GHOSTTY_MOUSE_LEFT, state: GHOSTTY_MOUSE_RELEASE, event: event)
    }

    override func mouseDragged(with event: NSEvent) {
        owner?.updateMouse(event)
    }

    override func scrollWheel(with event: NSEvent) {
        owner?.scroll(event)
    }
}

// MARK: - NSTextInputClient（输入法支持）

// @preconcurrency：协议要求 nonisolated，但 AppKit 实际只在主线程调用这些方法。
extension TerminalHostView: @preconcurrency NSTextInputClient {
    func hasMarkedText() -> Bool { markedText.length > 0 }

    func markedRange() -> NSRange {
        markedText.length > 0
            ? NSRange(location: 0, length: markedText.length)
            : NSRange(location: NSNotFound, length: 0)
    }

    func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let attributed as NSAttributedString:
            markedText = NSMutableAttributedString(attributedString: attributed)
        case let plain as String:
            markedText = NSMutableAttributedString(string: plain)
        default:
            markedText = NSMutableAttributedString()
        }
        // 非按键路径（如候选窗鼠标操作）也要同步预编辑显示
        if keyDownCommittedText == nil { owner?.setPreedit(markedText.string) }
    }

    func unmarkText() {
        markedText = NSMutableAttributedString()
        if keyDownCommittedText == nil { owner?.setPreedit(nil) }
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange,
                             actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        switch string {
        case let attributed as NSAttributedString: text = attributed.string
        case let plain as String: text = plain
        default: return
        }
        markedText = NSMutableAttributedString()
        if keyDownCommittedText != nil {
            keyDownCommittedText?.append(text)   // keyDown 流程统一分发
        } else {
            owner?.setPreedit(nil)               // 鼠标点候选字等直接提交
            owner?.sendTextInput(text)
        }
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    /// 候选词窗口的锚点：光标格子的屏幕坐标（ghostty 给的是 surface 内左上原点坐标）。
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        let cell = owner?.imeCursorRect() ?? CGRect(x: 0, y: 0, width: 10, height: 17)
        let viewRect = NSRect(
            x: cell.origin.x,
            y: bounds.height - cell.origin.y - cell.height,
            width: cell.width,
            height: cell.height)
        return window.convertToScreen(convert(viewRect, to: nil))
    }

    /// 文本编辑命令（方向键/回车/删除等选择器）不在这里处理：
    /// keyDown 兜底把原始按键转发给终端，由终端语义接管（不调 super，避免系统提示音）。
    override func doCommand(by selector: Selector) {}
}
