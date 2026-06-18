import ConductorCore
import SwiftUI

/// 设置面板：主窗口内 inspector，跟随主题、自定义控件 + 微交互。
/// 改控件 → `coordinator.applyConfig` 即时生效 + 落盘 config.yaml。
struct SettingsView: View {
    let coordinator: AppCoordinator
    var onClose: () -> Void = {}
    @ObservedObject private var configStore = ConfigStore.shared

    @State private var shell = ConfigStore.shared.config.terminal.shell ?? ""
    @State private var companionName = ConfigStore.shared.config.companion.name ?? ""
    @State private var selectedSection: SettingsSectionID = .default
    /// 键位编辑用本地草稿：避免每个按键都落盘，提交（回车）时才生效。
    @State private var keybindingDrafts: [String: String] = [:]
    @State private var languageChoice: String = AppLanguage.current
    @State private var draftAgentTitle = ""
    @State private var draftAgentCommand = ""

    private var config: AppConfig { configStore.config }

    private var languageBinding: Binding<String> {
        Binding(
            get: { languageChoice },
            set: { choice in
                guard choice != languageChoice else { return }
                languageChoice = choice
                AppLanguage.apply(choice)   // 持久化 + 热生效（整棵 UI 即时重建）
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(alignment: .top, spacing: 14) {
                sectionRail

                ScrollView {
                    VStack(spacing: Space.lg) {
                        selectedSectionContent
                    }
                    .padding(.top, Space.sm)
                    .padding(.trailing, 22)
                    .padding(.bottom, 22)
                }
                .scrollIndicators(.visible)
            }
        }
        .frame(maxHeight: .infinity)
        .background(.clear)   // 透明：用根底统一磨砂
    }

    private var header: some View {
        HStack {
            Text(L("设置"))
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(AppStyle.textPrimary)
            Spacer()
            IconOnlyButton(
                systemName: "xmark",
                help: L("关闭设置"),
                size: 28,
                symbolSize: 11,
                weight: .bold,
                action: onClose)
        }
        .padding(.horizontal, Space.lg)
        .padding(.top, 22)
        .padding(.bottom, 10)
    }

    private var sectionRail: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(SettingsSectionID.allCases) { section in
                SettingsRailButton(
                    section: section,
                    selected: selectedSection == section
                ) {
                    withAnimation(Motion.snappy) {
                        selectedSection = section
                    }
                }
            }
            Spacer(minLength: 0)
            settingsFeedbackButton
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, Space.sm)
        .frame(width: 136)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private var settingsFeedbackButton: some View {
        Button {
            coordinator.openTools(.coCreate)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(AppStyle.textTertiary)
                    .frame(width: 18)
                Text(L("反馈 / 共创"))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(AppStyle.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .contentShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .help(L("打开反馈与共创"))
    }

    @ViewBuilder
    private var selectedSectionContent: some View {
        switch selectedSection {
        case .appearance:
            appearanceSection
            if config.appearance.theme == "custom" { colorsSection }
        case .terminal:
            terminalSection
        case .ghostty:
            ghosttySection
        case .behavior:
            behaviorSection
        case .companion:
            companionSection
        case .keybindings:
            keybindingsSection
        }
    }

    private var companionSection: some View {
        SettingsSection(title: L("桌面伙伴")) {
            SettingsRow(label: L("显示桌面伙伴"), first: true) {
                ThemedToggle(isOn: bind(\.companion.enabled))
            }
            SettingsRow(label: L("伙伴通知")) {
                ThemedToggle(isOn: bind(\.companion.notifyPet))
            }
            SettingsRow(label: L("系统通知")) {
                ThemedToggle(isOn: bind(\.companion.notifySystem))
            }
            SettingsRow(label: L("昵称")) {
                ThemedTextField(placeholder: L(config.companion.template.nameKey), text: $companionName) {
                    update { $0.companion.name = companionName.isEmpty ? nil : companionName }
                }
            }
            SettingsRow(label: L("停靠角落")) {
                ThemedSegmented(
                    options: [(L("左上"), "topLeft"), (L("右上"), "topRight"),
                              (L("左下"), "bottomLeft"), (L("右下"), "bottomRight")],
                    selection: companionCornerBinding)
            }
            SettingsRow(label: L("说话气泡")) {
                ThemedToggle(isOn: bind(\.companion.speechBubbles))
            }
            SettingsRow(label: L("待审批时气泡内联允许/拒绝")) {
                ThemedToggle(isOn: bind(\.companion.inlineApproval))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(L("模版"))
                    .font(.system(size: 12))
                    .foregroundStyle(AppStyle.textSecondary)
                CompanionTemplatePicker(selectedID: bind(\.companion.templateID))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
            .padding(.horizontal, 2)
        }
    }

    /// Corner ↔ String 桥接（ThemedSegmented 只吃 String）。
    private var companionCornerBinding: Binding<String> {
        Binding(
            get: { config.companion.corner.rawValue },
            set: { raw in
                update { $0.companion.corner = CompanionConfig.Corner(rawValue: raw) ?? .bottomRight }
            })
    }

    private var appearanceSection: some View {
        SettingsSection(title: L("外观")) {
            ThemePickerRow(selection: bind(\.appearance.theme))
            SettingsRow(label: L("语言")) {
                // 语言名按惯例保持各自语言原文，不随界面语言翻译
                ThemedSegmented(
                    options: [(L("跟随系统"), AppLanguage.system),
                              ("简体中文", AppLanguage.simplifiedChinese),
                              ("English", AppLanguage.english)],
                    selection: languageBinding)
            }
            SettingsRow(label: L("水平内边距")) {
                ThemedStepper(value: bind(\.appearance.padding.x), range: 0...60)
            }
            SettingsRow(label: L("垂直内边距")) {
                ThemedStepper(value: bind(\.appearance.padding.y), range: 0...60)
            }
        }
    }

    private var terminalSection: some View {
        VStack(spacing: Space.lg) {
            SettingsSection(title: L("终端")) {
                SettingsRow(label: "Shell", first: true) {
                    ThemedTextField(placeholder: L("登录 shell"), text: $shell) {
                        update { $0.terminal.shell = shell.isEmpty ? nil : shell }
                    }
                }
                SettingsRow(label: L("回滚行数")) {
                    ThemedStepper(value: bind(\.terminal.scrollback), range: 60_000...1_000_000, step: 10_000)
                }
                SettingsRow(label: L("选中即复制")) {
                    ThemedToggle(isOn: bind(\.terminal.copyOnSelect))
                }
                SettingsRow(label: L("有运行进程时关闭需确认")) {
                    ThemedToggle(isOn: bind(\.terminal.confirmCloseRunning))
                }
                SettingsRow(label: L("恢复时自动续聊 Agent")) {
                    ThemedToggle(isOn: bind(\.terminal.autoResumeAgentSessions))
                }
            }
            aiAgentsSection
        }
    }

    private var aiAgentsSection: some View {
        SettingsSection(title: L("AI 助手")) {
            SettingsRow(label: L("会话入口"), first: true) {
                HStack(spacing: 8) {
                    Text(config.terminal.aiAgents.isEmpty ? L("自动检测") : L("%ld 个", config.terminal.aiAgents.count))
                        .font(.system(size: 12))
                        .foregroundStyle(AppStyle.textSecondary)
                    ToolActionButton(
                        title: L("自动扫描"),
                        systemImage: "wand.and.stars",
                        height: 24,
                        fontSize: 11,
                        horizontalPadding: 9) {
                            coordinator.scanAIAgentsIntoConfig()
                        }
                }
            }
            ForEach(config.terminal.aiAgents, id: \.id) { agent in
                ConfiguredAgentRow(
                    agent: agent,
                    isEnabled: agentEnabledBinding(agent.id),
                    onDelete: { removeAgent(agent.id) }
                )
            }
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 8) {
                    ThemedTextField(placeholder: L("名称"), text: $draftAgentTitle)
                    ThemedTextField(placeholder: L("Agent 启动命令"), text: $draftAgentCommand) {
                        addDraftAgent()
                    }
                    IconOnlyButton(
                        systemName: "plus",
                        help: L("添加自定义 Agent"),
                        size: 28,
                        symbolSize: 12,
                        weight: .bold,
                        action: addDraftAgent)
                    .disabled(draftAgentCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text(L("留空配置时使用自动检测结果；手动配置后，新建 AI 会话入口按这里的启用项显示。"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(AppStyle.textTertiary)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 6)
        }
    }

    private var ghosttySection: some View {
        VStack(spacing: Space.lg) {
            SettingsSection(title: L("常用能力")) {
                GhosttyMappedConfigRow(
                    title: L("字体与字号"),
                    summary: L("字体、字号和字格微调会直接影响终端阅读感"),
                    keys: ["font-family", "font-size", "adjust-cell-height"],
                    first: true
                )
                GhosttyMappedConfigRow(
                    title: L("窗口与光标"),
                    summary: L("窗口留白、光标样式和颜色会跟随下方设置即时生效"),
                    keys: ["cursor-style", "cursor-color"]
                )
                GhosttyMappedConfigRow(
                    title: L("主题颜色"),
                    summary: L("背景、文字、选区和搜索颜色统一归到颜色分类里")
                )
            }

            ForEach(ConductorGhosttyConfigCatalog.productGroups) { group in
                SettingsSection(title: group.title) {
                    GhosttyConfigGroupHeader(group: group, first: true)
                    ForEach(group.keys, id: \.self) { key in
                        GhosttyOverrideRow(
                            key: key,
                            value: configStore.config.ghosttyOverrides[key] ?? "",
                            setValue: { setGhosttyOverride(key, to: $0) },
                            reset: { setGhosttyOverride(key, to: "") }
                        )
                    }
                }
            }
        }
    }

    private var behaviorSection: some View {
        SettingsSection(title: L("行为")) {
            SettingsRow(label: L("启动时恢复布局"), first: true) {
                ThemedToggle(isOn: bind(\.behavior.restoreLayoutOnLaunch))
            }
            SettingsRow(label: L("新标签目录")) {
                ThemedSegmented(options: [(L("工作区"), "workspace"), (L("当前"), "activePane"), (L("主目录"), "home")],
                                selection: bind(\.behavior.newTabCwd))
            }
        }
    }

    // MARK: 自定义配色（仅 theme=custom 时显示）

    private var colorsSection: some View {
        SettingsSection(title: L("自定义配色")) {
            SettingsRow(label: L("背景"), first: true) {
                ColorPicker("", selection: colorBinding({ $0?.background }, "1b1c22", { $0.background = $1 })).labelsHidden()
            }
            SettingsRow(label: L("前景")) {
                ColorPicker("", selection: colorBinding({ $0?.foreground }, "e6e6e6", { $0.foreground = $1 })).labelsHidden()
            }
            SettingsRow(label: L("光标")) {
                ColorPicker("", selection: colorBinding({ $0?.cursor }, "7aa2f7", { $0.cursor = $1 })).labelsHidden()
            }
            SettingsRow(label: L("选区")) {
                ColorPicker("", selection: colorBinding({ $0?.selection }, "33467c", { $0.selection = $1 })).labelsHidden()
            }
        }
    }

    private func colorBinding(_ get: @escaping (Colors?) -> String?, _ fallback: String,
                              _ set: @escaping (inout Colors, String) -> Void) -> Binding<Color> {
        Binding(
            get: { Color(hex: get(configStore.config.appearance.colors) ?? fallback) ?? .gray },
            set: { newColor in
                update { cfg in
                    var colors = cfg.appearance.colors ?? Colors()
                    set(&colors, newColor.hexString)
                    cfg.appearance.colors = colors
                }
            })
    }

    // MARK: 快捷键自定义（输入键位串，回车生效；留空回落内置默认）

    private var keybindingsSection: some View {
        SettingsSection(title: L("快捷键")) {
            ForEach(Array(coordinator.commandRegistry.commands.enumerated()), id: \.element.id) { idx, cmd in
                SettingsRow(label: cmd.title, first: idx == 0) {
                    ThemedTextField(placeholder: cmd.defaultKeybinding ?? L("未设置"),
                                    text: keybindingDraftBinding(cmd.id)) {
                        commitKeybinding(cmd.id)
                    }
                }
            }
        }
    }

    private func keybindingDraftBinding(_ id: String) -> Binding<String> {
        Binding(
            get: { keybindingDrafts[id] ?? coordinator.commandRegistry.effectiveKeybinding(for: id) ?? "" },
            set: { keybindingDrafts[id] = $0 })
    }

    private func commitKeybinding(_ id: String) {
        let raw = (keybindingDrafts[id] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        update { cfg in
            if raw.isEmpty { cfg.keybindings.removeValue(forKey: id) }
            else { cfg.keybindings[id] = raw }
        }
        keybindingDrafts[id] = nil   // 回落到“有效键位”展示
    }

    private func agentEnabledBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { configStore.config.terminal.aiAgents.first(where: { $0.id == id })?.enabled ?? false },
            set: { enabled in
                update { cfg in
                    guard let index = cfg.terminal.aiAgents.firstIndex(where: { $0.id == id }) else { return }
                    cfg.terminal.aiAgents[index].enabled = enabled
                }
            })
    }

    private func addDraftAgent() {
        let title = draftAgentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = draftAgentCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        let id = Self.agentID(from: title.isEmpty ? command : title)
        update { cfg in
            cfg.terminal.aiAgents.removeAll { $0.id == id }
            cfg.terminal.aiAgents.append(AIAgentConfig(
                id: id,
                title: title.isEmpty ? command : title,
                command: command,
                enabled: true))
        }
        draftAgentTitle = ""
        draftAgentCommand = ""
    }

    private func removeAgent(_ id: String) {
        update { $0.terminal.aiAgents.removeAll { $0.id == id } }
    }

    private static func agentID(from raw: String) -> String {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let scalars = lower.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(scalars)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? UUID().uuidString : collapsed
    }

    private func bind<T>(_ keyPath: WritableKeyPath<AppConfig, T>) -> Binding<T> {
        Binding(
            get: { configStore.config[keyPath: keyPath] },
            set: { newValue in update { $0[keyPath: keyPath] = newValue } })
    }

    private func update(_ mutate: (inout AppConfig) -> Void) {
        var c = configStore.config
        mutate(&c)
        coordinator.applyConfig(c)
    }

    private func setGhosttyOverride(_ key: String, to value: String) {
        update { config in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                config.ghosttyOverrides.removeValue(forKey: key)
                return
            }
            config.ghosttyOverrides[key] = trimmed
        }
    }
}

/// 主题选择：带实时预览色卡的网格（纯色 / 渐变 / 玻璃一眼可辨），替代朴素分段控件。
private struct ThemePickerRow: View {
    @Binding var selection: String

    private var options: [(value: String, label: String)] {
        // 配色专名不随界面语言翻译，保留原文。
        [("dark", L("深色")), ("light", L("浅色")),
         ("tokyo-night", "Tokyo Night"), ("catppuccin", "Catppuccin"),
         ("nord", "Nord"), ("rose-pine", "Rosé Pine"),
         ("midnight", "Midnight"),
         ("orchid-dusk", "Orchid Dusk"), ("ember", "Ember"),
         ("graphite", "Graphite"), ("deep-sea", "Deep Sea"),
         ("blossom", "Blossom"), ("nebula", "Nebula"),
         ("mojave", "Mojave"), ("bordeaux", "Bordeaux"),
         ("slate", "Slate"),
         ("custom", L("自定义"))]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("主题"))
                .font(.system(size: 13))
                .foregroundStyle(AppStyle.textPrimary)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 92, maximum: 150), spacing: 12)],
                alignment: .leading, spacing: 12
            ) {
                ForEach(options, id: \.value) { opt in
                    ThemeSwatchButton(
                        value: opt.value, label: opt.label,
                        isSelected: selection == opt.value,
                        action: { withAnimation(Motion.snappy) { selection = opt.value } })
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 2)
    }
}

