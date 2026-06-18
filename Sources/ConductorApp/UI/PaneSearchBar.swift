import AppKit

/// 终端内搜索条（⌘F）：浮在 pane 卡片右上角，驱动 libghostty 的滚回搜索。
/// 回车下一个、⇧回车上一个、Esc 关闭；计数从 SEARCH_TOTAL/SELECTED 动作回填。
@MainActor
final class PaneSearchBar: NSView, NSTextFieldDelegate {
    var onQueryChange: ((String) -> Void)?
    var onNavigate: ((_ forward: Bool) -> Void)?
    var onClose: (() -> Void)?

    private let icon = NSImageView()
    private let field = NSTextField()
    private let countLabel = NSTextField(labelWithString: "")
    private let prevButton = NSButton()
    private let nextButton = NSButton()
    private let closeButton = NSButton()

    private var total: Int?
    private var selected: Int?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        // 阴影几何静态；颜色 / 不透明度随主题，在 refreshColors() 里套用（含热切换）。
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -2)

        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        icon.contentTintColor = NSColor(AppStyle.textTertiary)

        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.placeholderString = L("搜索…")
        field.delegate = self
        field.cell?.sendsActionOnEndEditing = false

        countLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        countLabel.alignment = .right

        configure(prevButton, symbol: "chevron.up", help: L("上一个（⇧回车）")) { [weak self] in
            self?.onNavigate?(false)
        }
        configure(nextButton, symbol: "chevron.down", help: L("下一个（回车）")) { [weak self] in
            self?.onNavigate?(true)
        }
        configure(closeButton, symbol: "xmark", help: L("关闭（Esc）")) { [weak self] in
            self?.onClose?()
        }

        for sub in [icon, field, countLabel, prevButton, nextButton, closeButton] {
            addSubview(sub)
        }
        refreshColors()
        updateCount()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// 跟当前主题取色（show 时调、PaneContainerView.restyle() 热切换时也调）。
    func refreshColors() {
        let theme = AppStyle.theme
        layer?.backgroundColor = NSColor(AppStyle.elevated).cgColor
        layer?.borderColor = theme.cardBorder.cgColor
        layer?.shadowColor = theme.cardShadowColor.cgColor
        layer?.shadowOpacity = theme.cardShadowOpacity
        field.textColor = NSColor(AppStyle.textPrimary)
        countLabel.textColor = NSColor(AppStyle.textTertiary)
        for button in [prevButton, nextButton, closeButton] {
            button.contentTintColor = NSColor(AppStyle.textSecondary)
        }
        updateCount()   // 重算计数色（命中为零时的错误红也跟随主题 token）
    }

    private func configure(_ button: NSButton, symbol: String, help: String, action: @escaping () -> Void) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)?
            .withSymbolConfiguration(.init(pointSize: 9.5, weight: .bold))
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.toolTip = help
        buttonActions[ObjectIdentifier(button)] = action
        button.target = self
        button.action = #selector(buttonTapped(_:))
    }

    private var buttonActions: [ObjectIdentifier: () -> Void] = [:]

    @objc private func buttonTapped(_ sender: NSButton) {
        buttonActions[ObjectIdentifier(sender)]?()
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        icon.frame = NSRect(x: 10, y: (h - 14) / 2, width: 14, height: 14)
        closeButton.frame = NSRect(x: bounds.width - 26, y: (h - 18) / 2, width: 18, height: 18)
        nextButton.frame = NSRect(x: closeButton.frame.minX - 22, y: (h - 18) / 2, width: 18, height: 18)
        prevButton.frame = NSRect(x: nextButton.frame.minX - 20, y: (h - 18) / 2, width: 18, height: 18)
        let countW: CGFloat = 56
        countLabel.frame = NSRect(x: prevButton.frame.minX - countW - 4, y: (h - 14) / 2, width: countW, height: 14)
        let fieldX: CGFloat = icon.frame.maxX + 6
        field.frame = NSRect(x: fieldX, y: (h - 17) / 2,
                             width: max(40, countLabel.frame.minX - fieldX - 6), height: 17)
    }

    // MARK: - 对外状态

    var needle: String { field.stringValue }

    func setNeedle(_ text: String) {
        field.stringValue = text
    }

    func focusField() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func setTotal(_ n: Int) {
        total = max(0, n)
        updateCount()
    }

    func setSelected(_ i: Int) {
        selected = i >= 0 ? i : nil
        updateCount()
    }

    func resetCount() {
        total = nil
        selected = nil
        updateCount()
    }

    private func updateCount() {
        guard let total else {
            countLabel.stringValue = ""
            prevButton.isEnabled = false
            nextButton.isEnabled = false
            return
        }
        prevButton.isEnabled = total > 0
        nextButton.isEnabled = total > 0
        if let selected, total > 0 {
            countLabel.stringValue = "\(selected + 1)/\(total)"
        } else {
            countLabel.stringValue = "\(total)"
        }
        countLabel.textColor = total == 0
            ? NSColor(AppStyle.errorRed).withAlphaComponent(0.9)
            : NSColor(AppStyle.textTertiary)
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        // 输入即搜（核心在搜索线程异步跑，增量代价小）；清空即取消高亮
        onQueryChange?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            onNavigate?(!shift)
            return true
        case #selector(NSResponder.moveUp(_:)):
            onNavigate?(false)
            return true
        case #selector(NSResponder.moveDown(_:)):
            onNavigate?(true)
            return true
        default:
            return false
        }
    }
}
