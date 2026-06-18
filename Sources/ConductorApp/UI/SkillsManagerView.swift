import AppKit
import ConductorCore
import SwiftUI

@MainActor
private enum SkillUI {
    static let railWidth: CGFloat = 220
    static let panelRadius: CGFloat = Radius.sm + 2
    static let rowRadius: CGFloat = Radius.sm + 2
    static let controlRadius: CGFloat = Radius.sm + 1
    static let iconRadius: CGFloat = Radius.sm + 1
    static let panelHPadding: CGFloat = 11
    static let panelVPadding: CGFloat = 10
    static let controlHeight: CGFloat = 26
    static let chipHeight: CGFloat = 22

    static var railFill: Color { AppStyle.hoverFill.opacity(0.14) }
    static var softFill: Color { AppStyle.hoverFill.opacity(0.46) }
    static var softerFill: Color { AppStyle.hoverFill.opacity(0.36) }
    static var selectedFill: Color { AppStyle.activeFill.opacity(0.62) }
    static var selectedStroke: Color { AppStyle.accent.opacity(0.30) }
    static var subtleStroke: Color { AppStyle.separator.opacity(0.12) }
}

@MainActor
private extension View {
    func skillPanelSurface() -> some View {
        // 去白卡片：浅色下不再用不透明白卡，统一走通透表面（深色=磨砂玻璃，浅色=极淡描边）。
        agentToolsGlass(cornerRadius: SkillUI.panelRadius)
    }

    func skillRailSurface() -> some View {
        background(SkillUI.railFill)
    }

    func skillSoftSurface(opacity: Double = 1) -> some View {
        background(RoundedRectangle(cornerRadius: SkillUI.rowRadius, style: .continuous)
            .fill(SkillUI.softFill.opacity(opacity)))
    }

    func skillControlSurface(active: Bool = false,
                             tint: Color? = nil,
                             disabled: Bool = false) -> some View {
        let resolvedTint = tint ?? AppStyle.accent
        return background(RoundedRectangle(cornerRadius: SkillUI.controlRadius, style: .continuous)
            .fill(disabled
                ? AppStyle.textTertiary.opacity(0.28)
                : active ? resolvedTint : AppStyle.hoverFill))
    }

    func skillPrimaryControlSurface(disabled: Bool = false) -> some View {
        background(RoundedRectangle(cornerRadius: SkillUI.controlRadius, style: .continuous)
            .fill(disabled ? AppStyle.textTertiary.opacity(0.55) : AppStyle.accent))
    }

    func skillIconSurface(color: Color,
                          shape: SkillIconSurfaceShape = .rounded) -> some View {
        background {
            switch shape {
            case .circle:
                Circle().fill(color.opacity(0.11))
            case .rounded:
                RoundedRectangle(cornerRadius: SkillUI.iconRadius, style: .continuous)
                    .fill(color.opacity(0.11))
            }
        }
    }

    func skillRowSurface(active: Bool = false,
                         selected: Bool = false,
                         hovering: Bool = false,
                         tint: Color? = nil) -> some View {
        let resolvedTint = tint ?? AppStyle.accent
        return background(RoundedRectangle(cornerRadius: SkillUI.rowRadius, style: .continuous)
            .fill(active || selected
                ? SkillUI.selectedFill
                : AppStyle.hoverFill.opacity(hovering ? 0.58 : 0.42)))
        .overlay(RoundedRectangle(cornerRadius: SkillUI.rowRadius, style: .continuous)
            .stroke(active || selected ? resolvedTint.opacity(0.30) : SkillUI.subtleStroke, lineWidth: 1))
    }

    func skillRailItemSurface(selected: Bool) -> some View {
        background(RoundedRectangle(cornerRadius: SkillUI.rowRadius, style: .continuous)
            .fill(selected ? SkillUI.selectedFill : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: SkillUI.rowRadius, style: .continuous)
            .stroke(selected ? SkillUI.selectedStroke : Color.clear, lineWidth: 1))
    }
}

private enum SkillIconSurfaceShape {
    case rounded
    case circle
}

@MainActor
private struct SkillModalShell<Rail: View, Header: View, Content: View>: View {
    let railWidth: CGFloat
    let rail: Rail
    let header: Header
    let content: Content

    init(railWidth: CGFloat = 220,
         @ViewBuilder rail: () -> Rail,
         @ViewBuilder header: () -> Header,
         @ViewBuilder content: () -> Content) {
        self.railWidth = railWidth
        self.rail = rail()
        self.header = header()
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            rail
                .frame(width: railWidth)
            VStack(spacing: 0) {
                header
                content
            }
        }
        .background(AppStyle.windowBackground)
    }
}

@MainActor
private struct SkillRailBrand: View {
    let icon: String
    let title: String
    let subtitle: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .skillIconSurface(color: tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(AppStyle.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(AppStyle.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }
}

@MainActor
private struct SkillModalHeader<Actions: View, Meta: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    let tint: Color
    let actions: Actions
    let meta: Meta

    init(icon: String,
         title: String,
         subtitle: String,
         tint: Color? = nil,
         @ViewBuilder actions: () -> Actions,
         @ViewBuilder meta: () -> Meta) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.tint = tint ?? AppStyle.accent
        self.actions = actions()
        self.meta = meta()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    headerIdentity
                    Spacer(minLength: 10)
                    actions
                }

                VStack(alignment: .leading, spacing: 8) {
                    headerIdentity
                    actions
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            meta
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var headerIdentity: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .skillIconSurface(color: tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(AppStyle.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(AppStyle.textTertiary)
                    .lineLimit(2)
            }
        }
    }
}

@MainActor
private struct SkillPanelTitle: View {
    let icon: String
    let title: String
    let value: String?
    var tint: Color = AppStyle.accent

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16)
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(AppStyle.textPrimary)
                .lineLimit(1)
            Spacer()
            if let value {
                Text(value)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(AppStyle.textTertiary)
                    .lineLimit(1)
            }
        }
    }
}

@MainActor
private struct SkillHeaderActionButton: View {
    let title: String
    let systemImage: String
    var primary = false
    var tint: Color = AppStyle.accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(primary ? .white : AppStyle.textSecondary)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: SkillUI.controlRadius, style: .continuous)
                        .fill(primary ? tint : AppStyle.hoverFill)
                )
        }
        .buttonStyle(PressScaleStyle())
        .help(title)
    }
}

enum SkillManagerPresentationMode {
    case compactPanel
    case workbench
}

private enum SkillDrawerSection: String, CaseIterable, Identifiable {
    case library
    case install
    case detail

    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: return L("技能库")
        case .install: return L("安装")
        case .detail: return L("详情")
        }
    }

    var icon: String {
        switch self {
        case .library: return "square.stack.3d.up"
        case .install: return "sparkles"
        case .detail: return "sidebar.right"
        }
    }
}

/// Skills Manager：中央库 + 多 Agent 同步 + 本机发现。
/// 后端来自 ConductorCore.SkillManagerEngine。
struct SkillsManagerView: View {
    private let presentationMode: SkillManagerPresentationMode
    private let agentFocused: Bool
    private let openAgents: (() -> Void)?
    @ObservedObject private var configStore = ConfigStore.shared
    @State private var engine: SkillManagerEngine?
    @State private var skills: [ManagedSkill] = []
    @State private var tools: [SkillToolInfo] = []
    @State private var presets: [SkillPreset] = []
    @State private var presetSummaries: [SkillPresetSummary] = []
    @State private var projects: [SkillProject] = []
    @State private var projectTargets: [SkillProjectTargetRecord] = []
    @State private var projectSkills: [String: [ProjectSkillInfo]] = [:]
    @State private var auditEntries: [SkillAuditEntry] = []
    @State private var scanResult: SkillScanResult?
    @State private var selectedSection: SkillManagerSection
    @State private var query = ""
    @State private var syncMode = "symlink"
    @State private var newPresetName = ""
    @State private var tagDraft = ""
    @State private var sourceFilters: Set<String> = []
    @State private var tagFilters: Set<String> = []
    @State private var skillsShQuery = ""
    @State private var skillsShBoard = "hot"
    @State private var skillsShSourceFilter = "all"
    @State private var skillsShVisibleLimit = 24
    @State private var installTab: SkillInstallTab = .market
    @State private var drawerSection: SkillDrawerSection = .library
    @State private var libraryViewMode: SkillLibraryViewMode = .grid
    @State private var focusedWorkspaceToolKey: String?
    @State private var skillsShSkills: [SkillsShSkill] = []
    @State private var skillsShLoading = false
    @State private var skillsShError: String?
    @State private var gitInstallURL = ""
    @State private var gitInstallSubdirectory = ""
    @State private var gitInstallRef = ""
    @State private var gitPreviewSkills: [GitSkillPreview] = []
    @State private var gitPreviewSelectedPaths: Set<String> = []
    @State private var gitPreviewLoading = false
    @State private var gitPreviewError: String?
    @State private var gitPreviewSignature: String?
    @State private var selectedDiscoveryGroupIDs: Set<String> = []
    @State private var selectedSkillIDs: Set<String> = []
    @State private var loading = false
    @State private var loadingText = ""
    @State private var expandedSkillID: String?
    @State private var inspectedSkillID: String?
    @State private var detailSkillID: String?
    @State private var detailTab: SkillDetailTab = .overview
    @State private var expandedPresetID: String?
    @State private var expandedProjectID: String?
    @State private var skillDocuments: [String: SkillDocument] = [:]
    @State private var skillFiles: [String: [SkillFileInfo]] = [:]
    @State private var skillDiffs: [String: SkillSourceDiff] = [:]
    @State private var error: String?
    @State private var pendingDelete: ManagedSkill?
    @State private var pendingBatchDelete = false
    @State private var pendingPresetDelete: SkillPreset?
    @State private var pendingProjectDelete: SkillProject?

    init(
        presentationMode: SkillManagerPresentationMode = .compactPanel,
        agentFocused: Bool = false,
        openAgents: (() -> Void)? = nil,
        initialSection: String? = nil
    ) {
        self.presentationMode = presentationMode
        self.agentFocused = agentFocused
        self.openAgents = openAgents
        let requestedSection = initialSection.flatMap(SkillManagerSection.init(rawValue:))
        let fallbackSection: SkillManagerSection = agentFocused ? .agents : .library
        let startSection = requestedSection ?? fallbackSection
        _selectedSection = State(initialValue: startSection)
    }

    private var visibleSections: [SkillManagerSection] {
        if agentFocused { return [.workspace, .agents] }
        return [.library, .discover, .workspace, .deploy, .projects, .agents, .activity]
    }

    private var availableTools: [SkillToolInfo] {
        tools
            .filter { $0.enabled && ($0.installed || $0.isCustom || $0.hasPathOverride) }
            .sorted(by: toolSort)
    }

    private var projectTools: [SkillToolInfo] {
        tools
            .filter { $0.enabled && $0.projectRelativeSkillsDir?.isEmpty == false }
            .sorted(by: toolSort)
    }