private struct ThemeSwatchButton: View {
    let value: String
    let label: String
    let isSelected: Bool
    let action: () -> Void

    private var theme: Theme { Theme.resolve(Appearance(theme: value)) }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ThemeSwatch(theme: theme, selected: isSelected)
                    .frame(height: 52)
                Text(label)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? AppStyle.textPrimary : AppStyle.textSecondary)
            }
        }
        .buttonStyle(PressScaleStyle())
        .help(label)
    }
}

/// 单个主题的迷你预览：画布（纯色/渐变/玻璃）+ 侧栏条 + 两行示意文字 + 强调点。
private struct ThemeSwatch: View {
    let theme: Theme
    let selected: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        ZStack(alignment: .topLeading) {
            if theme.backgroundGlows != nil {
                ThemeBackdrop(theme: theme)   // 暗底 + 光晕，与主窗口同款
            } else {
                theme.windowBackground
            }
            HStack(spacing: 0) {
                Rectangle()
                    .fill(theme.isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.05))
                    .frame(width: 15)
                VStack(alignment: .leading, spacing: 4) {
                    Capsule().fill(theme.textSecondary.opacity(0.55)).frame(width: 28, height: 4)
                    Capsule().fill(theme.textTertiary.opacity(0.5)).frame(width: 18, height: 4)
                }
                .padding(7)
                Spacer(minLength: 0)
            }
            HStack {
                Spacer()
                Circle().fill(theme.accent).frame(width: 7, height: 7)
            }
            .padding(7)
        }
        .frame(maxWidth: .infinity)
        .clipShape(shape)
        .overlay(shape.strokeBorder(
            selected ? AppStyle.accent : AppStyle.separator.opacity(0.7),
            lineWidth: selected ? 2 : 1))
        .overlay(alignment: .bottomTrailing) {
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white, AppStyle.accent)
                    .padding(4)
            }
        }
        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
    }
}

