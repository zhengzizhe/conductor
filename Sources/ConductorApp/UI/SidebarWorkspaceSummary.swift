import ConductorCore
import Foundation

struct SidebarWorkspaceSummary: Equatable {
    let pathText: String
    let metricsText: String
    let activeDetailText: String?
    let tooltipText: String
    let tabCount: Int
    let paneCount: Int

    init(
        workspace: Workspace,
        isSelected: Bool,
        paneTitles: [PaneID: String],
        paneCwds: [PaneID: String]
    ) {
        let tabCount = workspace.tabs.count
        let paneCount = workspace.tabs.reduce(0) { $0 + $1.paneCount }
        let pathText = Self.compactPath(workspace.path)
        let metricsText = L("%1$ld 标签 · %2$ld 面板", tabCount, paneCount)
        let activeDetailText = Self.activeDetailText(
            workspace: workspace,
            isSelected: isSelected,
            paneTitles: paneTitles,
            paneCwds: paneCwds
        )

        var tooltipLines = [workspace.name, pathText, metricsText]
        if let activeDetailText {
            tooltipLines.append(activeDetailText)
        }

        self.pathText = pathText
        self.metricsText = metricsText
        self.activeDetailText = activeDetailText
        self.tooltipText = tooltipLines.joined(separator: "\n")
        self.tabCount = tabCount
        self.paneCount = paneCount
    }

    private static func activeDetailText(
        workspace: Workspace,
        isSelected: Bool,
        paneTitles: [PaneID: String],
        paneCwds: [PaneID: String]
    ) -> String? {
        guard isSelected,
              let activeTabID = workspace.activeTab,
              let activeTab = workspace.tabs.first(where: { $0.id == activeTabID }) else { return nil }

        let tabTitle = activeTab.customTitle ?? paneTitles[activeTab.activePane] ?? activeTab.title
        guard let cwd = paneCwds[activeTab.activePane] else {
            return L("当前：%@", tabTitle)
        }
        return L("当前：%1$@ · %2$@", tabTitle, compactPath(cwd))
    }

    private static func compactPath(_ path: String) -> String { PathDisplay.tilde(path) }
}
