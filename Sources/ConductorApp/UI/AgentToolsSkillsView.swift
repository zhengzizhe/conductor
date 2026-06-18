import AppKit
import Combine
import ConductorCore
import SwiftUI

struct AgentToolsSkillsView: View {
    @ObservedObject var store: AgentToolsConsoleStore
    let initialSection: String
    let reloadID: UUID
    let onOpenModule: (AgentToolsManagementModule) -> Void

    private let refreshTimer = Timer.publish(every: 8, on: .main, in: .common).autoconnect()

    var body: some View {
        SkillsManagerView(
            presentationMode: .workbench,
            initialSection: initialSection)
            .id(reloadID)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
            .onAppear {
                store.refreshAgentRegistry()
            }
            .onReceive(refreshTimer) { _ in
                store.refreshAgentRegistry()
            }
    }
}

struct AgentToolsSkillsInspector: View {
    @ObservedObject var store: AgentToolsConsoleStore
    @ObservedObject private var configStore = ConfigStore.shared
    let onOpenModule: (AgentToolsManagementModule) -> Void
    let onOpenSection: (String) -> Void

    private var enabledSkillCount: Int {
        store.managedSkills.filter(\.enabled).count
    }

    private var deployedTargetCount: Int {
        store.managedSkills.reduce(0) { $0 + $1.targets.count }
    }

    private var unsyncedSkillCount: Int {
        store.managedSkills.filter(\.targets.isEmpty).count
    }

    private var sourceIssueCount: Int {
        store.managedSkills.filter { ["source_missing", "error"].contains($0.updateStatus) }.count
    }

    private var updatableSkillCount: Int {
        store.managedSkills.filter { $0.updateStatus == "update_available" }.count
    }

    private var coveragePercent: Int {
        guard !store.managedSkills.isEmpty, store.skillTargetCount > 0 else { return 0 }
        let total = store.managedSkills.count * store.skillTargetCount
        guard total > 0 else { return 0 }
        return min(100, Int((Double(deployedTargetCount) / Double(total) * 100).rounded()))
    }

    private var centralLibraryPath: String? {
        guard let centralPath = store.managedSkills.first?.centralPath else { return nil }
        return URL(fileURLWithPath: centralPath).deletingLastPathComponent().path
    }