private struct ConfiguredAgentRow: View {
    let agent: AIAgentConfig
    @Binding var isEnabled: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(AppStyle.textPrimary)
                Text(agent.command)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(AppStyle.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            ThemedToggle(isOn: $isEnabled)
            IconOnlyButton(
                systemName: "trash",
                help: L("删除"),
                size: 26,
                symbolSize: 11.5,
                tint: AppStyle.textTertiary,
                action: onDelete)
        }
        .padding(.horizontal, 2)
        .frame(height: 46)
    }
}

private struct SettingsRailButton: View {
    let section: SettingsSectionID
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 12.5, weight: .semibold))
                    .frame(width: 17)
                VStack(alignment: .leading, spacing: 1) {
                    Text(section.title)
                        .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                    Text(section.subtitle)
                        .font(.system(size: 9.5, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(AppStyle.textTertiary)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? AppStyle.textPrimary : AppStyle.textSecondary)
            .padding(.horizontal, 9)
            .frame(height: 42)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .fill(selected ? AppStyle.activeFill.opacity(0.78) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct GhosttyMappedConfigRow: View {
    let title: String
    let summary: String
    var keys: [String] = []
    var first = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(AppStyle.textPrimary)
            Text(summary)
                .font(.system(size: 11.5))
                .foregroundStyle(AppStyle.textSecondary)
                .lineLimit(2)
        }
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(keys.isEmpty ? "" : keys.joined(separator: ", "))
    }
}

private struct GhosttyConfigGroupHeader: View {
    let group: ConductorGhosttyConfigGroup
    var first = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: group.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppStyle.accent)
                .frame(width: 18, height: 22)
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(group.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(AppStyle.textPrimary)
                    Spacer(minLength: 8)
                    Text(group.countTitle)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(AppStyle.textTertiary)
                }
                Text(group.subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(AppStyle.textSecondary)
                    .lineLimit(2)
            }
        }
        .padding(.top, 2)
        .padding(.bottom, 6)
    }
}

