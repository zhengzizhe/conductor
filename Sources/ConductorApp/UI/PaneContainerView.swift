import AppKit
import ConductorCore

/// 落点边缘：决定把被拖 pane 放到目标 pane 的哪一侧。
enum PaneDropEdge { case left, right, top, bottom }

/// 新 pane 的入场动势：区分普通出现与分屏打开。
enum PaneEntranceMotion: Equatable {
    case fade
    case split(axis: SplitAxis)
}

/// pane 右键「新建终端运行」子菜单的一项：要执行的命令 + 显示标题 + 品牌 logo。
struct PaneAgentMenuItem {
    let command: String
    let title: String
    let image: NSImage?
}

/// pane 右键菜单动作（终端正文与头条共用一套）。
enum PaneContextAction: Equatable {
    case copy, paste, selectAll, clear   // 终端文本操作（经 ghostty）
    case splitRight, splitDown, zoom     // 布局
    case copyCwd, openInFinder           // 当前目录
    case exportText                      // 屏幕+回滚文本存盘
    case close
}

enum PaneHeaderActionPresentation {
    static let primaryActions: [PaneContextAction] = [.splitRight, .splitDown, .zoom, .close]
    static let moreActions: [PaneContextAction] = [.copy, .paste, .selectAll, .clear, .copyCwd, .openInFinder, .exportText]

    static func title(for action: PaneContextAction) -> String {
        switch action {
        case .copy: return L("复制")
        case .paste: return L("粘贴")
        case .selectAll: return L("全选")
        case .clear: return L("清屏")
        case .splitRight: return L("向右分屏")
        case .splitDown: return L("向下分屏")
        case .zoom: return L("放大 / 还原")
        case .copyCwd: return L("复制路径")
        case .openInFinder: return L("在 Finder 中显示")
        case .exportText: return L("导出输出为文本…")
        case .close: return L("关闭面板")
        }
    }

    static func systemImage(for action: PaneContextAction) -> String {
        switch action {
        case .copy: return "doc.on.doc"
        case .paste: return "clipboard"
        case .selectAll: return "checklist"
        case .clear: return "eraser"
        case .splitRight: return "rectangle.split.2x1"
        case .splitDown: return "rectangle.split.1x2"
        case .zoom: return "arrow.up.left.and.arrow.down.right"
        case .copyCwd: return "doc.text"
        case .openInFinder: return "folder"
        case .exportText: return "square.and.arrow.down"
        case .close: return "xmark"
        }
    }
}

struct PaneHeaderControlLayout: Equatable {
    let buttonFrames: [NSRect]
    let buttonSize: CGFloat
    let spacing: CGFloat
    let trailingInset: CGFloat

    static func layout(headerWidth: CGFloat, controlCount: Int) -> PaneHeaderControlLayout {
        guard controlCount > 0, headerWidth > 0 else {
            return PaneHeaderControlLayout(buttonFrames: [], buttonSize: 0, spacing: 0, trailingInset: 0)
        }

        let desiredButton: CGFloat = 20
        let desiredSpacing: CGFloat = 3
        let desiredInset: CGFloat = 8
        let minButton: CGFloat = 9
        let minSpacing: CGFloat = 1
        let minInset: CGFloat = 2
        let count = CGFloat(controlCount)

        let desiredWidth = count * desiredButton + (count - 1) * desiredSpacing + desiredInset * 2
        let buttonSize: CGFloat
        let spacing: CGFloat
        let inset: CGFloat

        if headerWidth >= desiredWidth {
            buttonSize = desiredButton
            spacing = desiredSpacing
            inset = desiredInset
        } else {
            inset = minInset
            spacing = minSpacing
            let available = max(0, headerWidth - inset * 2 - (count - 1) * spacing)
            buttonSize = max(minButton, floor(available / count))
        }

        let totalWidth = count * buttonSize + (count - 1) * spacing
        let originX = max(0, headerWidth - inset - totalWidth)
        let frames = (0..<controlCount).map { index in
            NSRect(
                x: originX + CGFloat(index) * (buttonSize + spacing),
                y: 0,
                width: buttonSize,
                height: buttonSize
            )
        }
        return PaneHeaderControlLayout(
            buttonFrames: frames,
            buttonSize: buttonSize,
            spacing: spacing,
            trailingInset: inset
        )
    }
}

/// 包裹一个终端 hostView。**关键：hostView 必须是唯一子视图，且本视图不 wantsLayer、不重写 draw()**——
/// 否则给 CAMetalLayer 的终端视图加普通 layer-backed 兄弟/做 CPU 绘制会破坏 Metal 呈现（非聚焦 pane 白屏）。
/// 焦点环用 hostView 自身的 CAMetalLayer 边框；拖拽发起由终端 ⌘+拖 触发。
@MainActor
final class PaneContainerView: NSView, NSDraggingSource, NSMenuDelegate {
    static let paneType = NSPasteboard.PasteboardType("com.conductor.pane")

    let paneID: PaneID
    let hostView: NSView

