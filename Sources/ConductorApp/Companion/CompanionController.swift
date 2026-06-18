import AppKit
import Combine
import ConductorCore
import SwiftUI

/// 桌面通知宠物的控制器：订阅 app 里**真实在线**的 agent 活动信号
/// （`thinkingPanes` / `unseenDonePanes` / `feedCenter.pending`），映射成 Core 的
/// `AgentSignal`，交给纯逻辑 `PetStateReducer` 归约出 `PetMood`，再驱动透明浮窗里的宠物。
///
/// 同时是配置中枢：观察 `ConfigStore` 的 `companion` 段（启用/模版/角落/气泡/内联审批），
/// 并把待审批请求暴露给气泡做就地「允许/拒绝」（复用 `FeedCenter`，与右侧面板/ socket 零分叉）。
///
/// 信号源**有意可替换**：今天喂 pane 世界的状态；将来 `BuiltinAgentSession`（pi）接进 app 后，
/// 只需在 `recompute()` 多并一个 `phase` 源，reducer / 视图一行不动。
@MainActor
final class CompanionController: ObservableObject {
    @Published private(set) var mood: PetMood = .idle
    /// 队长头顶的临时卖萌气泡（摸一下）。审批 / 跑完 / 干活都进 `members` 了，这里只剩闲聊。
    @Published private(set) var bubble: String?
    @Published private(set) var config: CompanionConfig
    /// 点宠物时自增 → 视图弹一下（点击反馈）。
    @Published private(set) var pokeNonce = 0

    /// 在线会话们（每个一颗头顶光点）。一只宠物罩多会话，不分身。
    @Published private(set) var members: [CompanionMember] = []
    /// 容量外被折叠掉的会话数（→ "+N" 光点，点了在它们之间轮转聚焦）。
    @Published private(set) var rosterOverflow = 0
    /// 宠物当前替哪个会话开口（说话/批准）。默认最急的；点头顶光点可切。
    @Published private(set) var activeMemberID: String?
    /// 用户显式点过的会话（在它还在线期间黏住，盖过"默认最急"）。
    private var userPickedID: String?

    /// 当前被宠物"代言"的会话。
    var activeMember: CompanionMember? {
        guard let id = activeMemberID else { return nil }
        return members.first { $0.id == id }
    }

    /// 每个 pane 最近一次 AI 完成的真实回复全文（带过期）——跑完那行直接显示，点进去看全文。
    /// 新一轮开始干活、或窗口过期则清。
    private var results: [String: (text: String, until: TimeInterval)] = [:]
    private static let resultWindow: TimeInterval = 20

    /// 摸一下的临时卖萌气泡。
    private var quip: String?
    private var quipUntil: TimeInterval?

    /// 窗口宽固定；高随小队行数增长（见 `desiredWindowHeight`）。
    static let windowWidth: CGFloat = 252
    /// 「队长命中区」高度：这块归原生 NSView（拖拽 + 点击跳转），固定占 pet 边的这一截；
    /// 小队行落在另一侧的 SwiftUI 区（按钮可点）。见 `CompanionPanelContentView.hitTest`。
    static let petZoneHeight: CGFloat = 104
    /// 最多同时显示几行小队；超出折叠成 "+N"。
    static let maxVisibleMembers = 5
    static let rowSpacing: CGFloat = 7
    /// 折叠态（无小队）窗口基准尺寸。
    static var windowSize: CGSize { CGSize(width: windowWidth, height: petZoneHeight + 8) }
    private static let frameAutosaveName = "ConductorCompanionWindow"

    private weak var coordinator: AppCoordinator?
    private let feedCenter: FeedCenter
    private var reducer = PetStateReducer()

    /// 顶部角落 → 队长贴窗口顶端、小队向下长；底部角落 → 队长贴底、小队向上长。
    var petAtTop: Bool { config.corner == .topLeft || config.corner == .topRight }

