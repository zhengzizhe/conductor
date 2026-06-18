import AppKit
import ConductorCore

/// 把一棵 ConductorCore `SplitNode` 递归构建成 AppKit 视图：
/// 叶子 → 对应 pane 的视图（GhosttySurface 的 hostView）；分屏 → 可拖动的 `NSSplitView`。
/// 拖动分隔条会通过 `onRatioChange` 把新比例写回模型，从而不被 rebuild 重置、并可持久化。
@MainActor
enum SplitTreeBuilder {
    static func build(
        _ node: SplitNode,
        paneView: (PaneID) -> NSView,
        onRatioChange: @escaping (SplitID, Double) -> Void
    ) -> NSView {
        switch node {
        case let .leaf(pane):
            return paneView(pane)
        case let .split(id, axis, ratio, first, second):
            let split = RatioSplitView()
            split.isVertical = (axis == .vertical)
            split.dividerStyle = .thin
            split.splitID = id
            split.onRatioChange = onRatioChange
            split.delegate = split
            split.addArrangedSubview(build(first, paneView: paneView, onRatioChange: onRatioChange))
            split.addArrangedSubview(build(second, paneView: paneView, onRatioChange: onRatioChange))
            split.initialRatio = CGFloat(ratio)
            return split
        }
    }
}

/// NSSplitView 子类：首次按 ratio 设分隔位置；用户拖动后把新比例回报给模型。
/// 分隔条颜色走主题 token，尽量贴近 pane 卡片底，避免两块终端之间出现硬线。
final class RatioSplitView: NSSplitView, NSSplitViewDelegate {
    var initialRatio: CGFloat = 0.5
    var splitID: SplitID?
    var onRatioChange: ((SplitID, Double) -> Void)?
    private var applied = false
    private var applyingInitialRatio = false

    override var dividerColor: NSColor { AppStyle.splitDivider }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        restyleForCurrentTheme()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        restyleForCurrentTheme()
    }

    func restyleForCurrentTheme() {
        wantsLayer = true
        layer?.backgroundColor = .clear   // 终端画布透明：露出窗口毛玻璃；pane 卡片自带实色保可读
        needsDisplay = true
        setNeedsDisplay(bounds)
    }

    override func drawDivider(in rect: NSRect) {
        AppStyle.splitDivider.setFill()
        rect.fill()
    }

    /// 双击分隔条 → 两侧均分（macOS 原生分屏惯例）。新比例经
    /// `splitViewDidResizeSubviews` 回报模型，照常持久化。
    /// 单击拖动：NSSplitView 的分隔条拖动是同步 tracking loop（整个拖动都在
    /// `super.mouseDown` 里），期间让两侧终端的 Metal 呈现与布局事务同步，
    /// 消除拖动时内容滞后一帧的果冻感。
    override func mouseDown(with event: NSEvent) {
        guard isOnDivider(convert(event.locationInWindow, from: nil)) else {
            return super.mouseDown(with: event)
        }
        if event.clickCount == 2, arrangedSubviews.count == 2 {
            setPosition(pixelAligned(splitExtent / 2), ofDividerAt: 0)
            return
        }
        setTerminalSynchronousPresentation(true)
        super.mouseDown(with: event)
        setTerminalSynchronousPresentation(false)
    }

    /// 递归找出本分屏树下所有终端视图，切换其呈现同步模式。
    private func setTerminalSynchronousPresentation(_ on: Bool) {
        func walk(_ view: NSView) {
            if let host = view as? TerminalHostView { host.setSynchronousPresentation(on) }
            for sub in view.subviews { walk(sub) }
        }
        walk(self)
    }

    /// 拖动分隔条时把位置吸附到物理像素边界：小数坐标会让两侧的 Metal 终端
    /// 被半像素重采样（文字发虚/锯齿）。
    func splitView(_ splitView: NSSplitView,
                   constrainSplitPosition proposedPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        pixelAligned(proposedPosition)
    }

    private func pixelAligned(_ position: CGFloat) -> CGFloat {
        let scale = window?.backingScaleFactor ?? 2
        return (position * scale).rounded() / scale
    }

    /// 命中判定放宽到分隔条两侧各 3pt（thin 分隔条只有 1px，太难点）。
    private func isOnDivider(_ point: NSPoint) -> Bool {
        guard bounds.contains(point) else { return false }
        let dividerStart = isVertical ? arrangedSubviews[0].frame.maxX : arrangedSubviews[0].frame.maxY
        let coordinate = isVertical ? point.x : point.y
        return coordinate >= dividerStart - 3 && coordinate <= dividerStart + dividerThickness + 3
    }

    override func layout() {
        super.layout()
        applyInitialRatioIfNeeded()
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard applied, !applyingInitialRatio, let splitID, arrangedSubviews.count == 2 else { return }
        let total = splitExtent
        guard total > 1, visiblePaneCount == 2 else { return }
        let firstSize = isVertical ? arrangedSubviews[0].frame.width : arrangedSubviews[0].frame.height
        let minRatio = min(0.45, Double(minimumPaneExtent(for: total) / total))
        let ratio = max(minRatio, min(1 - minRatio, Double(firstSize / total)))
        onRatioChange?(splitID, ratio)
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        false
    }

    func splitView(_ splitView: NSSplitView,
                   constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        minimumPaneExtent(for: splitExtent)
    }

    func splitView(_ splitView: NSSplitView,
                   constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        splitExtent - minimumPaneExtent(for: splitExtent)
    }

    private var splitExtent: CGFloat {
        isVertical ? bounds.width : bounds.height
    }

    private var visiblePaneCount: Int {
        arrangedSubviews.filter { view in
            let extent = isVertical ? view.frame.width : view.frame.height
            return extent > 1
        }.count
    }

    private func applyInitialRatioIfNeeded() {
        guard !applied, arrangedSubviews.count == 2 else { return }
        let total = splitExtent
        guard total >= 24 else { return }

        let minExtent = minimumPaneExtent(for: total)
        let proposed = initialRatio * total
        let position = pixelAligned(min(max(proposed, minExtent), total - minExtent))

        applyingInitialRatio = true
        setPosition(position, ofDividerAt: 0)
        adjustSubviews()
        applyingInitialRatio = false

        if visiblePaneCount == 2 {
            applied = true
        }
    }

    private func minimumPaneExtent(for total: CGFloat) -> CGFloat {
        let available = max(0, total - dividerThickness)
        guard available > 0 else { return 0 }
        return min(72, max(24, floor(available * 0.18)))
    }
}