    var onMove: ((_ moving: PaneID, _ target: PaneID, _ edge: PaneDropEdge) -> Void)?
    var onFocus: ((PaneID) -> Void)?
    var onContextAction: ((PaneContextAction) -> Void)?
    /// 滚动条拖动 → 按像素滚动终端。
    var onScroll: ((Double) -> Void)?
    /// 右键「新建终端运行」子菜单：动态提供当前可启动的 Agent。
    var agentItemsProvider: (() -> [PaneAgentMenuItem])?
    /// 选中某个 Agent → 在分屏中启动。
    var onLaunchAgent: ((String) -> Void)?
    /// 右键「续聊会话」子菜单：当前 pane 目录下的最近会话。
    var sessionItemsProvider: (() -> [AgentSessionRecord])?
    /// 选中某条会话 → 在当前 pane 续聊。
    var onResumeSession: ((AgentSessionRecord) -> Void)?
    /// 打开完整会话管理面板。
    var onManageSessions: (() -> Void)?
    /// 右键「二次意见」子菜单：可来审查的其他 Agent。
    var secondOpinionItemsProvider: (() -> [PaneAgentMenuItem])?
    /// 选中审查者 → 分屏起 agent 审查本 pane 输出。
    var onSecondOpinion: ((String) -> Void)?
    /// 打开本 pane 的任务队列面板。
    var onManageQueue: (() -> Void)?
    private weak var sessionSubmenu: NSMenu?
    private weak var agentSubmenu: NSMenu?
    private weak var secondOpinionSubmenu: NSMenu?
    var isActive = false { didSet { if isActive != oldValue { updateRing() } } }
    /// 是否允许拖拽重排：只有当所在 tab 含 ≥2 个 pane 时才有意义（单个终端无处可排）。
    var canDrag = false
    /// 放大态：头条亮「已放大」徽标，点击还原（⌘⏎ 同效）。
    var isZoomed = false { didSet { if isZoomed != oldValue { header.isZoomed = isZoomed } } }
    /// 卡片四周留的间隙（露出画布 + 给柔阴影留空间）。紧凑一些。
    private let gap: CGFloat = 3
    private let headerH: CGFloat = 22
    /// 与卡片圆角一致（统一到设计系统圆角阶梯）。
    private let cornerRadius: CGFloat = Radius.md
    /// 柔阴影层（在 frameView 之下、同形状；frameView 不透明地盖住它的填充，只露出四周阴影）。
    private let shadowView = NSView()
    /// 统一圆角卡片：含头条 + 终端，共用一个圆角；masksToBounds 把里面的 Metal 终端裁成圆角。
    private let frameView = NSView()
    /// Metal 终端的非 Metal 包装层（隔离，避免终端与头条做兄弟而破坏渲染）。
    private let card = NSView()
    /// 顶部标题栏 + 拖拽抓手（是 card 的兄弟、在 frameView 内）。
    private let header = PaneHeaderView()
    /// 拖放落点高亮（独立覆盖层，frameView 的兄弟、非终端兄弟 → 不破坏 Metal）。
    private let dropOverlay = NSView()
    /// 自绘滚动条（card 的兄弟，贴右缘；非 Metal 兄弟，安全）。
    private let scrollbar = PaneScrollbar()
    /// ⌘F 搜索条（懒创建；card 的兄弟，浮在右上角，非 Metal 兄弟，安全）。
    private var searchBar: PaneSearchBar?

    /// 搜索条文本变化 → `search:<needle>`（空串取消高亮）。
    var onSearchQuery: ((String) -> Void)?
    /// 搜索条导航 → `navigate_search:next/previous`。
    var onSearchNavigate: ((_ forward: Bool) -> Void)?
    /// 用户关掉搜索条 → `end_search` + 焦点还给终端。
    var onSearchEnded: (() -> Void)?

