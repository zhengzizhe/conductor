import AppKit

/// 自绘终端滚动条：贴 pane 右缘。ghostty 通过 SCROLLBAR action 推送 total/offset/len，
/// 据此画 thumb；滚动时淡现、~1.3s 后淡隐、悬停变粗、可拖动滚动。
/// **非 Metal 兄弟**：放在 frameView 内、是 card 的兄弟（和 header 一样安全，不破坏 Metal 渲染）。
@MainActor
final class PaneScrollbar: NSView {
    /// 拖动 → 按像素滚动终端（正负方向已对齐自然滚动）。
    var onScroll: ((Double) -> Void)?

    private var total: CGFloat = 0
    private var offset: CGFloat = 0
    private var len: CGFloat = 0
    private let thumb = CALayer()
    private var hovering = false
    private var dragging = false
    private var grabOffset: CGFloat = 0   // mouseDown 时指针相对 thumb 顶部的偏移
    private var hideWork: DispatchWorkItem?
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }   // y 自上而下，offset 直接映射

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        thumb.cornerCurve = .continuous
        thumb.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull()]  // 跟手，无隐式动画
        layer?.addSublayer(thumb)
        alphaValue = 0
        applyColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setMetrics(total: UInt64, offset: UInt64, len: UInt64) {
        if dragging {
            return
        }
        self.total = CGFloat(total); self.offset = CGFloat(offset); self.len = CGFloat(len)
        layoutThumb()
        if total > len, total > 0 { fadeIn(); scheduleHide() } else { fadeOut() }
    }

    func restyle() { applyColor() }

    private func applyColor() {
        // 从中性文本 token 派生（替代裸 white/black），仍随主题深浅自适应，alpha 行为不变。
        thumb.backgroundColor = NSColor(AppStyle.textTertiary)
            .withAlphaComponent(hovering || dragging ? 0.42 : 0.26).cgColor
    }

    override func layout() { super.layout(); layoutThumb() }

    /// 轨道几何：内边距 / 轨道高 / thumb 高 / 可移动行程。
    private var geometry: (pad: CGFloat, trackH: CGFloat, thumbH: CGFloat, travel: CGFloat) {
        let pad: CGFloat = 3
        let trackH = bounds.height - 2 * pad
        let thumbH = max(28, trackH * (len / max(1, total)))
        return (pad, trackH, thumbH, max(0, trackH - thumbH))
    }

    private func layoutThumb() {
        guard total > 0, len > 0, len < total, bounds.height > 0 else { thumb.isHidden = true; return }
        thumb.isHidden = false
        let g = geometry
        let frac = min(1, max(0, offset / max(1, total - len)))
        let y = g.pad + g.travel * frac
        let w: CGFloat = (hovering || dragging) ? 7 : 4
        thumb.frame = CGRect(x: bounds.width - w - 3, y: y, width: w, height: g.thumbH)
        thumb.cornerRadius = w / 2
    }

    // MARK: 显隐

    private func scheduleHide() {
        hideWork?.cancel()
        guard !hovering, !dragging else { return }
        let w = DispatchWorkItem { [weak self] in self?.fadeOut() }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: w)
    }
    private func fadeIn() {
        hideWork?.cancel()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; animator().alphaValue = 1 }
    }
    private func fadeOut() {
        NSAnimationContext.runAnimationGroup { $0.duration = 0.3; animator().alphaValue = 0 }
    }

    /// 隐藏时点击穿透到终端，避免无谓拦截右缘点击。
    override func hitTest(_ point: NSPoint) -> NSView? {
        alphaValue < 0.06 ? nil : super.hitTest(point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; applyColor(); layoutThumb(); fadeIn() }
    override func mouseExited(with event: NSEvent) { hovering = false; applyColor(); layoutThumb(); scheduleHide() }

    // MARK: 拖动滚动（绝对定位：thumb 跟手）

    override func mouseDown(with event: NSEvent) {
        guard total > len, len > 0 else { return }
        dragging = true
        hideWork?.cancel()
        let y = convert(event.locationInWindow, from: nil).y
        let t = thumb.frame
        if y >= t.minY, y <= t.maxY {
            grabOffset = y - t.minY        // 抓在 thumb 上：保持指针与 thumb 的相对位置
        } else {
            grabOffset = t.height / 2      // 点轨道空白：thumb 中心跳到指针处
            scroll(toThumbTop: y - grabOffset)
        }
        applyColor(); layoutThumb()
    }
    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        let y = convert(event.locationInWindow, from: nil).y
        scroll(toThumbTop: y - grabOffset)
    }
    override func mouseUp(with event: NSEvent) {
        dragging = false
        applyColor(); layoutThumb(); scheduleHide()
    }

    /// 把 thumb 顶移到 targetY：换算目标 offset（行），按与当前 offset 的差值滚动。
    /// 本地乐观更新 offset 让 thumb 立即跟手；ghostty 的 SCROLLBAR 推送会随后校正。
    private func scroll(toThumbTop targetY: CGFloat) {
        guard total > len, len > 0, bounds.height > 0 else { return }
        let g = geometry
        guard g.travel > 0 else { return }
        let frac = min(1, max(0, (targetY - g.pad) / g.travel))
        let targetOffset = frac * (total - len)
        let deltaRows = targetOffset - offset
        guard abs(deltaRows) > 0.001 else { return }
        // ghostty 精确滚动按设备像素折算行数：行高(pt) × backingScale。
        let scale = window?.backingScaleFactor ?? 2
        let cellH = (bounds.height / len) * scale
        onScroll?(-deltaRows * cellH)          // 向下拖（offset 增大）→ 负向滚动 = 更新内容
        offset = targetOffset
        layoutThumb()
    }
}