    private var panel: NSPanel?
    /// 始终在的订阅（只观察配置，用来起停下面的"活动订阅"）。
    private var cancellables: Set<AnyCancellable> = []
    /// 仅"启用"时挂的订阅（信号源 sink）；停用即全撤，不空转。
    private var activeCancellables: Set<AnyCancellable> = []
    private var tick: Timer?

    /// 选中宠物若是 Codex 图集，这里是已加载的图集；nil = 用程序化模版渲染。
    @Published private(set) var atlasSheet: CGImage?
    /// 程序化兜底模版（atlasSheet 为 nil 时用）。
    private(set) var proceduralTemplate: PetTemplate = PetTemplateCatalog.default
    private var resolvedPetName: String = L(PetTemplateCatalog.default.nameKey)
    private var petLoadGeneration = 0

    var displayName: String {
        if let n = config.name, !n.isEmpty { return n }
        return resolvedPetName
    }

    /// 把 `config.templateID` 解析成具体渲染源（内置程序化 / 发现到的 Codex 图集）。
    private func resolvePet() {
        petLoadGeneration &+= 1
        let generation = petLoadGeneration
        let pet = CompanionPetCatalog.pet(id: config.templateID)
        let templateID = pet.id
        resolvedPetName = pet.name
        switch pet.kind {
        case let .procedural(template):
            proceduralTemplate = template
            atlasSheet = nil
        case let .atlas(url):
            if let sheet = CodexPetCatalog.preparedSheet(at: url) {
                atlasSheet = sheet
                return
            }

            // 第一次切到某个 Codex 图集时，解码 + 切 8×9 动画帧都比较贵。
            // 放到后台做，完成后再发布给 SwiftUI，避免点击设置卡片时主线程卡一下。
            DispatchQueue.global(qos: .userInitiated).async { [url, generation, templateID] in
                let sheet = CodexPetCatalog.prepareSheet(at: url)
                Task { @MainActor [weak self] in
                    guard let self,
                          self.petLoadGeneration == generation,
                          self.config.templateID == templateID else { return }
                    if let sheet {
                        self.atlasSheet = sheet
                    } else {                           // 加载失败 → 程序化兜底，不空屏
                        self.proceduralTemplate = PetTemplateCatalog.default
                        self.atlasSheet = nil
                    }
                }
            }
        }
    }

    init(coordinator: AppCoordinator, feedCenter: FeedCenter) {
        self.coordinator = coordinator
        self.feedCenter = feedCenter
        self.config = ConfigStore.shared.config.companion
    }

    // MARK: 启动 / 配置

    /// 启动调用：始终观察配置（用来起停活动订阅），按配置决定是否显示与挂载活动订阅。
    func activate() {
        guard cancellables.isEmpty else { return }   // 防重复 activate
        CodexPetCatalog.ensureDropFolder()       // 备好 ~/.config/conductor/pets/ 投放点（社区宠物丢这里即认）
        ConfigStore.shared.$config
            .map(\.companion)
            .removeDuplicates()
            .sink { [weak self] companion in MainActor.assumeIsolated { self?.applyConfig(companion) } }
            .store(in: &cancellables)
        applyConfig(config, isInitial: true)
    }

    // MARK: AI 会话通知

    private func handleNotice(paneID: String?, title: String, body: String) {
        guard CompanionConfig.shouldDeliverToPet(notifyPet: config.notifyPet) else { return }  // 伙伴通知关 → 宠物不冒通知
        let text = Self.noticeText(title: title, body: body)
        // 回复挂到**具体会话**那一行上（多会话各显各的）；无 pane 归属的通知交给系统横幅，不上小队。
        guard !text.isEmpty, let paneID, !paneID.isEmpty else { return }
        results[paneID] = (text, Date().timeIntervalSinceReferenceDate + Self.resultWindow)
        recompute()                              // 立刻把真实回复顶上来
    }

    /// 通知气泡文案：优先正文（agent 真回复，保留全文给展开），空则用标题。可单测。
    nonisolated static func noticeText(title: String, body: String) -> String {
        let b = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return b.isEmpty ? title.trimmingCharacters(in: .whitespaces) : b
    }