    init(paneID: PaneID, hostView: NSView, title: String) {
        self.paneID = paneID
        self.hostView = hostView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = .clear   // 间隙/画布透明：露出窗口毛玻璃（pane 卡片自带实色）

        // 柔阴影层（最底）
        shadowView.wantsLayer = true
        shadowView.layer?.cornerRadius = cornerRadius
        shadowView.layer?.cornerCurve = .continuous
        shadowView.layer?.masksToBounds = false
        applyCardShadow()

        frameView.wantsLayer = true
        frameView.layer?.cornerRadius = cornerRadius
        frameView.layer?.cornerCurve = .continuous
        frameView.layer?.masksToBounds = true

        card.wantsLayer = true
        card.addSubview(hostView)

        header.title = title
        applyCardFills()   // 卡片/正文/标题栏的底色：按主题是否「终端透明」分两条路径
        header.onDragStart = { [weak self] event in self?.beginPaneDrag(event) }
        header.onClick = { [weak self] in if let id = self?.paneID { self?.onFocus?(id) } }
        header.onAction = { [weak self] action in self?.onContextAction?(action) }
        // 头条与终端正文共用同一套右键菜单（各建一份实例，避免菜单被两个视图共享）。
        header.menu = buildContextMenu()
        hostView.menu = buildContextMenu()

        scrollbar.onScroll = { [weak self] dy in self?.onScroll?(dy) }

        frameView.addSubview(card)
        frameView.addSubview(header)
        frameView.addSubview(scrollbar)   // card 的兄弟，贴右缘
        addSubview(shadowView)   // 在 frameView 之下
        addSubview(frameView)
        updateRing()

        dropOverlay.wantsLayer = true
        dropOverlay.layer?.backgroundColor = NSColor(AppStyle.accent).withAlphaComponent(0.15).cgColor
        dropOverlay.layer?.cornerRadius = cornerRadius   // 高亮与卡片圆角一致
        dropOverlay.layer?.cornerCurve = .continuous
        // 落点高亮的静态边：克制，无硬线（与「焦点环细环」同一审美）。
        dropOverlay.layer?.borderWidth = 1.5
        dropOverlay.layer?.borderColor = NSColor(AppStyle.accent).withAlphaComponent(0.6).cgColor
        dropOverlay.isHidden = true
        addSubview(dropOverlay)   // 顶层，frameView 的兄弟

        registerForDraggedTypes([Self.paneType])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setTitle(_ title: String) { header.title = title }

    /// 设置头条左侧的 Agent logo（nil 表示无 agent 在跑）。
    func setAgentLogo(_ image: NSImage?) { header.agentLogo = image }

    /// Agent 思考起点（nil = 没在思考）：头条右侧亮活计时，每秒走、停止即收。
    func setThinkingSince(_ date: Date?) { header.thinkingSince = date }

    /// 任务队列长度：>0 时头条显示排队数。
    func setQueuedCount(_ count: Int) { header.queuedCount = count }

    /// OSC 9;4 进度徽标：nil 清除。
    func setProgress(_ info: PaneProgressInfo?) { header.progress = info }

    /// 新 pane 入场：新 tab 保持轻淡入；分屏从分割缝方向打开。
    func animateEntrance(_ motion: PaneEntranceMotion) {
        guard let layer else { return }
        layer.removeAnimation(forKey: "paneEntrance")

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let initialTransform = reduceMotion ? CATransform3DIdentity : entranceTransform(for: motion)
        let duration = (motion == .fade || reduceMotion) ? 0.2 : 0.3

        layer.opacity = 1
        layer.transform = CATransform3DIdentity

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1

        let transform = CABasicAnimation(keyPath: "transform")
        transform.fromValue = NSValue(caTransform3D: initialTransform)
        transform.toValue = NSValue(caTransform3D: CATransform3DIdentity)

        let group = CAAnimationGroup()
        group.animations = [fade, transform]
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.isRemovedOnCompletion = true
        group.allowHighFrameRate()
        layer.add(group, forKey: "paneEntrance")
    }

    private func entranceTransform(for motion: PaneEntranceMotion) -> CATransform3D {
        switch motion {
        case .fade:
            return CATransform3DIdentity
        case .split(.vertical):
            let travel = -min(max(bounds.width * 0.18, 18), 72)
            let t = CGAffineTransform(translationX: travel, y: 0).scaledBy(x: 0.88, y: 1)
            return CATransform3DMakeAffineTransform(t)
        case .split(.horizontal):
            let travel = min(max(bounds.height * 0.18, 18), 72)
            let t = CGAffineTransform(translationX: 0, y: travel).scaledBy(x: 1, y: 0.88)
            return CATransform3DMakeAffineTransform(t)
        }
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ image: String, _ action: PaneContextAction) {
            menu.addItem(ClosureMenuItem(title, systemImage: image) { [weak self] in self?.onContextAction?(action) })
        }
        add(PaneHeaderActionPresentation.title(for: .copy), PaneHeaderActionPresentation.systemImage(for: .copy), .copy)
        add(PaneHeaderActionPresentation.title(for: .paste), PaneHeaderActionPresentation.systemImage(for: .paste), .paste)
        add(PaneHeaderActionPresentation.title(for: .selectAll), PaneHeaderActionPresentation.systemImage(for: .selectAll), .selectAll)
        menu.addItem(.separator())
        add(PaneHeaderActionPresentation.title(for: .splitRight), PaneHeaderActionPresentation.systemImage(for: .splitRight), .splitRight)
        add(PaneHeaderActionPresentation.title(for: .splitDown), PaneHeaderActionPresentation.systemImage(for: .splitDown), .splitDown)
        add(PaneHeaderActionPresentation.title(for: .zoom), PaneHeaderActionPresentation.systemImage(for: .zoom), .zoom)
        menu.addItem(.separator())
        add(PaneHeaderActionPresentation.title(for: .copyCwd), PaneHeaderActionPresentation.systemImage(for: .copyCwd), .copyCwd)
        add(PaneHeaderActionPresentation.title(for: .openInFinder), PaneHeaderActionPresentation.systemImage(for: .openInFinder), .openInFinder)
        add(PaneHeaderActionPresentation.title(for: .exportText), PaneHeaderActionPresentation.systemImage(for: .exportText), .exportText)
        menu.addItem(.separator())
        let sessionItem = NSMenuItem(title: L("续聊会话"), action: nil, keyEquivalent: "")
        sessionItem.image = NSImage(systemSymbolName: "bubble.left.and.text.bubble.right", accessibilityDescription: nil)
        let sessionMenu = NSMenu()
        sessionMenu.delegate = self
        sessionItem.submenu = sessionMenu
        sessionSubmenu = sessionMenu
        menu.addItem(sessionItem)
        menu.addItem(ClosureMenuItem(L("管理会话…"), systemImage: "list.bullet.rectangle") { [weak self] in
            self?.onManageSessions?()
        })
        menu.addItem(.separator())
        let launchItem = NSMenuItem(title: L("新建终端运行"), action: nil, keyEquivalent: "")
        launchItem.image = NSImage(systemSymbolName: "play.circle", accessibilityDescription: nil)
        let submenu = NSMenu()
        submenu.delegate = self
        launchItem.submenu = submenu
        agentSubmenu = submenu
        menu.addItem(launchItem)
        // 二次意见：把本 pane 的输出交给另一个 agent 审一遍
        let reviewItem = NSMenuItem(title: L("二次意见"), action: nil, keyEquivalent: "")
        reviewItem.image = NSImage(systemSymbolName: "person.2.badge.gearshape", accessibilityDescription: nil)
        let reviewMenu = NSMenu()
        reviewMenu.delegate = self
        reviewItem.submenu = reviewMenu
        secondOpinionSubmenu = reviewMenu
        menu.addItem(reviewItem)
        menu.addItem(ClosureMenuItem(L("任务队列…"), systemImage: "text.badge.plus") { [weak self] in
            self?.onManageQueue?()
        })
        menu.addItem(.separator())
        add(PaneHeaderActionPresentation.title(for: .clear), PaneHeaderActionPresentation.systemImage(for: .clear), .clear)
        add(PaneHeaderActionPresentation.title(for: .close), PaneHeaderActionPresentation.systemImage(for: .close), .close)
        return menu
    }