    private var sourceDistribution: [(ManagedSkill.SourceType, Int)] {
        Dictionary(grouping: store.managedSkills, by: \.sourceType)
            .map { ($0.key, $0.value.count) }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return sourceLabel(lhs.0) < sourceLabel(rhs.0)
            }
    }

    private var targetDistribution: [(String, String, Int)] {
        var namesByKey: [String: String] = [:]
        for tool in store.skillTools {
            namesByKey[tool.key] = tool.displayName
        }
        return Dictionary(grouping: store.managedSkills.flatMap(\.targets), by: \.tool)
            .map { key, targets in
                (key, namesByKey[key] ?? key, targets.count)
            }
            .sorted { lhs, rhs in
                if lhs.2 != rhs.2 { return lhs.2 > rhs.2 }
                return lhs.1.localizedCaseInsensitiveCompare(rhs.1) == .orderedAscending
            }
    }

    var body: some View {
        AgentToolsInspectorShell {
            HStack {
                Spacer()
                if store.isLoadingAgentRegistry {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    summaryPanel
                    shortcutsPanel
                    sourcePanel
                    targetPanel
                    operationsPanel
                    if let error = store.agentRegistryError {
                        errorPanel(error)
                    }
                }
                .padding(.bottom, 8)
            }
            .scrollIndicators(.never)
        }
    }

    private var summaryPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppStyle.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Skill 管理"))
                        .font(.system(size: 14.5, weight: .bold))
                        .foregroundStyle(AppStyle.textPrimary)
                    Text(L("完整 workbench"))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(AppStyle.textTertiary)
                }
                Spacer(minLength: 0)
            }

            Text(L("中心库、安装、分发、Presets、Projects 和活动记录都保留在中间工作区。"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppStyle.textTertiary)
                .lineSpacing(3)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                AgentToolsStat(value: "\(store.managedSkills.count)", title: L("中央库"), sub: L("%ld 启用", enabledSkillCount), valueColor: AppStyle.accent)
                AgentToolsStat(value: "\(store.skillTargetCount)", title: L("目标"), sub: L("可接收"), valueColor: AppStyle.doneGreen)
                AgentToolsStat(value: "\(deployedTargetCount)", title: L("同步"), sub: L("覆盖率 %@%%", "\(coveragePercent)"), valueColor: coveragePercent >= 80 ? AppStyle.doneGreen : AppStyle.accent)
                AgentToolsStat(value: "\(unsyncedSkillCount + sourceIssueCount + updatableSkillCount)", title: L("待处理"), sub: pendingSummary, valueColor: pendingColor)
            }
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, 14)
        .agentToolsGlass()
        .contextMenu {
            Button(L("复制状态摘要")) { store.copyText(diagnosticsText) }
            if let centralLibraryPath {
                Button(L("在 Finder 中显示中央库")) { reveal(centralLibraryPath) }
            }
        }
    }

    private var shortcutsPanel: some View {
        AgentToolsSection(L("模块跳转")) {
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 9) {
                AgentToolsLinkButton(title: L("技能库"), icon: "square.stack.3d.up", tint: AppStyle.accent) { onOpenSection("library") }
                AgentToolsLinkButton(title: L("安装"), icon: "sparkles", tint: AppStyle.accent) { onOpenSection("discover") }
                AgentToolsLinkButton(title: L("工作区"), icon: "globe", tint: AppStyle.accent) { onOpenSection("workspace") }
                AgentToolsLinkButton(title: "Presets", icon: "rectangle.stack.badge.plus", tint: AppStyle.accent) { onOpenSection("deploy") }
                AgentToolsLinkButton(title: L("项目"), icon: "folder.badge.gearshape", tint: AppStyle.accent) { onOpenSection("projects") }
                AgentToolsLinkButton(title: "Agents", icon: "cpu", tint: AppStyle.accent) { onOpenSection("agents") }
            }
        }
    }

    private var sourcePanel: some View {
        VStack(alignment: .leading, spacing: 7) {
            ToolsSectionLabel(L("来源分布"))
            VStack(alignment: .leading, spacing: 7) {
                if sourceDistribution.isEmpty {
                    emptyLine(L("暂无 Skill"))
                } else {
                    ForEach(sourceDistribution, id: \.0) { source, count in
                        distributionRow(
                            title: sourceLabel(source),
                            value: count,
                            total: max(store.managedSkills.count, 1),
                            color: sourceColor(source))
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .agentToolsGlass()
        }
    }

    private var targetPanel: some View {
        VStack(alignment: .leading, spacing: 7) {
            ToolsSectionLabel(L("目标分布"))
            VStack(alignment: .leading, spacing: 7) {
                if targetDistribution.isEmpty {
                    emptyLine(L("还没有同步目标"))
                } else {
                    ForEach(Array(targetDistribution.prefix(6)), id: \.0) { _, name, count in
                        distributionRow(
                            title: name,
                            value: count,
                            total: max(deployedTargetCount, 1),
                            color: AppStyle.accent)
                    }
                    if targetDistribution.count > 6 {
                        Text(L("还有 %ld 个目标", targetDistribution.count - 6))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(AppStyle.textTertiary)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .agentToolsGlass()
        }
    }

    private var operationsPanel: some View {
        AgentToolsSection(L("操作")) {
            VStack(alignment: .leading, spacing: 7) {
                ToolActionButton(
                    title: store.isLoadingAgentRegistry ? L("刷新中") : L("刷新索引"),
                    systemImage: "arrow.clockwise",
                    height: 28,
                    fontSize: 11,
                    horizontalPadding: 10,
                    help: L("刷新 Skills 管理台外层统计")) {
                        store.refreshAgentRegistry()
                    }
                    .disabled(store.isLoadingAgentRegistry)

                ToolActionButton(
                    title: L("复制状态摘要"),
                    systemImage: "doc.on.doc",
                    height: 28,
                    fontSize: 11,
                    horizontalPadding: 10) {
                        store.copyText(diagnosticsText)
                    }

                if let centralLibraryPath {
                    ToolActionButton(
                        title: L("显示中央库"),
                        systemImage: "folder",
                        height: 28,
                        fontSize: 11,
                        horizontalPadding: 10) {
                            reveal(centralLibraryPath)
                        }
                }
            }
        }
    }

    private var pendingSummary: String {
        if unsyncedSkillCount == 0, sourceIssueCount == 0, updatableSkillCount == 0 {
            return L("状态正常")
        }
        var parts: [String] = []
        if unsyncedSkillCount > 0 { parts.append(L("%ld 未同步", unsyncedSkillCount)) }
        if updatableSkillCount > 0 { parts.append(L("%ld 可更新", updatableSkillCount)) }
        if sourceIssueCount > 0 { parts.append(L("%ld 来源异常", sourceIssueCount)) }
        return parts.joined(separator: " · ")
    }

    private var pendingColor: Color {
        sourceIssueCount > 0 ? AppStyle.errorRed : (unsyncedSkillCount + updatableSkillCount > 0 ? AppStyle.waitAmber : AppStyle.doneGreen)
    }

    private var diagnosticsText: String {
        var lines: [String] = []
        lines.append("Conductor Skills Diagnostics")
        lines.append("skills.total: \(store.managedSkills.count)")
        lines.append("skills.enabled: \(enabledSkillCount)")
        lines.append("targets.available: \(store.skillTargetCount)")
        lines.append("targets.synced: \(deployedTargetCount)")
        lines.append("coverage.percent: \(coveragePercent)")
        lines.append("skills.unsynced: \(unsyncedSkillCount)")
        lines.append("skills.updatable: \(updatableSkillCount)")
        lines.append("skills.source_issues: \(sourceIssueCount)")
        if let centralLibraryPath {
            lines.append("central_library: \(centralLibraryPath)")
        }
        for (source, count) in sourceDistribution {
            lines.append("source.\(source.rawValue): \(count)")
        }
        for (key, name, count) in targetDistribution {
            lines.append("target.\(key): \(name) \(count)")
        }
        if let error = store.agentRegistryError {
            lines.append("error: \(error)")
        }
        return lines.joined(separator: "\n")
    }

    private func distributionRow(title: String, value: Int, total: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(AppStyle.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(value)")
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color)
            }
            GeometryReader { proxy in
                let width = total <= 0 ? 0 : proxy.size.width * min(1, CGFloat(value) / CGFloat(total))
                ZStack(alignment: .leading) {
                    Capsule().fill(AppStyle.hoverFill.opacity(0.72))
                    Capsule().fill(color.opacity(0.86)).frame(width: width)
                }
            }
            .frame(height: 5)
        }
    }

    private func emptyLine(_ title: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "tray")
                .font(.system(size: 10, weight: .semibold))
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
        }
        .foregroundStyle(AppStyle.textTertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private func errorPanel(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppStyle.errorRed)
            Text(error)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(AppStyle.textSecondary)
                .lineLimit(4)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .fill(AppStyle.errorRed.opacity(0.10)))
    }

    private func sourceLabel(_ source: ManagedSkill.SourceType) -> String {
        switch source {
        case .local: return L("本地")
        case .git: return "Git"
        case .skillssh: return "skills.sh"
        case .imported: return L("导入")
        }
    }

    private func sourceColor(_ source: ManagedSkill.SourceType) -> Color {
        switch source {
        case .local: return AppStyle.textSecondary
        case .git: return AppStyle.doneGreen
        case .skillssh: return AppStyle.accent
        case .imported: return AppStyle.waitAmber
        }
    }

    private func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