    private var filteredSkills: [ManagedSkill] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return skills.filter { skill in
            if !sourceFilters.isEmpty, !sourceFilters.contains(skill.sourceType.rawValue) {
                return false
            }
            if !tagFilters.isEmpty {
                let tagSet = Set(skill.tags)
                if tagFilters.contains("__untagged__") {
                    if !skill.tags.isEmpty && tagFilters.isDisjoint(with: tagSet) {
                        return false
                    }
                } else if tagFilters.isDisjoint(with: tagSet) {
                    return false
                }
            }
            guard !q.isEmpty else { return true }
            return skill.name.lowercased().contains(q) ||
                (skill.description ?? "").lowercased().contains(q) ||
                skill.tags.joined(separator: " ").lowercased().contains(q)
        }
    }

    private var allTags: [String] {
        Array(Set(skills.flatMap(\.tags))).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    private var sourceTypesInUse: [String] {
        Array(Set(skills.map { $0.sourceType.rawValue })).sorted()
    }

    private var inspectedSkill: ManagedSkill? {
        if let inspectedSkillID,
           let skill = skills.first(where: { $0.id == inspectedSkillID }) {
            return skill
        }
        return filteredSkills.first ?? skills.first
    }

    private var detailSkill: ManagedSkill? {
        guard let detailSkillID else { return nil }
        return skills.first { $0.id == detailSkillID }
    }

    private var unsyncedSkillsCount: Int {
        skills.filter(\.targets.isEmpty).count
    }

    private var sourceProblemSkillsCount: Int {
        skills.filter { ["source_missing", "error"].contains($0.updateStatus) }.count
    }

    private var deployedTargetCount: Int {
        skills.reduce(0) { $0 + $1.targets.count }
    }

    private var deploymentCoverageSummary: String {
        guard !skills.isEmpty, !availableTools.isEmpty else { return "0%" }
        let total = skills.count * availableTools.count
        guard total > 0 else { return "0%" }
        let percent = Double(deployedTargetCount) / Double(total)
        return "\(Int((percent * 100).rounded()))%"
    }

    private var deploymentCoverageColor: Color {
        guard !skills.isEmpty, !availableTools.isEmpty else { return AppStyle.textTertiary }
        return unsyncedSkillsCount == 0 ? AppStyle.accent : AppStyle.waitAmber
    }

    private var commandTasks: [SkillCommandTask] {
        var tasks: [SkillCommandTask] = []
        if skills.isEmpty {
            tasks.append(SkillCommandTask(
                id: "market",
                icon: "sparkles",
                title: "skills.sh",
                detail: L("从市场挑选第一批 Skill"),
                count: nil,
                tint: AppStyle.accent,
                action: .market))
            tasks.append(SkillCommandTask(
                id: "import",
                icon: "folder.badge.plus",
                title: L("导入本地"),
                detail: L("收纳已有目录或 bundle"),
                count: nil,
                tint: AppStyle.textSecondary,
                action: .importLocal))
        }
        if scanResult == nil {
            tasks.append(SkillCommandTask(
                id: "scan",
                icon: "scope",
                title: L("扫描本机"),
                detail: L("发现 Codex / Claude / 自定义 Agent 里的旧 Skill"),
                count: nil,
                tint: AppStyle.waitAmber,
                action: .scan))
        }
        if unsyncedSkillsCount > 0, !availableTools.isEmpty {
            tasks.append(SkillCommandTask(
                id: "sync-unsynced",
                icon: "arrow.triangle.2.circlepath",
                title: L("分发未同步"),
                detail: L("把还没进入 Agent 的 Skill 推过去"),
                count: unsyncedSkillsCount,
                tint: AppStyle.accent,
                action: .syncUnsynced))
        }
        if !updatableSkills.isEmpty {
            tasks.append(SkillCommandTask(
                id: "update",
                icon: "arrow.down.circle",
                title: L("更新可用"),
                detail: L("刷新已经确认有新版的 Skill"),
                count: updatableSkills.count,
                tint: AppStyle.waitAmber,
                action: .updateAvailable))
        }
        if sourceProblemSkillsCount > 0 {
            tasks.append(SkillCommandTask(
                id: "source-problems",
                icon: "exclamationmark.triangle",
                title: L("来源异常"),
                detail: L("重新绑定或解除失效来源"),
                count: sourceProblemSkillsCount,
                tint: AppStyle.errorRed,
                action: .library))
        }
        if tasks.isEmpty {
            tasks.append(SkillCommandTask(
                id: "library",
                icon: "square.stack.3d.up",
                title: L("管理技能库"),
                detail: L("筛选、标签、详情和同步"),
                count: nil,
                tint: AppStyle.accent,
                action: .library))
        }
        return Array(tasks.prefix(5))
    }

    private var installedSkillsshRefs: Set<String> {
        Set(skills.compactMap { skill in
            skill.sourceType == .skillssh ? skill.sourceRef : nil
        })
    }

    private var skillsShSources: [String] {
        Array(Set(skillsShSkills.map(\.source))).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    private var filteredSkillsShSkills: [SkillsShSkill] {
        guard skillsShSourceFilter != "all" else { return skillsShSkills }
        return skillsShSkills.filter { $0.source == skillsShSourceFilter }
    }

    private var visibleSkillsShSkills: [SkillsShSkill] {
        Array(filteredSkillsShSkills.prefix(skillsShVisibleLimit))
    }

    private var filteredGroups: [DiscoveredSkillGroup] {
        let groups = scanResult?.groups ?? []
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return groups }
        return groups.filter {
            $0.name.lowercased().contains(q) ||
                $0.locations.contains { $0.tool.lowercased().contains(q) || $0.foundPath.lowercased().contains(q) }
        }
    }

    private var importableFilteredGroups: [DiscoveredSkillGroup] {
        filteredGroups.filter { !$0.imported }
    }

    private var selectedDiscoveryGroups: [DiscoveredSkillGroup] {
        filteredGroups.filter { selectedDiscoveryGroupIDs.contains($0.id) && !$0.imported }
    }

    private var filteredPresets: [SkillPreset] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return presets }
        let skillByID = Dictionary(uniqueKeysWithValues: skills.map { ($0.id, $0.name.lowercased()) })
        return presets.filter { preset in
            preset.name.lowercased().contains(q) ||
                (preset.description ?? "").lowercased().contains(q) ||
                preset.skills.contains { item in
                    skillByID[item.skillID]?.contains(q) == true
                }
        }
    }

    var body: some View {
        Group {
            switch presentationMode {
            case .compactPanel:
                compactPanelBody
            case .workbench:
                workbenchBody
            }
        }
    }

    private var compactPanelBody: some View {
        VStack(spacing: 0) {
            compactHeader
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let error {
                        ToolStatusLine(icon: "exclamationmark.triangle.fill", text: error, color: AppStyle.errorRed)
                    }
                    compactHero
                    compactDrawerTabs
                    compactDrawerContent
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .scrollIndicators(.never)
        }
        .onAppear {
            normalizeSelectedSection()
            if engine == nil { reload() }
        }
    }

    private var workbenchBody: some View {
        GeometryReader { proxy in
            SkillModalShell(railWidth: workbenchRailWidth(for: proxy.size.width)) {
                workbenchSidebar
            } header: {
                header
            } content: {
                content
            }
        }
        .onAppear {
            normalizeSelectedSection()
            if engine == nil { reload() }
        }
        .sheet(isPresented: Binding(
            get: { detailSkill != nil },
            set: { if !$0 { detailSkillID = nil } }
        )) {
            if let skill = detailSkill {
                SkillDetailCockpit(
                    skill: skill,
                    tools: availableTools,
                    document: skillDocuments[skill.id],
                    files: skillFiles[skill.id] ?? [],
                    sourceDiff: skillDiffs[skill.id],
                    auditEntries: auditEntries.filter { entry in
                        entry.skillID == skill.id || entry.skillName == skill.name
                    },
                    readinessItems: readinessItems(for: skill),
                    selectedTab: $detailTab,
                    syncMode: syncModeLabel,
                    canRefreshFromSource: canRefreshFromSource(skill),
                    onClose: { detailSkillID = nil },
                    onSyncAll: { syncAll(skill) },
                    onToggleTool: { tool, enabled in
                        toggle(skill: skill, tool: tool, enabled: enabled)
                    },
                    onCheckUpdate: { checkSkillUpdate(skill) },
                    onRefreshSource: { refreshSkillFromSource(skill) },
                    onReveal: { reveal(skill.centralPath) },
                    onDelete: {
                        detailSkillID = nil
                        pendingDelete = skill
                    },
                    onLoadDetails: { loadSkillDetails(skill) })
                    .frame(minWidth: 960, idealWidth: 1080, minHeight: 660, idealHeight: 760)
                    .background(AppStyle.windowBackground)
            }
        }
        .alert(L("删除 Skill？"), isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button(L("取消"), role: .cancel) { pendingDelete = nil }
            Button(L("删除"), role: .destructive) {
                if let skill = pendingDelete { delete(skill) }
                pendingDelete = nil
            }
        } message: {
            Text(L("会从中央库删除该 Skill，并移除由 Conductor 管理的同步目标。"))
        }
        .alert(L("删除选中的 Skills？"), isPresented: $pendingBatchDelete) {
            Button(L("取消"), role: .cancel) { pendingBatchDelete = false }
            Button(L("删除"), role: .destructive) {
                deleteSelectedSkills()
                pendingBatchDelete = false
            }
        } message: {
            Text(L("会删除选中的 Skills，并移除由 Conductor 管理的同步目标。"))
        }
        .alert(L("删除 Preset？"), isPresented: Binding(
            get: { pendingPresetDelete != nil },
            set: { if !$0 { pendingPresetDelete = nil } }
        )) {
            Button(L("取消"), role: .cancel) { pendingPresetDelete = nil }
            Button(L("删除"), role: .destructive) {
                if let preset = pendingPresetDelete { deletePreset(preset) }
                pendingPresetDelete = nil
            }
        } message: {
            Text(L("只删除 Preset 分组，不删除中央库里的 Skills。"))
        }
        .alert(L("移除项目？"), isPresented: Binding(
            get: { pendingProjectDelete != nil },
            set: { if !$0 { pendingProjectDelete = nil } }
        )) {
            Button(L("取消"), role: .cancel) { pendingProjectDelete = nil }
            Button(L("移除"), role: .destructive) {
                if let project = pendingProjectDelete { deleteProject(project) }
                pendingProjectDelete = nil
            }
        } message: {
            Text(L("只从 Conductor 移除这个项目记录，不删除项目目录。"))
        }
    }

    private func workbenchRailWidth(for width: CGFloat) -> CGFloat {
        if width < 860 { return 188 }
        if width < 980 { return 204 }
        return SkillUI.railWidth
    }

    private var header: some View {
        SkillModalHeader(
            icon: selectedSection.icon,
            title: selectedSection.title,
            subtitle: selectedSection.subtitle,
            tint: AppStyle.accent) {
            HStack(spacing: 8) {
                searchField
                    .frame(minWidth: 260, idealWidth: 360, maxWidth: 420)

                Menu {
                    Button { selectedSection = .discover } label: {
                        Label("skills.sh", systemImage: "sparkles")
                    }
                    Button(action: importLocal) {
                        Label(L("导入本地"), systemImage: "folder.badge.plus")
                    }
                    Button { reload(scan: true) } label: {
                        Label(L("扫描本机"), systemImage: "scope")
                    }
                    Button { selectedSection = .discover } label: {
                        Label(L("从 Git 安装"), systemImage: "git.branch")
                    }
                } label: {
                    Label(L("添加"), systemImage: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppStyle.textSecondary)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .skillControlSurface()
                }
                .menuStyle(.borderlessButton)
                .help(L("添加 Skill"))

                Picker("", selection: $syncMode) {
                    Text(L("软链")).tag("symlink")
                    Text(L("复制")).tag("copy")
                }
                .pickerStyle(.segmented)
                .frame(width: 94)
                .help(L("同步模式"))

                iconButton("arrow.clockwise", help: L("刷新")) { reload() }
                    .disabled(loading)
            }
        } meta: {
            HStack(spacing: 6) {
                ToolBadge(text: L("%ld Skills", skills.count), color: AppStyle.textTertiary, style: .muted, height: 20)
                ToolBadge(text: L("%ld Agent", availableTools.count), color: AppStyle.textTertiary, style: .muted, height: 20)
                if unsyncedSkillsCount > 0 {
                    ToolBadge(text: L("%ld 未同步", unsyncedSkillsCount), color: AppStyle.waitAmber, height: 20)
                }
                if loading {
                    ProgressView().controlSize(.small)
                    Text(loadingText)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(AppStyle.textTertiary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var compactHeader: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppStyle.accent)
                    .frame(width: 24, height: 24)
                    .skillIconSurface(color: AppStyle.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Skills")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(AppStyle.textPrimary)
                    Text(L("中央库 / Agent / 项目"))
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(AppStyle.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if let openAgents {
                IconOnlyButton(
                    systemName: "cpu",
                    help: L("打开 Agent 管理"),
                    size: 28,
                    symbolSize: 11,
                    weight: .semibold,
                    action: openAgents)
            }
            IconOnlyButton(
                systemName: "arrow.clockwise",
                help: L("刷新"),
                size: 28,
                symbolSize: 11,
                weight: .semibold) {
                    reload()
                }
                .disabled(loading)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var compactHero: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Skill 控制台"))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(AppStyle.textPrimary)
                    Text(compactHeroSubtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(AppStyle.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                if loading {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.top, 2)
                }
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 7) {
                ToolBadge(text: L("%ld Skills", skills.count), color: AppStyle.textTertiary, style: .muted, height: 20)
                ToolBadge(text: L("%ld Agent", availableTools.count), color: AppStyle.textTertiary, style: .muted, height: 20)
                if unsyncedSkillsCount > 0 {
                    ToolBadge(text: L("%ld 未同步", unsyncedSkillsCount), color: AppStyle.waitAmber, height: 20)
                }
                if !updatableSkills.isEmpty {
                    ToolBadge(text: L("%ld 可更新", updatableSkills.count), color: AppStyle.waitAmber, height: 20)
                }
            }

            Button {
                withAnimation(AgentToolsMotion.selection) {
                    drawerSection = .install
                    installTab = .market
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11.5, weight: .semibold))
                    Text(L("安装 Skill"))
                        .font(.system(size: 11.5, weight: .bold))
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .skillPrimaryControlSurface()
            }
            .buttonStyle(PressScaleStyle())
            .help(L("从 skills.sh、Git 或本地导入 Skill"))
        }
        .padding(11)
        .skillPanelSurface()
    }

    private var compactHeroSubtitle: String {
        if skills.isEmpty {
            return L("先从 skills.sh、Git 或本地导入 Skill。")
        }
        if unsyncedSkillsCount > 0 {
            return L("%ld 个 Skill 还没有进入 Agent。", unsyncedSkillsCount)
        }
        return L("中央库、Agent 分发和项目工作区状态正常。")
    }

    private func performCompactCommand(_ action: SkillCommandAction) {
        switch action {
        case .importLocal:
            withAnimation(AgentToolsMotion.selection) {
                drawerSection = .install
                installTab = .local
            }
            runCommandTask(action)
        case .scan:
            withAnimation(AgentToolsMotion.selection) {
                drawerSection = .install
                installTab = .scan
            }
            runCommandTask(action)
        case .syncUnsynced, .checkUpdates:
            runCommandTask(action)
        case .market:
            withAnimation(AgentToolsMotion.selection) {
                drawerSection = .install
                installTab = .market
            }
        case .updateAvailable, .library:
            withAnimation(AgentToolsMotion.selection) {
                drawerSection = .library
            }
        case .agents:
            openAgents?()
        }
    }

    private var compactDrawerTabs: some View {
        HStack(spacing: 2) {
            ForEach(SkillDrawerSection.allCases) { section in
                Button {
                    withAnimation(AgentToolsMotion.selection) {
                        drawerSection = section
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: section.icon)
                            .font(.system(size: 10, weight: .semibold))
                        Text(section.title)
                            .font(.system(size: 10.5, weight: drawerSection == section ? .bold : .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(drawerSection == section ? AppStyle.textPrimary : AppStyle.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                    .skillRailItemSurface(selected: drawerSection == section)
                }
                .buttonStyle(.plain)
                .help(section.title)
            }
        }
        .padding(3)
        .skillSoftSurface(opacity: 0.82)
    }

    @ViewBuilder
    private var compactDrawerContent: some View {
        switch drawerSection {
        case .library:
            compactPrimaryActions
            compactLibraryDrawer
        case .install:
            discoveredContent
        case .detail:
            compactDetailDrawer
        }
    }

    private var compactPrimaryActions: some View {
        VStack(alignment: .leading, spacing: 7) {
            compactPanelTitle(icon: "bolt.fill", title: L("快速动作"), value: nil)
            let tasks = commandTasks
            ForEach(Array(tasks.prefix(3))) { task in
                Button {
                    performCompactCommand(task.action)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: task.icon)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(task.tint)
                            .frame(width: 22, height: 22)
                            .skillIconSurface(color: task.tint, shape: .circle)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(task.title)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(AppStyle.textPrimary)
                                .lineLimit(1)
                            Text(task.detail)
                                .font(.system(size: 9.5))
                                .foregroundStyle(AppStyle.textTertiary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if let count = task.count {
                            tinyBadge("\(count)", color: task.tint)
                        }
                        Image(systemName: task.action == .importLocal ? "arrow.down" : "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(task.tint)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 38)
                    .skillRowSurface(tint: task.tint)
                }
                .buttonStyle(PressScaleStyle())
                .help(task.detail)
            }
        }
        .padding(10)
        .skillPanelSurface()
    }

    private var compactLibraryPreview: some View {
        VStack(alignment: .leading, spacing: 7) {
            compactPanelTitle(icon: "square.stack.3d.up", title: L("技能库"), value: "\(filteredSkills.count)")
            if filteredSkills.isEmpty {
                compactEmpty(icon: "tray", title: L("还没有 Skill"))
                    .frame(height: 68)
            } else {
                ForEach(filteredSkills.prefix(5)) { skill in
                    SkillCommandRow(
                        skill: skill,
                        active: inspectedSkill?.id == skill.id,
                        healthColor: skillHealthColor(skill)) {
                            inspectSkill(skill)
                        }
                }
            }
        }
        .padding(10)
        .skillPanelSurface()
    }

    private var compactLibraryDrawer: some View {
        VStack(alignment: .leading, spacing: 10) {
            searchField
            compactLibraryPreview
            if inspectedSkill != nil {
                commandInspectorPanel
                    .transition(AgentToolsMotion.revealTransition)
            }
        }
        .animation(AgentToolsMotion.reveal, value: inspectedSkill?.id)
    }

    private var compactDetailDrawer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if inspectedSkill == nil {
                compactLibraryPreview
            }
            commandInspectorPanel
        }
    }

    private var workbenchSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            SkillRailBrand(
                icon: "wand.and.stars",
                title: "Skills Manager",
                subtitle: L("Central Library"),
                tint: AppStyle.accent)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    workbenchRailSection(L("工作台")) {
                        let primary: [SkillManagerSection] = agentFocused
                            ? [.workspace, .agents]
                            : [.library, .discover, .workspace]
                        ForEach(primary) { section in
                            workbenchSidebarItem(section)
                        }
                    }

                    if !agentFocused {
                        workbenchRailSection("Presets") {
                            workbenchSidebarItem(.deploy)
                            ForEach(Array(presets.prefix(6))) { preset in
                                workbenchPresetItem(preset)
                            }
                            if presets.count > 6 {
                                workbenchOverflowHint(count: presets.count - 6)
                            }
                        }

                        workbenchRailSection(L("项目")) {
                            workbenchSidebarItem(.projects)
                            ForEach(Array(projects.prefix(6))) { project in
                                workbenchProjectItem(project)
                            }
                            if projects.count > 6 {
                                workbenchOverflowHint(count: projects.count - 6)
                            }
                        }

                    }

                    if !agentFocused {
                        workbenchRailSection(L("迁移")) {
                            workbenchSidebarItem(.activity)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
            .scrollIndicators(.never)

            Spacer(minLength: 0)

            if !agentFocused {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("中央库"))
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(AppStyle.textTertiary)
                    HStack(spacing: 6) {
                        ToolBadge(text: L("%ld Skills", skills.count), color: AppStyle.textTertiary, style: .muted, height: 20)
                        ToolBadge(text: L("%ld Agent", availableTools.count), color: AppStyle.textTertiary, style: .muted, height: 20)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .skillRailSurface()
    }

    private func workbenchSidebarItem(_ section: SkillManagerSection) -> some View {
        let selected = selectedSection == section
        return Button {
            selectWorkbenchSection(section)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: section.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(selected ? AppStyle.accent : AppStyle.textTertiary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(section.title)
                        .font(.system(size: 11.5, weight: selected ? .bold : .semibold))
                        .foregroundStyle(selected ? AppStyle.textPrimary : AppStyle.textSecondary)
                        .lineLimit(1)
                    Text(section.sidebarHint)
                        .font(.system(size: 8.8, weight: .medium))
                        .foregroundStyle(AppStyle.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if let badge = sectionBadge(section) {
                    Text(badge)
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(selected ? AppStyle.accent : AppStyle.textTertiary)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 38)
            .skillRailItemSurface(selected: selected)
        }
        .buttonStyle(.plain)
        .help(section.subtitle)
    }

    private func workbenchRailSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(AppStyle.textTertiary)
                .padding(.horizontal, 9)
                .textCase(.uppercase)
            content()
        }
    }

    private func workbenchPresetItem(_ preset: SkillPreset) -> some View {
        workbenchObjectItem(
            icon: "rectangle.stack",
            title: preset.name,
            detail: L("%ld 个 Skill", preset.skills.count),
            badge: nil,
            selected: selectedSection == .deploy && expandedPresetID == preset.id) {
                withAnimation(AgentToolsMotion.selection) {
                    selectedSection = .deploy
                    expandedPresetID = preset.id
                }
            }
            .contextMenu {
                Button(L("打开")) {
                    selectedSection = .deploy
                    expandedPresetID = preset.id
                }
                Button(L("应用 Preset")) { applyPreset(preset) }
                Button(L("移除 Preset 同步")) { removePreset(preset) }
                Divider()
                Button(L("删除 Preset"), role: .destructive) { pendingPresetDelete = preset }
            }
    }

    private func workbenchProjectItem(_ project: SkillProject) -> some View {
        let targetCount = projectTargets.filter { $0.projectID == project.id }.count
        return workbenchObjectItem(
            icon: "folder",
            title: project.name,
            detail: collapsedPath(project.path),
            badge: targetCount > 0 ? "\(targetCount)" : nil,
            selected: selectedSection == .projects && expandedProjectID == project.id) {
                withAnimation(AgentToolsMotion.selection) {
                    selectedSection = .projects
                    expandedProjectID = project.id
                }
            }
            .contextMenu {
                Button(L("打开")) {
                    selectedSection = .projects
                    expandedProjectID = project.id
                }
                Button(L("在 Finder 显示")) { reveal(project.path) }
                Divider()
                Button(L("移除项目"), role: .destructive) { pendingProjectDelete = project }
            }
    }

    private func workbenchObjectItem(icon: String,
                                     title: String,
                                     detail: String,
                                     badge: String?,
                                     selected: Bool,
                                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(selected ? AppStyle.accent : AppStyle.textTertiary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 10.5, weight: selected ? .bold : .semibold))
                        .foregroundStyle(selected ? AppStyle.textPrimary : AppStyle.textSecondary)
                        .lineLimit(1)
                    Text(detail)
                        .font(.system(size: 8.8))
                        .foregroundStyle(AppStyle.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if let badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(selected ? AppStyle.accent : AppStyle.textTertiary)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 34)
            .skillRailItemSurface(selected: selected)
        }
        .buttonStyle(.plain)
    }

    private func workbenchOverflowHint(count: Int) -> some View {
        Text(L("还有 %ld 个", count))
            .font(.system(size: 9))
            .foregroundStyle(AppStyle.textTertiary)
            .padding(.horizontal, 30)
            .frame(height: 18)
    }

    private func selectWorkbenchSection(_ section: SkillManagerSection) {
        withAnimation(AgentToolsMotion.selection) {
            selectedSection = section
            if section != .workspace {
                focusedWorkspaceToolKey = nil
            }
        }
    }

    private func sectionBadge(_ section: SkillManagerSection) -> String? {
        switch section {
        case .dashboard:
            return nil
        case .library:
            return "\(skills.count)"
        case .discover:
            return nil
        case .workspace:
            return "\(availableTools.count)"
        case .deploy:
            return "\(presets.count)"
        case .projects:
            return "\(projects.count)"
        case .maintain:
            return nil
        case .activity:
            return auditEntries.isEmpty ? nil : "\(auditEntries.count)"
        case .agents:
            return "\(tools.filter(\.installed).count)"
        }
    }

    private func compactPanelTitle(icon: String, title: String, value: String?) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(AppStyle.accent)
            Text(title)
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(AppStyle.textPrimary)
            Spacer(minLength: 0)
            if let value {
                Text(value)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(AppStyle.textTertiary)
            }
        }
    }

    private func normalizeSelectedSection() {
        guard !visibleSections.contains(selectedSection),
              let fallback = visibleSections.first else { return }
        selectedSection = fallback
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(AppStyle.textTertiary)
            TextField(L("搜索 Skill / 标签 / 来源"), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(AppStyle.textPrimary)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(AppStyle.textTertiary)
                }
                .buttonStyle(.plain)
                .help(L("清空搜索"))
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .skillControlSurface()
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if let error {
                    ToolStatusLine(icon: "exclamationmark.triangle.fill", text: error, color: AppStyle.errorRed)
                }

                switch selectedSection {
                case .dashboard:
                    libraryWorkbenchContent
                case .library:
                    libraryWorkbenchContent
                case .deploy:
                    deployContent
                case .discover:
                    discoveredContent
                case .workspace:
                    workspaceContent
                case .projects:
                    projectsContent
                case .maintain:
                    maintenanceActionPanel
                case .activity:
                    backupActivityContent
                case .agents:
                    agentsContent
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .scrollIndicators(.never)
    }

    @ViewBuilder
    private var deployContent: some View {
        deploymentSummaryPanel
        presetsContent
    }

    @ViewBuilder
    private var workspaceContent: some View {
        workspaceSummaryPanel
        if availableTools.isEmpty {
            emptyState(
                icon: "cpu",
                title: L("没有可用 Agent"),
                detail: L("启用或添加可接收 Skill 的工具"))
        } else if let focusedWorkspaceToolKey,
                  let tool = availableTools.first(where: { $0.key == focusedWorkspaceToolKey }) {
            agentWorkspaceDetail(tool)
        } else {
            ForEach(availableTools) { tool in
                AgentWorkspaceRow(
                    tool: tool,
                    skills: skills.filter { skill in
                        skill.targets.contains { $0.tool == tool.key }
                    },
                    unsyncedCount: unsyncedSkillsCount,
                    onReveal: { reveal(tool.skillsDirectory) },
                    onOpenAgents: { openAgentsView() })
            }
        }
    }

    private var workspaceSummaryPanel: some View {
        HStack(spacing: 8) {
            ToolBadge(text: L("%ld Agent", availableTools.count), color: AppStyle.textTertiary, style: .muted)
            ToolBadge(text: L("%ld 目标", deployedTargetCount), color: deployedTargetCount == 0 ? AppStyle.textTertiary : AppStyle.accent)
            ToolBadge(text: L("覆盖率 %@", deploymentCoverageSummary), color: deploymentCoverageColor)
            if focusedWorkspaceToolKey != nil {
                ToolActionButton(
                    title: L("全部 Agent"),
                    systemImage: "rectangle.grid.1x2",
                    height: 26,
                    fontSize: 10.5,
                    horizontalPadding: 9) {
                        focusedWorkspaceToolKey = nil
                    }
            }
            Spacer(minLength: 0)
            ToolActionButton(
                title: L("分发未同步"),
                systemImage: "arrow.triangle.2.circlepath",
                role: .tinted(AppStyle.accent),
                height: 26,
                fontSize: 10.5,
                horizontalPadding: 9,
                help: L("把未同步的 Skills 分发到可用 Agent")) {
                    syncUnsyncedSkills()
                }
                .disabled(unsyncedSkillsCount == 0 || availableTools.isEmpty)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .skillPanelSurface()
    }

    private func agentWorkspaceDetail(_ tool: SkillToolInfo) -> some View {
        let syncedSkills = skills.filter { skill in
            skill.targets.contains { $0.tool == tool.key }
        }
        let localGroups = (scanResult?.groups ?? []).filter { group in
            group.locations.contains { $0.tool == tool.key }
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                SkillAgentIconView(tool: tool, size: 34, cornerRadius: 9)
                    .opacity(tool.enabled ? 1 : 0.5)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(tool.displayName)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(AppStyle.textPrimary)
                        tinyBadge(tool.enabled ? L("启用") : L("停用"), color: tool.enabled ? AppStyle.accent : AppStyle.waitAmber)
                        tinyBadge(tool.installed ? L("已检测") : L("未检测"), color: tool.installed ? AppStyle.textTertiary : AppStyle.waitAmber)
                    }
                    Text(collapsedPath(tool.skillsDirectory))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(AppStyle.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                ToolActionButton(title: tool.enabled ? L("停用 Agent") : L("启用 Agent"), systemImage: tool.enabled ? "pause.circle" : "play.circle", height: 26, fontSize: 10.5, horizontalPadding: 9) {
                    toggleToolEnabled(tool)
                }
                ToolActionButton(title: L("显示"), systemImage: "folder", height: 26, fontSize: 10.5, horizontalPadding: 9) {
                    reveal(tool.skillsDirectory)
                }
            }

            HStack(spacing: 6) {
                ToolBadge(text: L("%ld Skills", syncedSkills.count), color: syncedSkills.isEmpty ? AppStyle.textTertiary : AppStyle.accent)
                ToolBadge(text: L("%ld 本地发现", localGroups.count), color: localGroups.isEmpty ? AppStyle.textTertiary : AppStyle.waitAmber)
                if let relative = tool.projectRelativeSkillsDir, !relative.isEmpty {
                    ToolBadge(text: collapsedPath(relative), color: AppStyle.textTertiary, style: .muted)
                }
            }

            if syncedSkills.isEmpty {
                compactEmpty(icon: "tray", title: L("这个 Agent 还没有由 Conductor 同步的 Skill。"))
                    .frame(height: 72)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("已部署 Skills"))
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(AppStyle.textSecondary)
                    ForEach(syncedSkills.prefix(10)) { skill in
                        SkillCommandRow(
                            skill: skill,
                            active: inspectedSkill?.id == skill.id,
                            healthColor: skillHealthColor(skill)) {
                                inspectSkill(skill)
                                selectedSection = .library
                            }
                    }
                    if syncedSkills.count > 10 {
                        Text(L("还有 %ld 个", syncedSkills.count - 10))
                            .font(.system(size: 10))
                            .foregroundStyle(AppStyle.textTertiary)
                    }
                }
            }

            if !localGroups.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("本地发现"))
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(AppStyle.textSecondary)
                    ForEach(localGroups.prefix(8)) { group in
                        DiscoveredSkillGroupRow(
                            group: group,
                            selected: selectedDiscoveryGroupIDs.contains(group.id),
                            onToggleSelection: { toggleDiscoveryGroupSelection(group) },
                            onImport: { importDiscovered(group) },
                            onReveal: { path in reveal(path) })
                    }
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .skillPanelSurface()
    }

    @ViewBuilder
    private var backupActivityContent: some View {
        ToolsSectionLabel(L("备份与迁移"))
        archivePanel

        ToolsSectionLabel(L("活动记录"))
        activityContent
    }

    private var deploymentSummaryPanel: some View {
        HStack(spacing: 8) {
            ToolBadge(text: L("%ld Skills", skills.count), color: AppStyle.textTertiary, style: .muted)
            ToolBadge(text: L("%ld Agent", availableTools.count), color: AppStyle.textTertiary, style: .muted)
            ToolBadge(text: L("%ld 目标", deployedTargetCount), color: deployedTargetCount == 0 ? AppStyle.textTertiary : AppStyle.accent)
            if unsyncedSkillsCount > 0 {
                ToolBadge(text: L("%ld 未同步", unsyncedSkillsCount), color: AppStyle.waitAmber)
            }
            Spacer(minLength: 0)
            ToolActionButton(
                title: L("分发未同步"),
                systemImage: "arrow.triangle.2.circlepath",
                role: .tinted(AppStyle.accent),
                height: 26,
                fontSize: 10.5,
                horizontalPadding: 9,
                help: L("把未同步的 Skills 分发到可用 Agent")) {
                    syncUnsyncedSkills()
                }
                .disabled(unsyncedSkillsCount == 0 || availableTools.isEmpty)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .skillPanelSurface()
    }

    private var maintenanceActionPanel: some View {
        HStack(spacing: 8) {
            if !updatableSkills.isEmpty {
                ToolBadge(text: L("%ld 可更新", updatableSkills.count), color: AppStyle.waitAmber)
                ToolActionButton(
                    title: L("更新"),
                    systemImage: "arrow.down.circle",
                    role: .tinted(AppStyle.waitAmber),
                    height: 26,
                    fontSize: 10.5,
                    horizontalPadding: 9) {
                        updateAvailableSkills()
                    }
            }
            if sourceProblemSkillsCount > 0 {
                ToolBadge(text: L("%ld 来源异常", sourceProblemSkillsCount), color: AppStyle.errorRed)
                ToolActionButton(
                    title: L("查看"),
                    systemImage: "exclamationmark.triangle",
                    role: .destructive,
                    height: 26,
                    fontSize: 10.5,
                    horizontalPadding: 9) {
                        selectedSkillIDs = Set(skills.filter { ["source_missing", "error"].contains($0.updateStatus) }.map(\.id))
                        if let first = skills.first(where: { selectedSkillIDs.contains($0.id) }) {
                            inspectSkill(first)
                        }
                        selectedSection = .library
                    }
            }
            Spacer(minLength: 0)
            ToolActionButton(
                title: L("检查全部"),
                systemImage: "checkmark.seal",
                height: 26,
                fontSize: 10.5,
                horizontalPadding: 9) {
                    checkAllSkillUpdates()
                }
                .disabled(skills.allSatisfy { !canRefreshFromSource($0) })
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .skillPanelSurface()
    }

    private var archivePanel: some View {
        HStack(spacing: 8) {
            ToolActionButton(
                title: L("导入 Bundle"),
                systemImage: "square.and.arrow.down",
                role: .tinted(AppStyle.accent),
                height: 28,
                fontSize: 10.5,
                horizontalPadding: 10,
                help: L("导入 Conductor Skill Bundle、单个 Skill 或父目录")) {
                    importLocal()
                }

            ToolActionButton(
                title: L("导出全部"),
                systemImage: "square.and.arrow.up",
                height: 28,
                fontSize: 10.5,
                horizontalPadding: 10,
                help: L("把中央库全部 Skills 导出为可迁移 Bundle")) {
                    exportAllSkills()
                }
                .disabled(skills.isEmpty)

            ToolActionButton(
                title: L("导出选中"),
                systemImage: "checkmark.circle",
                height: 28,
                fontSize: 10.5,
                horizontalPadding: 10,
                help: L("把当前选中的 Skills 导出为 Bundle")) {
                    exportSelectedSkills()
                }
                .disabled(selectedSkillIDs.isEmpty)

            Spacer(minLength: 0)

            ToolBadge(text: L("%ld 活动", auditEntries.count), color: AppStyle.textTertiary, style: .muted, height: 22)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .skillPanelSurface()
    }

    private var commandInspectorPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            commandPanelHeader(
                icon: "sidebar.right",
                title: L("当前 Skill"),
                value: inspectedSkill?.name ?? L("未选择"))

            if let skill = inspectedSkill {
                inspectorBody(skill)
                    .id(skill.id)
                    .transition(AgentToolsMotion.contentTransition)
            } else {
                compactEmpty(icon: "cursorarrow.click", title: L("选择一个 Skill"))
                    .transition(AgentToolsMotion.revealTransition)
            }
        }
        .padding(11)
        .skillPanelSurface()
        .animation(AgentToolsMotion.reveal, value: inspectedSkill?.id)
    }

    private func inspectorBody(_ skill: ManagedSkill) -> some View {
        let hasDeploymentSurface = !availableTools.isEmpty || !skill.targets.isEmpty

        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(skill.name)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(AppStyle.textPrimary)
                        .lineLimit(1)
                    tinyBadge(skill.sourceType.rawValue, color: AppStyle.textTertiary)
                }
                Text((skill.description?.isEmpty == false) ? skill.description! : collapsedPath(skill.centralPath))
                    .font(.system(size: 10.5))
                    .foregroundStyle(AppStyle.textSecondary)
                    .lineLimit(2)
            }

            HStack(spacing: 6) {
                Button { openSkillDetail(skill) } label: {
                    Label(L("详情"), systemImage: "rectangle.and.text.magnifyingglass")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .skillPrimaryControlSurface()
                }
                .buttonStyle(PressScaleStyle())
                .help(L("打开 Skill 详情控制台"))

                Button { syncAll(skill) } label: {
                    Label(L("同步"), systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(AppStyle.textSecondary)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .skillControlSurface()
                }
                .buttonStyle(PressScaleStyle())

                if canRefreshFromSource(skill) {
                    iconButton("magnifyingglass.circle", help: L("检查更新")) {
                        checkSkillUpdate(skill)
                    }
                    iconButton("arrow.clockwise.circle", help: L("刷新来源")) {
                        refreshSkillFromSource(skill)
                    }
                }
                iconButton("folder", help: L("在 Finder 显示")) { reveal(skill.centralPath) }
                iconButton("trash", help: L("删除"), destructive: true) { pendingDelete = skill }
            }

            inspectorStatusGrid(skill)
            if hasDeploymentSurface {
                inspectorQuickDeployment(skill)
                    .transition(AgentToolsMotion.revealTransition)
            }
        }
    }

    private func inspectorStatusGrid(_ skill: ManagedSkill) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                statusPill(title: L("Agent"), value: "\(skill.targets.count)", color: skill.targets.isEmpty ? AppStyle.textTertiary : AppStyle.accent)
                statusPill(title: L("标签"), value: "\(skill.tags.count)", color: AppStyle.textTertiary)
                statusPill(title: L("更新"), value: inspectorUpdateLabel(skill), color: skillHealthColor(skill))
            }
            if !skill.tags.isEmpty {
                HStack(spacing: 5) {
                    ForEach(skill.tags.prefix(6), id: \.self) { tag in
                        tinyBadge(tag, color: AppStyle.textTertiary)
                    }
                }
            }
        }
    }

    private func inspectorQuickDeployment(_ skill: ManagedSkill) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(L("部署"))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(AppStyle.textSecondary)
                Spacer()
                Button {
                    openSkillDetail(skill, tab: .deploy)
                } label: {
                    Label(L("矩阵"), systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(AppStyle.textTertiary)
                }
                .buttonStyle(.plain)
                .help(L("打开完整部署矩阵"))
            }

            if availableTools.isEmpty {
                compactEmpty(icon: "cpu", title: L("没有可用 Agent"))
                    .frame(height: 56)
            } else {
                LazyVGrid(columns: [
                    GridItem(.adaptive(minimum: 74), spacing: 6),
                ], spacing: 6) {
                    ForEach(Array(availableTools.prefix(6))) { tool in
                        let synced = skill.targets.contains { $0.tool == tool.key }
                        Button {
                            toggle(skill: skill, tool: tool, enabled: !synced)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: synced ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 9.5, weight: .semibold))
                                Text(tool.displayName)
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(synced ? .white : AppStyle.textSecondary)
                            .padding(.horizontal, 6)
                            .frame(maxWidth: .infinity)
                            .frame(height: 24)
                            .skillControlSurface(active: synced, tint: AppStyle.accent)
                        }
                        .buttonStyle(PressScaleStyle())
                        .help(synced ? L("移除同步") : L("同步到该 Agent"))
                    }
                }
            }
        }
    }

    private func commandPanelHeader(icon: String, title: String, value: String) -> some View {
        SkillPanelTitle(icon: icon, title: title, value: value)
    }

    private func compactEmpty(icon: String, title: String) -> some View {
        ToolEmptyState(icon: icon, title: title, compact: true)
    }

    private func statusPill(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(AppStyle.textTertiary)
            Text(value)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 38)
        .skillSoftSurface()
    }

    private func skillHealthColor(_ skill: ManagedSkill) -> Color {
        switch skill.updateStatus {
        case "update_available": return AppStyle.waitAmber
        case "source_missing", "error": return AppStyle.errorRed
        default:
            return skill.targets.isEmpty ? AppStyle.textTertiary : AppStyle.accent
        }
    }

    private func inspectorUpdateLabel(_ skill: ManagedSkill) -> String {
        switch skill.updateStatus {
        case "current": return L("最新")
        case "update_available": return L("可更新")
        case "source_missing": return L("失效")
        case "error": return L("错误")
        default: return L("未知")
        }
    }

    private func readinessItems(for skill: ManagedSkill) -> [SkillReadinessItem] {
        let files = skillFiles[skill.id] ?? []
        let hasKnownSkillDocument = skillDocuments[skill.id] != nil ||
            files.contains { $0.relativePath.lowercased() == "skill.md" }
        let hasDescription = skill.description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let sourceProblem = ["source_missing", "error"].contains(skill.updateStatus)
        let canRefresh = canRefreshFromSource(skill)

        return [
            SkillReadinessItem(
                id: "document",
                title: "SKILL.md",
                detail: hasKnownSkillDocument ? L("已识别") : L("待读取"),
                ready: hasKnownSkillDocument,
                icon: "doc.text.magnifyingglass",
                color: AppStyle.waitAmber),
            SkillReadinessItem(
                id: "description",
                title: L("摘要"),
                detail: hasDescription ? L("清晰") : L("缺少描述"),
                ready: hasDescription,
                icon: "text.alignleft",
                color: AppStyle.waitAmber),
            SkillReadinessItem(
                id: "deployment",
                title: L("分发"),
                detail: skill.targets.isEmpty ? L("未同步") : L("%ld Agent", skill.targets.count),
                ready: !skill.targets.isEmpty,
                icon: "arrow.triangle.2.circlepath",
                color: AppStyle.waitAmber),
            SkillReadinessItem(
                id: "source",
                title: L("来源"),
                detail: sourceProblem ? inspectorUpdateLabel(skill) : (canRefresh ? L("可维护") : L("静态")),
                ready: !sourceProblem,
                icon: "link.badge.plus",
                color: sourceProblem ? AppStyle.errorRed : AppStyle.textTertiary),
            SkillReadinessItem(
                id: "tags",
                title: L("分类"),
                detail: skill.tags.isEmpty ? L("未打标签") : L("%ld 标签", skill.tags.count),
                ready: !skill.tags.isEmpty,
                icon: "tag",
                color: AppStyle.textTertiary),
        ]
    }

    @ViewBuilder
    private var libraryWorkbenchContent: some View {
        if loading && skills.isEmpty {
            loadingRow
        } else if filteredSkills.isEmpty {
            emptyState(
                icon: "tray",
                title: query.isEmpty ? L("中央库还没有 Skill") : L("没有匹配的 Skill"),
                detail: L("从 Discover 添加，或扫描本机已有 Agent Skills 后纳入管理。"))
        } else {
            libraryHealthStrip
            libraryFilterBar
            if !selectedSkillIDs.isEmpty {
                librarySelectionBar
                    .transition(AgentToolsMotion.revealTransition)
            }
            libraryWorkspaceLayout
        }
    }

    private var libraryWorkspaceLayout: some View {
        ViewThatFits(in: .horizontal) {
            libraryWorkspaceColumns(inspectorWidth: 318, gridMinimum: 220, minLibraryWidth: 340)
            libraryWorkspaceColumns(inspectorWidth: 260, gridMinimum: 190, minLibraryWidth: 300)
            libraryWorkspaceColumns(inspectorWidth: nil, gridMinimum: 190, minLibraryWidth: 0)
        }
        .animation(AgentToolsMotion.route, value: libraryViewMode)
        .animation(AgentToolsMotion.selection, value: inspectedSkill?.id)
    }

    private func libraryWorkspaceColumns(inspectorWidth: CGFloat?,
                                         gridMinimum: CGFloat,
                                         minLibraryWidth: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 10) {
            libraryCollection(gridMinimum: gridMinimum)
                .frame(minWidth: minLibraryWidth, maxWidth: .infinity, alignment: .topLeading)

            if let skill = inspectedSkill, let inspectorWidth {
                libraryInspector(for: skill)
                    .frame(width: inspectorWidth)
                    .transition(AgentToolsMotion.revealTransition)
            }
        }
    }

    @ViewBuilder
    private func libraryCollection(gridMinimum: CGFloat) -> some View {
        switch libraryViewMode {
        case .list:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(filteredSkills) { skill in
                    libraryRow(for: skill)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        case .grid:
            LazyVGrid(columns: [GridItem(.adaptive(minimum: gridMinimum), spacing: 8)], spacing: 8) {
                ForEach(filteredSkills) { skill in
                    libraryCard(for: skill)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func libraryRow(for skill: ManagedSkill) -> some View {
        SkillLibraryRow(
            skill: skill,
            active: inspectedSkill?.id == skill.id,
            selected: selectedSkillIDs.contains(skill.id),
            healthLabel: libraryHealthLabel(skill),
            healthColor: skillHealthColor(skill),
            updateLabel: inspectorUpdateLabel(skill),
            canRefreshFromSource: canRefreshFromSource(skill),
            allTags: allTags,
            onActivate: { inspectSkill(skill) },
            onToggleSelection: { toggleSkillSelection(skill.id) },
            onOpenDetail: { openSkillDetail(skill) },
            onSync: { syncAll(skill) },
            onCheckUpdate: { checkSkillUpdate(skill) },
            onRefreshSource: { refreshSkillFromSource(skill) },
            onAddTag: { tag in
                if let tag {
                    applyTag(tag, to: [skill.id], add: true)
                } else {
                    promptTag(for: skill, add: true)
                }
            },
            onRemoveTag: { tag in
                applyTag(tag, to: [skill.id], add: false)
            },
            onReveal: { reveal(skill.centralPath) },
            onDelete: { pendingDelete = skill })
    }

    private func libraryCard(for skill: ManagedSkill) -> some View {
        SkillLibraryCard(
            skill: skill,
            active: inspectedSkill?.id == skill.id,
            selected: selectedSkillIDs.contains(skill.id),
            healthLabel: libraryHealthLabel(skill),
            healthColor: skillHealthColor(skill),
            updateLabel: inspectorUpdateLabel(skill),
            canRefreshFromSource: canRefreshFromSource(skill),
            allTags: allTags,
            onActivate: { inspectSkill(skill) },
            onToggleSelection: { toggleSkillSelection(skill.id) },
            onOpenDetail: { openSkillDetail(skill) },
            onSync: { syncAll(skill) },
            onCheckUpdate: { checkSkillUpdate(skill) },
            onRefreshSource: { refreshSkillFromSource(skill) },
            onAddTag: { tag in
                if let tag {
                    applyTag(tag, to: [skill.id], add: true)
                } else {
                    promptTag(for: skill, add: true)
                }
            },
            onRemoveTag: { tag in
                applyTag(tag, to: [skill.id], add: false)
            },
            onReveal: { reveal(skill.centralPath) },
            onDelete: { pendingDelete = skill })
    }

    private func libraryInspector(for skill: ManagedSkill) -> some View {
        SkillLibraryInspectorPanel(
            skill: skill,
            tools: Array(availableTools.prefix(8)),
            sourcePath: collapsedPath(skill.centralPath),
            syncMode: syncModeLabel,
            canRefreshFromSource: canRefreshFromSource(skill),
            onOpenDetail: { openSkillDetail(skill) },
            onSyncAll: { syncAll(skill) },
            onToggleTool: { tool, enabled in
                toggle(skill: skill, tool: tool, enabled: enabled)
            },
            onCheckUpdate: { checkSkillUpdate(skill) },
            onRefreshSource: { refreshSkillFromSource(skill) },
            onReveal: { reveal(skill.centralPath) },
            onDelete: { pendingDelete = skill })
    }

    private var libraryHealthStrip: some View {
        HStack(spacing: 8) {
            ToolBadge(text: L("%ld 个 Skill", filteredSkills.count), color: AppStyle.textTertiary, style: .muted)
            if unsyncedSkillsCount > 0 {
                ToolBadge(text: L("%ld 未同步", unsyncedSkillsCount), color: AppStyle.waitAmber)
            }
            if !updatableSkills.isEmpty {
                ToolBadge(text: L("%ld 可更新", updatableSkills.count), color: AppStyle.waitAmber)
            }
            if sourceProblemSkillsCount > 0 {
                ToolBadge(text: L("%ld 来源异常", sourceProblemSkillsCount), color: AppStyle.errorRed)
            }
            Spacer(minLength: 0)
            libraryViewModeToggle
            ToolActionButton(
                title: L("全选"),
                systemImage: "checklist",
                height: 24,
                fontSize: 10.5,
                horizontalPadding: 9) {
                    selectAllFilteredSkills()
                }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .skillPanelSurface()
    }

    private var libraryViewModeToggle: some View {
        HStack(spacing: 2) {
            ForEach(SkillLibraryViewMode.allCases) { mode in
                IconOnlyButton(
                    systemName: mode.icon,
                    help: mode.title,
                    size: 24,
                    symbolSize: 10.5,
                    tint: libraryViewMode == mode ? AppStyle.accent : AppStyle.textTertiary) {
                        withAnimation(AgentToolsMotion.selection) { libraryViewMode = mode }
                    }
                    .skillControlSurface(
                        active: libraryViewMode == mode,
                        tint: AppStyle.accent.opacity(0.12),
                        disabled: false)
            }
        }
        .padding(2)
        .skillSoftSurface(opacity: 0.9)
    }

    private var librarySelectionBar: some View {
        HStack(spacing: 8) {
            ToolBadge(text: L("已选 %ld", selectedSkillIDs.count), color: AppStyle.accent)
            Spacer(minLength: 0)
            Menu {
                Button(L("添加标签…")) { promptTagForSelection(add: true) }
                if !allTags.isEmpty {
                    Menu(L("添加已有标签")) {
                        ForEach(allTags, id: \.self) { tag in
                            Button(tag) { applyTag(tag, to: Array(selectedSkillIDs), add: true) }
                        }
                    }
                    Menu(L("移除已有标签")) {
                        ForEach(allTags, id: \.self) { tag in
                            Button(tag) { applyTag(tag, to: Array(selectedSkillIDs), add: false) }
                        }
                    }
                }
                Button(L("移除标签…")) { promptTagForSelection(add: false) }
            } label: {
                Label(L("标签"), systemImage: "tag")
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .disabled(selectedSkillIDs.isEmpty)

            ToolActionButton(
                title: L("同步"),
                systemImage: "arrow.triangle.2.circlepath",
                role: .tinted(AppStyle.accent),
                height: 24,
                fontSize: 10.5,
                horizontalPadding: 9) {
                    syncSelectedSkills()
                }
            ToolActionButton(
                title: L("导出"),
                systemImage: "square.and.arrow.up",
                height: 24,
                fontSize: 10.5,
                horizontalPadding: 9) {
                    exportSelectedSkills()
                }
            ToolActionButton(
                title: L("删除"),
                systemImage: "trash",
                role: .destructive,
                height: 24,
                fontSize: 10.5,
                horizontalPadding: 9) {
                    pendingBatchDelete = true
                }
            IconOnlyButton(
                systemName: "xmark",
                help: L("清空选择"),
                size: 24,
                symbolSize: 10.5) {
                    selectedSkillIDs.removeAll()
                }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .skillPanelSurface()
    }

    private func libraryHealthLabel(_ skill: ManagedSkill) -> String {
        switch skill.updateStatus {
        case "update_available": return L("可更新")
        case "source_missing": return L("来源失效")
        case "error": return L("错误")
        default:
            return skill.targets.isEmpty ? L("未同步") : L("正常")
        }
    }

    @ViewBuilder
    private var libraryContent: some View {
        if loading && skills.isEmpty {
            loadingRow
        } else if filteredSkills.isEmpty {
            emptyState(
                icon: "tray",
                title: query.isEmpty ? L("中央库还没有 Skill") : L("没有匹配的 Skill"),
                detail: L("从本地目录导入，或先扫描本机已有 Agent Skills 再纳入管理。"))
        } else {
            libraryFilterBar
            libraryBatchToolbar
            ForEach(filteredSkills) { skill in
                ManagedSkillRow(
                    skill: skill,
                    tools: Array(availableTools.prefix(14)),
                    expanded: expandedSkillID == skill.id,
                    selected: selectedSkillIDs.contains(skill.id),
                    document: skillDocuments[skill.id],
                    files: skillFiles[skill.id] ?? [],
                    sourceDiff: skillDiffs[skill.id],
                    syncMode: syncModeLabel,
                    onExpand: {
                        toggleSkillExpansion(skill)
                    },
                    onSelect: { toggleSkillSelection(skill.id) },
                    onOpenDetail: { openSkillDetail(skill) },
                    onToggleTool: { tool, enabled in
                        toggle(skill: skill, tool: tool, enabled: enabled)
                    },
                    onSyncAll: { syncAll(skill) },
                    onCheckUpdate: { checkSkillUpdate(skill) },
                    onRefreshSource: { refreshSkillFromSource(skill) },
                    onRelinkSource: { relinkSkillSource(skill) },
                    onDetachSource: { detachSkillSource(skill) },
                    onReveal: { reveal(skill.centralPath) },
                    onDelete: { pendingDelete = skill })
            }
        }
    }

    private var libraryFilterBar: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !sourceTypesInUse.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 5) {
                        ForEach(sourceTypesInUse, id: \.self) { source in
                            filterChip(
                                title: source == "skillssh" ? "skills.sh" : source,
                                active: sourceFilters.contains(source),
                                color: AppStyle.accent) {
                                    toggleString(source, in: &sourceFilters)
                                }
                        }
                    }
                    .padding(.vertical, 1)
                }
                .scrollIndicators(.never)
            }

            if !allTags.isEmpty || skills.contains(where: { $0.tags.isEmpty }) {
                ScrollView(.horizontal) {
                    HStack(spacing: 5) {
                        if skills.contains(where: { $0.tags.isEmpty }) {
                            filterChip(
                                title: L("未打标签"),
                                active: tagFilters.contains("__untagged__"),
                                color: AppStyle.waitAmber) {
                                    toggleString("__untagged__", in: &tagFilters)
                                }
                        }
                        ForEach(allTags, id: \.self) { tag in
                            filterChip(
                                title: tag,
                                active: tagFilters.contains(tag),
                                color: AppStyle.textTertiary) {
                                    toggleString(tag, in: &tagFilters)
                                }
                        }
                    }
                    .padding(.vertical, 1)
                }
                .scrollIndicators(.never)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .skillPanelSurface()
    }

    private var libraryBatchToolbar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                Button {
                    selectAllFilteredSkills()
                } label: {
                    Label(L("全选"), systemImage: "checklist")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(AppStyle.textSecondary)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .skillControlSurface()
                }
                .buttonStyle(PressScaleStyle())

                Button {
                    selectedSkillIDs.removeAll()
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(AppStyle.textSecondary)
                        .frame(width: 24, height: 24)
                        .skillIconSurface(color: AppStyle.textTertiary, shape: .circle)
                }
                .buttonStyle(PressScaleStyle())
                .help(L("清空选择"))

                tinyBadge(L("已选 %ld", selectedSkillIDs.count), color: selectedSkillIDs.isEmpty ? AppStyle.textTertiary : AppStyle.accent)

                Button {
                    syncSelectedSkills()
                } label: {
                    Label(L("同步"), systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(AppStyle.textSecondary)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .skillControlSurface()
                }
                .buttonStyle(PressScaleStyle())
                .disabled(selectedSkillIDs.isEmpty)

                Button {
                    refreshSelectedSkills()
                } label: {
                    Label(L("刷新来源"), systemImage: "arrow.clockwise.circle")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(AppStyle.textSecondary)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .skillControlSurface()
                }
                .buttonStyle(PressScaleStyle())
                .disabled(!selectedSkills.contains(where: canRefreshFromSource))

                Button {
                    updateAvailableSkills()
                } label: {
                    Label(L("更新可用"), systemImage: "arrow.down.circle")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(AppStyle.textSecondary)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .skillControlSurface()
                }
                .buttonStyle(PressScaleStyle())
                .disabled(updatableSkills.isEmpty)

                Button {
                    checkAllSkillUpdates()
                } label: {
                    Label(L("检查全部"), systemImage: "checkmark.seal")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(AppStyle.textSecondary)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .skillControlSurface()
                }
                .buttonStyle(PressScaleStyle())
                .disabled(skills.allSatisfy { !canRefreshFromSource($0) })

                Button {
                    checkSelectedSkillUpdates()
                } label: {
                    Label(L("检查更新"), systemImage: "magnifyingglass.circle")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(AppStyle.textSecondary)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .skillControlSurface()
                }
                .buttonStyle(PressScaleStyle())
                .disabled(!selectedSkills.contains(where: canRefreshFromSource))

                Button {
                    exportSelectedSkills()
                } label: {
                    Label(L("导出"), systemImage: "square.and.arrow.up")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(AppStyle.textSecondary)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .skillControlSurface()
                }
                .buttonStyle(PressScaleStyle())
                .disabled(selectedSkillIDs.isEmpty)

                TextField(L("标签"), text: $tagDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(AppStyle.textPrimary)
                    .padding(.horizontal, 8)
                    .frame(width: 150, height: 24)
                    .skillControlSurface()

                Button {
                    applyTagToSelection(add: true)
                } label: {
                    Label(L("添加"), systemImage: "tag.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .skillPrimaryControlSurface(disabled: !canApplyTag)
                }
                .buttonStyle(PressScaleStyle())
                .disabled(!canApplyTag)

                Button {
                    applyTagToSelection(add: false)
                } label: {
                    Label(L("移除"), systemImage: "tag.slash")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(AppStyle.textSecondary)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .skillControlSurface()
                }
                .buttonStyle(PressScaleStyle())
                .disabled(!canApplyTag)

                Button {
                    pendingBatchDelete = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(AppStyle.errorRed)
                        .frame(width: 24, height: 24)
                        .skillIconSurface(color: AppStyle.textTertiary, shape: .circle)
                }
                .buttonStyle(PressScaleStyle())
                .help(L("删除选中"))
                .disabled(selectedSkillIDs.isEmpty)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.never)
        .skillPanelSurface()
    }

    private var canApplyTag: Bool {
        !selectedSkillIDs.isEmpty && !tagDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var selectedSkills: [ManagedSkill] {
        skills.filter { selectedSkillIDs.contains($0.id) }
    }

    private var updatableSkills: [ManagedSkill] {
        skills.filter { $0.updateStatus == "update_available" && canRefreshFromSource($0) }
    }

    @ViewBuilder
    private var presetsContent: some View {
        presetCreator

        if filteredPresets.isEmpty {
            emptyState(
                icon: "rectangle.stack.badge.plus",
                title: query.isEmpty ? L("还没有 Preset") : L("没有匹配的 Preset"),
                detail: L("Preset 是一组可复用 Skills，能一键同步到当前可用 Agents。"))
        } else {
            ForEach(filteredPresets) { preset in
                PresetRow(
                    preset: preset,
                    summary: presetSummaries.first { $0.id == preset.id },
                    skills: skills,
                    expanded: expandedPresetID == preset.id,
                    onExpand: {
                        expandedPresetID = expandedPresetID == preset.id ? nil : preset.id
                    },
                    onApply: { applyPreset(preset) },
                    onRemove: { removePreset(preset) },
                    onDelete: { pendingPresetDelete = preset },
                    onToggleSkill: { skill, enabled in
                        togglePresetSkill(preset: preset, skill: skill, enabled: enabled)
                    },
                    onMoveSkill: { skill, offset in
                        movePresetSkill(preset: preset, skill: skill, offset: offset)
                    })
            }
        }
    }

    private var presetCreator: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppStyle.textTertiary)
            TextField(L("新 Preset 名称"), text: $newPresetName)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(AppStyle.textPrimary)
            Button {
                createPreset()
            } label: {
                Label(L("创建"), systemImage: "plus")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .skillPrimaryControlSurface(disabled: !canCreatePreset)
            }
            .buttonStyle(PressScaleStyle())
            .disabled(!canCreatePreset)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .skillPanelSurface()
    }

    private var canCreatePreset: Bool {
        !newPresetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private var projectsContent: some View {
        HStack(spacing: 8) {
            Button(action: addProject) {
                Label(L("添加项目"), systemImage: "folder.badge.gearshape")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .skillPrimaryControlSurface()
            }
            .buttonStyle(PressScaleStyle())
            Spacer()
        }

        if projects.isEmpty {
            emptyState(
                icon: "folder.badge.gearshape",
                title: L("还没有项目工作区"),
                detail: L("添加一个项目目录后，可以把中央库 Skills 同步到该项目的 .codex/.claude 等本地目录。"))
        } else {
            ForEach(projects) { project in
                ProjectWorkspaceRow(
                    project: project,
                    projectSkills: projectSkills[project.id] ?? [],
                    centralSkills: skills,
                    presets: presets,
                    tools: Array(projectTools.prefix(12)),
                    targets: projectTargets.filter { $0.projectID == project.id },
                    expanded: expandedProjectID == project.id,
                    onExpand: {
                        expandedProjectID = expandedProjectID == project.id ? nil : project.id
                    },
                    onReveal: { reveal(project.path) },
                    onDelete: { pendingProjectDelete = project },
                    onToggleSkill: { skill, tool, enabled in
                        toggleProjectSkill(project: project, skill: skill, tool: tool, enabled: enabled)
                    },
                    onApplyPreset: { preset in
                        applyPresetToProject(preset: preset, project: project)
                    },
                    onRemovePreset: { preset in
                        removePresetFromProject(preset: preset, project: project)
                    })
            }
        }
    }

    @ViewBuilder
    private var agentsContent: some View {
        HStack(spacing: 8) {
            Button(action: addCustomAgent) {
                Label(L("添加自定义 Agent"), systemImage: "plus.circle")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .skillPrimaryControlSurface()
            }
            .buttonStyle(PressScaleStyle())
            Spacer()
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .skillPanelSurface()

        if tools.isEmpty {
            loadingRow
        } else {
            ForEach(tools.sorted(by: toolSort)) { tool in
                SkillToolRow(
                    tool: tool,
                    syncedCount: skills.filter { skill in
                        skill.targets.contains { $0.tool == tool.key }
                    }.count,
                    onToggleEnabled: { toggleToolEnabled(tool) },
                    onReveal: { reveal(tool.skillsDirectory) })
            }
        }
    }

    @ViewBuilder
    private var activityContent: some View {
        if auditEntries.isEmpty {
            emptyState(
                icon: "clock.arrow.circlepath",
                title: L("还没有活动记录"),
                detail: L("导入、同步、刷新、删除、标签和 Agent 状态变化会出现在这里。"))
        } else {
            ForEach(auditEntries) { entry in
                SkillAuditRow(entry: entry)
            }
        }
    }

    @ViewBuilder
    private var discoveredContent: some View {
        installTabBar
        switch installTab {
        case .market:
            skillsShMarketPanel
        case .local:
            localInstallPanel
        case .git:
            gitInstallPanel
        case .scan:
            scanInstallContent
        }
    }

    private var installTabBar: some View {
        HStack(spacing: 8) {
            Picker("", selection: $installTab) {
                ForEach(SkillInstallTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.icon).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 420)
            Spacer(minLength: 0)
            if installTab == .scan, let scanResult {
                ToolBadge(text: L("发现 %ld", scanResult.skillsFound), color: AppStyle.textTertiary, style: .muted, height: 22)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .skillPanelSurface()
    }

    @ViewBuilder
    private var scanInstallContent: some View {
        scanInstallPanel
        if scanResult != nil {
            discoveryToolbar
        }

        if scanResult == nil {
            emptyState(
                icon: "scope",
                title: L("还没有扫描"),
                detail: L("扫描会查找各 Agent 目录里不是由 Conductor 管理的 Skills。"))
        } else if filteredGroups.isEmpty {
            emptyState(
                icon: "checkmark.circle",
                title: query.isEmpty ? L("没有发现外部 Skill") : L("发现结果无匹配"),
                detail: L("已经同步到中央库的目标会自动跳过。"))
        } else {
            ForEach(filteredGroups) { group in
                DiscoveredSkillGroupRow(
                    group: group,
                    selected: selectedDiscoveryGroupIDs.contains(group.id),
                    onToggleSelection: { toggleDiscoveryGroupSelection(group) },
                    onImport: { importDiscovered(group) },
                    onReveal: { path in reveal(path) })
            }
        }
    }

    private var discoveryToolbar: some View {
        HStack(spacing: 8) {
            Button { reload(scan: true) } label: {
                Label(L("重新扫描"), systemImage: "scope")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(AppStyle.textSecondary)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .skillControlSurface()
            }
            .buttonStyle(PressScaleStyle())

            Button { importFilteredDiscovered() } label: {
                Label(L("导入当前筛选"), systemImage: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .skillPrimaryControlSurface(disabled: !canImportAllDiscovered)
            }
            .buttonStyle(PressScaleStyle())
            .disabled(!canImportAllDiscovered)

            Button { importSelectedDiscovered() } label: {
                Label(L("导入选中"), systemImage: "checkmark.square")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(AppStyle.textSecondary)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .skillControlSurface()
            }
            .buttonStyle(PressScaleStyle())
            .disabled(!canImportSelectedDiscovered)

            Button {
                selectedDiscoveryGroupIDs = Set(importableFilteredGroups.map(\.id))
            } label: {
                Label(L("全选"), systemImage: "checklist")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(AppStyle.textSecondary)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .skillControlSurface()
            }
            .buttonStyle(PressScaleStyle())
            .disabled(importableFilteredGroups.isEmpty)

            if !selectedDiscoveryGroups.isEmpty {
                IconOnlyButton(
                    systemName: "xmark",
                    help: L("清空选择"),
                    size: 24,
                    symbolSize: 10.5) {
                        selectedDiscoveryGroupIDs.removeAll()
                    }
                    .transition(AgentToolsMotion.revealTransition)
            }

            if let scanResult {
                tinyBadge(L("发现 %ld", scanResult.skillsFound), color: AppStyle.textTertiary)
            }
            if !selectedDiscoveryGroups.isEmpty {
                tinyBadge(L("已选 %ld", selectedDiscoveryGroups.count), color: AppStyle.accent)
            }
            Spacer()
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .skillPanelSurface()
    }

    private var localInstallPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppStyle.accent)
                Text(L("本地安装"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppStyle.textPrimary)
                Spacer()
                if let scanResult {
                    tinyBadge(L("发现 %ld", scanResult.skillsFound), color: AppStyle.textTertiary)
                }
            }

            Text(L("导入单个 Skill、包含多个 Skills 的父目录，或扫描已有 Agent 目录后纳入中央库。"))
                .font(.system(size: 10.5))
                .foregroundStyle(AppStyle.textTertiary)
                .lineLimit(2)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                localInstallAction(
                    icon: "square.and.arrow.down",
                    title: L("导入目录 / Bundle"),
                    detail: L("选择 Skill 目录、父目录或 .zip"),
                    color: AppStyle.accent,
                    action: importLocal)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .skillPanelSurface()
    }

    private var scanInstallPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "scope")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppStyle.waitAmber)
                Text(L("扫描本机"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppStyle.textPrimary)
                Spacer()
                if let scanResult {
                    tinyBadge(L("%ld 个工具", scanResult.toolsScanned), color: AppStyle.textTertiary)
                    tinyBadge(L("发现 %ld", scanResult.skillsFound), color: scanResult.skillsFound > 0 ? AppStyle.waitAmber : AppStyle.textTertiary)
                }
            }

            Text(L("扫描各 Agent 目录，找出尚未进入中央库的本地 Skills。"))
                .font(.system(size: 10.5))
                .foregroundStyle(AppStyle.textTertiary)
                .lineLimit(2)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                localInstallAction(
                    icon: "scope",
                    title: scanResult == nil ? L("开始扫描") : L("重新扫描"),
                    detail: L("发现 Agent 目录里的旧 Skill"),
                    color: AppStyle.waitAmber) {
                        reload(scan: true)
                    }
                localInstallAction(
                    icon: "square.and.arrow.down.on.square",
                    title: L("全部导入发现项"),
                    detail: scanResult == nil ? L("先扫描本机 Skills") : L("把发现项收纳到中央库"),
                    color: canImportAllDiscovered ? AppStyle.accent : AppStyle.textTertiary) {
                        importFilteredDiscovered()
                    }
                    .disabled(!canImportAllDiscovered)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .skillPanelSurface()
    }

    private func localInstallAction(icon: String, title: String, detail: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 26, height: 26)
                    .skillIconSurface(color: color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(AppStyle.textPrimary)
                        .lineLimit(1)
                    Text(detail)
                        .font(.system(size: 9.5))
                        .foregroundStyle(AppStyle.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(height: 46)
            .skillRowSurface(tint: color)
        }
        .buttonStyle(PressScaleStyle())
        .help(detail)
    }

    private var canImportAllDiscovered: Bool {
        !importableFilteredGroups.isEmpty
    }

    private var canImportSelectedDiscovered: Bool {
        !selectedDiscoveryGroups.isEmpty
    }

    private var skillsShMarketPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppStyle.accent)
                Text("skills.sh")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppStyle.textPrimary)
                Picker("", selection: $skillsShBoard) {
                    Text(L("热门")).tag("hot")
                    Text(L("趋势")).tag("trending")
                    Text(L("全部")).tag("alltime")
                }
                .pickerStyle(.segmented)
                .frame(width: 132)
                Spacer()
                if !skillsShSkills.isEmpty {
                    tinyBadge(L("%ld / %ld", filteredSkillsShSkills.count, skillsShSkills.count), color: AppStyle.textTertiary)
                }
                Button {
                    loadSkillsShMarket()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(AppStyle.textSecondary)
                        .frame(width: 24, height: 24)
                        .skillIconSurface(color: AppStyle.textTertiary, shape: .circle)
                }
                .buttonStyle(PressScaleStyle())
                .help(L("刷新 skills.sh"))
                .disabled(skillsShLoading)
            }

            HStack(spacing: 8) {
                TextField(L("搜索 skills.sh"), text: $skillsShQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(AppStyle.textPrimary)
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .skillControlSurface()
                    .onSubmit { loadSkillsShMarket() }
                Button {
                    loadSkillsShMarket()
                } label: {
                    Label(L("搜索"), systemImage: "magnifyingglass")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .frame(height: 26)
                        .skillPrimaryControlSurface()
                }
                .buttonStyle(PressScaleStyle())
                .disabled(skillsShLoading)
            }

            if !skillsShSources.isEmpty {
                skillsShSourceFilterBar
            }

            if skillsShLoading {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text(L("正在加载 skills.sh…"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(AppStyle.textTertiary)
                    Spacer()
                }
            } else if let skillsShError {
                ToolStatusLine(icon: "exclamationmark.triangle.fill", text: skillsShError, color: AppStyle.waitAmber)
            } else if skillsShSkills.isEmpty {
                Text(L("加载榜单或搜索后，可以直接安装远程 Skill。"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(AppStyle.textTertiary)
            } else {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(visibleSkillsShSkills) { skill in
                        SkillsShMarketRow(
                            skill: skill,
                            installed: installedSkillsshRefs.contains(skill.id),
                            onInstall: { installSkillssh(skill) })
                    }
                    if filteredSkillsShSkills.count > visibleSkillsShSkills.count {
                        Button {
                            withAnimation(AgentToolsMotion.reveal) {
                                skillsShVisibleLimit += 24
                            }
                        } label: {
                            Label(L("显示更多"), systemImage: "chevron.down")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(AppStyle.textSecondary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 30)
                                .skillControlSurface()
                        }
                        .buttonStyle(PressScaleStyle())
                    }
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .skillPanelSurface()
        .onAppear {
            if skillsShSkills.isEmpty, !skillsShLoading {
                loadSkillsShMarket()
            }
        }
    }

    private var skillsShSourceFilterBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 5) {
                filterChip(
                    title: L("全部来源"),
                    active: skillsShSourceFilter == "all",
                    color: AppStyle.accent) {
                        withAnimation(AgentToolsMotion.selection) {
                            skillsShSourceFilter = "all"
                            skillsShVisibleLimit = 24
                        }
                    }
                ForEach(skillsShSources, id: \.self) { source in
                    filterChip(
                        title: source,
                        active: skillsShSourceFilter == source,
                        color: AppStyle.textTertiary) {
                            withAnimation(AgentToolsMotion.selection) {
                                skillsShSourceFilter = source
                                skillsShVisibleLimit = 24
                            }
                        }
                }
            }
            .padding(.vertical, 1)
        }
        .scrollIndicators(.never)
    }

    private var gitInstallPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "git.branch")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppStyle.accent)
                Text(L("从 Git 安装 Skill"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppStyle.textPrimary)
                Spacer()
                Button {
                    previewGitSkills()
                } label: {
                    Label(L("预览"), systemImage: "doc.text.magnifyingglass")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(AppStyle.textSecondary)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .skillControlSurface()
                }
                .buttonStyle(PressScaleStyle())
                .disabled(!canPreviewGitSkill || gitPreviewLoading)

                Button {
                    installGitSkill()
                } label: {
                    Label(L("安装选中"), systemImage: "square.and.arrow.down")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .skillPrimaryControlSurface(disabled: !canInstallGitSkill)
                }
                .buttonStyle(PressScaleStyle())
                .disabled(!canInstallGitSkill)
            }

            TextField("https://github.com/org/repo.git", text: $gitInstallURL)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(AppStyle.textPrimary)
                .padding(.horizontal, 9)
                .frame(height: 28)
                .skillControlSurface()

            HStack(spacing: 8) {
                TextField(L("子目录，可空"), text: $gitInstallSubdirectory)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(AppStyle.textPrimary)
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                    .skillControlSurface()
                TextField("branch / tag / sha", text: $gitInstallRef)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(AppStyle.textPrimary)
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                    .skillControlSurface()
            }

            if gitPreviewLoading {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text(L("正在预览 Git 仓库…"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(AppStyle.textTertiary)
                    Spacer()
                }
                .padding(.horizontal, 9)
                .frame(height: 34)
                .skillSoftSurface()
            } else if let gitPreviewError {
                ToolStatusLine(icon: "exclamationmark.triangle.fill", text: gitPreviewError, color: AppStyle.waitAmber)
            } else if gitPreviewSkills.isEmpty {
                Text(L("先预览仓库，选择要安装的 Skill。支持单个 Skill 仓库，也支持一个仓库里多个 Skill。"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(AppStyle.textTertiary)
                    .lineLimit(2)
            } else {
                gitPreviewResults
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .skillPanelSurface()
    }

    private var canPreviewGitSkill: Bool {
        !gitInstallURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canInstallGitSkill: Bool {
        canPreviewGitSkill &&
            gitPreviewSignature == currentGitPreviewSignature &&
            !gitPreviewSelectedPaths.isEmpty &&
            !gitPreviewLoading
    }

    private var currentGitPreviewSignature: String {
        [
            gitInstallURL.trimmingCharacters(in: .whitespacesAndNewlines),
            gitInstallSubdirectory.trimmingCharacters(in: .whitespacesAndNewlines),
            gitInstallRef.trimmingCharacters(in: .whitespacesAndNewlines)
        ].joined(separator: "\u{1F}")
    }

    private var gitPreviewIsStale: Bool {
        gitPreviewSignature != nil && gitPreviewSignature != currentGitPreviewSignature
    }

    private var gitPreviewResults: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                tinyBadge(L("%ld 个 Skill", gitPreviewSkills.count), color: AppStyle.textTertiary)
                tinyBadge(L("已选 %ld", gitPreviewSelectedPaths.count), color: gitPreviewSelectedPaths.isEmpty ? AppStyle.textTertiary : AppStyle.accent)
                if gitPreviewIsStale {
                    tinyBadge(L("预览已过期"), color: AppStyle.waitAmber)
                }
                Spacer()
                Button(L("全选")) {
                    gitPreviewSelectedPaths = Set(gitPreviewSkills.map(\.relativePath))
                }
                .font(.system(size: 10.5, weight: .semibold))
                .buttonStyle(.plain)
                Button(L("清空")) {
                    gitPreviewSelectedPaths.removeAll()
                }
                .font(.system(size: 10.5, weight: .semibold))
                .buttonStyle(.plain)
                Button(L("清空预览")) {
                    clearGitPreview()
                }
                .font(.system(size: 10.5, weight: .semibold))
                .buttonStyle(.plain)
            }

            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(gitPreviewSkills) { preview in
                    GitSkillPreviewRow(
                        preview: preview,
                        selected: gitPreviewSelectedPaths.contains(preview.relativePath),
                        stale: gitPreviewIsStale) {
                            toggleGitPreviewSelection(preview.relativePath)
                        }
                }
            }
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(loadingText.isEmpty ? L("正在加载 Skills Manager…") : loadingText)
                .font(.system(size: 12))
                .foregroundStyle(AppStyle.textSecondary)
            Spacer()
        }
        .padding(.vertical, 20)
    }

    private func emptyState(icon: String, title: String, detail: String) -> some View {
        ToolEmptyState(icon: icon, title: title, detail: detail)
        .skillPanelSurface()
    }

    private func reload(scan: Bool = false) {
        do {
            let engine = try ensureEngine()
            loading = true
            error = nil
            loadingText = scan ? L("正在扫描本机 Skills…") : L("正在刷新 Skills…")

            Task {
                do {
                    let payload = try await Task.detached(priority: .userInitiated) {
                        let result = scan ? try engine.scanLocalSkills() : nil
                        let projects = engine.listProjects()
                        return SkillManagerPayload(
                            skills: engine.listSkills(),
                            tools: engine.tools(),
                            presets: engine.listPresets(),
                            presetSummaries: engine.presetSummaries(),
                            projects: projects,
                            projectTargets: engine.listProjectTargets(),
                            projectSkills: Dictionary(
                                uniqueKeysWithValues: projects.map {
                                    ($0.id, engine.readProjectSkills(projectID: $0.id))
                                }),
                            auditEntries: engine.listAudit(limit: 140),
                            scanResult: result)
                    }.value
                    await MainActor.run {
                        skills = payload.skills
                        tools = payload.tools
                        presets = payload.presets
                        presetSummaries = payload.presetSummaries
                        projects = payload.projects
                        projectTargets = payload.projectTargets
                        projectSkills = payload.projectSkills
                        auditEntries = payload.auditEntries
                        selectedSkillIDs = selectedSkillIDs.intersection(Set(payload.skills.map(\.id)))
                        if let inspectedSkillID,
                           !payload.skills.contains(where: { $0.id == inspectedSkillID }) {
                            self.inspectedSkillID = payload.skills.first?.id
                        } else if inspectedSkillID == nil {
                            inspectedSkillID = payload.skills.first?.id
                        }
                        if let result = payload.scanResult { applyScanResult(result) }
                        loading = false
                        loadingText = ""
                    }
                } catch {
                    await MainActor.run {
                        self.error = error.localizedDescription
                        loading = false
                        loadingText = ""
                    }
                }
            }
        } catch {
            self.error = error.localizedDescription
            loading = false
            loadingText = ""
        }
    }

    private func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = L("添加")
        panel.message = L("选择要管理项目级 Skills 的项目目录")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        let bookmarks = Dictionary(
            urls.compactMap { url in
                SecurityScopedBookmarks.bookmarkData(for: url).map { (url.path, $0) }
            },
            uniquingKeysWith: { first, _ in first })

        run(L("正在添加项目…")) { engine in
            for url in urls {
                _ = try engine.addProject(
                    path: url,
                    bookmarkData: bookmarks[url.path])
            }
        }
    }

    private func importLocal() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = L("导入")
        panel.message = L("选择 Skill 目录、包含多个 Skills 的父目录，或 .zip 包")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        let bookmarks = Dictionary(
            urls.compactMap { url in
                SecurityScopedBookmarks.bookmarkData(for: url).map { (url.path, $0) }
            },
            uniquingKeysWith: { first, _ in first })

        run(L("正在导入本地 Skills…")) { engine in
            for url in urls {
                _ = try engine.importSkillBundle(
                    source: url,
                    sourceBookmarkData: bookmarks[url.path])
            }
        }
    }

    private func addCustomAgent() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("选择")
        panel.message = L("选择这个 Agent 的 skills 目录")
        guard panel.runModal() == .OK, let url = panel.urls.first else { return }

        let alert = NSAlert()
        alert.messageText = L("自定义 Agent")
        alert.informativeText = L("给这个 skills 目录起一个显示名称。")
        alert.addButton(withTitle: L("添加"))
        alert.addButton(withTitle: L("取消"))
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = url.deletingLastPathComponent().lastPathComponent.isEmpty
            ? url.lastPathComponent
            : url.deletingLastPathComponent().lastPathComponent
        alert.accessoryView = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let bookmarkData = SecurityScopedBookmarks.bookmarkData(for: url)
        run(L("正在添加自定义 Agent…")) { engine in
            try engine.addCustomTool(
                key: name,
                displayName: name,
                skillsDirectory: url,
                bookmarkData: bookmarkData)
        }
    }

    private func exportSelectedSkills() {
        let ids = Array(selectedSkillIDs)
        guard !ids.isEmpty else { return }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.prompt = L("导出")
        panel.nameFieldStringValue = "skills-bundle.zip"
        panel.message = L("导出选中的 Skills，包含 manifest、标签和来源信息")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        run(L("正在导出 Skill Bundle…")) { engine in
            _ = try engine.exportSkillBundle(skillIDs: ids, to: url)
        }
    }

    private func exportAllSkills() {
        guard !skills.isEmpty else { return }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.prompt = L("导出")
        panel.nameFieldStringValue = "all-skills-bundle.zip"
        panel.message = L("导出中央库全部 Skills，包含 manifest、标签和来源信息")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        run(L("正在导出 Skill Bundle…")) { engine in
            _ = try engine.exportSkillBundle(skillIDs: nil, to: url)
        }
    }

    private func installGitSkill() {
        let remote = gitInstallURL
        let subdirectory = gitInstallSubdirectory
        let ref = gitInstallRef
        let selectedSubpaths = Array(gitPreviewSelectedPaths).sorted()
        run(L("正在从 Git 安装 Skill…")) { engine in
            _ = try engine.installGitSkills(
                repositoryURL: remote,
                subdirectory: subdirectory.isEmpty ? nil : subdirectory,
                ref: ref.isEmpty ? nil : ref,
                selectedSubpaths: selectedSubpaths)
        }
        gitPreviewSkills.removeAll()
        gitPreviewSelectedPaths.removeAll()
        gitPreviewError = nil
        gitPreviewSignature = nil
    }

    private func previewGitSkills() {
        do {
            let engine = try ensureEngine()
            let remote = gitInstallURL
            let subdirectory = gitInstallSubdirectory
            let ref = gitInstallRef
            let signature = currentGitPreviewSignature
            gitPreviewLoading = true
            gitPreviewError = nil
            Task {
                do {
                    let result = try await Task.detached(priority: .userInitiated) {
                        try engine.previewGitSkills(
                            repositoryURL: remote,
                            subdirectory: subdirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : subdirectory,
                            ref: ref.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : ref)
                    }.value
                    await MainActor.run {
                        gitPreviewSkills = result
                        gitPreviewSelectedPaths = Set(result.map(\.relativePath))
                        gitPreviewSignature = signature
                        gitPreviewLoading = false
                    }
                } catch {
                    await MainActor.run {
                        gitPreviewError = error.localizedDescription
                        gitPreviewSkills.removeAll()
                        gitPreviewSelectedPaths.removeAll()
                        gitPreviewSignature = nil
                        gitPreviewLoading = false
                    }
                }
            }
        } catch {
            gitPreviewError = error.localizedDescription
        }
    }

    private func toggleGitPreviewSelection(_ relativePath: String) {
        if gitPreviewSelectedPaths.contains(relativePath) {
            gitPreviewSelectedPaths.remove(relativePath)
        } else {
            gitPreviewSelectedPaths.insert(relativePath)
        }
    }

    private func clearGitPreview() {
        gitPreviewSkills.removeAll()
        gitPreviewSelectedPaths.removeAll()
        gitPreviewError = nil
        gitPreviewSignature = nil
    }

    private func applyScanResult(_ result: SkillScanResult) {
        scanResult = result
        selectedDiscoveryGroupIDs.formIntersection(Set(result.groups.map(\.id)))
    }

    private func importDiscovered(_ group: DiscoveredSkillGroup) {
        guard let id = group.locations.first?.id else { return }
        run(L("正在导入发现的 Skill…"), scanAfter: true) { engine in
            _ = try engine.importDiscoveredSkill(recordID: id, name: group.name)
        }
        selectedDiscoveryGroupIDs.remove(group.id)
    }

    private func importFilteredDiscovered() {
        importDiscoveredGroups(importableFilteredGroups, loadingText: L("正在导入当前筛选 Skills…"))
    }

    private func importSelectedDiscovered() {
        importDiscoveredGroups(selectedDiscoveryGroups, loadingText: L("正在导入选中 Skills…"))
    }

    private func importDiscoveredGroups(_ groups: [DiscoveredSkillGroup], loadingText: String) {
        let items = groups.compactMap { group -> (id: String, name: String, groupID: String)? in
            guard let id = group.locations.first?.id else { return nil }
            return (id, group.name, group.id)
        }
        guard !items.isEmpty else { return }
        run(loadingText, scanAfter: true) { engine in
            for item in items {
                _ = try engine.importDiscoveredSkill(recordID: item.id, name: item.name)
            }
        }
        selectedDiscoveryGroupIDs.subtract(items.map(\.groupID))
    }

    private func toggleDiscoveryGroupSelection(_ group: DiscoveredSkillGroup) {
        guard !group.imported else { return }
        if selectedDiscoveryGroupIDs.contains(group.id) {
            selectedDiscoveryGroupIDs.remove(group.id)
        } else {
            selectedDiscoveryGroupIDs.insert(group.id)
        }
    }

    private func loadSkillsShMarket() {
        do {
            let engine = try ensureEngine()
            let query = skillsShQuery
            let board = skillsShBoard
            skillsShLoading = true
            skillsShError = nil
            Task {
                do {
                    let result = try await Task.detached(priority: .userInitiated) {
                        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.isEmpty {
                            return try engine.fetchSkillsShLeaderboard(board: board)
                        }
                        return try engine.searchSkillsSh(query: trimmed, limit: 60)
                    }.value
                    await MainActor.run {
                        skillsShSkills = result
                        skillsShVisibleLimit = 24
                        if skillsShSourceFilter != "all",
                           !result.contains(where: { $0.source == skillsShSourceFilter }) {
                            skillsShSourceFilter = "all"
                        }
                        skillsShLoading = false
                    }
                } catch {
                    await MainActor.run {
                        skillsShError = error.localizedDescription
                        skillsShLoading = false
                    }
                }
            }
        } catch {
            skillsShError = error.localizedDescription
        }
    }

    private func installSkillssh(_ skill: SkillsShSkill) {
        run(L("正在从 skills.sh 安装 Skill…")) { engine in
            _ = try engine.installSkillsshSkill(source: skill.source, skillID: skill.skillID)
        }
    }

    private func runCommandTask(_ action: SkillCommandAction) {
        switch action {
        case .market:
            selectedSection = .discover
            if skillsShSkills.isEmpty { loadSkillsShMarket() }
        case .importLocal:
            importLocal()
        case .scan:
            reload(scan: true)
        case .agents:
            openAgentsView()
        case .syncUnsynced:
            syncUnsyncedSkills()
        case .updateAvailable:
            updateAvailableSkills()
        case .library:
            let problemIDs = skills
                .filter { ["source_missing", "error"].contains($0.updateStatus) }
                .map(\.id)
            if !problemIDs.isEmpty {
                selectedSkillIDs = Set(problemIDs)
                if let first = skills.first(where: { problemIDs.contains($0.id) }) {
                    inspectSkill(first)
                }
            }
            selectedSection = .library
        case .checkUpdates:
            checkAllSkillUpdates()
        }
    }

    private func openAgentsView() {
        if let openAgents {
            openAgents()
        } else {
            selectedSection = .workspace
        }
    }

    private func toggleString(_ value: String, in set: inout Set<String>) {
        if set.contains(value) {
            set.remove(value)
        } else {
            set.insert(value)
        }
    }

    private func inspectSkill(_ skill: ManagedSkill) {
        inspectedSkillID = skill.id
        if skillDocuments[skill.id] == nil {
            loadSkillDetails(skill)
        }
    }

    private func openSkillDetail(_ skill: ManagedSkill, tab: SkillDetailTab = .overview) {
        inspectedSkillID = skill.id
        detailTab = tab
        if presentationMode == .compactPanel {
            withAnimation(AgentToolsMotion.selection) {
                drawerSection = .detail
            }
        } else {
            detailSkillID = skill.id
        }
        if skillDocuments[skill.id] == nil {
            loadSkillDetails(skill)
        }
    }

    private func toggleSkillExpansion(_ skill: ManagedSkill) {
        let opening = expandedSkillID != skill.id
        // 瞬时展开：不做高度生长动画（那种"撑开"和工作台其它处的淡入不是一种动作）。
        expandedSkillID = opening ? skill.id : nil
        if opening {
            inspectedSkillID = skill.id
            loadSkillDetails(skill)
        }
    }

    private func loadSkillDetails(_ skill: ManagedSkill) {
        do {
            let engine = try ensureEngine()
            Task {
                do {
                    let details = try await Task.detached(priority: .userInitiated) {
                        (
                            try engine.readSkillDocument(skillID: skill.id),
                            try engine.listSkillFiles(skillID: skill.id),
                            skill.updateStatus == "update_available"
                                ? try? engine.readSkillSourceDiff(skillID: skill.id)
                                : nil
                        )
                    }.value
                    await MainActor.run {
                        skillDocuments[skill.id] = details.0
                        skillFiles[skill.id] = details.1
                        skillDiffs[skill.id] = details.2
                    }
                } catch {
                    await MainActor.run {
                        skillDocuments[skill.id] = nil
                        skillFiles[skill.id] = []
                        skillDiffs[skill.id] = nil
                    }
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func refreshSkillFromSource(_ skill: ManagedSkill) {
        run(L("正在从来源刷新 Skill…")) { engine in
            _ = try engine.refreshSkillFromSource(id: skill.id)
        }
        skillDocuments[skill.id] = nil
        skillFiles[skill.id] = []
        skillDiffs[skill.id] = nil
    }

    private func checkSkillUpdate(_ skill: ManagedSkill) {
        run(L("正在检查 Skill 更新…")) { engine in
            _ = try engine.checkSkillUpdate(id: skill.id)
        }
    }

    private func relinkSkillSource(_ skill: ManagedSkill) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("绑定")
        panel.message = L("选择新的 Skill 来源目录、父目录或 .zip 包")
        guard panel.runModal() == .OK, let url = panel.urls.first else { return }
        let bookmarkData = SecurityScopedBookmarks.bookmarkData(for: url)

        run(L("正在重新绑定来源…")) { engine in
            _ = try engine.relinkSkillSource(
                id: skill.id,
                source: url,
                sourceBookmarkData: bookmarkData)
        }
    }

    private func detachSkillSource(_ skill: ManagedSkill) {
        run(L("正在解除来源绑定…")) { engine in
            _ = try engine.detachSkillSource(id: skill.id)
        }
    }

    private func syncSelectedSkills() {
        let mode = selectedSyncMode
        let ids = Array(selectedSkillIDs)
        let toolKeys = availableTools.map(\.key)
        run(L("正在批量同步 Skills…")) { engine in
            for id in ids {
                for toolKey in toolKeys {
                    _ = try engine.syncSkill(id: id, toTool: toolKey, mode: mode)
                }
            }
        }
    }

    private func syncUnsyncedSkills() {
        let mode = selectedSyncMode
        let ids = skills.filter(\.targets.isEmpty).map(\.id)
        let toolKeys = availableTools.map(\.key)
        guard !ids.isEmpty, !toolKeys.isEmpty else { return }
        run(L("正在分发未同步 Skills…")) { engine in
            for id in ids {
                for toolKey in toolKeys {
                    _ = try engine.syncSkill(id: id, toTool: toolKey, mode: mode)
                }
            }
        }
    }

    private func refreshSelectedSkills() {
        let ids = selectedSkills
            .filter(canRefreshFromSource)
            .map(\.id)
        guard !ids.isEmpty else { return }
        run(L("正在批量刷新来源…")) { engine in
            for id in ids {
                _ = try engine.refreshSkillFromSource(id: id)
            }
        }
        for id in ids {
            skillDocuments[id] = nil
            skillFiles[id] = []
            skillDiffs[id] = nil
        }
    }

    private func checkSelectedSkillUpdates() {
        let ids = selectedSkills
            .filter(canRefreshFromSource)
            .map(\.id)
        guard !ids.isEmpty else { return }
        run(L("正在批量检查更新…")) { engine in
            _ = try engine.checkSkillUpdates(ids: ids)
        }
    }

    private func checkAllSkillUpdates() {
        let ids = skills
            .filter(canRefreshFromSource)
            .map(\.id)
        guard !ids.isEmpty else { return }
        run(L("正在检查全部 Skill 更新…")) { engine in
            _ = try engine.checkSkillUpdates(ids: ids)
        }
    }

    private func updateAvailableSkills() {
        let ids = updatableSkills.map(\.id)
        guard !ids.isEmpty else { return }
        run(L("正在更新可用 Skills…")) { engine in
            for id in ids {
                _ = try engine.refreshSkillFromSource(id: id)
            }
        }
        for id in ids {
            skillDocuments[id] = nil
            skillFiles[id] = []
            skillDiffs[id] = nil
        }
    }

    private func deleteSelectedSkills() {
        let ids = Array(selectedSkillIDs)
        guard !ids.isEmpty else { return }
        run(L("正在批量删除 Skills…"), scanAfter: true) { engine in
            for id in ids {
                try engine.deleteSkill(id: id)
            }
        }
        selectedSkillIDs.removeAll()
    }

    private func canRefreshFromSource(_ skill: ManagedSkill) -> Bool {
        switch skill.sourceType {
        case .local, .imported, .git, .skillssh:
            return skill.sourceRef?.isEmpty == false
        }
    }

    private func toggleSkillSelection(_ skillID: String) {
        if selectedSkillIDs.contains(skillID) {
            selectedSkillIDs.remove(skillID)
        } else {
            selectedSkillIDs.insert(skillID)
        }
    }

    private func selectAllFilteredSkills() {
        selectedSkillIDs.formUnion(filteredSkills.map(\.id))
    }

    private func applyTagToSelection(add: Bool) {
        let tag = tagDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let ids = Array(selectedSkillIDs)
        guard !tag.isEmpty, !ids.isEmpty else { return }
        applyTag(tag, to: ids, add: add)
    }

    private func applyTag(_ tag: String, to ids: [String], add: Bool) {
        let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, !ids.isEmpty else { return }
        run(add ? L("正在添加标签…") : L("正在移除标签…")) { engine in
            if add {
                try engine.addTag(normalized, toSkillIDs: ids)
            } else {
                try engine.removeTag(normalized, fromSkillIDs: ids)
            }
        }
    }

    private func promptTag(for skill: ManagedSkill, add: Bool) {
        promptTag(skillIDs: [skill.id], add: add)
    }

    private func promptTagForSelection(add: Bool) {
        promptTag(skillIDs: Array(selectedSkillIDs), add: add)
    }

    private func promptTag(skillIDs: [String], add: Bool) {
        guard !skillIDs.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = add ? L("添加标签") : L("移除标签")
        alert.informativeText = add ? L("输入要添加到所选 Skills 的标签。") : L("输入要从所选 Skills 移除的标签。")
        alert.addButton(withTitle: add ? L("添加") : L("移除"))
        alert.addButton(withTitle: L("取消"))
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.placeholderString = L("标签")
        input.stringValue = tagDraft
        alert.accessoryView = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let tag = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { return }
        tagDraft = tag
        applyTag(tag, to: skillIDs, add: add)
    }

    private func createPreset() {
        let name = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        newPresetName = ""
        run(L("正在创建 Preset…")) { engine in
            _ = try engine.createPreset(name: name)
        }
    }

    private func deletePreset(_ preset: SkillPreset) {
        run(L("正在删除 Preset…")) { engine in
            try engine.deletePreset(id: preset.id)
        }
    }

    private func togglePresetSkill(preset: SkillPreset, skill: ManagedSkill, enabled: Bool) {
        run(enabled ? L("正在加入 Preset…") : L("正在移出 Preset…")) { engine in
            if enabled {
                _ = try engine.addSkillToPreset(presetID: preset.id, skillID: skill.id)
            } else {
                _ = try engine.removeSkillFromPreset(presetID: preset.id, skillID: skill.id)
            }
        }
    }

    private func movePresetSkill(preset: SkillPreset, skill: ManagedSkill, offset: Int) {
        run(L("正在调整 Preset 顺序…")) { engine in
            _ = try engine.moveSkillInPreset(
                presetID: preset.id,
                skillID: skill.id,
                offset: offset)
        }
    }

    private func applyPreset(_ preset: SkillPreset) {
        let mode = selectedSyncMode
        let toolKeys = availableTools.map(\.key)
        run(L("正在应用 Preset…")) { engine in
            _ = try engine.applyPreset(id: preset.id, toTools: toolKeys, mode: mode)
        }
    }

    private func removePreset(_ preset: SkillPreset) {
        let toolKeys = availableTools.map(\.key)
        run(L("正在移除 Preset 同步…")) { engine in
            try engine.removePreset(id: preset.id, fromTools: toolKeys)
        }
    }

    private func deleteProject(_ project: SkillProject) {
        run(L("正在移除项目…")) { engine in
            try engine.deleteProject(id: project.id)
        }
    }

    private func toggleProjectSkill(project: SkillProject,
                                    skill: ManagedSkill,
                                    tool: SkillToolInfo,
                                    enabled: Bool) {
        let mode = selectedSyncMode
        run(enabled ? L("正在同步到项目…") : L("正在移除项目同步…")) { engine in
            if enabled {
                _ = try engine.syncSkillToProject(
                    skillID: skill.id,
                    projectID: project.id,
                    toolKey: tool.key,
                    mode: mode)
            } else {
                try engine.unsyncSkillFromProject(
                    skillID: skill.id,
                    projectID: project.id,
                    toolKey: tool.key)
            }
        }
    }

    private func applyPresetToProject(preset: SkillPreset, project: SkillProject) {
        let mode = selectedSyncMode
        let toolKeys = projectTools.map(\.key)
        run(L("正在应用 Preset 到项目…")) { engine in
            _ = try engine.applyPresetToProject(
                presetID: preset.id,
                projectID: project.id,
                toolKeys: toolKeys,
                mode: mode)
        }
    }

    private func removePresetFromProject(preset: SkillPreset, project: SkillProject) {
        let toolKeys = projectTools.map(\.key)
        run(L("正在移除项目 Preset…")) { engine in
            try engine.removePresetFromProject(
                presetID: preset.id,
                projectID: project.id,
                toolKeys: toolKeys)
        }
    }

    private func toggle(skill: ManagedSkill, tool: SkillToolInfo, enabled: Bool) {
        let mode = selectedSyncMode
        run(enabled ? L("正在同步 Skill…") : L("正在移除同步…")) { engine in
            if enabled {
                _ = try engine.syncSkill(id: skill.id, toTool: tool.key, mode: mode)
            } else {
                try engine.unsyncSkill(id: skill.id, fromTool: tool.key)
            }
        }
    }

    private func toggleToolEnabled(_ tool: SkillToolInfo) {
        run(tool.enabled ? L("正在停用 Agent…") : L("正在启用 Agent…")) { engine in
            try engine.setToolEnabled(tool.key, enabled: !tool.enabled)
        }
    }

    private func syncAll(_ skill: ManagedSkill) {
        let mode = selectedSyncMode
        let toolKeys = availableTools.map(\.key)
        run(L("正在同步到所有可用 Agent…")) { engine in
            for toolKey in toolKeys {
                _ = try engine.syncSkill(id: skill.id, toTool: toolKey, mode: mode)
            }
        }
    }

    private func delete(_ skill: ManagedSkill) {
        run(L("正在删除 Skill…"), scanAfter: true) { engine in
            try engine.deleteSkill(id: skill.id)
        }
    }

    private func run(_ message: String,
                     scanAfter: Bool = false,
                     operation: @escaping @Sendable (SkillManagerEngine) throws -> Void) {
        do {
            let engine = try ensureEngine()
            loading = true
            loadingText = message
            error = nil

            Task {
                do {
                    let payload = try await Task.detached(priority: .userInitiated) {
                        try operation(engine)
                        let result = scanAfter ? try engine.scanLocalSkills() : nil
                        let projects = engine.listProjects()
                        return SkillManagerPayload(
                            skills: engine.listSkills(),
                            tools: engine.tools(),
                            presets: engine.listPresets(),
                            presetSummaries: engine.presetSummaries(),
                            projects: projects,
                            projectTargets: engine.listProjectTargets(),
                            projectSkills: Dictionary(
                                uniqueKeysWithValues: projects.map {
                                    ($0.id, engine.readProjectSkills(projectID: $0.id))
                                }),
                            auditEntries: engine.listAudit(limit: 140),
                            scanResult: result)
                    }.value
                    await MainActor.run {
                        skills = payload.skills
                        tools = payload.tools
                        presets = payload.presets
                        presetSummaries = payload.presetSummaries
                        projects = payload.projects
                        projectTargets = payload.projectTargets
                        projectSkills = payload.projectSkills
                        auditEntries = payload.auditEntries
                        selectedSkillIDs = selectedSkillIDs.intersection(Set(payload.skills.map(\.id)))
                        if let inspectedSkillID,
                           !payload.skills.contains(where: { $0.id == inspectedSkillID }) {
                            self.inspectedSkillID = payload.skills.first?.id
                        } else if inspectedSkillID == nil {
                            inspectedSkillID = payload.skills.first?.id
                        }
                        if let result = payload.scanResult { applyScanResult(result) }
                        loading = false
                        loadingText = ""
                    }
                } catch {
                    await MainActor.run {
                        self.error = error.localizedDescription
                        loading = false
                        loadingText = ""
                    }
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func ensureEngine() throws -> SkillManagerEngine {
        if let engine { return engine }
        let created = try SkillManagerEngine()
        engine = created
        return created
    }

    private var selectedSyncMode: SkillTargetRecord.Mode {
        syncMode == "copy" ? .copy : .symlink
    }

    private var syncModeLabel: String {
        selectedSyncMode == .copy ? L("复制") : L("软链")
    }

    private func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func iconButton(_ icon: String,
                            help: String,
                            destructive: Bool = false,
                            action: @escaping () -> Void) -> some View {
        IconOnlyButton(
            systemName: icon,
            help: help,
            size: 28,
            symbolSize: 11,
            weight: .semibold,
            tint: destructive ? AppStyle.errorRed : nil,
            action: action)
    }

    private func filterChip(title: String,
                            active: Bool,
                            color: Color,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: active ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 9.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(active ? .white : AppStyle.textSecondary)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .skillControlSurface(active: active, tint: color)
        }
        .buttonStyle(PressScaleStyle())
    }

    private func toolSort(_ lhs: SkillToolInfo, _ rhs: SkillToolInfo) -> Bool {
        if lhs.installed != rhs.installed { return lhs.installed && !rhs.installed }
        if lhs.category != rhs.category { return lhs.category.rawValue < rhs.category.rawValue }
        return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
    }
}

private enum SkillManagerSection: String, CaseIterable, Identifiable {
    case dashboard
    case library
    case deploy
    case discover
    case workspace
    case projects
    case maintain
    case activity
    case agents

    var id: String { rawValue }

    /// 窄栏 tab 上的短标题（中文，2–3 字最佳）。
    var title: String {
        switch self {
        case .dashboard: return L("首页")
        case .library: return L("技能库")
        case .discover: return L("安装")
        case .workspace: return L("工作区")
        case .deploy: return "Presets"
        case .projects: return L("项目")
        case .maintain: return L("更新")
        case .activity: return L("备份")
        case .agents: return "Agents"
        }
    }

    /// tab 栏下方一行说明：直接讲清这个分区里装的是什么——窄栏里「不知道什么是什么」的解药。
    var subtitle: String {
        switch self {
        case .dashboard: return L("技能库、安装和工作区入口")
        case .library: return L("你收藏的全部 Skill · 搜索、详情、同步")
        case .deploy: return L("可复用 Skill 分组 · 一键应用")
        case .discover: return L("skills.sh / Git / 本地导入 / 扫描本机")
        case .workspace: return L("全局 Agent 目录 · 实际可见状态")
        case .projects: return L("项目级 Skills · 本地目录同步")
        case .maintain: return L("更新与来源异常")
        case .activity: return L("导入导出 · Bundle 迁移 · 操作记录")
        case .agents: return L("可接收 Skill 的 Agent 工具")
        }
    }

    var sidebarHint: String {
        switch self {
        case .dashboard: return L("状态")
        case .library: return L("中央库")
        case .discover: return L("市场/Git/本地")
        case .workspace: return L("全局目录")
        case .deploy: return L("分组")
        case .projects: return L("项目目录")
        case .maintain: return L("更新")
        case .activity: return L("迁移/日志")
        case .agents: return L("工具")
        }
    }

    var icon: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .library: return "square.stack.3d.up"
        case .discover: return "sparkles"
        case .workspace: return "globe"
        case .deploy: return "rectangle.stack.badge.plus"
        case .projects: return "folder.badge.gearshape"
        case .maintain: return "arrow.down.circle"
        case .activity: return "archivebox"
        case .agents: return "cpu"
        }
    }
}

private enum SkillDetailTab: String, CaseIterable, Identifiable {
    case overview
    case deploy
    case docs
    case source
    case activity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return L("总览")
        case .deploy: return L("部署")
        case .docs: return L("文档")
        case .source: return L("来源")
        case .activity: return L("活动")
        }
    }

    var icon: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.67percent"
        case .deploy: return "point.3.connected.trianglepath.dotted"
        case .docs: return "doc.text.magnifyingglass"
        case .source: return "link"
        case .activity: return "clock.arrow.circlepath"
        }
    }
}