    /// 动态子菜单打开前重建：续聊会话 / 新建终端运行 / 二次意见。
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.delegate === self else { return }
        menu.removeAllItems()
        if menu === sessionSubmenu {
            populateSessionSubmenu(menu)
            return
        }
        if menu === secondOpinionSubmenu {
            populateSecondOpinionSubmenu(menu)
            return
        }
        guard menu === agentSubmenu else { return }
        let agents = agentItemsProvider?() ?? []
        guard !agents.isEmpty else {
            let empty = NSMenuItem(title: L("未检测到可用 CLI"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for agent in agents {
            let item = ClosureMenuItem(agent.title) { [weak self] in self?.onLaunchAgent?(agent.command) }
            item.image = agent.image
            menu.addItem(item)
        }
    }

    private func populateSecondOpinionSubmenu(_ menu: NSMenu) {
        let reviewers = secondOpinionItemsProvider?() ?? []
        guard !reviewers.isEmpty else {
            let empty = NSMenuItem(title: L("没有其他可用的 Agent"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for reviewer in reviewers {
            let item = ClosureMenuItem(L("让 %@ 审一遍", reviewer.title)) { [weak self] in
                self?.onSecondOpinion?(reviewer.command)
            }
            item.image = reviewer.image
            menu.addItem(item)
        }
    }

    private func populateSessionSubmenu(_ menu: NSMenu) {
        let sessions = sessionItemsProvider?() ?? []
        guard !sessions.isEmpty else {
            let empty = NSMenuItem(title: L("此目录暂无会话"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for record in sessions {
            let logo = record.agent == "claude" ? "claude" : "codex"
            let image = CLIToolLogo.image(named: logo)?.copy() as? NSImage
            image?.size = NSSize(width: 15, height: 15)
            if CLIToolLogo.isMonochrome(logo) { image?.isTemplate = true }
            let subtitle = record.title.count > 36 ? String(record.title.prefix(33)) + "…" : record.title
            let item = ClosureMenuItem("\(record.agent.capitalized) · \(subtitle)") { [weak self] in
                self?.onResumeSession?(record)
            }
            item.image = image
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("管理全部会话…"), systemImage: "list.bullet.rectangle") { [weak self] in
            self?.onManageSessions?()
        })
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutCard()
    }

    override func layout() {
        super.layout()
        layoutCard()
    }

    private func layoutCard() {
        // 卡片矩形吸附到物理像素边界：分屏比例/SwiftUI 布局可能给出小数坐标，
        // Metal 终端层落在半像素上会被 GPU 重采样，文字发虚、边缘起锯齿。
        guard bounds.width.isFinite, bounds.height.isFinite else { return }
        var inset = NSRect(
            x: gap,
            y: gap,
            width: max(0, bounds.width - gap * 2),
            height: max(0, bounds.height - gap * 2)
        )
        if window != nil {
            inset = backingAlignedRect(inset, options: .alignAllEdgesNearest)
        }
        frameView.frame = inset
        shadowView.frame = inset
        shadowView.layer?.shadowPath = CGPath(roundedRect: shadowView.bounds,
                                              cornerWidth: cornerRadius, cornerHeight: cornerRadius,
                                              transform: nil)
        let fb = frameView.bounds
        let fbWidth = max(0, fb.width)
        let fbHeight = max(0, fb.height)
        let headerHeight = min(headerH, fbHeight)
        header.frame = NSRect(x: 0, y: max(0, fbHeight - headerHeight), width: fbWidth, height: headerHeight)
        card.frame = NSRect(x: 0, y: 0, width: fbWidth, height: max(0, fbHeight - headerHeight))
        hostView.frame = card.bounds
        scrollbar.frame = NSRect(x: max(0, fbWidth - 14), y: 0, width: min(14, fbWidth), height: card.bounds.height)
        if let searchBar, !searchBar.isHidden {
            let width = min(320, max(0, fbWidth - 24))
            searchBar.frame = NSRect(x: max(0, fbWidth - width - 12),
                                     y: max(0, fbHeight - headerHeight - 32 - 8),
                                     width: width, height: 32)
        }
    }

    // MARK: - ⌘F 搜索条

    var isSearchVisible: Bool { searchBar?.isHidden == false }

    /// 显示搜索条；`initialNeedle` 来自 core 的 START_SEARCH（如 search_selection 绑定）。
    func showSearch(initialNeedle: String? = nil) {
        let bar = searchBar ?? makeSearchBar()
        if let initialNeedle, !initialNeedle.isEmpty {
            bar.setNeedle(initialNeedle)
        }
        bar.refreshColors()
        if bar.isHidden {
            bar.isHidden = false
            bar.layer?.opacity = 0
            needsLayout = true
            layoutSubtreeIfNeeded()
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.14
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            fade.allowHighFrameRate()
            bar.layer?.add(fade, forKey: "searchIn")
            bar.layer?.opacity = 1
        }
        bar.focusField()
    }

    /// 用户主动关闭（Esc / ✕）：藏条 + 通知外面 end_search。
    private func closeSearch() {
        guard let searchBar, !searchBar.isHidden else { return }
        searchBar.isHidden = true
        searchBar.resetCount()
        onSearchEnded?()
    }

    /// core 发来 END_SEARCH（如终端侧绑定触发）：只藏条，不再回发 end_search。
    func searchEndedExternally() {
        searchBar?.isHidden = true
        searchBar?.resetCount()
    }

    func setSearchTotal(_ total: Int) { searchBar?.setTotal(total) }
    func setSearchSelected(_ selected: Int) { searchBar?.setSelected(selected) }

    private func makeSearchBar() -> PaneSearchBar {
        let bar = PaneSearchBar(frame: NSRect(x: 0, y: 0, width: 320, height: 32))
        bar.isHidden = true
        bar.onQueryChange = { [weak self] text in self?.onSearchQuery?(text) }
        bar.onNavigate = { [weak self] forward in self?.onSearchNavigate?(forward) }
        bar.onClose = { [weak self] in self?.closeSearch() }
        frameView.addSubview(bar)   // card 的兄弟（非 Metal 兄弟，安全）
        searchBar = bar
        return bar
    }

    func updateScrollbar(total: UInt64, offset: UInt64, len: UInt64) {
        scrollbar.setMetrics(total: total, offset: offset, len: len)
    }

    /// 卡片三层底色：按主题是否「终端透明」分两条路径。
    /// - 光晕主题（透明）：frame/card 清空，正文 ghostty 0.8 透出后方光晕；磨砂底单独给 header（标题栏仍清晰）。
    /// - 纯色主题（实底）：frame/card 铺 cardBackground 微玻璃，header **不**独立铺底（靠 frameView，
    ///   避免在「整窗一色」变体上重新造出异色标题条）。
    private func applyCardFills() {
        let theme = AppStyle.theme
        if theme.terminalTranslucent {
            frameView.layer?.backgroundColor = .clear
            card.layer?.backgroundColor = .clear
            header.layer?.backgroundColor = theme.cardBackground.withAlphaComponent(0.7).cgColor
        } else {
            let fill = theme.cardBackground.withAlphaComponent(0.62).cgColor
            frameView.layer?.backgroundColor = fill
            card.layer?.backgroundColor = fill
            header.layer?.backgroundColor = .clear
        }
    }

    private func applyCardShadow() {
        let theme = AppStyle.theme
        let layer = shadowView.layer
        // 透明主题：阴影靠 shadowPath，shadowView 不铺底（否则挡住终端透出）；
        // 纯色主题：shadowView 铺卡底，既是卡体也是阴影源。
        layer?.backgroundColor = theme.terminalTranslucent ? .clear
            : theme.cardBackground.withAlphaComponent(0.62).cgColor
        layer?.shadowColor = theme.cardShadowColor.cgColor
        layer?.shadowOpacity = theme.cardShadowOpacity
        layer?.shadowRadius = theme.cardShadowRadius
        layer?.shadowOffset = CGSize(width: 0, height: -4)      // 翻转坐标系：负 y = 视觉向下，更"浮起"
    }

    /// 主题热更新：重新套用当前主题色到各层。
    func restyle() {
        layer?.backgroundColor = .clear   // 间隙/画布透明：露出窗口毛玻璃
        applyCardFills()
        dropOverlay.layer?.backgroundColor = NSColor(AppStyle.accent).withAlphaComponent(0.15).cgColor
        dropOverlay.layer?.borderColor = NSColor(AppStyle.accent).withAlphaComponent(0.6).cgColor
        applyCardShadow()
        updateRing()
        header.needsDisplay = true
        scrollbar.restyle()
        searchBar?.refreshColors()   // 搜索条若开着也跟随主题热更新（否则停留在旧主题色）
    }

    private func updateRing() {
        // 静态：极淡边（主题感知）；活动：克制的浅 accent 环（细）。无硬线。
        frameView.layer?.borderWidth = 1
        frameView.layer?.borderColor = (isActive
            ? NSColor(AppStyle.accent).withAlphaComponent(0.38)
            : AppStyle.theme.cardBorder).cgColor
        header.isActive = isActive
    }

    /// 边框脉冲两下（通知跳转定位 / 完成提示用），结束后回到当前焦点环样式。
    /// `tint` 可换信号色（如完成绿），默认 accent。
    func flashHighlight(tint: NSColor? = nil) {
        guard let layer = frameView.layer else { return }
        layer.removeAnimation(forKey: "paneFlash")
        let resting = layer.borderColor ?? AppStyle.theme.cardBorder.cgColor
        let tintColor = tint ?? NSColor(AppStyle.accent)
        let accent = tintColor.cgColor
        let faint = tintColor.withAlphaComponent(0.25).cgColor

        let color = CAKeyframeAnimation(keyPath: "borderColor")
        color.values = [resting, accent, faint, accent, resting]
        let width = CAKeyframeAnimation(keyPath: "borderWidth")
        width.values = [layer.borderWidth, 2.5, 1.5, 2.5, layer.borderWidth]

        let group = CAAnimationGroup()
        group.animations = [color, width]
        group.duration = 0.9
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        group.allowHighFrameRate()
        layer.add(group, forKey: "paneFlash")
    }

    // MARK: - 拖动源（由终端 ⌘+拖 调用）

    func beginPaneDrag(_ event: NSEvent) {
        guard canDrag else { return }   // 单 pane tab 不允许拖（无处重排）
        let item = NSPasteboardItem()
        item.setString(paneID.value, forType: Self.paneType)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        dragItem.setDraggingFrame(bounds, contents: dragImage())
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }

    private func dragImage() -> NSImage {
        let size = bounds.size == .zero ? NSSize(width: 220, height: 140) : bounds.size
        let img = NSImage(size: size)
        img.lockFocus()
        // 圆角卡片（与终端卡片同形状），accent 半透明填充 + 细 accent 边
        let rect = NSRect(origin: .zero, size: size).insetBy(dx: gap + 1, dy: gap + 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor(AppStyle.accent).withAlphaComponent(0.16).setFill()
        path.fill()
        NSColor(AppStyle.accent).withAlphaComponent(0.9).setStroke()
        path.lineWidth = 2
        path.stroke()
        img.unlockFocus()
        return img
    }

    // MARK: - 拖放目标

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dropOperation(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dropOperation(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { hideDropOverlay() }
    override func draggingEnded(_ sender: NSDraggingInfo) { hideDropOverlay() }

    private func dropOperation(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let s = sender.draggingPasteboard.string(forType: Self.paneType), PaneID(s) != paneID else {
            hideDropOverlay()
            return []
        }
        showDropOverlay(Self.edge(for: convert(sender.draggingLocation, from: nil), in: bounds))
        return .move
    }

    /// 在落点半区画高亮，提示松手后这个 pane 会去到目标的哪一侧（左/右=并排，上/下=堆叠）。
    /// 首次淡入；在不同落点之间平滑滑动（不再硬切）。
    private func showDropOverlay(_ edge: PaneDropEdge) {
        let r = frameView.frame
        let half: NSRect
        switch edge {
        case .left: half = NSRect(x: r.minX, y: r.minY, width: r.width / 2, height: r.height)
        case .right: half = NSRect(x: r.midX, y: r.minY, width: r.width / 2, height: r.height)
        case .bottom: half = NSRect(x: r.minX, y: r.minY, width: r.width, height: r.height / 2)
        case .top: half = NSRect(x: r.minX, y: r.midY, width: r.width, height: r.height / 2)
        }
        let target = half.insetBy(dx: 4, dy: 4)
        let firstShow = dropOverlay.isHidden
        if firstShow {
            dropOverlay.isHidden = false
            dropOverlay.alphaValue = 0
            dropOverlay.frame = target          // 初次不从别处滑入
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = firstShow ? 0.15 : 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            dropOverlay.animator().alphaValue = 1
            dropOverlay.animator().frame = target   // 在落点之间平滑滑动
        }
    }

    private func hideDropOverlay() {
        guard !dropOverlay.isHidden else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.13
            dropOverlay.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            if dropOverlay.alphaValue == 0 { dropOverlay.isHidden = true }
        })
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hideDropOverlay()
        guard let s = sender.draggingPasteboard.string(forType: Self.paneType) else { return false }
        let moving = PaneID(s)
        guard moving != paneID else { return false }
        let edge = Self.edge(for: convert(sender.draggingLocation, from: nil), in: bounds)
        onMove?(moving, paneID, edge)
        return true
    }

    /// 按对角线把目标分成左/右/上/下四个三角区（归一化，不受宽高比影响）。
    /// 左半→并排到左、右半→并排到右、上下三角→堆叠。
    static func edge(for p: CGPoint, in rect: NSRect) -> PaneDropEdge {
        guard rect.width > 0, rect.height > 0 else { return .right }
        let nx = p.x / rect.width - 0.5
        let ny = p.y / rect.height - 0.5
        if abs(nx) >= abs(ny) {
            return nx < 0 ? .left : .right
        } else {
            return ny < 0 ? .bottom : .top
        }
    }
}

/// pane 头条：拖动发起整块 pane 的拖拽；单击聚焦；显示标题。layer-backed（是 card 的兄弟，非终端兄弟，安全）。
@MainActor
final class PaneHeaderView: NSView {
    var title = L("终端") { didSet { needsDisplay = true } }
    var isActive = false { didSet { restyleButtons(); needsDisplay = true } }
    /// 头条左侧的 Agent logo（如该 pane 在跑 codex/claude…）。
    var agentLogo: NSImage? { didSet { needsDisplay = true } }
    /// Agent 思考起点：非 nil 时头条右侧画活计时「2:31」，每秒重绘；置 nil 即收。
    var thinkingSince: Date? {
        didSet {
            guard thinkingSince != oldValue else { return }
            syncThinkingTimer()
            needsDisplay = true
        }
    }
    private var thinkingTimer: Timer?
    /// 任务队列长度：>0 时头条显示「队列 n」。
    var queuedCount = 0 {
        didSet {
            guard queuedCount != oldValue else { return }
            needsDisplay = true
        }
    }
    /// OSC 9;4 进度（构建/下载等长任务）：set 画百分比、indeterminate 画「进行中」、error/pause 变色。
    var progress: PaneProgressInfo? {
        didSet {
            guard progress != oldValue else { return }
            needsDisplay = true
        }
    }
    /// 放大态徽标：亮起表示该 pane 正占满整个 tab，点徽标还原。
    var isZoomed = false {
        didSet {
            zoomBadge.isHidden = !isZoomed
            needsLayout = true
            needsDisplay = true
        }
    }
    var onDragStart: ((NSEvent) -> Void)?
    var onClick: (() -> Void)?
    var onAction: ((PaneContextAction) -> Void)?
    private var dragStarted = false
    private let controls = NSView()
    private var controlButtons: [PaneHeaderButton] = []
    private let zoomBadge = PaneZoomBadge()
    private let moreButton = PaneHeaderButton(
        symbolName: "ellipsis",
        label: L("更多操作"),
        action: nil
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupControls()
        zoomBadge.isHidden = true
        zoomBadge.onPress = { [weak self] in self?.onAction?(.zoom) }
        addSubview(zoomBadge)
    }

    convenience init() { self.init(frame: .zero) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { dragStarted = false }

    override func mouseDragged(with event: NSEvent) {
        guard !dragStarted else { return }
        dragStarted = true
        onDragStart?(event)
    }

    /// 计时只在「正在思考且在屏上」时走表；离屏停表省电，回屏续走（起点不变，读数仍准）。
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncThinkingTimer()
    }

    private func syncThinkingTimer() {
        if thinkingSince != nil, window != nil {
            guard thinkingTimer == nil else { return }
            let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.needsDisplay = true }
            }
            timer.tolerance = 0.1
            thinkingTimer = timer
        } else {
            thinkingTimer?.invalidate()
            thinkingTimer = nil
        }
    }

    /// 思考用时读数：61s →「1:01」；过小时进位「1:02:31」。
    static func thinkingText(since: Date) -> String {
        let total = max(0, Int(Date().timeIntervalSince(since).rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// 在头条右侧画一枚状态徽标（可选小圆点 + 等宽小字），返回新的标题截断边界。
    private func drawStatusChip(_ text: String, color: NSColor, rightEdge: CGFloat,
                                withDot: Bool = true) -> CGFloat {
        let label = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold),
            .foregroundColor: color,
        ])
        let size = label.size()
        let textX = rightEdge - 8 - size.width
        var leftEdge = textX
        if withDot {
            let dotSide: CGFloat = 4
            let dotX = textX - dotSide - 4
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: dotX, y: (bounds.height - dotSide) / 2,
                                        width: dotSide, height: dotSide)).fill()
            leftEdge = dotX
        }
        label.draw(at: NSPoint(x: textX, y: (bounds.height - size.height) / 2))
        return leftEdge
    }

    override func mouseUp(with event: NSEvent) {
        guard !dragStarted else { return }
        if event.clickCount == 2 {
            onAction?(.zoom)   // iTerm 惯例：双击头条放大/还原（首击已聚焦该 pane）
        } else {
            onClick?()
        }
    }

    override func layout() {
        super.layout()
        let layout = PaneHeaderControlLayout.layout(
            headerWidth: bounds.width,
            controlCount: controlButtons.count)
        let controlsFrame = layout.buttonFrames.reduce(NSRect.null) { partial, frame in
            partial.union(frame)
        }
        controls.frame = NSRect(
            x: controlsFrame.isNull ? bounds.width : controlsFrame.minX,
            y: controlsFrame.isNull ? 0 : (bounds.height - controlsFrame.height) / 2,
            width: controlsFrame.isNull ? 0 : controlsFrame.width,
            height: controlsFrame.isNull ? 0 : controlsFrame.height
        )
        for (button, frame) in zip(controlButtons, layout.buttonFrames) {
            button.frame = frame.offsetBy(dx: -controls.frame.minX, dy: 0)
            button.symbolPointSize = max(8, frame.width - 6)
        }
        // 「已放大」徽标贴在控制按钮组左侧
        if !zoomBadge.isHidden {
            let badgeWidth = zoomBadge.fittingWidth
            zoomBadge.frame = NSRect(
                x: max(0, controls.frame.minX - badgeWidth - 7),
                y: (bounds.height - PaneZoomBadge.height) / 2,
                width: badgeWidth,
                height: PaneZoomBadge.height
            )
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // 无分隔线、无底色（与卡片融为一体）；仅活动态极淡 accent 染色。
        if isActive {
            NSColor(AppStyle.accent).withAlphaComponent(0.08).setFill()
            bounds.fill()
        }
        var titleX: CGFloat = 11
        if let agentLogo {
            let side: CGFloat = 14
            let logoRect = NSRect(x: 11, y: (bounds.height - side) / 2, width: side, height: side)
            agentLogo.draw(in: logoRect, from: .zero, operation: .sourceOver, fraction: 1)
            titleX = logoRect.maxX + 6
        }
        let label = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: isActive ? .medium : .regular),
            .foregroundColor: NSColor(isActive ? AppStyle.textSecondary : AppStyle.textTertiary),
        ])
        // 标题在状态徽标（思考计时/队列）、放大徽标（若亮）或控制按钮组前截断
        var titleLimit = zoomBadge.isHidden ? controls.frame.minX : zoomBadge.frame.minX
        // 思考计时每秒重绘走表
        if let since = thinkingSince {
            titleLimit = drawStatusChip(Self.thinkingText(since: since),
                                        color: NSColor(AppStyle.accent), rightEdge: titleLimit)
        }
        if queuedCount > 0 {
            titleLimit = drawStatusChip(L("队列 %ld", queuedCount),
                                        color: NSColor(AppStyle.textTertiary), rightEdge: titleLimit,
                                        withDot: false)
        }
        // OSC 9;4 进度徽标：与状态徽标共存（进度在更右侧先画会更挤，放最后画在剩余空间）
        if let progress {
            let (text, color): (String, NSColor) = {
                switch progress.state {
                case .error: return (progress.percent.map { "\($0)%" } ?? L("出错"), NSColor(AppStyle.errorRed))
                case .pause: return (progress.percent.map { "\($0)%" } ?? L("已暂停"), NSColor(AppStyle.textTertiary))
                case .indeterminate: return (L("进行中"), NSColor(AppStyle.accent))
                default: return (progress.percent.map { "\($0)%" } ?? "…", NSColor(AppStyle.accent))
                }
            }()
            titleLimit = drawStatusChip(text, color: color, rightEdge: titleLimit)
        }
        let clip = NSRect(x: titleX, y: 0, width: max(0, titleLimit - titleX - 7), height: bounds.height)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: clip).addClip()
        label.draw(at: NSPoint(x: titleX, y: (bounds.height - label.size().height) / 2))
        NSGraphicsContext.restoreGraphicsState()
    }

    private func setupControls() {
        controls.wantsLayer = true
        controls.layer?.masksToBounds = true

        for action in PaneHeaderActionPresentation.primaryActions {
            let button = PaneHeaderButton(
                symbolName: PaneHeaderActionPresentation.systemImage(for: action),
                label: PaneHeaderActionPresentation.title(for: action),
                action: action
            )
            button.onPress = { [weak self] in self?.onAction?(action) }
            controls.addSubview(button)
            controlButtons.append(button)
        }

        moreButton.onPress = { [weak self] in self?.showMoreMenu(from: self?.moreButton) }
        controls.addSubview(moreButton)
        controlButtons.append(moreButton)
        addSubview(controls)
        restyleButtons()
    }

    private func restyleButtons() {
        for button in controlButtons {
            button.isPaneActive = isActive
        }
    }

    private func showMoreMenu(from sender: PaneHeaderButton?) {
        guard let sender else { return }
        let menu = NSMenu()
        for action in PaneHeaderActionPresentation.moreActions {
            menu.addItem(ClosureMenuItem(
                PaneHeaderActionPresentation.title(for: action),
                systemImage: PaneHeaderActionPresentation.systemImage(for: action)
            ) { [weak self] in
                self?.onAction?(action)
            })
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY - 3), in: sender)
    }
}