private struct GhosttyOverrideRow: View {
    let key: String
    let value: String
    let setValue: (String) -> Void
    let reset: () -> Void

    private var isOverridden: Bool { !value.isEmpty }
    private var copy: ConductorGhosttyConfigCopy { ConductorGhosttyConfigCatalog.copy(for: key) }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(copy.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(AppStyle.textPrimary)
                Text(copy.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(AppStyle.textSecondary)
                    .lineLimit(2)
                Text(isOverridden ? L("已自定义") : L("使用默认值"))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(isOverridden ? AppStyle.accent : AppStyle.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 10)
            control
            IconOnlyButton(
                systemName: "arrow.uturn.backward",
                help: L("恢复默认"),
                size: 24,
                symbolSize: 10.5,
                weight: .bold,
                tint: isOverridden ? AppStyle.textSecondary : AppStyle.textTertiary,
                action: reset)
            .disabled(!isOverridden)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minHeight: 58)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isOverridden ? AppStyle.activeFill.opacity(0.22) : Color.clear)
        )
        .help(key)
    }

    @ViewBuilder
    private var control: some View {
        switch ConductorGhosttyConfigCatalog.controlKind(for: key) {
        case .boolean:
            ThemedSegmented(
                options: [(L("默认"), ""), (L("开"), "true"), (L("关"), "false")],
                selection: Binding(get: { value }, set: setValue)
            )
        case let .choice(options):
            Picker("", selection: Binding(get: { value }, set: setValue)) {
                Text(L("默认")).tag("")
                ForEach(options, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .labelsHidden()
            .frame(width: 136)
        case .color:
            GhosttyColorControl(value: value, setValue: setValue)
        case .filePath:
            GhosttyPathControl(key: key, value: value, setValue: setValue)
        case .fontFamily:
            Picker("", selection: Binding(get: { value }, set: setValue)) {
                Text(L("默认")).tag("")
                ForEach(SystemFonts.monospaced, id: \.self) { family in
                    Text(family).tag(family)
                }
            }
            .labelsHidden()
            .frame(width: 150)
        case let .integer(range, step):
            GhosttyIntegerControl(value: value, range: range, step: step, setValue: setValue)
        case let .percent(range, defaultValue, format):
            GhosttyPercentControl(value: value, range: range, defaultValue: defaultValue, format: format, setValue: setValue)
        case let .decimal(range, defaultValue, step):
            GhosttyDecimalControl(value: value, range: range, defaultValue: defaultValue, step: step, setValue: setValue)
        case .text:
            GhosttyFreeTextControl(value: value, setValue: setValue)
        }
    }
}

private struct GhosttyFreeTextControl: View {
    let value: String
    let setValue: (String) -> Void
    @State private var isEditing = false
    @FocusState private var focused: Bool

    private var showsEditor: Bool { isEditing || !value.isEmpty }

    var body: some View {
        if showsEditor {
            ThemedTextField(
                placeholder: L("输入自定义值"),
                text: Binding(get: { value }, set: setValue)
            )
            .focused($focused)
            .frame(width: 172)
            .onAppear {
                guard isEditing else { return }
                DispatchQueue.main.async { focused = true }
            }
        } else {
            HStack(spacing: 8) {
                Text(L("默认"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppStyle.textTertiary)
                    .frame(width: 48, alignment: .trailing)
                IconOnlyButton(
                    systemName: "pencil",
                    help: L("添加自定义值"),
                    size: 28,
                    symbolSize: 11.5,
                    weight: .semibold) {
                        isEditing = true
                    }
            }
        }
    }
}

private struct GhosttyIntegerControl: View {
    let value: String
    let range: ClosedRange<Int>
    let step: Int
    let setValue: (String) -> Void

    private var binding: Binding<Int> {
        Binding(
            get: { Int(value) ?? range.lowerBound },
            set: { newValue in setValue(String(min(max(newValue, range.lowerBound), range.upperBound))) }
        )
    }

    var body: some View {
        ThemedStepper(value: binding, range: range, step: step)
    }
}

private struct GhosttyDecimalControl: View {
    let value: String
    let range: ClosedRange<Double>
    let defaultValue: Double
    let step: Double
    let setValue: (String) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Slider(
                value: Binding(
                    get: { Double(value) ?? defaultValue },
                    set: { setValue(Self.formatted($0, step: step)) }
                ),
                in: range,
                step: step
            )
            .frame(width: 118)
            Text(Self.formatted(Double(value) ?? defaultValue, step: step))
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(AppStyle.accent)
                .frame(width: 38, alignment: .trailing)
        }
    }

    private static func formatted(_ value: Double, step: Double) -> String {
        step < 1 ? String(format: "%.1f", value) : String(format: "%.0f", value)
    }
}

