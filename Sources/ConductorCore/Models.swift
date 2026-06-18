import Foundation

/// 工作区内的一个 Tab：持有一棵分屏树和当前焦点 pane。
public struct Tab: Codable, Equatable {
    public var id: TabID
    public var title: String
    public var rootSplit: SplitNode
    public var activePane: PaneID
    /// 用户手动重命名的标题；有则显示它、不再被 cwd 自动覆盖（nil = 自动）。
    public var customTitle: String?

    public init(id: TabID, title: String, rootSplit: SplitNode, activePane: PaneID, customTitle: String? = nil) {
        self.id = id
        self.title = title
        self.rootSplit = rootSplit
        self.activePane = activePane
        self.customTitle = customTitle
    }

    /// 便捷构造：单 pane 的 Tab。
    public static func single(id: TabID, title: String, pane: PaneID) -> Tab {
        Tab(id: id, title: title, rootSplit: .leaf(pane), activePane: pane)
    }

    /// 该 Tab 是否为"分组"：含 ≥2 个终端 pane（即已分屏）。
    /// 派生自 rootSplit，不额外存状态；关到只剩一个 pane 会自动退回普通 tab。
    public var isGroup: Bool { rootSplit.leaves().count > 1 }

    /// 该 Tab 内的 pane 数量。
    public var paneCount: Int { rootSplit.leaves().count }
}

/// 绑定一个目录路径的工作区，含若干 Tab。
public struct Workspace: Codable, Equatable {
    public var id: WorkspaceID
    public var name: String
    public var path: String            // 绝对 POSIX 路径
    /// macOS security-scoped bookmark for user-selected workspaces.
    /// Kept optional so old persisted state remains readable.
    public var bookmarkData: Data?
    public var tabs: [Tab]
    public var activeTab: TabID?

    public init(
        id: WorkspaceID,
        name: String,
        path: String,
        bookmarkData: Data? = nil,
        tabs: [Tab],
        activeTab: TabID?
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.bookmarkData = bookmarkData
        self.tabs = tabs
        self.activeTab = activeTab
    }

    /// 追加一个 Tab 并设为 active。
    public mutating func addTab(_ tab: Tab) {
        tabs.append(tab)
        activeTab = tab.id
    }

    /// 关闭指定 Tab；若它是 active，则回退到它前一个（无则后一个，再无则 nil）。
    public mutating func closeTab(_ id: TabID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasActive = activeTab == id
        tabs.remove(at: index)
        guard wasActive else { return }
        if tabs.isEmpty {
            activeTab = nil
        } else {
            let fallback = index > 0 ? index - 1 : 0
            activeTab = tabs[fallback].id
        }
    }
}

/// 所有工作区的容器。
public struct WorkspaceStore: Codable, Equatable {
    public var workspaces: [Workspace]
    public var activeWorkspace: WorkspaceID?

    public init(workspaces: [Workspace], activeWorkspace: WorkspaceID?) {
        self.workspaces = workspaces
        self.activeWorkspace = activeWorkspace
    }

    /// 插入或按 id 替换一个工作区；插入新工作区时将其设为 active。
    public mutating func upsert(_ workspace: Workspace) {
        if let index = workspaces.firstIndex(where: { $0.id == workspace.id }) {
            workspaces[index] = workspace
        } else {
            workspaces.append(workspace)
            activeWorkspace = workspace.id
        }
    }

    /// 移除工作区；若它是 active，则回退到第一个剩余工作区（无则 nil）。
    public mutating func remove(_ id: WorkspaceID) {
        workspaces.removeAll { $0.id == id }
        if activeWorkspace == id {
            activeWorkspace = workspaces.first?.id
        }
    }
}