private enum SkillInstallTab: String, CaseIterable, Identifiable {
    case market
    case local
    case git
    case scan

    var id: String { rawValue }

    var title: String {
        switch self {
        case .market: return L("市场")
        case .local: return L("本地")
        case .git: return "Git"
        case .scan: return L("扫描")
        }
    }

    var icon: String {
        switch self {
        case .market: return "sparkles"
        case .local: return "folder.badge.plus"
        case .git: return "git.branch"
        case .scan: return "scope"
        }
    }
}

private enum SkillLibraryViewMode: String, CaseIterable, Identifiable {
    case grid
    case list

    var id: String { rawValue }

    var title: String {
        switch self {
        case .grid: return L("网格")
        case .list: return L("列表")
        }
    }

    var icon: String {
        switch self {
        case .grid: return "square.grid.2x2"
        case .list: return "list.bullet"
        }
    }
}

private enum SkillCommandAction: Equatable {
    case market
    case importLocal
    case scan
    case agents
    case syncUnsynced
    case updateAvailable
    case library
    case checkUpdates
}

private struct SkillCommandTask: Identifiable {
    let id: String
    let icon: String
    let title: String
    let detail: String
    let count: Int?
    let tint: Color
    let action: SkillCommandAction
}

private struct SkillReadinessItem: Identifiable {
    let id: String
    let title: String
    let detail: String
    let ready: Bool
    let icon: String
    let color: Color
}