@MainActor
private final class PaneHeaderButton: NSView {
    let paneAction: PaneContextAction?
    var onPress: (() -> Void)?
    var isPaneActive = false { didSet { updateAppearance() } }
    var symbolPointSize: CGFloat = 14 { didSet { updateSymbol() } }
    private var hovering = false { didSet { updateAppearance() } }
    private var pressing = false { didSet { updateAppearance() } }
    private var trackingArea: NSTrackingArea?
    private let symbolName: String
    private let label: String
    private let imageView = NSImageView()

    init(symbolName: String, label: String, action: PaneContextAction?) {
        self.symbolName = symbolName
        self.label = label
        self.paneAction = action
        super.init(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        toolTip = label
        setAccessibilityLabel(label)
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        updateSymbol()
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 20, height: 20) }

    override func layout() {
        super.layout()
        let inset = max(2, floor(bounds.width * 0.18))
        imageView.frame = bounds.insetBy(dx: inset, dy: inset)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
    }

    override func mouseDown(with event: NSEvent) {
        pressing = true
        animateScale(0.86)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let shouldFire = bounds.contains(point)
        clearInteractionState()
        animateScale(1)
        if shouldFire { onPress?() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { clearInteractionState() }
    }

    private func clearInteractionState() {
        pressing = false
        hovering = false
    }

    private func updateAppearance() {
        let activeOpacity = isPaneActive ? 0.72 : 0.46
        imageView.contentTintColor = NSColor(isPaneActive ? AppStyle.textSecondary : AppStyle.textTertiary)
            .withAlphaComponent(hovering ? 0.95 : activeOpacity)
        layer?.backgroundColor = (hovering || pressing)
            ? NSColor(AppStyle.hoverFill).cgColor
            : NSColor.clear.cgColor
    }

    private func updateSymbol() {
        let config = NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .medium)
        imageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label)?
            .withSymbolConfiguration(config)
        needsLayout = true
    }

    private func animateScale(_ scale: CGFloat) {
        guard let layer else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = scale == 1 ? 0.16 : 0.08
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        }
    }
}

