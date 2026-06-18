import AppKit
import ConductorCore
import SwiftUI

/// 侧栏列表模式：固定的工作区列表，或从家目录开始的文件夹树。
enum SidebarListMode: String {
    case workspaces
    case folders
}

/// 左侧工作区栏（自绘，深色 Craft 风）：列出工作区；点击切换，`+` 选目录新建，active 高亮。
/// 分区头可切到「文件夹」模式：家目录文件夹树，点击展开下级、右键/悬停按钮在该目录开终端。
/// 右键菜单可重命名（行内编辑）/ 删除工作区。
struct SidebarView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject private var configStore = ConfigStore.shared   // 主题变 → 重渲染（AppStyle 跟随）
    @ObservedObject private var sessionStore = SessionManagerStore.shared
    @State private var editingWorkspace: WorkspaceID?
    @State private var draftName: String = ""
    @FocusState private var renameFocused: Bool
    @State private var hoverRecord: AgentSessionRecord?
    @State private var hoverPanelPinned = false
    @State private var hoverTask: Task<Void, Never>?
    /// 一次性引导：用户首次触发悬停预览后永久隐藏提示。
    @AppStorage("sidebar.sessionHoverHintSeen") private var hoverHintSeen = false
    /// AI 会话开关：开了在每个工作区下方内嵌它自己的最近会话，关了只看工作区。
    @AppStorage("sidebar.showSessions") private var showSessions = true
    /// 按工作区收起的会话列表（逗号分隔的 workspace id，持久化）。
    @AppStorage("sidebar.collapsedSessionLists") private var collapsedSessionListsRaw = ""
    /// 「展开显示」临时放开条数限制的工作区（会话内联展开，不持久化）。
    @State private var inlineExpandedSessionLists: Set<String> = []

    private var collapsedSessionLists: Set<String> {
        Set(collapsedSessionListsRaw.split(separator: ",").map(String.init))
    }

    private func toggleSessionListCollapsed(_ id: WorkspaceID) {
        var set = collapsedSessionLists
        if set.contains(id.value) { set.remove(id.value) } else { set.insert(id.value) }
        collapsedSessionListsRaw = set.sorted().joined(separator: ",")
    }
    /// Finder 文件夹正悬在侧栏上方（释放即新建工作区）→ 整栏亮接收态。
    @State private var folderDropTargeted = false
    /// 文件夹树状态（展开集合 + 懒加载缓存），与侧栏同生命周期。
    @StateObject private var folderTree = FolderTreeModel()
    /// 分段控件选中底块的滑动动画命名空间。
    @Namespace private var modeTabNamespace

    /// 列表模式由 coordinator 持有：切模式时右侧整套标签/分屏跟着换上下文。
    private var listMode: SidebarListMode {
        coordinator.sidebarListMode
    }

    var body: some View {
        sidebarContent
    }

    private var sidebarContent: some View {
        VStack(alignment: isCollapsed ? .center : .leading, spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    if !isCollapsed, listMode == .folders {
                        SidebarFolderTree(coordinator: coordinator, model: folderTree)
                            .padding(.horizontal, 10)
                            .padding(.top, 2)
                    } else {
                        workspaceList
                    }
                }
                .scrollIndicators(.never)   // `.hidden` 在系统“始终显示滚动条”下仍会画 legacy 滚动条
                // 「定位当前目录」：等展开后的行上树再滚（Lazy 容器需要一拍布局）
                .onChange(of: folderTree.revealRequest) { _, request in
                    guard let request else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        withAnimation(Motion.panel) {
                            proxy.scrollTo(request.path, anchor: .center)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
        // 侧栏与底部状态栏共用根背景；和内容区之间不再额外画分割线。
        .background(.clear)
        // 从 Finder 拖文件夹进来 → 新建工作区（同路径已存在则直接切过去）
        .dropDestination(for: URL.self) { urls, _ in
            handleFolderDrop(urls)
        } isTargeted: { folderDropTargeted = $0 }
        .overlay {
            if folderDropTargeted {
                ZStack {
                    Rectangle().fill(AppStyle.accent.opacity(0.07))
                    Rectangle().strokeBorder(AppStyle.accent.opacity(0.6), lineWidth: 2)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: folderDropTargeted)
        // 点走输入框即提交重命名
        .onChange(of: renameFocused) { _, focused in
            if !focused, editingWorkspace != nil { commitRename() }
        }
        .onChange(of: coordinator.sidebarPresentation.isCollapsed) { _, collapsed in
            if collapsed, editingWorkspace != nil { commitRename() }
        }
        .clipShape(Rectangle())
    }

    private var workspaceList: some View {
        VStack(alignment: isCollapsed ? .center : .leading, spacing: 5) {
            let workspaces = coordinator.visibleWorkspaces
            ForEach(Array(workspaces.enumerated()), id: \.element.id) { index, ws in
                let selected = ws.id == coordinator.store.activeWorkspace
                let summary = SidebarWorkspaceSummary(
                    workspace: ws,
                    isSelected: selected,
                    paneTitles: coordinator.paneTitles,
                    paneCwds: coordinator.paneCwds
                )
                let sessionRecords: [AgentSessionRecord] = (!isCollapsed && showSessions)
                    ? ownedSessions(
                        for: ws,
                        fetch: inlineExpandedSessionLists.contains(ws.id.value) ? 31 : 6)
                    : []
                let sessionsCollapsed: Bool? = sessionRecords.isEmpty
                    ? nil
                    : collapsedSessionLists.contains(ws.id.value)
                let row = WorkspaceRow(
                    name: ws.name,
                    summary: summary,
                    selected: selected,
                    isThinking: coordinator.isWorkspaceThinking(ws),
                    unseenDoneCount: coordinator.workspaceUnseenDoneCount(ws),
                    isEditing: editingWorkspace == ws.id,
                    isCollapsed: isCollapsed,
                    sessionsCollapsed: sessionsCollapsed,
                    draft: $draftName,
                    focused: $renameFocused,
                    onSelect: { if editingWorkspace == nil { coordinator.selectWorkspace(ws.id) } },
                    onCommit: { commitRename() },
                    onToggleSessions: {
                        withAnimation(Motion.panel) { toggleSessionListCollapsed(ws.id) }
                    }
                )
                .contextMenu {
                    ForEach(coordinator.launchableAgents) { agent in
                        Button {
                            coordinator.launchAIAgentSession(agent, workspaceID: ws.id, cwd: ws.path)
                        } label: {
                            Label(
                                AIAgentMenuPresentation.sessionTitle(for: agent),
                                systemImage: AIAgentMenuPresentation.menuSystemImage(for: agent))
                        }
                    }
                    if !coordinator.launchableAgents.isEmpty {
                        Divider()
                    }
                    Button { beginRename(ws) } label: { Label(L("重命名"), systemImage: "pencil") }
                    Button { coordinator.revealInFinder(ws.path) } label: {
                        Label(L("在 Finder 中显示"), systemImage: "folder")
                    }
                    Button { coordinator.copyToClipboard(ws.path) } label: {
                        Label(L("复制路径"), systemImage: "doc.on.doc")
                    }
                    Button { reauthorizeWorkspace(ws) } label: {
                        Label(L("重新授权目录"), systemImage: "lock.open")
                    }
                    Divider()
                    Button(role: .destructive) { confirmRemoveWorkspace(ws) } label: {
                        Label(L("删除工作区"), systemImage: "trash")
                    }
                    .disabled(workspaces.count <= 1)
                }

                // 仅多个工作区时才挂拖拽重排（单个无处可排，且避免与点击争手势）
                if workspaces.count > 1, editingWorkspace == nil {
                    row
                        .draggable(ws.id.value)
                        .dropDestination(for: String.self) { dropped, _ in
                            guard let s = dropped.first else { return false }
                            coordinator.moveWorkspace(WorkspaceID(s), toIndex: index)
                            return true
                        }
                } else {
                    row
                }

                // 会话列表在卡片外面、紧贴下方（折叠箭头在工作区行里）
                if sessionsCollapsed == false {
                    workspaceSessionList(for: ws, records: sessionRecords, selected: selected)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .padding(.horizontal, isCollapsed ? 8 : 10)
        .padding(.top, 2)
        .animation(Motion.panel, value: collapsedSessionListsRaw)
        .animation(Motion.panel, value: showSessions)
    }

    /// 悬停预览绑定：popover 是独立 NSWindow，能浮在终端区的 Metal 视图之上
    /// （SwiftUI 越界 overlay 会被 ghostty 的 AppKit 视图盖住，所以不能画在侧栏内）。
    private func hoverPreviewBinding(for record: AgentSessionRecord) -> Binding<Bool> {
        Binding(
            get: { hoverRecord?.id == record.id },
            set: { presented in
                if !presented, hoverRecord?.id == record.id { hoverRecord = nil }
            }
        )
    }

    private func handleSessionHover(_ record: AgentSessionRecord, inside: Bool) {
        hoverTask?.cancel()
        if inside {
            SessionPreviewCache.shared.prefetch(record)
            hoverTask = Task {
                try? await Task.sleep(nanoseconds: 280_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    hoverRecord = record
                    // 预览已出现，引导完成使命
                    if !hoverHintSeen {
                        withAnimation(.easeOut(duration: 0.3)) { hoverHintSeen = true }
                    }
                }
            }
        } else if !hoverPanelPinned {
            // 留出从行移入 popover 的时间，否则中途就被关掉
            scheduleClearHover(after: 0.25)
        }
    }

    private func scheduleClearHover(after seconds: Double) {
        hoverTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if !hoverPanelPinned { hoverRecord = nil }
            }
        }
    }

    private var isCollapsed: Bool { coordinator.sidebarPresentation.isCollapsed }

    private var header: some View {
        VStack(alignment: isCollapsed ? .center : .leading, spacing: 0) {
            // 品牌头：应用名（无 logo）
            HStack(spacing: 0) {
                if !isCollapsed {
                    Text("Conductor")
                        .font(.system(size: 16, weight: .bold))
                        .tracking(0.2)
                        .foregroundStyle(AppStyle.textPrimary)
                    Spacer()
                }
                IconOnlyButton(
                    systemName: isCollapsed ? "sidebar.right" : "sidebar.left",
                    help: isCollapsed ? L("展开侧边栏") : L("收起侧边栏"),
                    size: 28,
                    symbolSize: 13) {
                        coordinator.toggleSidebar()
                    }
            }
            .frame(maxWidth: .infinity, alignment: isCollapsed ? .center : .leading)
            .padding(.horizontal, isCollapsed ? 0 : 16)
            .padding(.top, 24)
            .padding(.bottom, 12)

            // 工作区分区头
            if isCollapsed {
                IconOnlyButton(
                    systemName: "bubble.left.and.text.bubble.right",
                    help: L("Agent 会话"),
                    size: 30,
                    symbolSize: 12) {
                    let path = coordinator.store.workspaces
                        .first(where: { $0.id == coordinator.store.activeWorkspace })?.path
                    coordinator.openSessionManager(scopePath: path)
                }
                IconOnlyButton(
                    systemName: "plus",
                    help: L("新增工作区"),
                    size: 30,
                    symbolSize: 12,
                    action: addWorkspace)
                .padding(.bottom, 6)
            } else {
                HStack(spacing: 8) {
                    listModeSwitcher
                    Spacer(minLength: 4)
                    if listMode == .workspaces {
                        IconOnlyButton(
                            systemName: showSessions
                                ? "bubble.left.and.text.bubble.right.fill"
                                : "bubble.left.and.text.bubble.right",
                            help: showSessions ? L("隐藏 AI 会话") : L("显示 AI 会话"),
                            size: 24,
                            symbolSize: 11,
                            tint: showSessions ? AppStyle.accent : AppStyle.textSecondary) {
                            withAnimation(Motion.panel) { showSessions.toggle() }
                        }
                        .transition(.scale.combined(with: .opacity))
                        IconOnlyButton(
                            systemName: "plus",
                            help: L("新增工作区"),
                            size: 24,
                            symbolSize: 12,
                            action: addWorkspace)
                        .transition(.scale.combined(with: .opacity))
                    } else {
                        IconOnlyButton(
                            systemName: "scope",
                            help: L("在树中定位当前终端目录"),
                            size: 24,
                            symbolSize: 12,
                            action: locateActiveDirectory)
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .padding(.leading, 12)
                .padding(.trailing, 10)
                .padding(.bottom, 8)
                .animation(Motion.panel, value: listMode)
            }
        }
    }

    /// 分区头的「工作区 / 文件夹」胶囊分段控件：选中底块滑动跟随。
    private var listModeSwitcher: some View {
        HStack(spacing: 2) {
            modeSegment(L("工作区"), icon: "square.grid.2x2", mode: .workspaces)
            modeSegment(L("文件夹"), icon: "folder", mode: .folders)
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .fill(AppStyle.activeFill.opacity(0.7))
        )
        // 模式也可能被外部切换（命令面板跳工作区、通知跳进文件夹上下文），同样要有滑动
        .animation(Motion.panel, value: listMode)
    }

    private func modeSegment(_ title: String, icon: String, mode: SidebarListMode) -> some View {
        let selected = listMode == mode
        return Button {
            withAnimation(Motion.panel) {
                coordinator.setSidebarListMode(mode)
            }
        } label: {
            HStack(spacing: 4.5) {
                Image(systemName: selected ? icon + ".fill" : icon)
                    .font(.system(size: 9.5, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                Text(title)
                    .font(.system(size: 11, weight: selected ? .semibold : .medium))
            }
            .foregroundStyle(selected ? AppStyle.textPrimary : AppStyle.textTertiary)
            .padding(.horizontal, 9)
            .frame(height: 21)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(AppStyle.elevated)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(AppStyle.textPrimary.opacity(0.08), lineWidth: 1)
                        )
                        .shadow(color: Color(nsColor: AppStyle.theme.cardShadowColor).opacity(0.28), radius: 2.5, y: 1)
                        .matchedGeometryEffect(id: "modeTabSelection", in: modeTabNamespace)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func beginRename(_ ws: Workspace) {
        draftName = ws.name
        editingWorkspace = ws.id
        coordinator.expandSidebar()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { renameFocused = true }
    }

    private func commitRename() {
        if let id = editingWorkspace { coordinator.renameWorkspace(id, to: draftName) }
        editingWorkspace = nil
        renameFocused = false
    }

    private func reauthorizeWorkspace(_ ws: Workspace) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: ws.path)
        panel.prompt = L("重新授权")
        panel.message = L("选择「%@」目录以保存长期访问权限。", ws.name)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let selected = url.standardizedFileURL
        let current = URL(fileURLWithPath: ws.path).standardizedFileURL
        guard selected.path == current.path else {
            ToastHUD.shared.show(
                L("请选择同一个工作区目录"),
                icon: "exclamationmark.triangle.fill",
                over: coordinator.window)
            return
        }
        guard let bookmarkData = SecurityScopedBookmarks.bookmarkData(for: selected) else {
            ToastHUD.shared.show(
                L("无法保存目录授权"),
                icon: "exclamationmark.triangle.fill",
                over: coordinator.window)
            return
        }
        coordinator.addWorkspace(path: selected.path, bookmarkData: bookmarkData)
        ToastHUD.shared.show(
            L("已保存目录授权"),
            icon: "lock.open.fill",
            over: coordinator.window)
    }

    /// 会话归属去重：cwd 同时落在父子两个工作区路径下时，只归路径最深的那个，
    /// 否则同一条会话会在 `~` 和 `~/xxx` 下各出现一次（悬停预览也会弹两个）。
    private func ownedSessions(for ws: Workspace, fetch: Int) -> [AgentSessionRecord] {
        let paths = coordinator.visibleWorkspaces.map {
            $0.path.hasSuffix("/") ? String($0.path.dropLast()) : $0.path
        }
        let own = ws.path.hasSuffix("/") ? String(ws.path.dropLast()) : ws.path
        return sessionStore.recordsForWorkspace(ws.path, limit: 50).filter { record in
            guard let cwd = record.cwd else { return false }
            let owner = paths
                .filter { cwd == $0 || cwd.hasPrefix($0 + "/") }
                .max { $0.count < $1.count }
            return owner == own
        }
        .prefix(fetch).map { $0 }
    }

    /// 工作区卡片下方的会话列表（参考样式：标题 + 右侧相对时间，底部「展开显示」）。
    @ViewBuilder
    private func workspaceSessionList(
        for ws: Workspace, records: [AgentSessionRecord], selected: Bool
    ) -> some View {
        let expanded = inlineExpandedSessionLists.contains(ws.id.value)
        let displayLimit = expanded ? 30 : 5
        VStack(alignment: .leading, spacing: 1) {
            if selected, !hoverHintSeen {
                HStack(spacing: 5) {
                    Image(systemName: "cursorarrow.rays")
                        .font(.system(size: 10, weight: .medium))
                    Text(L("鼠标悬停可预览对话"))
                        .font(.system(size: 10.5))
                }
                .foregroundStyle(AppStyle.textTertiary)
                .padding(.leading, 9)
                .padding(.bottom, 2)
                .transition(.opacity)
            }
            ForEach(records.prefix(displayLimit)) { record in
                SidebarSessionRow(
                    record: record,
                    coordinator: coordinator,
                    onResume: { coordinator.resumeSession(record, inPane: nil) },
                    onHover: { handleSessionHover(record, inside: $0) }
                )
                .popover(isPresented: hoverPreviewBinding(for: record), arrowEdge: .trailing) {
                    SessionHoverPreviewPanel(record: record) {
                        coordinator.resumeSession(record, inPane: nil)
                        hoverRecord = nil
                    }
                    .onHover { pinned in
                        hoverPanelPinned = pinned
                        if pinned {
                            hoverTask?.cancel()
                        } else {
                            scheduleClearHover(after: 0.15)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if records.count > displayLimit || expanded {
                Button {
                    withAnimation(Motion.panel) {
                        if expanded {
                            inlineExpandedSessionLists.remove(ws.id.value)
                        } else {
                            inlineExpandedSessionLists.insert(ws.id.value)
                        }
                    }
                } label: {
                    Text(expanded ? L("收起显示") : L("展开显示"))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(AppStyle.textTertiary)
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 16)
        .padding(.bottom, 4)
        .animation(Motion.panel, value: expanded)
    }

    /// 删除工作区是不可撤销的破坏性操作（会关掉其中所有终端），先确认再动手。
    private func confirmRemoveWorkspace(_ ws: Workspace) {
        let paneCount = ws.tabs.flatMap { $0.rootSplit.leaves() }.count
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("删除工作区「%@」？", ws.name)
        alert.informativeText = paneCount > 0
            ? L("其中 %ld 个终端会被关闭，此操作无法撤销。", paneCount)
            : L("此操作无法撤销。")
        alert.addButton(withTitle: L("删除"))
        alert.addButton(withTitle: L("取消"))
        if let deleteButton = alert.buttons.first { deleteButton.hasDestructiveAction = true }
        if alert.runModal() == .alertFirstButtonReturn {
            coordinator.removeWorkspace(ws.id)
        }
    }

    /// 「定位当前终端目录」：在文件夹树里展开、滚动并高亮活动 pane 的 cwd。
    private func locateActiveDirectory() {
        let active = coordinator.store.workspaces
            .first(where: { $0.id == coordinator.store.activeWorkspace })?.path
        guard let cwd = coordinator.activeCwd ?? active else { return }
        let found = withAnimation(Motion.expand) { folderTree.reveal(cwd) }
        if !found {
            ToastHUD.shared.show(L("该目录不在家目录下，树里看不到"),
                                 icon: "exclamationmark.circle.fill", over: coordinator.window)
        }
    }

    /// Finder 拖入的目录 → 逐个建工作区；同路径已有的不重复建，直接切过去。
    /// 返回 false 表示拖进来的不含目录（如纯文件），让系统显示拒收。
    private func handleFolderDrop(_ urls: [URL]) -> Bool {
        let dirs = urls.map(\.standardizedFileURL).filter { url in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
        guard !dirs.isEmpty else { return false }

        var created = 0
        var lastCreated: URL?
        var lastExisting: Workspace?
        for dir in dirs {
            if let existing = coordinator.visibleWorkspaces.first(where: { $0.path == dir.path }) {
                coordinator.addWorkspace(
                    path: dir.path,
                    bookmarkData: SecurityScopedBookmarks.bookmarkData(for: dir))
                lastExisting = existing
            } else {
                coordinator.addWorkspace(
                    path: dir.path,
                    bookmarkData: SecurityScopedBookmarks.bookmarkData(for: dir))
                created += 1
                lastCreated = dir
            }
        }
        switch (created, lastCreated, lastExisting) {
        case (0, _, let existing?):
            // 全是已有的 → 切到最后一个并提示
            coordinator.selectWorkspace(existing.id)
            ToastHUD.shared.show(L("已切到工作区「%@」", existing.name),
                                 icon: "folder.fill", over: coordinator.window)
        case (1, let dir?, _):
            ToastHUD.shared.show(L("已新建工作区「%@」", dir.lastPathComponent),
                                 icon: "folder.fill.badge.plus", over: coordinator.window)
        default:
            ToastHUD.shared.show(L("已新建 %ld 个工作区", created),
                                 icon: "folder.fill.badge.plus", over: coordinator.window)
        }
        return true
    }

    private func addWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("选为工作区")
        if panel.runModal() == .OK, let url = panel.url {
            coordinator.addWorkspace(
                path: url.path,
                bookmarkData: SecurityScopedBookmarks.bookmarkData(for: url))
        }
    }
}

private struct SidebarSessionRow: View {
    let record: AgentSessionRecord
    let coordinator: AppCoordinator
    let onResume: () -> Void
    let onHover: (Bool) -> Void
    @State private var hovering = false

    private var logoName: String { record.agent == "claude" ? "claude" : "codex" }

    var body: some View {
        Button(action: onResume) {
            // 单行：logo + 标题（左）/ 相对时间（右），细节悬停预览里都有。
            HStack(spacing: 7) {
                sessionLogo
                Text(record.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(hovering ? AppStyle.textPrimary : AppStyle.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(Self.compactAge(record.modifiedAt))
                    .font(.system(size: 10))
                    .foregroundStyle(AppStyle.textTertiary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5.5)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .fill(hovering ? AppStyle.hoverFill : Color.clear))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovering = inside
            onHover(inside)
        }
        // 右键菜单：与「管理会话」面板同一套动作（侧栏行此前只能点击续聊）。
        .contextMenu {
            Button { coordinator.resumeSession(record, inPane: nil) } label: {
                Label(L("新标签续聊"), systemImage: "plus.bubble")
            }
            Button { coordinator.resumeSession(record, inPane: coordinator.sessionTargetPane) } label: {
                Label(L("当前面板续聊"), systemImage: "bubble.left.and.text.bubble.right")
            }
            .disabled(coordinator.sessionTargetPane == nil)
            Divider()
            Button { coordinator.copyToClipboard(record.sessionID) } label: {
                Label(L("复制会话 ID"), systemImage: "number")
            }
            if let cmd = record.resumeCommand {
                Button { coordinator.copyToClipboard(cmd) } label: {
                    Label(L("复制续聊命令"), systemImage: "terminal")
                }
            }
            Button { coordinator.openSessionManager(scopePath: record.cwd) } label: {
                Label(L("管理全部会话…"), systemImage: "list.bullet.rectangle")
            }
            Divider()
            Button(role: .destructive) { confirmDelete() } label: {
                Label(L("删除会话…"), systemImage: "trash")
            }
        }
    }

    /// 删除确认（与管理面板同款）。
    private func confirmDelete() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("删除会话「%@」？", String(record.title.prefix(40)))
        alert.informativeText = L("会删除这条本机会话记录，无法撤销。")
        alert.addButton(withTitle: L("删除"))
        alert.addButton(withTitle: L("取消"))
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn {
            SessionManagerStore.shared.delete(record)
        }
    }

    /// 紧凑相对时间：刚刚 / N 分钟 / N 小时 / N 天。
    private static func compactAge(_ date: Date) -> String {
        let seconds = max(0, -date.timeIntervalSinceNow)
        switch seconds {
        case ..<60: return L("刚刚")
        case ..<3600: return L("%ld 分钟", Int(seconds / 60))
        case ..<86400: return L("%ld 小时", Int(seconds / 3600))
        default: return L("%ld 天", Int(seconds / 86400))
        }
    }

    @ViewBuilder
    private var sessionLogo: some View {
        if let image = CLIToolLogo.image(named: logoName) {
            Image(nsImage: image)
                .resizable().scaledToFit()
                .frame(width: 14, height: 14)
        } else {
            Image(systemName: "bubble.left")
                .font(.system(size: 11))
                .foregroundStyle(AppStyle.textTertiary)
                .frame(width: 14, height: 14)
        }
    }
}

private struct WorkspaceRow: View {
    let name: String
    let summary: SidebarWorkspaceSummary
    let selected: Bool
    let isThinking: Bool
    /// 这个工作区里「后台跑完还没看」的 pane 数（绿点 + 数字角标）。
    let unseenDoneCount: Int
    let isEditing: Bool
    let isCollapsed: Bool
    /// 名字旁的会话折叠箭头（nil = 这个工作区没有可显示的会话，不画箭头）。
    let sessionsCollapsed: Bool?
    @Binding var draft: String
    var focused: FocusState<Bool>.Binding
    let onSelect: () -> Void
    let onCommit: () -> Void
    let onToggleSessions: () -> Void
    @State private var hovering = false

    var body: some View {
        mainRow
        .padding(.horizontal, isCollapsed ? 0 : 7)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .fill(selected ? AppStyle.accent.opacity(0.12) : (hovering ? AppStyle.hoverFill : Color.clear))
        )
        .contentShape(Rectangle())
        .animation(Motion.hover, value: hovering)
        .animation(.easeInOut(duration: 0.2), value: selected)
        .animation(Motion.panel, value: isCollapsed)
        .animation(.easeInOut(duration: 0.2), value: summary.activeDetailText)
        .onTapGesture { if !isEditing { onSelect() } }
        .onHover { hovering = $0 }
        .help(unseenDoneCount > 0
            ? summary.tooltipText + "\n" + L("%ld 个 Agent 已完成，等你来看", unseenDoneCount)
            : summary.tooltipText)
        .accessibilityLabel("\(name), \(summary.pathText), \(summary.metricsText)")
        .animation(.easeOut(duration: 0.2), value: unseenDoneCount > 0)
    }

    private var mainRow: some View {
        HStack(alignment: .top, spacing: isCollapsed ? 0 : 7) {
            workspaceGlyph
                .padding(.top, isCollapsed ? 0 : 2)
            if !isCollapsed {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        if isEditing {
                            TextField("", text: $draft)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(AppStyle.textPrimary)
                                .focused(focused)
                                .onSubmit { onCommit() }
                                .layoutPriority(3)
                        } else {
                            Text(name)
                                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                                .foregroundStyle(selected ? AppStyle.textPrimary : AppStyle.textSecondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                                .allowsTightening(true)
                                .truncationMode(.middle)   // 目录名头尾都可能是区分信息，砍中间
                                .layoutPriority(8)         // 窄侧栏里名字必须优先于状态徽标
                        }
                        if !isEditing, let collapsed = sessionsCollapsed {
                            Button(action: onToggleSessions) {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(AppStyle.textTertiary)
                                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                                    .frame(width: 15, height: 15)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(collapsed ? L("展开会话") : L("收起会话"))
                        }
                        if isThinking {
                            ThinkingIndicator(size: 8)
                                .transition(.scale.combined(with: .opacity))
                        }
                        if unseenDoneCount > 0 {
                            unseenDoneBadge
                                .transition(.scale.combined(with: .opacity))
                        }
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(summary.pathText)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(AppStyle.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .layoutPriority(1)
                        Spacer(minLength: 4)
                        metricsBadge
                    }

                    if let activeDetail = summary.activeDetailText {
                        HStack(spacing: 5) {
                            Image(systemName: "terminal")
                                .font(.system(size: 10, weight: .semibold))
                            Text(activeDetail)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(AppStyle.accent)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: isCollapsed ? .center : .leading)
    }

    /// 「完成未读」绿点：>1 时带数字。
    private var unseenDoneBadge: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(AppStyle.doneGreen)
                .frame(width: 7, height: 7)
                .shadow(color: AppStyle.doneGreen.opacity(0.55), radius: 2.5)
            if unseenDoneCount > 1 {
                Text("\(unseenDoneCount)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(AppStyle.doneGreen)
            }
        }
    }

    private var workspaceGlyph: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: selected ? "folder.fill" : "folder")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selected ? AppStyle.accent : AppStyle.textSecondary)
                .frame(width: isCollapsed ? 22 : 18, height: 20)
            // 收起态没有名字行，思考动效挂在图标右下角（右上角留给 pane 数角标）
            if isCollapsed, isThinking {
                ThinkingIndicator(size: 7)
                    .offset(x: 5, y: 16)
                    .transition(.scale.combined(with: .opacity))
            }
            // 收起态的完成未读绿点：挂图标左上角（右上角是 pane 数、右下角是思考动效）
            if isCollapsed, unseenDoneCount > 0 {
                Circle()
                    .fill(AppStyle.doneGreen)
                    .frame(width: 6.5, height: 6.5)
                    .shadow(color: AppStyle.doneGreen.opacity(0.55), radius: 2.5)
                    .offset(x: -14, y: -3)
                    .transition(.scale.combined(with: .opacity))
            }
            if isCollapsed, summary.paneCount > 1 {
                Text("\(min(summary.paneCount, 99))")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(AppStyle.accent)
                    .padding(.horizontal, 3)
                    .frame(height: 11)
                    .background(Capsule().fill(AppStyle.accent.opacity(0.12)))
                    .offset(x: 7, y: -4)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: isCollapsed ? 22 : 18, height: 20)
    }

    /// 紧凑指标徽标：图标 + 数字（完整文字在行的悬浮提示里），把横向空间尽量让给名字。
    private var metricsBadge: some View {
        HStack(spacing: 6) {
            metricsItem(icon: "rectangle.stack", count: summary.tabCount)
            metricsItem(icon: "square.split.2x1", count: summary.paneCount)
        }
        .foregroundStyle(selected ? AppStyle.textSecondary : AppStyle.textTertiary)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 7)
        .frame(height: 18)
        .background(Capsule().fill(selected ? AppStyle.hoverFill : AppStyle.activeFill))
        .help(summary.metricsText)
    }

    private func metricsItem(icon: String, count: Int) -> some View {
        HStack(spacing: 2.5) {
            Image(systemName: icon)
                .font(.system(size: 8.5, weight: .semibold))
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
        }
    }
}