private enum SkillCueAction {
    case overview
    case deploy
    case docs
    case source
    case loadDetails
    case checkUpdate
}

private struct SkillActionCue {
    let icon: String
    let title: String
    let detail: String
    let color: Color
    let actionTitle: String
    let action: SkillCueAction
}


private struct SkillActionCuePanel: View {
    let cue: SkillActionCue
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: cue.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(cue.color)
                .frame(width: 28, height: 28)
                .skillIconSurface(color: cue.color)

            VStack(alignment: .leading, spacing: 3) {
                Text(cue.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppStyle.textPrimary)
                    .lineLimit(1)
                Text(cue.detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(AppStyle.textSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            SkillHeaderActionButton(
                title: cue.actionTitle,
                systemImage: "arrow.right",
                primary: true,
                tint: cue.color,
                action: action)
        }
        .padding(10)
        .skillRowSurface(tint: cue.color)
        .animation(AgentToolsMotion.selection, value: cue.title)
    }
}

private struct SkillCommandRow: View {
    let skill: ManagedSkill
    let active: Bool
    let healthColor: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(active ? AppStyle.accent : healthColor)
                    .frame(width: active ? 4 : 2, height: active ? 42 : 8)
                    .padding(.top, active ? 0 : 5)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(skill.name)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(AppStyle.textPrimary)
                            .lineLimit(1)
                        if skill.updateStatus == "update_available" {
                            tinyBadge(L("可更新"), color: AppStyle.waitAmber)
                                .transition(AgentToolsMotion.revealTransition)
                        }
                    }
                    Text((skill.description?.isEmpty == false) ? skill.description! : collapsedPath(skill.centralPath))
                        .font(.system(size: 9.5))
                        .foregroundStyle(AppStyle.textTertiary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        tinyBadge(skill.sourceType.rawValue, color: AppStyle.textTertiary)
                        tinyBadge(L("%ld Agent", skill.targets.count), color: skill.targets.isEmpty ? AppStyle.textTertiary : AppStyle.accent)
                    }
                }
                Spacer(minLength: 2)

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(active || hovering ? AppStyle.accent : AppStyle.textTertiary.opacity(0.45))
                    .padding(.top, 4)
                    .opacity(active || hovering ? 1 : 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .skillRowSurface(active: active, hovering: hovering, tint: healthColor)
            .offset(x: hovering && !active ? 2 : 0)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(AgentToolsMotion.hover, value: hovering)
        .animation(AgentToolsMotion.selection, value: active)
        .animation(AgentToolsMotion.selection, value: skill.updateStatus)
    }
}