private struct GhosttyPercentControl: View {
    let value: String
    let range: ClosedRange<Double>
    let defaultValue: Double
    let format: ConductorGhosttyPercentFormat
    let setValue: (String) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Slider(
                value: Binding(
                    get: { parse(value) ?? defaultValue },
                    set: { setValue(serialize($0)) }
                ),
                in: range
            )
            .frame(width: 124)
            Text(display(parse(value) ?? defaultValue))
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(AppStyle.accent)
                .frame(width: 46, alignment: .trailing)
        }
    }

    private func parse(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasSuffix("%") {
            return Double(trimmed.dropLast())
        }
        return Double(trimmed)
    }

    private func serialize(_ value: Double) -> String {
        switch format {
        case .fraction:
            return String(format: "%.2f", value)
        case .percentString:
            return "\(Int(value.rounded()))%"
        }
    }

    private func display(_ value: Double) -> String {
        switch format {
        case .fraction:
            return "\(Int((value * 100).rounded()))%"
        case .percentString:
            return "\(Int(value.rounded()))%"
        }
    }
}

private struct GhosttyColorControl: View {
    let value: String
    let setValue: (String) -> Void

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: value) ?? Color.white },
            set: { setValue($0.hexString) }
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            ColorPicker("", selection: colorBinding)
                .labelsHidden()
                .frame(width: 36)
            Text(value.isEmpty ? L("默认") : "#\(value.trimmingCharacters(in: CharacterSet(charactersIn: "#")))")
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(value.isEmpty ? AppStyle.textTertiary : AppStyle.accent)
                .frame(width: 74, alignment: .leading)
        }
    }
}