    /// 启用时才挂：信号源 sink + 通知出口 + 周期 tick。停用时全撤——不空转、不抢占全局 onNotify。
    private func startActive() {
        guard tick == nil else { return }   // 已在跑
        // 接「AI 会话通知」总出口（onNotify 现为 @MainActor 闭包，无需 assumeIsolated）。
        NotificationManager.shared.onNotify = { [weak self] paneID, title, body in
            self?.handleNotice(paneID: paneID, title: title, body: body)
        }
        coordinator?.$thinkingPanes
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.recompute() } }
            .store(in: &activeCancellables)
        coordinator?.$unseenDonePanes
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.recompute() } }
            .store(in: &activeCancellables)
        feedCenter.$pending
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.recompute() } }
            .store(in: &activeCancellables)
        // 周期 tick：驱动 reducer 的时序回落（庆祝→idle、idle→打盹），信号不变也要推进。
        tick = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.recompute() }
        }
        recompute()
    }

    private func stopActive() {
        guard tick != nil else { return }
        NotificationManager.shared.onNotify = nil   // 让出全局单槽
        activeCancellables.removeAll()
        tick?.invalidate(); tick = nil
    }

    private func applyConfig(_ new: CompanionConfig, isInitial: Bool = false) {
        let old = config
        config = new
        if isInitial || old.templateID != new.templateID { resolvePet() }
        if new.enabled {
            startActive()
            showWindowIfNeeded()
        } else {
            stopActive()
            hide()
        }
        // 角落设置变化 → 把窗口挪过去（用户手动拖动的位置由窗口自存档保留，仅此显式覆盖）。
        if !isInitial, old.corner != new.corner { repositionToCorner(new.corner) }
        if new.enabled { recompute() }
    }

    /// 菜单/设置开关：翻转 enabled 并落盘（经 coordinator → ConfigStore → 回调 applyConfig）。
    func toggleEnabled() {
        var cfg = ConfigStore.shared.config
        cfg.companion.enabled.toggle()
        coordinator?.applyConfig(cfg)
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    // MARK: 窗口

    private func showWindowIfNeeded() {
        let p = panel ?? makePanel()
        if !p.isVisible { p.orderFrontRegardless() }
    }

    func hide() { panel?.orderOut(nil) }

    private func makePanel() -> NSPanel {
        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.ignoresMouseEvents = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = CompanionPanelContentView(controller: self)
        p.setFrameAutosaveName(Self.frameAutosaveName)
        panel = p
        if p.frame.origin == .zero { repositionToCorner(config.corner) }   // 没有存档位置 → 落到配置角落
        return p
    }

    private func repositionToCorner(_ corner: CompanionConfig.Corner) {
        let p = panel ?? makePanel()
        guard let vf = NSScreen.main?.visibleFrame else { return }
        let m: CGFloat = 24, w = Self.windowWidth, h = desiredWindowHeight()
        let x = (corner == .topLeft || corner == .bottomLeft) ? vf.minX + m : vf.maxX - w - m
        let y = (corner == .topLeft || corner == .topRight) ? vf.maxY - h - m : vf.minY + m
        p.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        p.saveFrame(usingName: Self.frameAutosaveName)
    }

    // MARK: 动态高度（随光点/飘字内容增长，队长锚点不动）

    static let dotsRowHeight: CGFloat = 26
    static let quipRowHeight: CGFloat = 26

    /// 当前会话飘字块的高度——须与视图里 `speech(for:)` 的实际高度对上(略宽出，避免窗口裁切)。
    static func speechHeight(_ member: CompanionMember?) -> CGFloat {
        guard let member else { return 0 }
        switch member.state {
        case .working: return 24
        case let .done(reply): return (reply?.isEmpty == false) ? 50 : 26
        case .needsApproval: return 86
        }
    }

    /// 窗口高度 = 队长占位 + 头顶光晕（飘字块 + 光点排 / 或仅卖萌）+ 间距。
    private func desiredWindowHeight() -> CGFloat {
        var aura: CGFloat = 0
        if !members.isEmpty {
            aura = Self.speechHeight(activeMember) + Self.rowSpacing + Self.dotsRowHeight
        } else if bubble != nil {
            aura = Self.quipRowHeight
        }
        let gap: CGFloat = aura > 0 ? Self.rowSpacing : 0
        return Self.petZoneHeight + 8 + (aura > 0 ? aura + gap : 0)
    }

    /// 把窗口高度调到刚好放下小队，并保持队长锚点不动：
    /// 顶部角落锚住上边（队长贴顶、小队向下长）；底部角落锚住下边（队长贴底、小队向上长）。
    private func relayoutPanel() {
        guard let p = panel, p.isVisible else { return }
        let newH = desiredWindowHeight()
        let cur = p.frame
        guard abs(cur.height - newH) > 0.5 else { return }
        var origin = cur.origin
        if petAtTop { origin.y = (cur.origin.y + cur.height) - newH }   // 顶边固定
        if let vf = (p.screen ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, vf.minX), max(vf.minX, vf.maxX - Self.windowWidth))
            origin.y = min(max(origin.y, vf.minY), max(vf.minY, vf.maxY - newH))
        }
        p.setFrame(NSRect(origin: origin, size: CGSize(width: Self.windowWidth, height: newH)),
                   display: true, animate: true)
    }

    // MARK: 信号 → 心情

    /// 把 pane 世界的三组状态压成一帧 `AgentSignal`（纯函数，可单测）。
    nonisolated static func signal(thinking: Bool, done: Bool, pending: Int) -> AgentSignal {
        let activity: AgentSignal.Activity
        if thinking {
            activity = .working
        } else if done {
            activity = .ready
        } else {
            activity = .idle
        }
        return AgentSignal(activity: activity, pendingApprovals: pending)
    }

    /// 把 pane 世界的多组状态合并成"小队"：每个在线会话一员，审批/跑完/干活各成一行；
    /// 同一 pane 有待审批就只显示审批（盖过它的 working/done），在跑的 pane 旧结果作废。
    /// 纯函数，可单测。`cap` 外的按 `keepPriority`（审批>跑完>干活）折叠成 `overflow`。
    nonisolated static func buildRoster(
        thinking: [String],
        done: [String],
        feedPending: [FeedRequest],
        terminalApprovals: [FeedRequest],
        results: [String: String],
        titles: [String: String],
        fallbackTitle: String,
        cap: Int
    ) -> CompanionRoster {
        func title(forPane pane: String?) -> String {
            guard let pane, let t = titles[pane], !t.isEmpty else { return fallbackTitle }
            return t
        }

        // 1) 审批成员（feed 队列 + 终端嗅探），按 request.id 去重；记下被占用的 pane。
        var approvals: [CompanionMember] = []
        var approvalPanes = Set<String>()
        var seenRequests = Set<String>()
        func addApproval(_ req: FeedRequest, terminal: Bool) {
            guard seenRequests.insert(req.id).inserted else { return }
            if let p = req.paneID { approvalPanes.insert(p) }
            let name = title(forPane: req.paneID)
            approvals.append(CompanionMember(
                id: "approval:\(req.id)", paneID: req.paneID,
                title: name == fallbackTitle ? (req.tool ?? fallbackTitle) : name,
                state: .needsApproval(request: req, terminal: terminal)))
        }
        feedPending.forEach { addApproval($0, terminal: false) }
        terminalApprovals.forEach { addApproval($0, terminal: true) }

        let thinkingSet = Set(thinking)

        // 2) 干活成员：在思考、且没有待审批的 pane。
        let working = thinking.filter { !approvalPanes.contains($0) }.sorted().map {
            CompanionMember(id: "pane:\($0)", paneID: $0, title: title(forPane: $0), state: .working)
        }

        // 3) 跑完成员：跑完未读 ∪ 有新鲜回复的 pane，去掉在审批/在思考的（思考=新一轮，旧结果作废）。
        var donePanes: [String] = []
        var seenDone = Set<String>()
        for p in done + Array(results.keys)
        where !approvalPanes.contains(p) && !thinkingSet.contains(p) && seenDone.insert(p).inserted {
            donePanes.append(p)
        }
        let doneMembers = donePanes.sorted().map {
            CompanionMember(id: "pane:\($0)", paneID: $0, title: title(forPane: $0),
                            state: .done(reply: results[$0]))
        }

        // 4) 按 keepPriority 裁剪（审批 > 跑完 > 干活），再按 displayRank 排展示序（审批贴队长）。
        let prioritized = approvals + doneMembers + working
        let shown = Array(prioritized.prefix(max(0, cap)))
        let overflow = prioritized.count - shown.count
        let display = shown.sorted {
            $0.displayRank != $1.displayRank ? $0.displayRank < $1.displayRank : $0.id < $1.id
        }
        return CompanionRoster(members: display, overflow: overflow)
    }

    private func recompute() {
        guard let coordinator else { return }
        let now = Date().timeIntervalSinceReferenceDate

        results = results.filter { $0.value.until > now }              // 过期回复先清

        let thinking = coordinator.thinkingPanes
        let doneSet = coordinator.unseenDonePanes
        let terminalApprovals = detectTerminalApprovals(in: coordinator)
        let pending = feedCenter.pending.count + terminalApprovals.count

        // 队长心情 = 全队聚合（沿用既有 signal + reducer 的优先级归约：审批 > 失败 > 干活 > 庆祝 …）。
        let signal = Self.signal(thinking: !thinking.isEmpty, done: !doneSet.isEmpty, pending: pending)
        let newMood = reducer.reduce(signal, now: now)
        if newMood != mood { mood = newMood }

        var titles: [String: String] = [:]
        for (pane, t) in coordinator.paneTitles where !t.isEmpty { titles[pane.value] = t }
        // 还没拿到标题的活跃 pane（刚起、标题未落）→ 用 agent 名兜底，别露生硬的"会话"。
        for pane in thinking.union(doneSet) where titles[pane.value] == nil {
            if let a = coordinator.paneAgents[pane], !a.isEmpty { titles[pane.value] = a.capitalized }
        }

        let roster = Self.buildRoster(
            thinking: thinking.map(\.value),
            done: doneSet.map(\.value),
            feedPending: feedCenter.pending,
            terminalApprovals: terminalApprovals,
            results: results.mapValues { $0.text },
            titles: titles,
            fallbackTitle: L("会话"),
            cap: Self.maxVisibleMembers)
        if roster.members != members { members = roster.members }
        if roster.overflow != rosterOverflow { rosterOverflow = roster.overflow }

        // 代言谁：用户点过且还在线 → 黏住；否则默认最急的。
        let pick: String?
        if let picked = userPickedID, roster.members.contains(where: { $0.id == picked }) {
            pick = picked
        } else {
            userPickedID = nil
            pick = Self.mostUrgent(roster.members)?.id
        }
        if pick != activeMemberID { activeMemberID = pick }

        // 队长气泡：审批/结果都进 roster 了，这里只剩"摸一下"的卖萌（受 speechBubbles 开关）。
        let quipText = (config.speechBubbles && (quipUntil.map { now < $0 } ?? false)) ? quip : nil
        if quipText != bubble { bubble = quipText }

        relayoutPanel()
    }

    // MARK: 交互

    /// 点队长本体：弹一下（反馈）+ 拉前台 + 跳到全队最值得看处
    /// （待审批 → 跑完 → 在思考；都没有 → 摸一下回应）。
    func handleTap() {
        pokeNonce &+= 1
        guard let coordinator else { return }
        NSApp.activate(ignoringOtherApps: true)
        if let approval = members.first(where: { if case .needsApproval = $0.state { return true }; return false }),
           let pid = approval.paneID, !pid.isEmpty {
            coordinator.revealPane(PaneID(pid))
        } else if let pane = coordinator.unseenDonePanes.sorted(by: { $0.value < $1.value }).first {
            coordinator.revealPane(pane)
        } else if let pane = coordinator.thinkingPanes.sorted(by: { $0.value < $1.value }).first {
            coordinator.revealPane(pane)
        } else {
            poke()
        }
    }

    /// 摸一下的回应：短暂卖萌气泡（弹一下由 handleTap 的 pokeNonce 触发）。
    private func poke() {
        guard config.speechBubbles else { return }
        quip = [L("在呢"), L("嗯?"), L("喵~"), L("戳啥")].randomElement() ?? L("在呢")
        quipUntil = Date().timeIntervalSinceReferenceDate + 1.6
        recompute()
    }

    /// 某个会话行的就地审批（复用 FeedCenter / 终端按键，与右侧面板/socket 同一套闸）。
    func resolve(_ decision: FeedDecision, for member: CompanionMember) {
        guard case let .needsApproval(request, terminal) = member.state else { return }
        if terminal {
            resolveTerminalApproval(request, decision: decision)
        } else {
            _ = feedCenter.resolve(id: request.id, decision: decision)   // recompute 由 feedCenter.$pending 回调触发
        }
    }

    /// 点某行 → 拉前台并跳到那个会话；跑完行点完即清（那行随之消失）。
    func jump(to member: CompanionMember) {
        pokeNonce &+= 1
        guard let coordinator, let pid = member.paneID, !pid.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        coordinator.revealPane(PaneID(pid))
        if case .done = member.state { results[pid] = nil; recompute() }
    }

    /// "+N" 片：在被折叠掉的会话间轮转聚焦（复用状态栏中枢的轮转逻辑）。
    func cycleOverflow() {
        NSApp.activate(ignoringOtherApps: true)
        coordinator?.revealNextAttentionPane()
    }

    /// 点头顶某颗光点 → 宠物切过去替那个会话说话（黏住直到它下线）。
    func focusSession(_ id: String) {
        pokeNonce &+= 1
        guard members.contains(where: { $0.id == id }) else { return }
        userPickedID = id
        if activeMemberID != id { activeMemberID = id; relayoutPanel() }
    }

    /// 默认代言谁：最急的（keepPriority 最高，审批 > 跑完 > 干活）。
    private static func mostUrgent(_ members: [CompanionMember]) -> CompanionMember? {
        members.max { $0.keepPriority < $1.keepPriority }
    }

    /// 嗅探所有在思考的 pane 里"Codex 终端就地审批"提示（每个独立成一员）。
    private func detectTerminalApprovals(in coordinator: AppCoordinator) -> [FeedRequest] {
        var out: [FeedRequest] = []
        for pane in coordinator.thinkingPanes.sorted(by: { $0.value < $1.value }) {
            guard let surface = coordinator.registry.surface(for: pane) as? GhosttySurface,
                  let text = surface.readViewportText(),
                  let request = Self.codexTerminalApproval(from: text, paneID: pane.value, cwd: coordinator.paneCwds[pane])
            else { continue }
            out.append(request)
        }
        return out
    }

    private func resolveTerminalApproval(_ request: FeedRequest, decision: FeedDecision) {
        guard let coordinator, let pid = request.paneID else { return }
        let pane = PaneID(pid)
        guard let surface = coordinator.registry.surface(for: pane) as? GhosttySurface else { return }
        coordinator.revealPane(pane)
        switch decision {
        case .allow(.once):
            surface.sendTextInput("y")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak surface] in
                surface?.sendEnterKey()
            }
        case .allow:
            surface.sendTextInput("p")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak surface] in
                surface?.sendEnterKey()
            }
        case .deny, .answer:
            surface.sendEscapeKey()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated { self?.recompute() }
        }
    }

    nonisolated static func codexTerminalApproval(from text: String, paneID: String, cwd: String?) -> FeedRequest? {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.contains("Would you like to run the following command?"),
              normalized.contains("Press enter to confirm") || normalized.contains("Yes, proceed")
        else { return nil }

        let command = codexApprovalCommand(in: normalized)
        return FeedRequest(
            id: "codex-terminal:\(paneID):\(command ?? "unknown")",
            paneID: paneID,
            agent: "codex",
            cwd: cwd,
            kind: .permission(tool: "Codex", category: .executeCommand, detail: command),
            createdAt: Date(timeIntervalSinceReferenceDate: 0)
        )
    }

    private nonisolated static func codexApprovalCommand(in text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let shellLine = lines.last(where: { $0.hasPrefix("$ ") }) {
            let command = shellLine.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines)
            if !command.isEmpty { return command }
        }
        guard let regex = try? NSRegularExpression(pattern: "`([^`]+)`") else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let commandRange = Range(match.range(at: 1), in: text) else { return nil }
        let command = String(text[commandRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? nil : command
    }

    // MARK: 右键菜单动作

    func availablePets() -> [CompanionPet] { CompanionPetCatalog.all() }
    var selectedPetID: String { config.templateID }

    func selectPet(id: String) {
        guard config.templateID != id else { return }
        var cfg = ConfigStore.shared.config
        cfg.companion.templateID = id
        coordinator?.applyConfig(cfg)
    }

    func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        coordinator?.openSettings()
    }

    func hidePet() {
        var cfg = ConfigStore.shared.config
        cfg.companion.enabled = false
        coordinator?.applyConfig(cfg)
    }
}