private struct SkillAgentIconView: View {
    let tool: SkillToolInfo
    let size: CGFloat
    let cornerRadius: CGFloat
    @ObservedObject private var configStore = ConfigStore.shared

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(AppStyle.hoverFill.opacity(0.62))
            if let logoName = skillToolLogoName(tool.key),
               let logo = CLIToolLogo.image(named: logoName) {
                if CLIToolLogo.isMonochrome(logoName) {
                    Image(nsImage: logo)
                        .resizable()
                        .renderingMode(.template)
                        .interpolation(.high)
                        .scaledToFit()
                        .foregroundStyle(tool.enabled ? AppStyle.textPrimary : AppStyle.textTertiary)
                        .padding(size * 0.18)
                } else {
                    Image(nsImage: logo)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .padding(size * 0.14)
                }
            } else {
                Image(systemName: tool.category == .lobster ? "person.wave.2" : "cpu")
                    .font(.system(size: max(10, size * 0.38), weight: .semibold))
                    .foregroundStyle(tool.enabled ? AppStyle.accent : AppStyle.textTertiary)
            }
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(AppStyle.separator.opacity(0.28), lineWidth: 1)
        )
    }
}

private func skillToolLogoName(_ key: String) -> String? {
    switch key {
    case "claude_code":
        return "claude"
    case "codex":
        return "codex"
    case "cursor":
        return "cursor"
    case "gemini_cli":
        return "gemini"
    case "github_copilot":
        return "copilot"
    case "grok":
        return "grok"
    case "opencode":
        return "opencode"
    case "windsurf":
        return "windsurf"
    case "antigravity":
        return "antigravity"
    case "amp":
        return "amp"
    case "kilo_code":
        return "kilo"
    case "kiro":
        return "kiro"
    case "qwen_code":
        return "qwen"
    case "kimi":
        return "kimi"
    case "warp":
        return "warp"
    case "augment":
        return "augment"
    case "command_code":
        return "commandcode"
    case "droid":
        return "factory"
    default:
        return nil
    }
}

private struct AgentWorkspaceRow: View {
    let tool: SkillToolInfo
    let skills: [ManagedSkill]
    let unsyncedCount: Int
    let onReveal: () -> Void
    let onOpenAgents: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                SkillAgentIconView(tool: tool, size: 34, cornerRadius: 9)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(tool.displayName)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(AppStyle.textPrimary)
                            .lineLimit(1)
                        tinyBadge(tool.installed ? L("已检测") : L("未检测"), color: tool.installed ? AppStyle.accent : AppStyle.textTertiary)
                        if tool.isCustom {
                            tinyBadge(L("自定义"), color: AppStyle.accent)
                        }
                    }
                    Text(collapsedPath(tool.skillsDirectory))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(AppStyle.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    ToolBadge(text: L("%ld Skills", skills.count), color: skills.isEmpty ? AppStyle.textTertiary : AppStyle.accent, style: .muted)
                    IconOnlyButton(
                        systemName: "folder",
                        help: L("在 Finder 显示"),
                        size: 26,
                        symbolSize: 10.5,
                        weight: .semibold,
                        action: onReveal)
                    IconOnlyButton(
                        systemName: "slider.horizontal.3",
                        help: L("管理 Agent"),
                        size: 26,
                        symbolSize: 10.5,
                        weight: .semibold,
                        action: onOpenAgents)
                }
            }

            if skills.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: unsyncedCount > 0 ? "arrow.triangle.2.circlepath" : "tray")
                        .font(.system(size: 11, weight: .semibold))
                    Text(unsyncedCount > 0
                         ? L("中央库里有 %ld 个未同步 Skill，可以从工作区顶部一键分发。", unsyncedCount)
                         : L("这个 Agent 还没有由 Conductor 同步的 Skill。"))
                        .font(.system(size: 10.5))
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(AppStyle.textTertiary)
                .padding(.horizontal, 10)
                .frame(minHeight: 34)
                .skillSoftSurface(opacity: 0.84)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 6)], spacing: 6) {
                    ForEach(skills.prefix(8)) { skill in
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(AppStyle.accent)
                            Text(skill.name)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(AppStyle.textSecondary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .skillSoftSurface(opacity: 0.88)
                    }
                    if skills.count > 8 {
                        Text(L("+%ld", skills.count - 8))
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(AppStyle.textTertiary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 26)
                            .skillSoftSurface(opacity: 0.74)
                    }
                }
            }
        }
        .padding(12)
        .skillPanelSurface()
        .overlay(
            RoundedRectangle(cornerRadius: SkillUI.panelRadius, style: .continuous)
                .stroke(hovering ? AppStyle.accent.opacity(0.20) : Color.clear, lineWidth: 1)
        )
        .onHover { hovering = $0 }
        .animation(AgentToolsMotion.hover, value: hovering)
    }
}