private struct GhosttyPathControl: View {
    let key: String
    let value: String
    let setValue: (String) -> Void

    private var isImagePicker: Bool { key == "background-image" }

    var body: some View {
        Button(action: choosePath) {
            HStack(spacing: 6) {
                Image(systemName: isImagePicker ? "photo" : "folder")
                    .font(.system(size: 11.5, weight: .semibold))
                Text(value.isEmpty ? L("选择") : URL(fileURLWithPath: value).lastPathComponent)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(value.isEmpty ? AppStyle.textSecondary : AppStyle.accent)
            .frame(width: 142, height: 28)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .fill(AppStyle.hoverFill.opacity(0.76))
            )
        }
        .buttonStyle(PressScaleStyle())
    }

    private func choosePath() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = !isImagePicker
        panel.canChooseFiles = isImagePicker
        if isImagePicker {
            panel.allowedContentTypes = [.png, .jpeg]
        }
        panel.prompt = isImagePicker ? L("选择图片") : L("选择目录")
        if panel.runModal() == .OK, let url = panel.url, isUsableSelection(url) {
            setValue(url.path)
        }
    }

    private func isUsableSelection(_ url: URL) -> Bool {
        guard isImagePicker else { return true }
        return ["png", "jpg", "jpeg"].contains(url.pathExtension.lowercased())
    }
}