/// 头条「已放大」胶囊徽标：放大态的显性提示，点击还原（与 ⌘⏎ 同效）。
/// accent 染色胶囊 + 收缩图标 + 文字；hover 提亮。
@MainActor
final class PaneZoomBadge: NSView {
    var onPress: (() -> Void)?
    static let height: CGFloat = 16

    private static var text: String { L("已放大") }
    private static let font = NSFont.systemFont(ofSize: 9.5, weight: .semibold)
    private static let iconSide: CGFloat = 8

    private var hovering = false { didSet { updateAppearance() } }
    private var trackingArea: NSTrackingArea?
    private let iconView = NSImageView()
    private let labelField = NSTextField(labelWithString: PaneZoomBadge.text)

    /// 自适应宽度：图标 + 间隙 + 文字 + 两侧内边距。
    var fittingWidth: CGFloat {
        let textWidth = ceil((Self.text as NSString).size(withAttributes: [.font: Self.font]).width)
        return Self.iconSide + 4 + textWidth + 8 * 2
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Self.height / 2
        layer?.cornerCurve = .continuous
        toolTip = L("点击还原（⌘⏎）")
        setAccessibilityLabel(Self.text)

        let config = NSImage.SymbolConfiguration(pointSize: Self.iconSide, weight: .bold)
        iconView.image = NSImage(systemSymbolName: "arrow.down.right.and.arrow.up.left",
                                 accessibilityDescription: nil)?.withSymbolConfiguration(config)
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)

        labelField.font = Self.font
        labelField.lineBreakMode = .byClipping
        addSubview(labelField)
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        iconView.frame = NSRect(x: 8, y: (bounds.height - Self.iconSide) / 2 - 0.5,
                                width: Self.iconSide, height: Self.iconSide)
        let textX = iconView.frame.maxX + 4
        labelField.frame = NSRect(x: textX, y: 0, width: max(0, bounds.width - textX - 8),
                                  height: bounds.height)
        // labelWithString 自带基线对齐偏差，手动垂直居中
        let textHeight = labelField.cell?.cellSize(forBounds: bounds).height ?? bounds.height
        labelField.frame.origin.y = (bounds.height - textHeight) / 2
        labelField.frame.size.height = textHeight
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) { onPress?() }
    }

    private func updateAppearance() {
        let accent = NSColor(AppStyle.accent)
        layer?.backgroundColor = accent.withAlphaComponent(hovering ? 0.30 : 0.16).cgColor
        iconView.contentTintColor = accent
        labelField.textColor = accent
    }
}