private struct SkillDetailCockpit: View {
    let skill: ManagedSkill
    let tools: [SkillToolInfo]
    let document: SkillDocument?
    let files: [SkillFileInfo]
    let sourceDiff: SkillSourceDiff?
    let auditEntries: [SkillAuditEntry]
    let readinessItems: [SkillReadinessItem]
    @Binding var selectedTab: SkillDetailTab
    let syncMode: String
    let canRefreshFromSource: Bool
    let onClose: () -> Void
    let onSyncAll: () -> Void
    let onToggleTool: (SkillToolInfo, Bool) -> Void
    let onCheckUpdate: () -> Void
    let onRefreshSource: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void
    let onLoadDetails: () -> Void

    private var targetByTool: [String: SkillTargetRecord] {
        Dictionary(skill.targets.map { ($0.tool, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private var healthColor: Color {
        switch skill.updateStatus {
        case "update_available": return AppStyle.waitAmber
        case "source_missing", "error": return AppStyle.errorRed
        default:
            return skill.targets.isEmpty ? AppStyle.textTertiary : AppStyle.accent
        }
    }

    private var updateLabel: String {
        switch skill.updateStatus {
        case "current": return L("最新")
        case "update_available": return L("可更新")
        case "source_missing": return L("来源失效")
        case "error": return L("检查失败")
        case "unsupported": return L("不支持更新")
        default: return L("未知")
        }
    }

    private var sortedFiles: [SkillFileInfo] {
        files.sorted {
            $0.relativePath.localizedCaseInsensitiveCompare($1.relativePath) == .orderedAscending
        }
    }

    private var deploymentCoverage: Double {
        guard !tools.isEmpty else { return 0 }
        return Double(skill.targets.count) / Double(tools.count)
    }

    private var deploymentCoverageLabel: String {
        guard !tools.isEmpty else { return "--" }
        return "\(Int((deploymentCoverage * 100).rounded()))%"
    }

    private var totalFileBytes: Int64 {
        files.reduce(0) { $0 + $1.size }
    }

    private var fileProfileSegments: [SkillProfileSegment] {
        let markdown = files.filter { isMarkdownFile($0.relativePath) }.count
        let code = files.filter { isCodeFile($0.relativePath) }.count
        let assets = files.filter { isAssetFile($0.relativePath) }.count
        let other = max(0, files.count - markdown - code - assets)
        return [
            SkillProfileSegment(title: L("文档"), count: markdown, color: AppStyle.accent),
            // 文件类型构成是分类色板（非信号），与下方紫色资产同属一组分类色，保留原色。
            SkillProfileSegment(title: L("代码"), count: code, color: .orange),
            SkillProfileSegment(title: L("资产"), count: assets, color: Color(red: 0.58, green: 0.48, blue: 0.92)),
            SkillProfileSegment(title: L("其他"), count: other, color: AppStyle.textTertiary),
        ].filter { $0.count > 0 }
    }

    private var documentKnown: Bool {
        document != nil || files.contains { $0.relativePath.lowercased() == "skill.md" }
    }

    private var sourceProblem: Bool {
        ["source_missing", "error"].contains(skill.updateStatus)
    }

    private var nextCue: SkillActionCue {
        if sourceProblem {
            return SkillActionCue(
                icon: "exclamationmark.triangle.fill",
                title: L("来源需要处理"),
                detail: skill.lastCheckError?.isEmpty == false ? skill.lastCheckError! : L("这个 Skill 的来源不可用或更新检查失败，先进入来源页确认绑定信息。"),
                color: AppStyle.errorRed,
                actionTitle: L("查看来源"),
                action: .source)
        }
        if skill.updateStatus == "update_available" {
            return SkillActionCue(
                icon: "arrow.down.circle.fill",
                title: L("发现可更新版本"),
                detail: L("来源里已有新版内容，可以先看差异再决定刷新中央库。"),
                color: AppStyle.waitAmber,
                actionTitle: L("查看差异"),
                action: .source)
        }
        if !documentKnown {
            return SkillActionCue(
                icon: "doc.text.magnifyingglass",
                title: L("先读取 Skill 文档"),
                detail: L("读取 SKILL.md 和文件清单后，就绪检查、文档预览和来源差异会更完整。"),
                color: AppStyle.accent,
                actionTitle: L("读取文档"),
                action: .loadDetails)
        }
        if skill.targets.isEmpty {
            return SkillActionCue(
                icon: "point.3.connected.trianglepath.dotted",
                title: L("还没有分发到 Agent"),
                detail: L("这个 Skill 已进入中央库，但还没有同步到任何可用 Agent。"),
                color: AppStyle.waitAmber,
                actionTitle: L("打开部署"),
                action: .deploy)
        }
        return SkillActionCue(
            icon: "checkmark.seal.fill",
            title: L("已纳入管理"),
            detail: L("这个 Skill 已在中央库中，可以继续查看文档、同步到 Agent 或检查来源更新。"),
            color: AppStyle.accent,
            actionTitle: L("检查更新"),
            action: .checkUpdate)
    }


    var body: some View {
        SkillModalShell {
            tabRail
        } header: {
            header
        } content: {
            ScrollView {
                selectedContent
                    .id(selectedTab)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .transition(AgentToolsMotion.contentTransition)
            }
            .scrollIndicators(.never)
        }
        .animation(AgentToolsMotion.route, value: selectedTab)
        .animation(AgentToolsMotion.selection, value: skill.targets.count)
        .animation(AgentToolsMotion.selection, value: skill.updateStatus)
    }

    private var header: some View {
        SkillModalHeader(
            icon: sourceIcon,
            title: skill.name,
            subtitle: (skill.description?.isEmpty == false) ? skill.description! : collapsedPath(skill.centralPath),
            tint: healthColor) {
            HStack(spacing: 6) {
                SkillHeaderActionButton(
                    title: L("同步全部"),
                    systemImage: "arrow.triangle.2.circlepath",
                    primary: true,
                    tint: AppStyle.accent,
                    action: onSyncAll)

                if canRefreshFromSource {
                    iconButton("magnifyingglass.circle", help: L("检查更新"), action: onCheckUpdate)
                    iconButton("arrow.clockwise.circle", help: L("刷新来源"), action: onRefreshSource)
                }

                iconButton("doc.text.magnifyingglass", help: L("读取文档"), action: onLoadDetails)
                iconButton("folder", help: L("在 Finder 显示"), action: onReveal)
                iconButton("trash", help: L("删除 Skill"), destructive: true, action: onDelete)
                iconButton("xmark", help: L("关闭"), action: onClose)
            }
        } meta: {
            HStack(spacing: 8) {
                tinyBadge(skill.sourceType.rawValue, color: AppStyle.textTertiary)
                tinyBadge(updateLabel, color: healthColor)
                if skill.targets.isEmpty {
                    tinyBadge(L("未分发"), color: AppStyle.waitAmber)
                } else {
                    tinyBadge(L("%ld Agent", skill.targets.count), color: AppStyle.accent)
                }

                Spacer()

                Text(collapsedPath(skill.centralPath))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(AppStyle.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }

    private var tabRail: some View {
        VStack(alignment: .leading, spacing: 6) {
            SkillRailBrand(
                icon: sourceIcon,
                title: L("Skill 详情"),
                subtitle: skill.name,
                tint: healthColor)

            ForEach(SkillDetailTab.allCases) { tab in
                Button {
                    withAnimation(AgentToolsMotion.selection) { selectedTab = tab }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 11.5, weight: .semibold))
                            .frame(width: 17)
                        Text(tab.title)
                            .font(.system(size: 11.5, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if let value = tabValue(tab) {
                            Text(value)
                                .font(.system(size: 8.8, weight: .bold))
                                .foregroundStyle(selectedTab == tab ? AppStyle.textSecondary : tabValueColor(tab))
                                .padding(.horizontal, 5)
                                .frame(height: 17)
                                .background(Capsule().fill(tabValueColor(tab).opacity(selectedTab == tab ? 0.10 : 0.13)))
                        }
                    }
                    .foregroundStyle(selectedTab == tab ? AppStyle.textPrimary : AppStyle.textSecondary)
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .skillRailItemSurface(selected: selectedTab == tab)
                }
                .buttonStyle(.plain)
                .help(tabValue(tab).map { "\(tab.title) \($0)" } ?? tab.title)
                .animation(AgentToolsMotion.selection, value: selectedTab)
            }

            Spacer()

            Text(syncMode)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(AppStyle.textTertiary)
                .padding(.horizontal, 10)
                .frame(height: 26)
        }
        .padding(12)
        .skillRailSurface()
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch selectedTab {
        case .overview:
            overviewContent
        case .deploy:
            deployContent
        case .docs:
            docsContent
        case .source:
            sourceContent
        case .activity:
            activityContent
        }
    }

    private var overviewContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            SkillActionCuePanel(cue: nextCue) {
                runCueAction(nextCue.action)
            }

            SkillCockpitPanel(icon: "info.circle", title: L("属性")) {
                VStack(alignment: .leading, spacing: 7) {
                    detailPropertyRow(L("同步"), skill.targets.isEmpty ? L("未分发") : L("%ld Agent", skill.targets.count))
                    detailPropertyRow(L("更新"), updateLabel)
                    detailPropertyRow(L("文件"), L("%ld 文件", files.count))
                    detailPropertyRow(L("最近检查"), skill.lastCheckedAt.map { $0.formatted(date: .numeric, time: .shortened) } ?? "--")
                    detailPropertyRow(L("路径"), collapsedPath(skill.centralPath), monospaced: true)
                }
            }

            HStack(alignment: .top, spacing: 12) {
                sourceBlueprint
                deploymentSnapshot
            }
        }
    }

    private func detailPropertyRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(AppStyle.textTertiary)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(.system(size: 10.5, design: monospaced ? .monospaced : .default))
                .foregroundStyle(AppStyle.textSecondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var deployContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                SkillHeaderActionButton(
                    title: L("同步到所有可用 Agent"),
                    systemImage: "arrow.triangle.2.circlepath",
                    primary: true,
                    action: onSyncAll)
                tinyBadge("\(L("当前模式")) \(syncMode)", color: AppStyle.textTertiary)
                Spacer()
            }

            SkillCoverageStrip(
                icon: "antenna.radiowaves.left.and.right",
                title: L("部署覆盖率"),
                value: deploymentCoverageLabel,
                detail: tools.isEmpty
                    ? L("还没有可用 Agent")
                    : L("%ld 个已同步，%ld 个待同步", skill.targets.count, max(0, tools.count - skill.targets.count)),
                color: skill.targets.isEmpty ? AppStyle.waitAmber : AppStyle.accent,
                progress: tools.isEmpty ? nil : deploymentCoverage)

            SkillCockpitPanel(icon: "point.3.connected.trianglepath.dotted", title: L("Agent 部署矩阵")) {
                if tools.isEmpty {
                    emptyCockpitState(icon: "cpu", title: L("没有可用 Agent"))
                } else {
                    VStack(spacing: 7) {
                        ForEach(tools) { tool in
                            SkillDeploymentLane(
                                tool: tool,
                                target: targetByTool[tool.key],
                                onToggle: {
                                    onToggleTool(tool, targetByTool[tool.key] == nil)
                                })
                        }
                    }
                }
            }
        }
    }

    private var docsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            SkillFileProfilePanel(
                documentKnown: documentKnown,
                totalFiles: files.count,
                totalBytes: totalFileBytes,
                segments: fileProfileSegments,
                onLoadDetails: onLoadDetails)

            HStack(alignment: .top, spacing: 12) {
                SkillCockpitPanel(icon: "doc.text.magnifyingglass", title: document?.filename ?? "SKILL.md") {
                    if let document {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                tinyBadge(byteCount(Int64(document.content.utf8.count)), color: AppStyle.textTertiary)
                                if document.truncated {
                                    tinyBadge(L("已截断"), color: AppStyle.waitAmber)
                                }
                                Spacer()
                                Button(action: onLoadDetails) {
                                    Label(L("重读"), systemImage: "arrow.clockwise")
                                        .font(.system(size: 10.5, weight: .semibold))
                                }
                                .buttonStyle(.plain)
                            }
                            ScrollView {
                                Text(String(document.content.prefix(10_000)))
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(AppStyle.textSecondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                            }
                            .frame(minHeight: 360)
                            .skillSoftSurface()
                        }
                    } else {
                        Button(action: onLoadDetails) {
                            VStack(spacing: 8) {
                                Image(systemName: "doc.text.magnifyingglass")
                                    .font(.system(size: 22, weight: .semibold))
                                Text(L("读取 SKILL.md"))
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(AppStyle.textSecondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 180)
                            .skillSoftSurface()
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity)

                SkillCockpitPanel(icon: "doc.on.doc", title: L("文件")) {
                    if sortedFiles.isEmpty {
                        emptyCockpitState(icon: "folder", title: L("尚未读取文件列表"))
                    } else {
                        VStack(spacing: 5) {
                            ForEach(Array(sortedFiles.prefix(28))) { file in
                                SkillFileListRow(file: file)
                            }
                            if sortedFiles.count > 28 {
                                Text(L("还有 %ld 个文件", sortedFiles.count - 28))
                                    .font(.system(size: 10))
                                    .foregroundStyle(AppStyle.textTertiary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .frame(width: 290)
            }
        }
    }

    private var sourceContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            sourceBlueprint

            if let sourceDiff {
                SkillDiffStatsPanel(entries: sourceDiff.entries)
            }

            SkillCockpitPanel(icon: "arrow.left.arrow.right", title: L("来源差异")) {
                if let sourceDiff {
                    if sourceDiff.entries.isEmpty {
                        emptyCockpitState(icon: "checkmark.seal", title: L("来源与中央库一致"))
                    } else {
                        VStack(alignment: .leading, spacing: 9) {
                            HStack(spacing: 6) {
                                tinyBadge(collapsedPath(sourceDiff.sourcePath), color: AppStyle.textTertiary)
                                tinyBadge(L("%ld 个文件", sourceDiff.entries.count), color: AppStyle.waitAmber)
                                Spacer()
                            }

                            ForEach(Array(sourceDiff.entries.prefix(10))) { entry in
                                SkillDiffSummaryRow(entry: entry)
                            }

                            if let firstText = sourceDiff.entries.first(where: {
                                $0.originalContent != nil || $0.updatedContent != nil
                            }) {
                                SkillDiffPreview(entry: firstText)
                            }
                        }
                    }
                } else if skill.updateStatus == "update_available" {
                    Button(action: onLoadDetails) {
                        Label(L("读取来源差异"), systemImage: "arrow.left.arrow.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(AppStyle.textSecondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .skillSoftSurface()
                    }
                    .buttonStyle(.plain)
                } else {
                    emptyCockpitState(icon: "checkmark.seal", title: L("暂无可展示差异"))
                }
            }
        }
    }

    private var activityContent: some View {
        SkillCockpitPanel(icon: "clock.arrow.circlepath", title: L("Skill 活动")) {
            if auditEntries.isEmpty {
                emptyCockpitState(icon: "clock", title: L("这个 Skill 暂无活动记录"))
            } else {
                VStack(spacing: 8) {
                    ForEach(auditEntries.prefix(32)) { entry in
                        SkillActivityLine(entry: entry)
                    }
                }
            }
        }
    }

    private var sourceBlueprint: some View {
        SkillCockpitPanel(icon: "link", title: L("来源与标识")) {
            VStack(spacing: 8) {
                SkillKeyValueRow(label: L("中央库"), value: collapsedPath(skill.centralPath))
                SkillKeyValueRow(label: L("来源类型"), value: skill.sourceType.rawValue)
                if let sourceRef = skill.sourceRef {
                    SkillKeyValueRow(label: "source", value: sourceRef)
                }
                if let sourceSubpath = skill.sourceSubpath {
                    SkillKeyValueRow(label: "subpath", value: sourceSubpath)
                }
                if let sourceBranch = skill.sourceBranch {
                    SkillKeyValueRow(label: "ref", value: sourceBranch)
                }
                if let sourceRevision = skill.sourceRevision {
                    SkillKeyValueRow(label: "rev", value: String(sourceRevision.prefix(12)))
                }
                if let remoteRevision = skill.remoteRevision {
                    SkillKeyValueRow(label: "remote", value: String(remoteRevision.prefix(12)))
                }
                if let contentHash = skill.contentHash {
                    SkillKeyValueRow(label: "hash", value: String(contentHash.prefix(12)))
                }
                SkillKeyValueRow(label: L("状态"), value: "\(skill.status) / \(updateLabel)")
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
    }

    private var deploymentSnapshot: some View {
        SkillCockpitPanel(icon: "cpu", title: L("部署快照")) {
            if skill.targets.isEmpty {
                emptyCockpitState(icon: "point.3.connected.trianglepath.dotted", title: L("尚未分发"))
            } else {
                VStack(spacing: 6) {
                    ForEach(skill.targets.prefix(6)) { target in
                        HStack(spacing: 7) {
                            Image(systemName: target.status == "ok" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(target.status == "ok" ? AppStyle.accent : AppStyle.waitAmber)
                            Text(target.tool)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(AppStyle.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            Text(target.mode.rawValue)
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(AppStyle.textTertiary)
                        }
                        Text(collapsedPath(target.targetPath))
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(AppStyle.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if skill.targets.count > 6 {
                        Text(L("还有 %ld 个目标", skill.targets.count - 6))
                            .font(.system(size: 10))
                            .foregroundStyle(AppStyle.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .frame(width: 260)
    }

    private var sourceIcon: String {
        switch skill.sourceType {
        case .git: return "git.branch"
        case .skillssh: return "sparkles"
        case .local: return "folder"
        case .imported: return "archivebox"
        }
    }

    private func tabValue(_ tab: SkillDetailTab) -> String? {
        switch tab {
        case .overview:
            return nil
        case .deploy:
            return tools.isEmpty ? nil : "\(skill.targets.count)/\(tools.count)"
        case .docs:
            return files.isEmpty ? (document == nil ? nil : "1") : "\(files.count)"
        case .source:
            return ["update_available", "source_missing", "error"].contains(skill.updateStatus) ? updateLabel : nil
        case .activity:
            return auditEntries.isEmpty ? nil : "\(auditEntries.count)"
        }
    }

    private func tabValueColor(_ tab: SkillDetailTab) -> Color {
        switch tab {
        case .overview:
            return AppStyle.textTertiary
        case .deploy:
            return skill.targets.isEmpty ? AppStyle.waitAmber : AppStyle.accent
        case .docs:
            return documentKnown ? AppStyle.accent : AppStyle.textTertiary
        case .source:
            return healthColor
        case .activity:
            return AppStyle.textTertiary
        }
    }

    private func isMarkdownFile(_ path: String) -> Bool {
        ["md", "markdown", "mdx", "txt"].contains(fileExtension(path))
    }

    private func isCodeFile(_ path: String) -> Bool {
        ["swift", "js", "ts", "tsx", "jsx", "py", "rb", "go", "rs", "java", "kt", "sh", "zsh", "json", "yaml", "yml", "toml"].contains(fileExtension(path))
    }

    private func isAssetFile(_ path: String) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "svg", "pdf", "mp3", "wav", "mp4", "mov"].contains(fileExtension(path))
    }

    private func fileExtension(_ path: String) -> String {
        (path as NSString).pathExtension.lowercased()
    }

    private func runCueAction(_ action: SkillCueAction) {
        switch action {
        case .overview:
            selectedTab = .overview
        case .deploy:
            selectedTab = .deploy
        case .docs:
            selectedTab = .docs
        case .source:
            selectedTab = .source
            if skill.updateStatus == "update_available" {
                onLoadDetails()
            }
        case .loadDetails:
            selectedTab = .docs
            onLoadDetails()
        case .checkUpdate:
            onCheckUpdate()
        }
    }

    private func emptyCockpitState(icon: String, title: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(AppStyle.textTertiary)
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(AppStyle.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 118)
        .skillSoftSurface()
    }
}

private struct SkillProfileSegment: Identifiable {
    let title: String
    let count: Int
    let color: Color

    var id: String { title }
}

private struct SkillCoverageStrip: View {
    let icon: String
    let title: String
    let value: String
    let detail: String
    let color: Color
    let progress: Double?

    private var normalizedProgress: Double {
        min(max(progress ?? 0, 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SkillPanelTitle(icon: icon, title: title, value: value, tint: color)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(AppStyle.hoverFill)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(color)
                        .frame(width: proxy.size.width * CGFloat(normalizedProgress))
                }
            }
            .frame(height: 6)
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(AppStyle.textTertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .skillPanelSurface()
        .animation(AgentToolsMotion.route, value: normalizedProgress)
        .animation(AgentToolsMotion.selection, value: value)
    }
}

private struct SkillFileProfilePanel: View {
    let documentKnown: Bool
    let totalFiles: Int
    let totalBytes: Int64
    let segments: [SkillProfileSegment]
    let onLoadDetails: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SkillPanelTitle(
                    icon: documentKnown ? "doc.text.fill" : "doc.text.magnifyingglass",
                    title: documentKnown ? L("文件画像") : L("等待读取文件画像"),
                    value: L("%ld 文件", totalFiles),
                    tint: documentKnown ? AppStyle.accent : AppStyle.waitAmber)
                if totalBytes > 0 {
                    tinyBadge(byteCount(totalBytes), color: AppStyle.textTertiary)
                }
                IconOnlyButton(
                    systemName: "arrow.clockwise",
                    help: documentKnown ? L("刷新文件画像") : L("读取文件画像"),
                    size: 24,
                    symbolSize: 10.5,
                    weight: .semibold,
                    action: onLoadDetails)
            }

            if segments.isEmpty {
                Text(L("读取 SKILL.md 后会展示文档、代码、资产等结构占比。"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(AppStyle.textTertiary)
                    .lineLimit(1)
            } else {
                SkillSegmentBar(segments: segments)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .skillPanelSurface()
    }
}

private struct SkillSegmentBar: View {
    let segments: [SkillProfileSegment]

    private var total: Int {
        max(segments.reduce(0) { $0 + $1.count }, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(segments) { segment in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(segment.color)
                            .frame(width: max(6, proxy.size.width * CGFloat(segment.count) / CGFloat(total)))
                    }
                }
            }
            .frame(height: 7)
            .animation(AgentToolsMotion.route, value: segments.map { "\($0.id):\($0.count)" }.joined(separator: "|"))

            HStack(spacing: 8) {
                ForEach(segments) { segment in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(segment.color)
                            .frame(width: 6, height: 6)
                        Text("\(segment.title) \(segment.count)")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(AppStyle.textTertiary)
                            .lineLimit(1)
                    }
                    .transition(AgentToolsMotion.revealTransition)
                }
            }
        }
    }
}

private struct SkillDiffStatsPanel: View {
    let entries: [SkillSourceDiffEntry]

    private var segments: [SkillProfileSegment] {
        [
            SkillProfileSegment(title: L("新增"), count: count("added"), color: AppStyle.accent),
            SkillProfileSegment(title: L("修改"), count: count("modified"), color: AppStyle.waitAmber),
            SkillProfileSegment(title: L("删除"), count: count("removed"), color: AppStyle.errorRed),
        ].filter { $0.count > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SkillPanelTitle(
                icon: entries.isEmpty ? "checkmark.seal.fill" : "arrow.left.arrow.right",
                title: entries.isEmpty ? L("来源一致") : L("差异分布"),
                value: L("%ld 文件", entries.count),
                tint: entries.isEmpty ? AppStyle.accent : AppStyle.waitAmber)
            if segments.isEmpty {
                Text(L("中央库和来源当前没有文件级差异。"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(AppStyle.textTertiary)
            } else {
                SkillSegmentBar(segments: segments)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .skillPanelSurface()
    }

    private func count(_ status: String) -> Int {
        entries.filter { $0.status == status }.count
    }
}

private struct SkillCockpitPanel<Content: View>: View {
    let icon: String
    let title: String
    let content: Content

    init(icon: String,
         title: String,
         @ViewBuilder content: () -> Content) {
        self.icon = icon
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SkillPanelTitle(icon: icon, title: title, value: nil)
            content
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .skillPanelSurface()
    }
}


private struct SkillDeploymentLane: View {
    let tool: SkillToolInfo
    let target: SkillTargetRecord?
    let onToggle: () -> Void
    @State private var hovering = false

    private var synced: Bool { target != nil }

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 10) {
                Image(systemName: synced ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(synced ? AppStyle.accent : AppStyle.textTertiary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(tool.displayName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AppStyle.textPrimary)
                            .lineLimit(1)
                        tinyBadge(tool.category.rawValue, color: AppStyle.textTertiary)
                        if tool.isCustom {
                            tinyBadge(L("自定义"), color: AppStyle.accent)
                        }
                        if !tool.installed {
                            tinyBadge(L("未检测"), color: AppStyle.waitAmber)
                        }
                    }
                    Text(target.map { "\($0.mode.rawValue) · \(collapsedPath($0.targetPath))" } ?? collapsedPath(tool.skillsDirectory))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(AppStyle.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if let target, target.status != "ok" {
                    tinyBadge(target.status, color: AppStyle.waitAmber)
                }
                Image(systemName: synced ? "minus.circle" : "arrow.right.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppStyle.textTertiary)
                    .opacity(hovering || synced ? 1 : 0.55)
            }
            .padding(.horizontal, 10)
            .frame(height: 48)
            .skillRowSurface(selected: synced, hovering: hovering, tint: AppStyle.accent)
            .offset(x: hovering ? 2 : 0)
        }
        .buttonStyle(.plain)
        .help(synced ? L("移除同步") : L("同步到该 Agent"))
        .onHover { hovering = $0 }
        .animation(AgentToolsMotion.hover, value: hovering)
        .animation(AgentToolsMotion.selection, value: synced)
    }
}

private struct SkillFileListRow: View {
    let file: SkillFileInfo

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "doc.text")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(AppStyle.textTertiary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.relativePath)
                    .font(.system(size: 9.8, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppStyle.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let modifiedAt = file.modifiedAt {
                    Text(modifiedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 8.8))
                        .foregroundStyle(AppStyle.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Text(byteCount(file.size))
                .font(.system(size: 9))
                .foregroundStyle(AppStyle.textTertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 36)
        .skillSoftSurface(opacity: 0.92)
    }
}

private struct SkillDiffSummaryRow: View {
    let entry: SkillSourceDiffEntry

    var body: some View {
        HStack(spacing: 8) {
            tinyBadge(diffStatusLabel(entry.status), color: diffStatusColor(entry.status))
            Text(entry.relativePath)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(AppStyle.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if entry.originalKind != "text" || entry.updatedKind != "text" {
                Text([entry.originalKind, entry.updatedKind]
                    .filter { $0 != "missing" }
                    .joined(separator: " -> "))
                    .font(.system(size: 9.5))
                    .foregroundStyle(AppStyle.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 32)
        .skillSoftSurface()
    }
}

private struct SkillDiffPreview: View {
    let entry: SkillSourceDiffEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(entry.relativePath)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(AppStyle.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(alignment: .top, spacing: 8) {
                diffColumn(title: L("中央库"), content: entry.originalContent)
                diffColumn(title: L("来源"), content: entry.updatedContent)
            }
        }
    }

    private func diffColumn(title: String, content: String?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(AppStyle.textTertiary)
            ScrollView {
                Text(String((content ?? L("不存在")).prefix(3_000)))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(AppStyle.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 210)
            .skillSoftSurface()
        }
    }
}

private struct SkillActivityLine: View {
    let entry: SkillAuditEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(skillAuditActionLabel(entry.action))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(AppStyle.textPrimary)
                        .lineLimit(1)
                    if let tool = entry.tool {
                        tinyBadge(tool, color: AppStyle.textTertiary)
                    }
                    if !entry.success {
                        tinyBadge(L("失败"), color: AppStyle.errorRed)
                    }
                    Spacer()
                    Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 9.5))
                        .foregroundStyle(AppStyle.textTertiary)
                        .lineLimit(1)
                }
                if let detail = entry.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 9.8, design: .monospaced))
                        .foregroundStyle(AppStyle.textSecondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .skillSoftSurface(opacity: 0.92)
    }

    private var color: Color {
        if !entry.success { return AppStyle.errorRed }
        switch entry.action {
        case "delete", "unsync", "project_unsync", "tag_remove", "tool_disable", "preset_delete":
            return AppStyle.waitAmber
        default:
            return AppStyle.accent
        }
    }
}

private struct SkillKeyValueRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(AppStyle.textTertiary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(AppStyle.textSecondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SkillManagerPayload: Sendable {
    var skills: [ManagedSkill]
    var tools: [SkillToolInfo]
    var presets: [SkillPreset]
    var presetSummaries: [SkillPresetSummary]
    var projects: [SkillProject]
    var projectTargets: [SkillProjectTargetRecord]
    var projectSkills: [String: [ProjectSkillInfo]]
    var auditEntries: [SkillAuditEntry]
    var scanResult: SkillScanResult?
}

private struct SkillLibraryRow: View {
    let skill: ManagedSkill
    let active: Bool
    let selected: Bool
    let healthLabel: String
    let healthColor: Color
    let updateLabel: String
    let canRefreshFromSource: Bool
    let allTags: [String]
    let onActivate: () -> Void
    let onToggleSelection: () -> Void
    let onOpenDetail: () -> Void
    let onSync: () -> Void
    let onCheckUpdate: () -> Void
    let onRefreshSource: () -> Void
    let onAddTag: (String?) -> Void
    let onRemoveTag: (String) -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            IconOnlyButton(
                systemName: selected ? "checkmark.square.fill" : "square",
                help: selected ? L("取消选择") : L("选择"),
                size: 24,
                symbolSize: 11,
                weight: .semibold,
                tint: selected ? AppStyle.accent : AppStyle.textTertiary,
                action: onToggleSelection)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(skill.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(AppStyle.textPrimary)
                        .lineLimit(1)
                    ToolBadge(text: skill.sourceType.rawValue, color: AppStyle.textTertiary, style: .muted, height: 18)
                    if updateLabel != L("未知") {
                        ToolBadge(text: updateLabel, color: healthColor, height: 18)
                    }
                }

                Text((skill.description?.isEmpty == false) ? skill.description! : collapsedPath(skill.centralPath))
                    .font(.system(size: 10.5))
                    .foregroundStyle(AppStyle.textSecondary)
                    .lineLimit(2)

                HStack(spacing: 5) {
                    ToolBadge(
                        text: skill.targets.isEmpty ? L("未同步") : L("%ld Agent", skill.targets.count),
                        color: skill.targets.isEmpty ? AppStyle.textTertiary : AppStyle.accent,
                        height: 18)
                    ToolBadge(text: healthLabel, color: healthColor, height: 18)
                    ForEach(skill.tags.prefix(3), id: \.self) { tag in
                        ToolBadge(text: tag, color: AppStyle.textTertiary, style: .muted, height: 18)
                    }
                    if skill.tags.count > 3 {
                        ToolBadge(text: "+\(skill.tags.count - 3)", color: AppStyle.textTertiary, style: .muted, height: 18)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: onActivate)

            HStack(spacing: 4) {
                if hovering || active {
                    IconOnlyButton(systemName: "arrow.triangle.2.circlepath", help: L("同步到所有可用 Agent"), size: 24, symbolSize: 10.5, action: onSync)
                    IconOnlyButton(systemName: "rectangle.and.text.magnifyingglass", help: L("打开详情"), size: 24, symbolSize: 10.5, action: onOpenDetail)
                    IconOnlyButton(systemName: "folder", help: L("在 Finder 显示"), size: 24, symbolSize: 10.5, action: onReveal)
                    IconOnlyButton(systemName: "trash", help: L("删除"), size: 24, symbolSize: 10.5, tint: AppStyle.errorRed, action: onDelete)
                }
            }
            .frame(width: 112, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .skillRowSurface(active: active, selected: selected, hovering: hovering)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(L("打开详情")) { onOpenDetail() }
            Button(selected ? L("取消选择") : L("选择")) { onToggleSelection() }
            Divider()
            Button(L("同步到所有可用 Agent")) { onSync() }
            Button(L("检查更新")) { onCheckUpdate() }
                .disabled(!canRefreshFromSource)
            Button(L("刷新来源")) { onRefreshSource() }
                .disabled(!canRefreshFromSource)
            Divider()
            Menu(L("标签")) {
                Button(L("添加标签…")) { onAddTag(nil) }
                let addableTags = allTags.filter { !skill.tags.contains($0) }
                if !addableTags.isEmpty {
                    Menu(L("添加已有标签")) {
                        ForEach(addableTags, id: \.self) { tag in
                            Button(tag) { onAddTag(tag) }
                        }
                    }
                }
                if !skill.tags.isEmpty {
                    Menu(L("移除标签")) {
                        ForEach(skill.tags, id: \.self) { tag in
                            Button(tag) { onRemoveTag(tag) }
                        }
                    }
                }
            }
            Divider()
            Button(L("在 Finder 显示")) { onReveal() }
            Button(L("删除"), role: .destructive) { onDelete() }
        }
        .animation(AgentToolsMotion.hover, value: hovering)
        .animation(AgentToolsMotion.selection, value: active)
    }
}

private struct SkillLibraryCard: View {
    let skill: ManagedSkill
    let active: Bool
    let selected: Bool
    let healthLabel: String
    let healthColor: Color
    let updateLabel: String
    let canRefreshFromSource: Bool
    let allTags: [String]
    let onActivate: () -> Void
    let onToggleSelection: () -> Void
    let onOpenDetail: () -> Void
    let onSync: () -> Void
    let onCheckUpdate: () -> Void
    let onRefreshSource: () -> Void
    let onAddTag: (String?) -> Void
    let onRemoveTag: (String) -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: sourceIcon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(healthColor)
                    .frame(width: 26, height: 26)
                    .skillIconSurface(color: healthColor)

                VStack(alignment: .leading, spacing: 3) {
                    Text(skill.name)
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(AppStyle.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        ToolBadge(text: skill.sourceType.rawValue, color: AppStyle.textTertiary, style: .muted, height: 18)
                        if updateLabel != L("未知") {
                            ToolBadge(text: updateLabel, color: healthColor, height: 18)
                        }
                    }
                }

                Spacer(minLength: 0)

                IconOnlyButton(
                    systemName: selected ? "checkmark.square.fill" : "square",
                    help: selected ? L("取消选择") : L("选择"),
                    size: 24,
                    symbolSize: 11,
                    weight: .semibold,
                    tint: selected ? AppStyle.accent : AppStyle.textTertiary,
                    action: onToggleSelection)
            }

            Text((skill.description?.isEmpty == false) ? skill.description! : collapsedPath(skill.centralPath))
                .font(.system(size: 10.5))
                .foregroundStyle(AppStyle.textSecondary)
                .lineLimit(2)
                .frame(minHeight: 30, alignment: .topLeading)

            HStack(spacing: 5) {
                ToolBadge(
                    text: skill.targets.isEmpty ? L("未同步") : L("%ld Agent", skill.targets.count),
                    color: skill.targets.isEmpty ? AppStyle.textTertiary : AppStyle.accent,
                    height: 18)
                ToolBadge(text: healthLabel, color: healthColor, height: 18)
                Spacer(minLength: 0)
            }

            if !skill.tags.isEmpty {
                HStack(spacing: 5) {
                    ForEach(skill.tags.prefix(3), id: \.self) { tag in
                        ToolBadge(text: tag, color: AppStyle.textTertiary, style: .muted, height: 18)
                    }
                    if skill.tags.count > 3 {
                        ToolBadge(text: "+\(skill.tags.count - 3)", color: AppStyle.textTertiary, style: .muted, height: 18)
                    }
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 5) {
                IconOnlyButton(systemName: "arrow.triangle.2.circlepath", help: L("同步到所有可用 Agent"), size: 24, symbolSize: 10.5, action: onSync)
                IconOnlyButton(systemName: "rectangle.and.text.magnifyingglass", help: L("打开详情"), size: 24, symbolSize: 10.5, action: onOpenDetail)
                IconOnlyButton(systemName: "folder", help: L("在 Finder 显示"), size: 24, symbolSize: 10.5, action: onReveal)
                Spacer(minLength: 0)
                IconOnlyButton(systemName: "trash", help: L("删除"), size: 24, symbolSize: 10.5, tint: AppStyle.errorRed, action: onDelete)
            }
            .opacity(hovering || active ? 1 : 0.62)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 164, alignment: .topLeading)
        .skillRowSurface(active: active, selected: selected, hovering: hovering, tint: healthColor)
        .contentShape(RoundedRectangle(cornerRadius: SkillUI.rowRadius, style: .continuous))
        .onTapGesture(perform: onActivate)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(L("打开详情")) { onOpenDetail() }
            Button(selected ? L("取消选择") : L("选择")) { onToggleSelection() }
            Divider()
            Button(L("同步到所有可用 Agent")) { onSync() }
            Button(L("检查更新")) { onCheckUpdate() }
                .disabled(!canRefreshFromSource)
            Button(L("刷新来源")) { onRefreshSource() }
                .disabled(!canRefreshFromSource)
            Divider()
            Menu(L("标签")) {
                Button(L("添加标签…")) { onAddTag(nil) }
                let addableTags = allTags.filter { !skill.tags.contains($0) }
                if !addableTags.isEmpty {
                    Menu(L("添加已有标签")) {
                        ForEach(addableTags, id: \.self) { tag in
                            Button(tag) { onAddTag(tag) }
                        }
                    }
                }
                if !skill.tags.isEmpty {
                    Menu(L("移除标签")) {
                        ForEach(skill.tags, id: \.self) { tag in
                            Button(tag) { onRemoveTag(tag) }
                        }
                    }
                }
            }
            Divider()
            Button(L("在 Finder 显示")) { onReveal() }
            Button(L("删除"), role: .destructive) { onDelete() }
        }
        .animation(AgentToolsMotion.hover, value: hovering)
        .animation(AgentToolsMotion.selection, value: active)
        .animation(AgentToolsMotion.selection, value: selected)
    }

    private var sourceIcon: String {
        switch skill.sourceType {
        case .git: return "git.branch"
        case .skillssh: return "sparkles"
        case .local: return "folder"
        case .imported: return "archivebox"
        }
    }
}

private struct SkillLibraryInspectorPanel: View {
    let skill: ManagedSkill
    let tools: [SkillToolInfo]
    let sourcePath: String
    let syncMode: String
    let canRefreshFromSource: Bool
    let onOpenDetail: () -> Void
    let onSyncAll: () -> Void
    let onToggleTool: (SkillToolInfo, Bool) -> Void
    let onCheckUpdate: () -> Void
    let onRefreshSource: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void

    var body: some View {
        ToolSoftGroup {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(L("详情"))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(AppStyle.textPrimary)
                    Spacer()
                    ToolActionButton(title: L("打开"), systemImage: "rectangle.and.text.magnifyingglass", height: 24, fontSize: 10.5, horizontalPadding: 9, action: onOpenDetail)
                    ToolActionButton(title: L("同步"), systemImage: "arrow.triangle.2.circlepath", role: .tinted(AppStyle.accent), height: 24, fontSize: 10.5, horizontalPadding: 9, action: onSyncAll)
                }

                Text((skill.description?.isEmpty == false) ? skill.description! : L("无描述"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(AppStyle.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 5) {
                    inspectorLine(L("来源"), skill.sourceType.rawValue)
                    inspectorLine(L("路径"), sourcePath, monospace: true)
                    inspectorLine(L("同步模式"), syncMode)
                }

                if !tools.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 6)], spacing: 6) {
                        ForEach(tools) { tool in
                            let synced = skill.targets.contains { $0.tool == tool.key }
                            Button {
                                onToggleTool(tool, !synced)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: synced ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 9.5, weight: .semibold))
                                    Text(tool.displayName)
                                        .font(.system(size: 9.5, weight: .semibold))
                                        .lineLimit(1)
                                }
                                .foregroundStyle(synced ? AppStyle.accent : AppStyle.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 7)
                                .frame(height: 24)
                                .skillControlSurface(
                                    active: synced,
                                    tint: AppStyle.accent.opacity(0.11),
                                    disabled: false)
                            }
                            .buttonStyle(PressScaleStyle())
                            .help(synced ? L("移除同步") : L("同步到该 Agent"))
                        }
                    }
                }

                HStack(spacing: 6) {
                    if canRefreshFromSource {
                        ToolActionButton(title: L("检查更新"), systemImage: "magnifyingglass.circle", height: 24, fontSize: 10.5, horizontalPadding: 9, action: onCheckUpdate)
                        ToolActionButton(title: L("刷新来源"), systemImage: "arrow.clockwise.circle", height: 24, fontSize: 10.5, horizontalPadding: 9, action: onRefreshSource)
                    }
                    ToolActionButton(title: L("显示"), systemImage: "folder", height: 24, fontSize: 10.5, horizontalPadding: 9, action: onReveal)
                    ToolActionButton(title: L("删除"), systemImage: "trash", role: .destructive, height: 24, fontSize: 10.5, horizontalPadding: 9, action: onDelete)
                }
            }
        }
    }

    private func inspectorLine(_ label: String, _ value: String, monospace: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(AppStyle.textTertiary)
                .frame(width: 48, alignment: .leading)
            Text(value)
                .font(.system(size: 9.5, design: monospace ? .monospaced : .default))
                .foregroundStyle(AppStyle.textSecondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

private struct ManagedSkillRow: View {
    let skill: ManagedSkill
    let tools: [SkillToolInfo]
    let expanded: Bool
    let selected: Bool
    let document: SkillDocument?
    let files: [SkillFileInfo]
    let sourceDiff: SkillSourceDiff?
    let syncMode: String
    let onExpand: () -> Void
    let onSelect: () -> Void
    let onOpenDetail: () -> Void
    let onToggleTool: (SkillToolInfo, Bool) -> Void
    let onSyncAll: () -> Void
    let onCheckUpdate: () -> Void
    let onRefreshSource: () -> Void
    let onRelinkSource: () -> Void
    let onDetachSource: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(skill.name)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(AppStyle.textPrimary)
                            .lineLimit(1)
                        sourceBadge
                        if skill.targets.isEmpty {
                            tinyBadge(L("未同步"), color: AppStyle.textTertiary)
                        } else {
                            tinyBadge(L("已同步 %ld", skill.targets.count), color: AppStyle.accent)
                        }
                        if let updateLabel {
                            tinyBadge(updateLabel, color: updateColor)
                        }
                    }
                    Text((skill.description?.isEmpty == false) ? skill.description! : L("无描述"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(AppStyle.textSecondary)
                        .lineLimit(expanded ? nil : 2)
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: onExpand)
                Spacer(minLength: 6)
                HStack(spacing: 4) {
                    iconButton(selected ? "checkmark.square.fill" : "square", help: L("选择"), action: onSelect)
                    iconButton("rectangle.and.text.magnifyingglass", help: L("打开详情控制台"), action: onOpenDetail)
                    iconButton("arrow.triangle.2.circlepath", help: L("同步到所有可用 Agent"), action: onSyncAll)
                    if canRefreshFromSource {
                        iconButton("magnifyingglass.circle", help: L("检查更新"), action: onCheckUpdate)
                        iconButton("arrow.clockwise.circle", help: L("从来源刷新"), action: onRefreshSource)
                    }
                    iconButton("folder", help: L("在 Finder 显示"), action: onReveal)
                    iconButton("trash", help: L("删除"), destructive: true, action: onDelete)
                    iconButton(expanded ? "chevron.up" : "chevron.down", help: L("展开"), action: onExpand)
                }
            }

            if !skill.tags.isEmpty {
                HStack(spacing: 5) {
                    ForEach(skill.tags.prefix(8), id: \.self) { tag in
                        tinyBadge(tag, color: AppStyle.textTertiary)
                    }
                    if skill.tags.count > 8 {
                        tinyBadge("+\(skill.tags.count - 8)", color: AppStyle.textTertiary)
                    }
                }
            }

            if !tools.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 5) {
                        ForEach(tools) { tool in
                            toolToggle(tool)
                        }
                    }
                    .padding(.vertical, 1)
                }
                .scrollIndicators(.never)
            } else {
                Text(L("未检测到可用 Agent。后续可在设置里添加自定义 Skills 目录。"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(AppStyle.textTertiary)
            }

            if expanded {
                ToolSoftGroup {
                    VStack(alignment: .leading, spacing: 5) {
                        metaRow(L("中央库"), collapsedPath(skill.centralPath))
                        metaRow(L("来源"), skill.sourceType.rawValue)
                        if let sourceRef = skill.sourceRef {
                            metaRow("source", sourceRef)
                        }
                        if let sourceSubpath = skill.sourceSubpath {
                            metaRow("subpath", sourceSubpath)
                        }
                        if let sourceBranch = skill.sourceBranch {
                            metaRow("ref", sourceBranch)
                        }
                        if let sourceRevision = skill.sourceRevision {
                            metaRow("rev", String(sourceRevision.prefix(12)))
                        }
                        if let remoteRevision = skill.remoteRevision {
                            metaRow("remote", String(remoteRevision.prefix(12)))
                        }
                        metaRow(L("更新状态"), updateLabel ?? L("未知"))
                        if let lastCheckedAt = skill.lastCheckedAt {
                            metaRow(L("上次检查"), lastCheckedAt.formatted(date: .abbreviated, time: .shortened))
                        }
                        if let lastCheckError = skill.lastCheckError, !lastCheckError.isEmpty {
                            metaRow(L("检查错误"), lastCheckError)
                        }
                        if let contentHash = skill.contentHash {
                            metaRow("hash", String(contentHash.prefix(12)))
                        }
                        HStack(spacing: 5) {
                            iconButton("link", help: L("重新绑定来源"), action: onRelinkSource)
                            if canRefreshFromSource {
                                iconButton("link.slash", help: L("解除来源绑定"), action: onDetachSource)
                            }
                        }
                        metaRow(L("同步模式"), syncMode)
                        if !skill.targets.isEmpty {
                            ForEach(skill.targets) { target in
                                metaRow(target.tool, "\(target.mode.rawValue) · \(collapsedPath(target.targetPath))")
                            }
                        }
                    }
                }
                skillDocumentPreview
                sourceDiffPreview
                skillFilesPreview
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .skillPanelSurface()
    }

    private func toolToggle(_ tool: SkillToolInfo) -> some View {
        let synced = skill.targets.contains { $0.tool == tool.key }
        return Button {
            onToggleTool(tool, !synced)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: synced ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 10, weight: .semibold))
                Text(tool.displayName)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(synced ? .white : AppStyle.textSecondary)
            .padding(.horizontal, 7)
            .frame(height: 23)
            .skillControlSurface(active: synced, tint: AppStyle.accent)
        }
        .buttonStyle(PressScaleStyle())
        .help(synced ? L("点击移除同步") : L("点击同步到该 Agent"))
    }

    private var sourceBadge: some View {
        tinyBadge(skill.sourceType.rawValue, color: AppStyle.textTertiary)
    }

    private var canRefreshFromSource: Bool {
        switch skill.sourceType {
        case .local, .imported, .git, .skillssh:
            return skill.sourceRef?.isEmpty == false
        }
    }

    private var updateLabel: String? {
        switch skill.updateStatus {
        case "current": return L("已是最新")
        case "update_available": return L("可更新")
        case "source_missing": return L("来源失效")
        case "error": return L("检查失败")
        case "unsupported": return L("不支持更新")
        default: return nil
        }
    }

    private var updateColor: Color {
        switch skill.updateStatus {
        case "current": return AppStyle.accent
        case "update_available": return AppStyle.waitAmber
        case "source_missing", "error": return AppStyle.errorRed
        default: return AppStyle.textTertiary
        }
    }

    @ViewBuilder
    private var skillDocumentPreview: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(document?.filename ?? "SKILL.md")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(AppStyle.textSecondary)
                if document?.truncated == true {
                    tinyBadge(L("已截断"), color: AppStyle.waitAmber)
                }
                Spacer()
            }
            if let document {
                ScrollView {
                    Text(document.content)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(AppStyle.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 180)
                .skillSoftSurface()
            } else {
                Text(L("展开后会读取 Skill 文档。"))
                    .font(.system(size: 10))
                    .foregroundStyle(AppStyle.textTertiary)
            }
        }
    }

    @ViewBuilder
    private var skillFilesPreview: some View {
        if !files.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text(L("文件"))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(AppStyle.textSecondary)
                ForEach(files.prefix(10)) { file in
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(AppStyle.textTertiary)
                        Text(file.relativePath)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(AppStyle.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(byteCount(file.size))
                            .font(.system(size: 9))
                            .foregroundStyle(AppStyle.textTertiary)
                    }
                }
                if files.count > 10 {
                    Text(L("还有 %ld 个文件", files.count - 10))
                        .font(.system(size: 9.5))
                        .foregroundStyle(AppStyle.textTertiary)
                }
            }
        }
    }

    @ViewBuilder
    private var sourceDiffPreview: some View {
        if skill.updateStatus == "update_available" {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(L("来源差异"))
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(AppStyle.textSecondary)
                    if let sourceDiff {
                        tinyBadge(L("%ld 个文件", sourceDiff.entries.count), color: AppStyle.waitAmber)
                    }
                    Spacer()
                }
                if let sourceDiff {
                    if sourceDiff.entries.isEmpty {
                        Text(L("文件内容未发现差异。"))
                            .font(.system(size: 10))
                            .foregroundStyle(AppStyle.textTertiary)
                    } else {
                        ForEach(sourceDiff.entries.prefix(8)) { entry in
                            diffEntryRow(entry)
                        }
                        if let firstText = sourceDiff.entries.first(where: {
                            $0.originalContent != nil || $0.updatedContent != nil
                        }) {
                            diffTextPreview(firstText)
                        }
                    }
                } else {
                    Text(L("展开后会尝试读取来源差异。"))
                        .font(.system(size: 10))
                        .foregroundStyle(AppStyle.textTertiary)
                }
            }
        }
    }

    private func diffEntryRow(_ entry: SkillSourceDiffEntry) -> some View {
        HStack(spacing: 6) {
            tinyBadge(diffStatusLabel(entry.status), color: diffStatusColor(entry.status))
            Text(entry.relativePath)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(AppStyle.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if entry.originalKind != "text" || entry.updatedKind != "text" {
                Text([entry.originalKind, entry.updatedKind]
                    .filter { $0 != "missing" }
                    .joined(separator: " -> "))
                    .font(.system(size: 9))
                    .foregroundStyle(AppStyle.textTertiary)
            }
        }
    }

    private func diffTextPreview(_ entry: SkillSourceDiffEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.relativePath)
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(AppStyle.textTertiary)
                .lineLimit(1)
            HStack(alignment: .top, spacing: 6) {
                diffTextColumn(title: L("中央库"), content: entry.originalContent)
                diffTextColumn(title: L("来源"), content: entry.updatedContent)
            }
        }
    }