/// 浮窗内容视图：**底部精灵区**原生处理拖拽（`performDrag`，窗口服务器整窗平滑移动，
/// 无 setFrameOrigin 反馈环 → 不闪）与点击；**上方气泡/审批卡区**把事件交回 SwiftUI（按钮可点）。
private final class CompanionPanelContentView: NSView {
    private weak var controller: CompanionController?
    private var didDrag = false

    init(controller: CompanionController) {
        self.controller = controller
        super.init(frame: NSRect(origin: .zero, size: CompanionController.windowSize))
        let host = NSHostingView(rootView: CompanionView(controller: controller))
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        // 队长命中区随角落落在底部或顶部（y=0 在底）：这块归原生（拖拽/点击）；
        // 另一侧的小队行交回 SwiftUI（按钮可点）。
        let zone = CompanionController.petZoneHeight
        let inPetZone = (controller?.petAtTop ?? false)
            ? local.y >= bounds.height - zone
            : local.y <= zone
        if inPetZone { return self }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) { didDrag = false }

    override func mouseDragged(with event: NSEvent) {
        guard !didDrag else { return }
        didDrag = true
        window?.performDrag(with: event)     // 原生拖拽，平滑无闪
    }

    override func mouseUp(with event: NSEvent) {
        if !didDrag { controller?.handleTap() }
    }

    // 右键/Ctrl 点 → 上下文菜单（换宠物 / 设置 / 隐藏）。
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let controller else { return nil }
        let menu = NSMenu()

        let petsItem = NSMenuItem(title: L("换宠物"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for pet in controller.availablePets() {
            let item = NSMenuItem(title: pet.name, action: #selector(selectPetItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = pet.id
            item.state = (pet.id == controller.selectedPetID) ? .on : .off
            sub.addItem(item)
        }
        petsItem.submenu = sub
        menu.addItem(petsItem)
        menu.addItem(.separator())

        let settings = NSMenuItem(title: L("伙伴设置…"), action: #selector(openSettingsItem), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        let hide = NSMenuItem(title: L("隐藏伙伴"), action: #selector(hideItem), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)
        return menu
    }

    @objc private func selectPetItem(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { controller?.selectPet(id: id) }
    }
    @objc private func openSettingsItem() { controller?.openSettings() }
    @objc private func hideItem() { controller?.hidePet() }
}