    private func diffTextColumn(title: String, content: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(AppStyle.textTertiary)
            ScrollView {
                Text((content ?? L("不存在")).prefix(2_000))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(AppStyle.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .frame(maxHeight: 110)
            .skillSoftSurface()
        }
    }

    private func diffStatusLabel(_ status: String) -> String {
        switch status {
        case "added": return L("新增")
        case "removed": return L("删除")
        case "modified": return L("修改")
        default: return status
        }
    }

    private func diffStatusColor(_ status: String) -> Color {
        switch status {
        case "added": return AppStyle.accent
        case "removed": return AppStyle.errorRed
        case "modified": return AppStyle.waitAmber
        default: return AppStyle.textTertiary
        }
    }

    private func metaRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text(label)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(AppStyle.textTertiary)
                .frame(width: 58, alignment: .leading)
            Text(value)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(AppStyle.textSecondary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }
}

private struct PresetRow: View {
    let preset: SkillPreset
    let summary: SkillPresetSummary?
    let skills: [ManagedSkill]
    let expanded: Bool
    let onExpand: () -> Void
    let onApply: () -> Void
    let onRemove: () -> Void
    let onDelete: () -> Void
    let onToggleSkill: (ManagedSkill, Bool) -> Void
    let onMoveSkill: (ManagedSkill, Int) -> Void

    private var includedIDs: Set<String> {
        Set(preset.skills.map(\.skillID))
    }

    private var orderedIncludedSkills: [ManagedSkill] {
        let order = Dictionary(uniqueKeysWithValues: preset.skills.map { ($0.skillID, $0.order) })
        return skills
            .filter { includedIDs.contains($0.id) }
            .sorted { (order[$0.id] ?? Int.max) < (order[$1.id] ?? Int.max) }
    }

    private var availablePresetSkills: [ManagedSkill] {
        skills
            .filter { !includedIDs.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: statusIcon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(preset.name)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(AppStyle.textPrimary)
                            .lineLimit(1)
                        tinyBadge(L("%ld 个 Skill", preset.skills.count), color: AppStyle.textTertiary)
                        if let healthLabel {
                            tinyBadge(healthLabel, color: statusColor)
                        }
                    }
                    Text((preset.description?.isEmpty == false) ? preset.description! : L("一键应用这组 Skills 到可用 Agent。"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(AppStyle.textSecondary)
                        .lineLimit(2)
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: onExpand)

                Spacer(minLength: 6)
                HStack(spacing: 4) {
                    iconButton("play.fill", help: L("应用 Preset"), action: onApply)
                    iconButton("minus.circle", help: L("移除 Preset 同步"), action: onRemove)
                    iconButton("trash", help: L("删除 Preset"), destructive: true, action: onDelete)
                    iconButton(expanded ? "chevron.up" : "chevron.down", help: L("展开"), action: onExpand)
                }
            }

            if !orderedIncludedSkills.isEmpty {
                HStack(spacing: 5) {
                    ForEach(orderedIncludedSkills.prefix(8)) { skill in
                        tinyBadge(skill.name, color: AppStyle.textTertiary)
                    }
                    if orderedIncludedSkills.count > 8 {
                        tinyBadge("+\(orderedIncludedSkills.count - 8)", color: AppStyle.textTertiary)
                    }
                }
            }

            if expanded {
                ToolSoftGroup {
                    VStack(alignment: .leading, spacing: 9) {
                        if skills.isEmpty {
                            Text(L("中央库还没有 Skill。先导入或扫描发现。"))
                                .font(.system(size: 10.5))
                                .foregroundStyle(AppStyle.textTertiary)
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                presetSectionHeader(title: L("已启用"), count: orderedIncludedSkills.count)
                                if orderedIncludedSkills.isEmpty {
                                    compactPresetEmpty(L("这个 Preset 还没有 Skill"))
                                } else {
                                    ForEach(orderedIncludedSkills) { skill in
                                        skillToggle(skill)
                                    }
                                }
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                presetSectionHeader(title: L("可加入"), count: availablePresetSkills.count)
                                if availablePresetSkills.isEmpty {
                                    compactPresetEmpty(L("全部 Skill 都已在这个 Preset 中"))
                                } else {
                                    ForEach(availablePresetSkills) { skill in
                                        skillToggle(skill)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .contextMenu {
            Button(L("打开")) { onExpand() }
            Button(L("应用 Preset")) { onApply() }
            Button(L("移除 Preset 同步")) { onRemove() }
            Divider()
            Button(L("删除 Preset"), role: .destructive) { onDelete() }
        }
        .skillPanelSurface()
    }

    private func presetSectionHeader(title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(AppStyle.textSecondary)
            tinyBadge(L("%ld", count), color: AppStyle.textTertiary)
            Spacer(minLength: 0)
        }
    }

    private func compactPresetEmpty(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10.5))
            .foregroundStyle(AppStyle.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .frame(height: 30)
            .skillSoftSurface(opacity: 0.8)
    }

    private func skillToggle(_ skill: ManagedSkill) -> some View {
        let included = includedIDs.contains(skill.id)
        let index = orderedIncludedSkills.firstIndex(where: { $0.id == skill.id })
        return HStack(spacing: 6) {
            Button {
                onToggleSkill(skill, !included)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: included ? "checkmark.square.fill" : "square")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(included ? AppStyle.accent : AppStyle.textTertiary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(skill.name)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(AppStyle.textPrimary)
                        Text((skill.description?.isEmpty == false) ? skill.description! : collapsedPath(skill.centralPath))
                            .font(.system(size: 9.5))
                            .foregroundStyle(AppStyle.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if !skill.targets.isEmpty {
                        tinyBadge(L("已同步 %ld", skill.targets.count), color: AppStyle.accent)
                    }
                }
            }
            .buttonStyle(.plain)

            if let index {
                Button {
                    onMoveSkill(skill, -1)
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(index == 0 ? AppStyle.textTertiary.opacity(0.45) : AppStyle.textSecondary)
                        .frame(width: 22, height: 22)
                        .skillIconSurface(color: AppStyle.textTertiary, shape: .circle)
                }
                .buttonStyle(PressScaleStyle())
                .disabled(index == 0)
                .help(L("上移"))

                Button {
                    onMoveSkill(skill, 1)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(index >= orderedIncludedSkills.count - 1 ? AppStyle.textTertiary.opacity(0.45) : AppStyle.textSecondary)
                        .frame(width: 22, height: 22)
                        .skillIconSurface(color: AppStyle.textTertiary, shape: .circle)
                }
                .buttonStyle(PressScaleStyle())
                .disabled(index >= orderedIncludedSkills.count - 1)
                .help(L("下移"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .skillRowSurface(selected: included)
        .contextMenu {
            Button(included ? L("移出 Preset") : L("加入 Preset")) {
                onToggleSkill(skill, !included)
            }
            if let index {
                Button(L("上移")) { onMoveSkill(skill, -1) }
                    .disabled(index == 0)
                Button(L("下移")) { onMoveSkill(skill, 1) }
                    .disabled(index >= orderedIncludedSkills.count - 1)
            }
        }
    }

    private var healthLabel: String? {
        guard let summary, summary.totalPairs > 0 else { return nil }
        if summary.syncedPairs >= summary.totalPairs { return L("已应用") }
        if summary.syncedPairs > 0 { return "\(summary.syncedPairs)/\(summary.totalPairs)" }
        return L("未应用")
    }

    private var statusIcon: String {
        guard let summary, summary.totalPairs > 0 else { return "rectangle.stack" }
        if summary.syncedPairs >= summary.totalPairs { return "checkmark.circle.fill" }
        if summary.syncedPairs > 0 { return "circle.lefthalf.filled" }
        return "circle"
    }

    private var statusColor: Color {
        guard let summary, summary.totalPairs > 0 else { return AppStyle.textTertiary }
        if summary.syncedPairs >= summary.totalPairs { return AppStyle.accent }
        if summary.syncedPairs > 0 { return AppStyle.waitAmber }
        return AppStyle.textTertiary
    }
}

private struct ProjectWorkspaceRow: View {
    let project: SkillProject
    let projectSkills: [ProjectSkillInfo]
    let centralSkills: [ManagedSkill]
    let presets: [SkillPreset]
    let tools: [SkillToolInfo]
    let targets: [SkillProjectTargetRecord]
    let expanded: Bool
    let onExpand: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void
    let onToggleSkill: (ManagedSkill, SkillToolInfo, Bool) -> Void
    let onApplyPreset: (SkillPreset) -> Void
    let onRemovePreset: (SkillPreset) -> Void

    private var targetPairs: Set<String> {
        Set(targets.map { "\($0.skillID)|\($0.tool)" })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "folder.badge.gearshape")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppStyle.accent)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(project.name)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(AppStyle.textPrimary)
                            .lineLimit(1)
                        tinyBadge(L("%ld 个项目 Skill", projectSkills.count), color: AppStyle.textTertiary)
                        if !targets.isEmpty {
                            tinyBadge(L("同步 %ld", targets.count), color: AppStyle.accent)
                        }
                    }
                    Text(collapsedPath(project.path))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(AppStyle.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: onExpand)

                Spacer(minLength: 6)
                HStack(spacing: 4) {
                    iconButton("folder", help: L("在 Finder 显示"), action: onReveal)
                    iconButton("trash", help: L("移除项目"), destructive: true, action: onDelete)
                    iconButton(expanded ? "chevron.up" : "chevron.down", help: L("展开"), action: onExpand)
                }
            }

            if !tools.isEmpty {
                HStack(spacing: 5) {
                    ForEach(tools.prefix(8)) { tool in
                        tinyBadge(tool.displayName, color: AppStyle.textTertiary)
                    }
                    if tools.count > 8 {
                        tinyBadge("+\(tools.count - 8)", color: AppStyle.textTertiary)
                    }
                }
            }

            if expanded {
                ToolSoftGroup {
                    VStack(alignment: .leading, spacing: 10) {
                        presetControls
                        centralSkillControls
                        projectSkillList
                    }
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .contextMenu {
            Button(L("打开")) { onExpand() }
            Button(L("在 Finder 显示")) { onReveal() }
            if !presets.isEmpty {
                Divider()
                Menu(L("应用 Preset")) {
                    ForEach(presets) { preset in
                        Button(preset.name) { onApplyPreset(preset) }
                    }
                }
                Menu(L("移除 Preset 同步")) {
                    ForEach(presets) { preset in
                        Button(preset.name) { onRemovePreset(preset) }
                    }
                }
            }
            Divider()
            Button(L("移除项目"), role: .destructive) { onDelete() }
        }
        .skillPanelSurface()
    }

    @ViewBuilder
    private var presetControls: some View {
        if !presets.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Preset 到项目"))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(AppStyle.textSecondary)
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(presets) { preset in
                            HStack(spacing: 4) {
                                Button { onApplyPreset(preset) } label: {
                                    Label(preset.name, systemImage: "play.fill")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 7)
                                        .frame(height: 23)
                                        .skillPrimaryControlSurface()
                                }
                                .buttonStyle(PressScaleStyle())
                                Button { onRemovePreset(preset) } label: {
                                    Image(systemName: "minus.circle")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(AppStyle.textSecondary)
                                        .frame(width: 23, height: 23)
                                        .skillIconSurface(color: AppStyle.textTertiary, shape: .circle)
                                }
                                .buttonStyle(PressScaleStyle())
                                .help(L("移除这个 Preset 在项目里的同步"))
                            }
                        }
                    }
                    .padding(.vertical, 1)
                }
                .scrollIndicators(.never)
            }
        }
    }

    @ViewBuilder
    private var centralSkillControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("中央库 Skills 到项目"))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(AppStyle.textSecondary)
            if centralSkills.isEmpty {
                Text(L("中央库还没有 Skill。"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(AppStyle.textTertiary)
            } else if tools.isEmpty {
                Text(L("没有支持项目级目录的 Agent。"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(AppStyle.textTertiary)
            } else {
                ForEach(centralSkills) { skill in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(skill.name)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(AppStyle.textPrimary)
                            .lineLimit(1)
                        ScrollView(.horizontal) {
                            HStack(spacing: 5) {
                                ForEach(tools) { tool in
                                    projectToolToggle(skill: skill, tool: tool)
                                }
                            }
                            .padding(.vertical, 1)
                        }
                        .scrollIndicators(.never)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .skillRowSurface()
                }
            }
        }
    }

    @ViewBuilder
    private var projectSkillList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("项目实际存在的 Skills"))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(AppStyle.textSecondary)
            if projectSkills.isEmpty {
                Text(L("这个项目目录里还没有扫描到项目级 Skills。"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(AppStyle.textTertiary)
            } else {
                ForEach(projectSkills.prefix(12)) { skill in
                    HStack(spacing: 6) {
                        tinyBadge(skill.toolDisplayName, color: AppStyle.textTertiary)
                        Text(skill.name)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(AppStyle.textPrimary)
                            .lineLimit(1)
                        tinyBadge(statusLabel(skill.syncStatus), color: statusColor(skill.syncStatus))
                        Spacer()
                    }
                }
                if projectSkills.count > 12 {
                    Text(L("还有 %ld 个项目 Skill", projectSkills.count - 12))
                        .font(.system(size: 10))
                        .foregroundStyle(AppStyle.textTertiary)
                }
            }
        }
    }

    private func projectToolToggle(skill: ManagedSkill, tool: SkillToolInfo) -> some View {
        let synced = targetPairs.contains("\(skill.id)|\(tool.key)")
        return Button {
            onToggleSkill(skill, tool, !synced)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: synced ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 9.5, weight: .semibold))
                Text(tool.displayName)
                    .font(.system(size: 9.5, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(synced ? .white : AppStyle.textSecondary)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .skillControlSurface(active: synced, tint: AppStyle.accent)
        }
        .buttonStyle(PressScaleStyle())
    }

    private func statusLabel(_ status: String) -> String {
        switch status {
        case "in_sync": return L("同步")
        case "diverged": return L("差异")
        default: return L("项目")
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "in_sync": return AppStyle.accent
        case "diverged": return AppStyle.waitAmber
        default: return AppStyle.textTertiary
        }
    }
}

private struct SkillToolRow: View {
    let tool: SkillToolInfo
    let syncedCount: Int
    let onToggleEnabled: () -> Void
    let onReveal: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                SkillAgentIconView(tool: tool, size: 30, cornerRadius: 8)
                    .opacity(tool.enabled ? 1 : 0.48)
                Image(systemName: tool.installed ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(tool.installed ? AppStyle.accent : AppStyle.textTertiary)
                    .background(Circle().fill(AppStyle.windowBackground))
                    .offset(x: 3, y: 3)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(tool.displayName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(AppStyle.textPrimary)
                    tinyBadge(tool.category.rawValue, color: AppStyle.textTertiary)
                    if tool.isCustom { tinyBadge(L("自定义"), color: AppStyle.accent) }
                    if !tool.enabled { tinyBadge(L("停用"), color: AppStyle.errorRed) }
                }
                Text(collapsedPath(tool.skillsDirectory))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(AppStyle.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(L("已同步 %ld 个 Skill", syncedCount))
                    .font(.system(size: 10))
                    .foregroundStyle(AppStyle.textSecondary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                Button(action: onToggleEnabled) {
                    Image(systemName: tool.enabled ? "pause.circle" : "play.circle")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(AppStyle.textSecondary)
                        .frame(width: 26, height: 26)
                        .skillIconSurface(color: AppStyle.textTertiary, shape: .circle)
                }
                .buttonStyle(PressScaleStyle())
                .help(tool.enabled ? L("停用 Agent") : L("启用 Agent"))

                Button(action: onReveal) {
                    Image(systemName: "folder")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(AppStyle.textSecondary)
                        .frame(width: 26, height: 26)
                        .skillIconSurface(color: AppStyle.textTertiary, shape: .circle)
                }
                .buttonStyle(PressScaleStyle())
                .help(L("在 Finder 显示"))
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .contextMenu {
            Button(tool.enabled ? L("停用 Agent") : L("启用 Agent")) { onToggleEnabled() }
            Button(L("在 Finder 显示")) { onReveal() }
        }
        .skillPanelSurface()
    }
}

private struct SkillAuditRow: View {
    let entry: SkillAuditEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 18, height: 20)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(actionLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppStyle.textPrimary)
                    if let skillName = entry.skillName {
                        tinyBadge(skillName, color: AppStyle.textTertiary)
                    }
                    if let tool = entry.tool {
                        tinyBadge(tool, color: AppStyle.textTertiary)
                    }
                    if !entry.success {
                        tinyBadge(L("失败"), color: AppStyle.errorRed)
                    }
                    Spacer(minLength: 6)
                    Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 9.5))
                        .foregroundStyle(AppStyle.textTertiary)
                }
                if let detail = entry.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(AppStyle.textSecondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .skillPanelSurface()
    }

    private var actionLabel: String {
        switch entry.action {
        case "install": return L("安装 Skill")
        case "bundle_export": return L("导出 Bundle")
        case "bundle_import": return L("导入 Bundle")
        case "sync": return L("同步到 Agent")
        case "unsync": return L("移除 Agent 同步")
        case "project_sync": return L("同步到项目")
        case "project_unsync": return L("移除项目同步")
        case "refresh": return L("刷新来源")
        case "check_update": return L("检查更新")
        case "relink_source": return L("重新绑定来源")
        case "detach_source": return L("解除来源绑定")
        case "delete": return L("删除 Skill")
        case "tag_add": return L("添加标签")
        case "tag_remove": return L("移除标签")
        case "set_tags": return L("设置标签")
        case "tool_enable": return L("启用 Agent")
        case "tool_disable": return L("停用 Agent")
        case "tool_custom_add": return L("添加自定义 Agent")
        case "preset_create": return L("创建 Preset")
        case "preset_delete": return L("删除 Preset")
        case "preset_reorder": return L("调整 Preset 顺序")
        case "scan": return L("扫描本机")
        default: return entry.action
        }
    }

    private var icon: String {
        if !entry.success { return "exclamationmark.triangle.fill" }
        switch entry.action {
        case "install", "bundle_import": return "square.and.arrow.down"
        case "bundle_export": return "square.and.arrow.up"
        case "sync", "project_sync": return "arrow.triangle.2.circlepath"
        case "unsync", "project_unsync": return "minus.circle"
        case "refresh", "check_update": return "arrow.clockwise.circle"
        case "delete": return "trash"
        case "tag_add", "tag_remove", "set_tags": return "tag"
        case "tool_enable", "tool_disable", "tool_custom_add": return "cpu"
        case "preset_create", "preset_delete", "preset_reorder": return "rectangle.stack"
        case "scan": return "scope"
        default: return "clock"
        }
    }

    private var color: Color {
        if !entry.success { return AppStyle.errorRed }
        switch entry.action {
        case "delete", "unsync", "project_unsync", "tag_remove", "tool_disable", "preset_delete":
            return AppStyle.waitAmber
        default:
            return AppStyle.accent
        }
    }
}

private struct SkillsShMarketRow: View {
    let skill: SkillsShSkill
    let installed: Bool
    let onInstall: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: installed ? "checkmark.seal.fill" : "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(installed ? AppStyle.accent : AppStyle.textTertiary)
                .frame(width: 16, height: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(skill.name)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(AppStyle.textPrimary)
                        .lineLimit(1)
                    tinyBadge(skill.source, color: AppStyle.textTertiary)
                    if skill.installs > 0 {
                        tinyBadge("\(skill.installs)", color: AppStyle.textTertiary)
                    }
                    if installed {
                        tinyBadge(L("已安装"), color: AppStyle.accent)
                    }
                }
                Text(skill.skillID)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(AppStyle.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 6)
            Button(action: onInstall) {
                Label(installed ? L("更新") : L("安装"), systemImage: "square.and.arrow.down")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .skillPrimaryControlSurface()
            }
            .buttonStyle(PressScaleStyle())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .skillRowSurface()
    }
}

private struct GitSkillPreviewRow: View {
    let preview: GitSkillPreview
    let selected: Bool
    let stale: Bool
    let onToggle: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onToggle) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? AppStyle.accent : AppStyle.textTertiary)
                    .frame(width: 16, height: 22)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(preview.name)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(AppStyle.textPrimary)
                            .lineLimit(1)
                        tinyBadge(preview.relativePath, color: AppStyle.textTertiary)
                        if stale {
                            tinyBadge(L("已过期"), color: AppStyle.waitAmber)
                        }
                    }
                    Text((preview.description?.isEmpty == false) ? preview.description! : L("无描述"))
                        .font(.system(size: 9.5))
                        .foregroundStyle(AppStyle.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .skillRowSurface(selected: selected, hovering: hovering)
            .opacity(stale ? 0.68 : 1)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(selected ? L("取消选择") : L("选择")) { onToggle() }
        }
        .onHover { hovering = $0 }
        .animation(AgentToolsMotion.hover, value: hovering)
        .animation(AgentToolsMotion.selection, value: selected)
    }
}

private struct DiscoveredSkillGroupRow: View {
    let group: DiscoveredSkillGroup
    let selected: Bool
    let onToggleSelection: () -> Void
    let onImport: () -> Void
    let onReveal: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                IconOnlyButton(
                    systemName: selected ? "checkmark.square.fill" : "square",
                    help: selected ? L("取消选择") : L("选择"),
                    size: 24,
                    symbolSize: 11,
                    tint: selected ? AppStyle.accent : AppStyle.textTertiary,
                    action: onToggleSelection)
                    .disabled(group.imported)

                Image(systemName: group.imported ? "checkmark.seal.fill" : "sparkle.magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(group.imported ? AppStyle.accent : AppStyle.textTertiary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(group.name)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(AppStyle.textPrimary)
                        tinyBadge(L("%ld 处", group.locations.count), color: AppStyle.textTertiary)
                        if group.imported { tinyBadge(L("已导入"), color: AppStyle.accent) }
                    }
                    if let fingerprint = group.fingerprint {
                        Text(fingerprint)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(AppStyle.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
                Button(action: onImport) {
                    Label(group.imported ? L("更新") : L("导入"), systemImage: "square.and.arrow.down")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .skillPrimaryControlSurface()
                }
                .buttonStyle(PressScaleStyle())
            }

            ForEach(group.locations) { location in
                HStack(spacing: 6) {
                    tinyBadge(location.tool, color: AppStyle.textTertiary)
                    Text(collapsedPath(location.foundPath))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(AppStyle.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button { onReveal(location.foundPath) } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(AppStyle.textSecondary)
                            .frame(width: 22, height: 22)
                            .skillIconSurface(color: AppStyle.textTertiary, shape: .circle)
                    }
                    .buttonStyle(.plain)
                    .help(L("在 Finder 显示"))
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .contextMenu {
            if !group.imported {
                Button(selected ? L("取消选择") : L("选择")) { onToggleSelection() }
                Divider()
            }
            Button(group.imported ? L("更新") : L("导入")) { onImport() }
            if let firstPath = group.locations.first?.foundPath {
                Button(L("在 Finder 显示")) { onReveal(firstPath) }
            }
        }
        .skillRowSurface(selected: selected)
        .animation(AgentToolsMotion.selection, value: selected)
    }
}

@MainActor
private func tinyBadge(_ text: String, color: Color) -> some View {
    // 统一到 ToolBadge 的软胶囊样式，保留 tiny 体量（小号 + 矮胶囊）。
    ToolBadge(text: text, color: color, style: .soft, height: 18)
}

@MainActor
private func iconButton(_ icon: String,
                        help: String,
                        destructive: Bool = false,
                        action: @escaping () -> Void) -> some View {
    IconOnlyButton(
        systemName: icon,
        help: help,
        size: 24,
        symbolSize: 10.5,
        weight: .semibold,
        tint: destructive ? AppStyle.errorRed : nil,
        action: action)
}

private func diffStatusLabel(_ status: String) -> String {
    switch status {
    case "added": return L("新增")
    case "removed": return L("删除")
    case "modified": return L("修改")
    default: return status
    }
}

@MainActor
private func diffStatusColor(_ status: String) -> Color {
    switch status {
    case "added": return AppStyle.accent
    case "removed": return AppStyle.errorRed
    case "modified": return AppStyle.waitAmber
    default: return AppStyle.textTertiary
    }
}

private func skillAuditActionLabel(_ action: String) -> String {
    switch action {
    case "install": return L("安装 Skill")
    case "bundle_export": return L("导出 Bundle")
    case "bundle_import": return L("导入 Bundle")
    case "sync": return L("同步到 Agent")
    case "unsync": return L("移除 Agent 同步")
    case "project_sync": return L("同步到项目")
    case "project_unsync": return L("移除项目同步")
    case "refresh": return L("刷新来源")
    case "check_update": return L("检查更新")
    case "relink_source": return L("重新绑定来源")
    case "detach_source": return L("解除来源绑定")
    case "delete": return L("删除 Skill")
    case "tag_add": return L("添加标签")
    case "tag_remove": return L("移除标签")
    case "set_tags": return L("设置标签")
    case "tool_enable": return L("启用 Agent")
    case "tool_disable": return L("停用 Agent")
    case "tool_custom_add": return L("添加自定义 Agent")
    case "preset_create": return L("创建 Preset")
    case "preset_delete": return L("删除 Preset")
    case "preset_reorder": return L("调整 Preset 顺序")
    case "scan": return L("扫描本机")
    default: return action
    }
}

private func collapsedPath(_ path: String) -> String { PathDisplay.tilde(path) }

private func byteCount(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
