import AppKit
import ConductorCore
import SwiftUI

struct UsageProvidersSettingsView: View {
    let providers: [UsageProviderEntry]
    let tools: [CLIToolStatus]
    let states: [String: ToolUsageState]
    @Binding var selectedID: String?
    let onApplyConfig: (AppConfig) -> Void
    let onReload: (UsageProviderEntry) -> Void

    @ObservedObject private var configStore = ConfigStore.shared
    @State private var query = ""

    private var selectedProvider: UsageProviderEntry? {
        guard let selectedID else { return nil }
        return providers.first { $0.id == selectedID }
    }

    private var filteredProviders: [UsageProviderEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return providers }
        return providers.filter { provider in
            let profile = UsageProviderProfile.catalog(for: provider)
            return provider.name.lowercased().contains(trimmed)
                || provider.id.lowercased().contains(trimmed)
                || profile.category.lowercased().contains(trimmed)
                || profile.credentialKind.lowercased().contains(trimmed)
        }
    }

    var body: some View {
        Group {
            if let provider = selectedProvider {
                ProviderSettingsDetailView(
                    provider: provider,
                    tool: tools.first { $0.id == provider.id },
                    state: states[provider.id],
                    onBack: { withAnimation(Motion.panel) { selectedID = nil } },
                    onApplyConfig: onApplyConfig,
                    onReload: { onReload(provider) })
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)))
            } else {
                providerList
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)))
            }
        }
        .animation(Motion.panel, value: selectedID)
    }

    private var providerList: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            header
            searchField
            ProviderStatusStrip(providers: providers, states: states)
            VStack(alignment: .leading, spacing: Space.xs) {
                ForEach(filteredProviders) { provider in
                    ProviderSettingsListRow(
                        provider: provider,
                        tool: tools.first { $0.id == provider.id },
                        state: states[provider.id],
                        enabled: enabledBinding(for: provider),
                        onOpen: { withAnimation(Motion.panel) { selectedID = provider.id } },
                        onReload: { onReload(provider) })
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(AppStyle.accent)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(AppStyle.accent.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(L("渠道配置"))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(AppStyle.textPrimary)
                Text(L("选择账号渠道，查看状态、来源和凭证。"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(AppStyle.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppStyle.textTertiary)
            TextField(L("搜索渠道 / 来源 / 凭证"), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(AppStyle.textPrimary)
            if !query.isEmpty {
                IconOnlyButton(
                    systemName: "xmark.circle.fill",
                    help: L("清空搜索"),
                    size: 20,
                    symbolSize: 10,
                    tint: AppStyle.textTertiary) {
                        withAnimation(Motion.snappy) { query = "" }
                    }
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(AppStyle.hoverFill))
    }

    private func enabledBinding(for provider: UsageProviderEntry) -> Binding<Bool> {
        Binding(
            get: { configStore.config.usage.providers[provider.id]?.enabled ?? true },
            set: { enabled in
                var config = configStore.config
                var providerConfig = config.usage.providers[provider.id] ?? UsageProviderConfig()
                providerConfig.enabled = enabled
                config.usage.providers[provider.id] = providerConfig
                onApplyConfig(config)
            })
    }
}

private struct ProviderStatusStrip: View {
    let providers: [UsageProviderEntry]
    let states: [String: ToolUsageState]
    @ObservedObject private var configStore = ConfigStore.shared

    private var enabledCount: Int {
        providers.filter { configStore.config.usage.providers[$0.id]?.enabled ?? true }.count
    }

    private var readyCount: Int {
        providers.filter {
            if case .loaded = states[$0.id] { return true }
            return false
        }.count
    }

    private var manualCount: Int {
        providers.filter {
            if case .manual = states[$0.id] { return true }
            return false
        }.count
    }

    private var errorCount: Int {
        providers.filter {
            if case .error = states[$0.id] { return true }
            return false
        }.count
    }

    private var setupCount: Int {
        providers.filter {
            if case .unconfigured = states[$0.id] { return true }
            return false
        }.count
    }

    var body: some View {
        HStack(spacing: 7) {
            metric(L("全部"), "\(providers.count)", icon: "square.grid.2x2", color: AppStyle.textSecondary)
            metric(L("启用"), "\(enabledCount)", icon: "power", color: AppStyle.accent)
            metric(L("已取数"), "\(readyCount)", icon: "chart.bar.fill", color: AppStyle.doneGreen)
            metric(L("待刷新"), "\(manualCount)", icon: "arrow.clockwise", color: AppStyle.accent)
            metric(L("待配置"), "\(setupCount)", icon: "key", color: AppStyle.waitAmber)
            if errorCount > 0 {
                metric(L("错误"), "\(errorCount)", icon: "exclamationmark.triangle.fill", color: AppStyle.errorRed)
            }
            Spacer(minLength: 0)
        }
    }

    private func metric(_ title: String, _ value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 12.5, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .monospacedDigit()
            Text(title)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(AppStyle.textTertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(
            Capsule()
                .fill(AppStyle.hoverFill.opacity(0.72)))
    }
}

private struct ProviderSettingsListRow: View {
    let provider: UsageProviderEntry
    let tool: CLIToolStatus?
    let state: ToolUsageState?
    @Binding var enabled: Bool
    let onOpen: () -> Void
    let onReload: () -> Void

    @ObservedObject private var configStore = ConfigStore.shared
    @State private var hovering = false

    private var profile: UsageProviderProfile { UsageProviderProfile.catalog(for: provider) }
    private var status: ProviderStatusPresentation { ProviderStatusPresentation(state: state, enabled: enabled) }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        ProviderBrandIcon(provider: provider)
                            .frame(width: 22, height: 22)
                            .frame(width: 38, height: 38)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(status.color.opacity(status.isStrong ? 0.17 : 0.10)))
                            .overlay(alignment: .bottomTrailing) {
                                Circle()
                                    .fill(enabled ? status.color : AppStyle.textTertiary)
                                    .frame(width: 7, height: 7)
                                    .overlay(Circle().stroke(AppStyle.windowBackground, lineWidth: 1.4))
                                    .offset(x: 1, y: 1)
                            }
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(provider.name)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(AppStyle.textPrimary)
                                    .lineLimit(1)
                                ProviderStatusPill(label: status.label, color: status.color)
                            }
                            Text(rowSubtitle)
                                .font(.system(size: 10))
                                .foregroundStyle(AppStyle.textTertiary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        ProviderMiniUsage(state: state)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(AppStyle.textTertiary)
                    }
                    HStack(spacing: 5) {
                        ProviderMetaChip(icon: "tag", text: profile.category)
                        ProviderMetaChip(icon: "point.3.connected.trianglepath.dotted", text: sourceLabel)
                        ProviderMetaChip(icon: "key", text: profile.credentialKind)
                        if let version = tool?.version {
                            ProviderMetaChip(icon: "number", text: version, monospaced: true)
                        } else if tool?.isInstalled == false {
                            ProviderMetaChip(icon: "terminal", text: L("CLI 未检测到"))
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            ThemedToggle(isOn: $enabled)
                .scaleEffect(0.78)
                .frame(width: 34)
                .help(enabled ? L("停用") : L("启用"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hovering ? AppStyle.hoverFill : AppStyle.theme.isDark ? Color.white.opacity(0.035) : Color.black.opacity(0.025)))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(hovering ? AppStyle.accent.opacity(0.18) : Color.clear, lineWidth: 1))
        .onHover { inside in
            withAnimation(Motion.hover) { hovering = inside }
        }
        .contextMenu {
            Button(L("打开详情")) { onOpen() }
            Button(L("刷新用量")) { onReload() }
            Button(L("复制渠道 ID")) { copy(provider.id) }
            if let path = tool?.path {
                Button(L("复制路径")) { copy(path) }
                Button(L("在 Finder 中显示")) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            }
            Divider()
            Button(enabled ? L("停用渠道") : L("启用渠道")) {
                enabled.toggle()
            }
        }
    }

    private var sourceLabel: String {
        let config = configStore.config.usage.providers[provider.id]
        let selected = config?.sourceMode ?? profile.sourceOptions.first?.id ?? "auto"
        return profile.sourceOptions.first { $0.id == selected }?.title ?? selected
    }

    private var rowSubtitle: String {
        let kind = profile.credentialKind
        switch state {
        case let .loaded(snapshot):
            if let account = snapshot.accountLabel, !account.isEmpty { return account }
            if let plan = snapshot.planName, !plan.isEmpty { return "\(kind) · \(plan)" }
            return "\(profile.category) · \(kind)"
        case let .error(message):
            return message
        case .loading:
            return L("刷新中")
        case .manual:
            return L("已配置，等待手动刷新")
        case .unconfigured:
            return profile.setupHint
        case .unsupported:
            return L("暂不支持用量")
        case .none:
            return profile.subtitle
        }
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

private struct ProviderStatusPill: View {
    let label: String
    let color: Color

    var body: some View {
        ToolBadge(text: label, color: color, height: 18)
    }
}

private struct ProviderMetaChip: View {
    let icon: String
    let text: String
    var monospaced = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(AppStyle.textTertiary)
            Text(text)
                .font(.system(size: 9.5, weight: .medium, design: monospaced ? .monospaced : .default))
                .foregroundStyle(AppStyle.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 6)
        .frame(height: 20)
        .background(Capsule().fill(AppStyle.hoverFill.opacity(0.82)))
    }
}

private struct ProviderSettingsDetailView: View {
    let provider: UsageProviderEntry
    let tool: CLIToolStatus?
    let state: ToolUsageState?
    let onBack: () -> Void
    let onApplyConfig: (AppConfig) -> Void
    let onReload: () -> Void

    @ObservedObject private var configStore = ConfigStore.shared
    @ObservedObject private var history = UsageHistoryStore.shared

    private var profile: UsageProviderProfile { UsageProviderProfile.catalog(for: provider) }
    private var status: ProviderStatusPresentation {
        ProviderStatusPresentation(state: state, enabled: enabled.wrappedValue)
    }
    private var providerConfig: UsageProviderConfig {
        configStore.config.usage.providers[provider.id] ?? UsageProviderConfig()
    }
    private var enabled: Binding<Bool> {
        Binding(
            get: { providerConfig.enabled ?? true },
            set: { enabled in
                writeConfig { $0.enabled = enabled }
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            compactDetailPanel
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                IconOnlyButton(
                    systemName: "chevron.left",
                    help: L("返回渠道列表"),
                    size: 28,
                    symbolSize: 11,
                    tint: AppStyle.textSecondary,
                    action: onBack)
                Spacer()
                IconOnlyButton(
                    systemName: "arrow.clockwise",
                    help: L("刷新用量"),
                    size: 28,
                    symbolSize: 11,
                    tint: AppStyle.textSecondary,
                    action: onReload)
                ThemedToggle(isOn: enabled)
                    .scaleEffect(0.86)
                    .frame(width: 38)
                    .help(enabled.wrappedValue ? L("停用渠道") : L("启用渠道"))
            }

            HStack(alignment: .center, spacing: 12) {
                ProviderBrandIcon(provider: provider)
                    .frame(width: 31, height: 31)
                    .frame(width: 48, height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(AppStyle.accent.opacity(0.12)))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(provider.name)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(AppStyle.textPrimary)
                            .lineLimit(1)
                        statusPill
                    }
                    Text(profile.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(AppStyle.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    detailMetaChips
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var detailMetaChips: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                ProviderMetaChip(icon: "point.3.connected.trianglepath.dotted", text: sourceLabel)
                ProviderMetaChip(icon: "key", text: profile.credentialKind)
            }
            HStack(spacing: 5) {
                ProviderMetaChip(icon: "terminal", text: tool?.version ?? L("CLI 未检测到"), monospaced: tool?.version != nil)
                ProviderMetaChip(icon: "clock", text: updatedLabel)
            }
        }
        .padding(.top, 4)
    }

    private var statusPill: some View {
        let status = ProviderStatusPresentation(state: state, enabled: enabled.wrappedValue)
        return ProviderStatusPill(label: status.label, color: status.color)
    }

    private var compactDetailPanel: some View {
        VStack(spacing: 0) {
            ProviderDetailSubsection(title: L("概览"), icon: "info.circle") {
                VStack(spacing: 0) {
                    ProviderKeyValueRow(label: L("状态"), value: enabled.wrappedValue ? L("已启用") : L("已停用"), valueColor: status.color)
                    ProviderKeyValueRow(label: L("认证"), value: authLabel, valueColor: status.color)
                    ProviderKeyValueRow(label: L("渠道 ID"), value: provider.id, monospaced: true)
                    ProviderKeyValueRow(label: L("类别"), value: profile.category)
                    ProviderKeyValueRow(label: L("凭证"), value: profile.credentialKind)
                    ProviderKeyValueRow(label: L("来源"), value: sourceLabel)
                    ProviderKeyValueRow(label: L("更新"), value: updatedLabel)
                    ProviderKeyValueRow(label: L("历史样本"), value: "\(history.samples(for: provider.id).count)", monospaced: true)
                    if let account = loadedSnapshot?.accountLabel, !account.isEmpty {
                        ProviderKeyValueRow(label: L("账号"), value: account)
                    }
                    if let plan = loadedSnapshot?.planName, !plan.isEmpty {
                        ProviderKeyValueRow(label: L("套餐"), value: plan)
                    }
                    ProviderKeyValueRow(label: L("CLI 版本"), value: tool?.version ?? L("未检测到"), monospaced: tool?.version != nil)
                    ProviderKeyValueRow(label: L("CLI 路径"), value: tool?.path ?? L("未检测到位置"), monospaced: tool?.path != nil)
                }
            }

            if shouldShowSetupHint {
                ProviderPanelDivider()
                ProviderDetailSubsection(title: L("处理"), icon: "exclamationmark.triangle") {
                    ProviderInlineNotice(icon: "key.fill", text: profile.setupHint, color: status.color)
                }
            }

            ProviderPanelDivider()
            ProviderDetailSubsection(title: L("用量"), icon: "chart.bar.xaxis") {
                usageSummary
            }

            ProviderPanelDivider()
            ProviderDetailSubsection(title: L("配置"), icon: "slider.horizontal.3") {
                VStack(alignment: .leading, spacing: 12) {
                    ProviderKeyValueRow(label: L("说明"), value: profile.credentialHint)
                    configurationControls
                }
            }

            if !profile.toggles.isEmpty {
                ProviderPanelDivider()
                ProviderDetailSubsection(title: L("选项"), icon: "switch.2") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(profile.toggles) { toggle in
                            ProviderToggleRow(toggle: toggle, isOn: flagBinding(toggle.key, defaultValue: toggle.defaultValue))
                        }
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .toolsCard(cornerRadius: 10)
    }

    @ViewBuilder
    private var usageSummary: some View {
        switch state {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("正在刷新用量…"))
                    .font(.system(size: 11))
                    .foregroundStyle(AppStyle.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .manual:
            ProviderInlineNotice(
                icon: "hand.tap",
                text: L("不会自动请求账号；点击右上角刷新获取用量。"),
                color: AppStyle.accent)
        case .unconfigured:
            ProviderInlineNotice(icon: "key.fill", text: profile.setupHint, color: AppStyle.waitAmber)
        case let .error(message):
            VStack(alignment: .leading, spacing: 8) {
                ProviderInlineNotice(icon: "exclamationmark.triangle.fill", text: message, color: AppStyle.errorRed)
                ToolActionButton(
                    title: L("重试"),
                    systemImage: "arrow.clockwise",
                    role: .secondary,
                    height: 26,
                    fontSize: 11,
                    horizontalPadding: 10,
                    action: onReload)
            }
        case let .loaded(snapshot):
            ProviderUsageCompactDetail(snapshot: snapshot, samples: history.samples(for: provider.id))
        case .unsupported, .none:
            ProviderInlineNotice(icon: "chart.bar.xaxis", text: L("暂无用量数据"), color: AppStyle.textTertiary)
        }
    }

    @ViewBuilder
    private var configurationControls: some View {
        VStack(alignment: .leading, spacing: 12) {
                if !profile.sourceOptions.isEmpty {
                    ProviderPickerRow(
                        title: L("来源"),
                        subtitle: profile.sourceSubtitle,
                        selection: stringBinding(.sourceMode, fallback: profile.sourceOptions.first?.id ?? "auto"),
                        options: profile.sourceOptions)
                }
                if !profile.cookieOptions.isEmpty {
                    ProviderPickerRow(
                        title: "Cookie",
                        subtitle: profile.cookieSubtitle,
                        selection: stringBinding(.cookieSource, fallback: profile.cookieOptions.first?.id ?? "auto"),
                        options: profile.cookieOptions)
                }
                ForEach(profile.fields) { field in
                    ProviderTextFieldRow(
                        field: field,
                        text: stringBinding(field.key, fallback: ""),
                        onSubmit: onReload)
                }
                if profile.fields.isEmpty, profile.sourceOptions.isEmpty, profile.cookieOptions.isEmpty {
                    Text(profile.credentialHint)
                        .font(.system(size: 11))
                        .foregroundStyle(AppStyle.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !profile.actions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(profile.actions) { action in
                            ToolActionButton(
                                title: action.title,
                                systemImage: action.systemImage,
                                role: .secondary,
                                height: 26,
                                fontSize: 11,
                                horizontalPadding: 10,
                                help: action.help,
                                action: action.perform)
                        }
                    }
                }
            }
    }

    private var loadedSnapshot: UsageSnapshot? {
        if case let .loaded(snapshot) = state { return snapshot }
        return nil
    }

    private var sourceLabel: String {
        let selected = providerConfig.sourceMode ?? profile.sourceOptions.first?.id ?? "auto"
        return profile.sourceOptions.first { $0.id == selected }?.title ?? selected
    }

    private var authLabel: String {
        guard enabled.wrappedValue else { return L("已停用") }
        switch state {
        case .loaded: return L("就绪")
        case .loading: return L("检查中")
        case .manual: return L("待刷新")
        case .unconfigured: return L("待配置")
        case .error: return L("错误")
        case .unsupported: return L("不支持")
        case .none: return L("未知")
        }
    }

    private var updatedLabel: String {
        guard let snapshot = loadedSnapshot else {
            if case .manual = state { return L("待刷新") }
            if case .loading = state { return L("刷新中") }
            return L("未获取")
        }
        return UsageFormatting.agoText(snapshot.updatedAt)
    }

    private var shouldShowSetupHint: Bool {
        if case .unconfigured = state { return true }
        if case .error = state { return true }
        return false
    }

    private func stringBinding(_ key: ProviderStringConfigKey, fallback: String) -> Binding<String> {
        Binding(
            get: { stringValue(for: key) ?? fallback },
            set: { raw in
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                writeConfig { config in
                    setString(trimmed.isEmpty ? nil : trimmed, for: key, in: &config)
                }
            })
    }

    private func flagBinding(_ key: String, defaultValue: Bool) -> Binding<Bool> {
        Binding(
            get: { providerConfig.flags[key] ?? defaultValue },
            set: { value in
                writeConfig { config in
                    config.flags[key] = value
                }
            })
    }

    private func stringValue(for key: ProviderStringConfigKey) -> String? {
        switch key {
        case .apiKey: return providerConfig.apiKey
        case .sourceMode: return providerConfig.sourceMode
        case .cookieSource: return providerConfig.cookieSource
        case .cookieHeader: return providerConfig.cookieHeader
        case .projectID: return providerConfig.projectID
        case .baseURL: return providerConfig.baseURL
        case .organizationID: return providerConfig.organizationID
        case let .extra(extraKey): return providerConfig.extra[extraKey]
        }
    }

    private func setString(_ value: String?, for key: ProviderStringConfigKey, in config: inout UsageProviderConfig) {
        switch key {
        case .apiKey: config.apiKey = value
        case .sourceMode: config.sourceMode = value
        case .cookieSource: config.cookieSource = value
        case .cookieHeader: config.cookieHeader = value
        case .projectID: config.projectID = value
        case .baseURL: config.baseURL = value
        case .organizationID: config.organizationID = value
        case let .extra(extraKey):
            if let value { config.extra[extraKey] = value } else { config.extra.removeValue(forKey: extraKey) }
        }
    }

    private func writeConfig(_ mutate: (inout UsageProviderConfig) -> Void) {
        var config = configStore.config
        var providerConfig = config.usage.providers[provider.id] ?? UsageProviderConfig()
        mutate(&providerConfig)
        config.usage.providers[provider.id] = providerConfig
        onApplyConfig(config)
    }
}

private struct ProviderBrandIcon: View {
    let provider: UsageProviderEntry

    var body: some View {
        let logoName = provider.logoName
        if let image = CLIToolLogo.image(named: logoName) {
            if CLIToolLogo.isMonochrome(logoName) {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.template)
                    .interpolation(.high)
                    .scaledToFit()
                    .foregroundStyle(AppStyle.textPrimary)
            } else {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            }
        } else {
            Image(systemName: provider.fallbackSystemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppStyle.accent)
        }
    }
}

private struct ProviderMiniUsage: View {
    let state: ToolUsageState?

    var body: some View {
        switch state {
        case let .loaded(snapshot):
            if let text = compactSummary(snapshot) {
                ToolBadge(text: text, color: AppStyle.textSecondary, style: .muted, height: 20)
            }
        case .loading:
            ProgressView().controlSize(.small).scaleEffect(0.65)
        case .manual:
            ToolBadge(text: L("手动"), color: AppStyle.accent, height: 18)
        case .unconfigured:
            ToolBadge(text: L("配置"), color: AppStyle.waitAmber, height: 18)
        case .error:
            ToolBadge(text: L("失败"), color: AppStyle.errorRed, height: 18)
        case .unsupported, .none:
            EmptyView()
        }
    }

    private func compactSummary(_ snapshot: UsageSnapshot) -> String? {
        if let window = snapshot.primary ?? snapshot.secondary ?? snapshot.tertiary {
            return L("剩 %ld%%", Int(window.remainingPercent.rounded()))
        }
        if let cost = snapshot.providerCost {
            return CostLine.shortText(cost)
        }
        return nil
    }
}

private struct ProviderDetailSubsection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(AppStyle.accent)
                    .frame(width: 14)
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(AppStyle.textPrimary)
                Spacer(minLength: 0)
            }
            content
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProviderPanelDivider: View {
    var body: some View {
        Rectangle()
            .fill(AppStyle.separator.opacity(0.55))
            .frame(height: 1)
            .padding(.horizontal, 12)
    }
}

private struct ProviderKeyValueRow: View {
    let label: String
    let value: String
    var monospaced = false
    var valueColor: Color?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(AppStyle.textTertiary)
                    .frame(width: 76, alignment: .leading)
                    .lineLimit(1)
                Text(value)
                    .font(.system(size: 11.2, weight: .semibold, design: monospaced ? .monospaced : .default))
                    .foregroundStyle(valueColor ?? AppStyle.textSecondary)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 6)
            Divider().opacity(0.42)
        }
    }
}

private struct ProviderInlineNotice: View {
    let icon: String
    let text: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 16)
            Text(text)
                .font(.system(size: 10.8))
                .foregroundStyle(AppStyle.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

private struct ProviderUsageCompactDetail: View {
    let snapshot: UsageSnapshot
    let samples: [UsageSample]

    var body: some View {
        if snapshot.isEmpty {
            ProviderInlineNotice(
                icon: "chart.bar.xaxis",
                text: L("已连接，但当前没有可展示的额度窗口。"),
                color: AppStyle.textTertiary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                VStack(spacing: 0) {
                    ProviderKeyValueRow(label: L("更新时间"), value: UsageFormatting.agoText(snapshot.updatedAt))
                    if let account = snapshot.accountLabel, !account.isEmpty {
                        ProviderKeyValueRow(label: L("账号"), value: account)
                    }
                    if let plan = snapshot.planName, !plan.isEmpty {
                        ProviderKeyValueRow(label: L("套餐"), value: plan)
                    }
                    ProviderKeyValueRow(label: L("额度窗口"), value: "\(snapshot.allWindows.count)", monospaced: true)
                    ProviderKeyValueRow(label: L("趋势样本"), value: "\(samples.count)", monospaced: true)
                }

                ForEach(Array(snapshot.allWindows.enumerated()), id: \.offset) { _, item in
                    ProviderUsageInlineBar(title: item.title, window: item.window)
                }

                if let cost = snapshot.providerCost {
                    ProviderCostInlineRow(cost: cost)
                }

                if samples.count >= 2 {
                    UsageTrendChart(samples: samples, compact: false)
                        .frame(height: 74)
                        .padding(.top, 2)
                }
            }
        }
    }
}

private struct ProviderUsageInlineBar: View {
    let title: String
    let window: RateWindow

    private var fraction: Double { max(0.02, min(1, window.usedPercent / 100.0)) }

    private var barColor: Color {
        switch window.usedPercent {
        case ..<70: return AppStyle.accent
        case 70..<90: return AppStyle.waitAmber
        default: return AppStyle.errorRed
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppStyle.textPrimary)
                        .lineLimit(1)
                    Text(detailLine)
                        .font(.system(size: 9.8))
                        .foregroundStyle(AppStyle.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(L("剩 %ld%% · 已用 %ld%%",
                       Int(window.remainingPercent.rounded()),
                       Int(window.usedPercent.rounded())))
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(AppStyle.textSecondary)
                    .lineLimit(1)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(AppStyle.subtleFill)
                    Capsule()
                        .fill(barColor)
                        .frame(width: geo.size.width * fraction)
                        .animation(Motion.snappy, value: fraction)
                }
            }
            .frame(height: 5)
        }
    }

    private var detailLine: String {
        var parts: [String] = []
        if let reset = window.resetsAt { parts.append(UsageFormatting.resetText(reset)) }
        else if let description = window.resetDescription, !description.isEmpty { parts.append(description) }
        else { parts.append(L("无固定重置")) }
        if let durationText { parts.append(durationText) }
        return parts.joined(separator: " · ")
    }

    private var durationText: String? {
        guard let minutes = window.windowMinutes, minutes > 0 else { return nil }
        if minutes % (60 * 24) == 0 { return L("窗口 %ld 天", minutes / (60 * 24)) }
        if minutes % 60 == 0 { return L("窗口 %ld 小时", minutes / 60) }
        return L("窗口 %ld 分钟", minutes)
    }
}

private struct ProviderCostInlineRow: View {
    let cost: ProviderCostSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "creditcard")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppStyle.textTertiary)
                    .frame(width: 14)
                Text(text)
                    .font(.system(size: 10.8, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(AppStyle.textPrimary)
                if let period = cost.period, !period.isEmpty {
                    Text(period)
                        .font(.system(size: 10))
                        .foregroundStyle(AppStyle.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            if cost.hasLimit {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(AppStyle.subtleFill)
                        Capsule()
                            .fill(cost.usedPercent >= 90 ? AppStyle.errorRed : cost.usedPercent >= 70 ? AppStyle.waitAmber : AppStyle.accent)
                            .frame(width: geo.size.width * max(0.02, min(1, cost.usedPercent / 100)))
                            .animation(Motion.snappy, value: cost.usedPercent)
                    }
                }
                .frame(height: 5)
            }
        }
    }

    private var text: String {
        if cost.hasLimit {
            return "\(CostLine.money(cost.used, cost.currencyCode)) / \(CostLine.money(cost.limit, cost.currencyCode))"
        }
        return L("余额 %@", CostLine.money(cost.used, cost.currencyCode))
    }
}

private struct ProviderDetailSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(AppStyle.accent)
                Text(title)
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(AppStyle.textPrimary)
                Spacer(minLength: 0)
            }
            content
        }
        .padding(Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .toolsCard(cornerRadius: 10)
    }
}

private struct ProviderInfoCell: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(AppStyle.textTertiary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppStyle.textSecondary)
                .lineLimit(2)
                .minimumScaleFactor(0.82)
        }
        .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
        .padding(.horizontal, 9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppStyle.hoverFill.opacity(0.7)))
    }
}

private struct ProviderSetupHintView: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppStyle.waitAmber)
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(AppStyle.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppStyle.waitAmber.opacity(0.10)))
    }
}

private struct ProviderErrorView: View {
    let message: String
    let onReload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.system(size: 10.5))
                .foregroundStyle(AppStyle.textSecondary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            ToolActionButton(
                title: L("重试"),
                systemImage: "arrow.clockwise",
                role: .secondary,
                height: 26,
                fontSize: 11,
                horizontalPadding: 10,
                action: onReload)
        }
    }
}

private struct ProviderCalloutView: View {
    let icon: String
    let title: String
    let message: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 24, height: 24)
                .background(Circle().fill(color.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(AppStyle.textPrimary)
                Text(message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(AppStyle.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(color.opacity(0.08)))
    }
}

private struct ProviderUsageDetail: View {
    let snapshot: UsageSnapshot
    let samples: [UsageSample]

    var body: some View {
        if snapshot.isEmpty {
            Text(L("已连接，但当前没有可展示的额度窗口。"))
                .font(.system(size: 11))
                .foregroundStyle(AppStyle.textTertiary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if hasIdentity {
                    HStack(spacing: 6) {
                        if let account = snapshot.accountLabel, !account.isEmpty {
                            ProviderMetaChip(icon: "person.crop.circle", text: account)
                        }
                        if let plan = snapshot.planName, !plan.isEmpty {
                            ProviderMetaChip(icon: "sparkle", text: plan)
                        }
                        Spacer(minLength: 0)
                    }
                }
                ForEach(Array(snapshot.allWindows.enumerated()), id: \.offset) { _, item in
                    ProviderUsageBar(title: item.title, window: item.window)
                }
                if let cost = snapshot.providerCost {
                    ProviderCostRow(cost: cost)
                }
                if samples.count >= 2 {
                    UsageTrendChart(samples: samples, compact: false)
                        .padding(.top, 2)
                }
            }
        }
    }

    private var hasIdentity: Bool {
        (snapshot.accountLabel?.isEmpty == false) || (snapshot.planName?.isEmpty == false)
    }
}

private struct ProviderUsageBar: View {
    let title: String
    let window: RateWindow

    private var fraction: Double { max(0.02, min(1, window.usedPercent / 100.0)) }

    private var barColor: Color {
        switch window.usedPercent {
        case ..<70: return AppStyle.accent
        case 70..<90: return AppStyle.waitAmber
        default: return AppStyle.errorRed
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppStyle.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(detailLine)
                            .font(.system(size: 9.5))
                            .foregroundStyle(AppStyle.textTertiary)
                            .lineLimit(1)
                        if let durationText {
                            Text(durationText)
                                .font(.system(size: 9.5))
                                .foregroundStyle(AppStyle.textTertiary)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(L("剩 %ld%%", Int(window.remainingPercent.rounded())))
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(AppStyle.textPrimary)
                    Text(L("已用 %ld%%", Int(window.usedPercent.rounded())))
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(AppStyle.textTertiary)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(AppStyle.subtleFill)
                    Capsule()
                        .fill(barColor)
                        .frame(width: geo.size.width * fraction)
                        .animation(Motion.snappy, value: fraction)
                }
            }
            .frame(height: 6)
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(AppStyle.hoverFill.opacity(0.56)))
    }

    private var detailLine: String {
        if let reset = window.resetsAt { return UsageFormatting.resetText(reset) }
        if let description = window.resetDescription, !description.isEmpty { return description }
        return L("无固定重置")
    }

    private var durationText: String? {
        guard let minutes = window.windowMinutes, minutes > 0 else { return nil }
        if minutes % (60 * 24) == 0 { return L("窗口 %ld 天", minutes / (60 * 24)) }
        if minutes % 60 == 0 { return L("窗口 %ld 小时", minutes / 60) }
        return L("窗口 %ld 分钟", minutes)
    }
}

private struct ProviderCostRow: View {
    let cost: ProviderCostSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "creditcard")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppStyle.textTertiary)
                Text(text)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(AppStyle.textPrimary)
                Spacer(minLength: 6)
                if let period = cost.period, !period.isEmpty {
                    Text(period)
                        .font(.system(size: 10))
                        .foregroundStyle(AppStyle.textTertiary)
                        .lineLimit(1)
                }
            }
            if cost.hasLimit {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(AppStyle.subtleFill)
                        Capsule()
                            .fill(cost.usedPercent >= 90 ? AppStyle.errorRed : cost.usedPercent >= 70 ? AppStyle.waitAmber : AppStyle.accent)
                            .frame(width: geo.size.width * max(0.02, min(1, cost.usedPercent / 100)))
                            .animation(Motion.snappy, value: cost.usedPercent)
                    }
                }
                .frame(height: 5)
            }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(AppStyle.hoverFill.opacity(0.56)))
    }

    private var text: String {
        if cost.hasLimit {
            return "\(CostLine.money(cost.used, cost.currencyCode)) / \(CostLine.money(cost.limit, cost.currencyCode))"
        }
        return L("余额 %@", CostLine.money(cost.used, cost.currencyCode))
    }
}

private struct ProviderPickerRow: View {
    let title: String
    let subtitle: String
    @Binding var selection: String
    let options: [ProviderOption]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(AppStyle.textPrimary)
                    .frame(width: 68, alignment: .leading)
                Picker("", selection: $selection) {
                    ForEach(options) { option in
                        Text(option.title).tag(option.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                Spacer(minLength: 0)
            }
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(AppStyle.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ProviderTextFieldRow: View {
    let field: ProviderFieldDescriptor
    @Binding var text: String
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(field.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(AppStyle.textPrimary)
                    if !field.subtitle.isEmpty {
                        Text(field.subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(AppStyle.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Group {
                    switch field.kind {
                    case .plain:
                        TextField(field.placeholder, text: $text)
                    case .secure:
                        SecureField(field.placeholder, text: $text)
                    }
                }
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, design: field.kind == .secure ? .monospaced : .default))
                .foregroundStyle(AppStyle.textPrimary)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(AppStyle.hoverFill))
                .onSubmit(onSubmit)

                IconOnlyButton(
                    systemName: "doc.on.doc",
                    help: L("复制字段值"),
                    size: 30,
                    symbolSize: 11,
                    tint: AppStyle.textTertiary,
                    action: copyValue)
                    .disabled(text.isEmpty)

                IconOnlyButton(
                    systemName: "clipboard",
                    help: L("从剪贴板粘贴"),
                    size: 30,
                    symbolSize: 11,
                    tint: AppStyle.textTertiary,
                    action: pasteValue)
            }
            .contextMenu {
                Button(action: copyValue) {
                    Label(L("复制字段值"), systemImage: "doc.on.doc")
                }
                .disabled(text.isEmpty)

                Button(action: pasteValue) {
                    Label(L("从剪贴板粘贴"), systemImage: "clipboard")
                }
            }

            if let footer = field.footer, !footer.isEmpty {
                Text(footer)
                    .font(.system(size: 9.5))
                    .foregroundStyle(AppStyle.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func copyValue() {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func pasteValue() {
        guard let value = NSPasteboard.general.string(forType: .string) else { return }
        text = value
    }
}

private struct ProviderToggleRow: View {
    let toggle: ProviderToggleDescriptor
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(toggle.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(AppStyle.textPrimary)
                Text(toggle.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(AppStyle.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            ThemedToggle(isOn: $isOn)
                .scaleEffect(0.82)
                .frame(width: 36)
        }
    }
}

@MainActor
private struct ProviderStatusPresentation {
    let label: String
    let color: Color
    let isStrong: Bool

    init(state: ToolUsageState?, enabled: Bool) {
        guard enabled else {
            label = L("已停用")
            color = AppStyle.textTertiary
            isStrong = false
            return
        }
        switch state {
        case .loaded:
            label = L("就绪")
            color = AppStyle.doneGreen
            isStrong = true
        case .loading:
            label = L("检查中")
            color = AppStyle.accent
            isStrong = false
        case .manual:
            label = L("待刷新")
            color = AppStyle.accent
            isStrong = false
        case .unconfigured:
            label = L("待配置")
            color = AppStyle.waitAmber
            isStrong = true
        case .error:
            label = L("错误")
            color = AppStyle.errorRed
            isStrong = true
        case .unsupported:
            label = L("不支持")
            color = AppStyle.textTertiary
            isStrong = false
        case .none:
            label = L("未知")
            color = AppStyle.textTertiary
            isStrong = false
        }
    }
}

private struct UsageProviderProfile {
    let subtitle: String
    let category: String
    let credentialKind: String
    let credentialHint: String
    let setupHint: String
    let sourceSubtitle: String
    let cookieSubtitle: String
    let sourceOptions: [ProviderOption]
    let cookieOptions: [ProviderOption]
    let fields: [ProviderFieldDescriptor]
    let toggles: [ProviderToggleDescriptor]
    let actions: [ProviderActionDescriptor]

    static func catalog(for provider: UsageProviderEntry) -> UsageProviderProfile {
        let envVar = UsageCredentials.envVar[provider.id]
        let isCookie = cookieProviders.contains(provider.id)
        let isLocal = localCredentialProviders.contains(provider.id)
        let sourceOptions: [ProviderOption] = {
            switch provider.id {
            case "codex":
                return [
                    .init(id: "auto", title: L("自动")),
                    .init(id: "oauth", title: "OAuth"),
                    .init(id: "cli", title: "CLI"),
                    .init(id: "api", title: L("API 密钥")),
                ]
            case "claude":
                return [
                    .init(id: "auto", title: L("自动")),
                    .init(id: "oauth", title: "OAuth"),
                    .init(id: "keychain", title: L("系统登录")),
                    .init(id: "file", title: L("本机文件")),
                    .init(id: "api", title: L("管理 API")),
                ]
            case "amp":
                return [
                    .init(id: "auto", title: L("自动")),
                    .init(id: "api", title: L("API 令牌")),
                    .init(id: "browser", title: L("浏览器")),
                    .init(id: "cli", title: "CLI"),
                ]
            default:
                if envVar != nil, isCookie {
                    return [
                        .init(id: "auto", title: L("自动")),
                        .init(id: "api", title: L("API 密钥")),
                        .init(id: "browser", title: L("浏览器")),
                    ]
                }
                if envVar != nil {
                    return [
                        .init(id: "auto", title: L("自动")),
                        .init(id: "api", title: L("API 密钥")),
                    ]
                }
                if isCookie {
                    return [
                        .init(id: "auto", title: L("自动")),
                        .init(id: "browser", title: L("浏览器")),
                        .init(id: "manual", title: L("手动")),
                    ]
                }
                if isLocal {
                    return [
                        .init(id: "auto", title: L("自动")),
                .init(id: "file", title: L("本机文件")),
                .init(id: "cli", title: "CLI"),
            ]
                }
                return [.init(id: "auto", title: L("自动"))]
            }
        }()

        var fields: [ProviderFieldDescriptor] = []
        if let envVar {
            let title: String = provider.id == "openai" ? L("管理 / API 密钥") : L("API 密钥")
            let subtitle: String = provider.id == "openai"
                ? L("需要带 billing 权限；project key 可能无法读取额度。")
                : L("保存到本机配置，刷新时作为 %@ 使用。", envVar)
            fields.append(.init(
                key: .apiKey,
                title: title,
                subtitle: subtitle,
                placeholder: envVar,
                kind: .secure,
                footer: envVar))
        }

        if cookieProviders.contains(provider.id) || provider.id == "amp" {
            fields.append(.init(
                key: .cookieHeader,
                title: L("手动 Cookie"),
                subtitle: L("浏览器读取失败时，可临时粘贴 Cookie。"),
                placeholder: "name=value; ...",
                kind: .secure,
                footer: nil))
        }

        if ["openai", "azureopenai", "vertexai", "deepgram", "opencode", "opencodego"].contains(provider.id) {
            let title: String = switch provider.id {
            case "azureopenai": L("Deployment")
            case "deepgram": L("项目")
            case "opencode", "opencodego": "Workspace"
            default: L("项目")
            }
            let placeholder: String = switch provider.id {
            case "azureopenai": "deployment name"
            case "deepgram": "project id"
            case "opencode", "opencodego": "workspace id"
            default: "proj_..."
            }
            fields.append(.init(
                key: .projectID,
                title: title,
                subtitle: L("项目、deployment 或 workspace 标识。"),
                placeholder: placeholder,
                kind: .plain,
                footer: nil))
        }

        if ["glm", "openrouter", "kimi", "groq", "codebuff", "azureopenai", "llmproxy", "deepgram", "elevenlabs", "bedrock"].contains(provider.id) {
            fields.append(.init(
                key: .baseURL,
                title: L("基础 URL"),
                subtitle: L("自定义兼容端点。留空使用 provider 默认地址。"),
                placeholder: "https://...",
                kind: .plain,
                footer: nil))
        }

        if ["devin", "openai"].contains(provider.id) {
            fields.append(.init(
                key: .organizationID,
                title: L("组织"),
                subtitle: L("组织、workspace 或 account id。"),
                placeholder: "org / organization id",
                kind: .plain,
                footer: nil))
        }

        if provider.id == "azureopenai" {
            fields.append(.init(
                key: .extra("apiVersion"),
                title: L("API 版本"),
                subtitle: L("留空使用默认版本。"),
                placeholder: "2024-10-21",
                kind: .plain,
                footer: "AZURE_OPENAI_API_VERSION"))
        }

        if provider.id == "bedrock" {
            fields.append(contentsOf: [
                .init(
                    key: .extra("awsAccessKeyID"),
                    title: "Access Key",
                    subtitle: L("AWS_ACCESS_KEY_ID，用于 Cost Explorer 签名。"),
                    placeholder: "AKIA...",
                    kind: .plain,
                    footer: "AWS_ACCESS_KEY_ID"),
                .init(
                    key: .extra("awsSecretAccessKey"),
                    title: "Secret Key",
                    subtitle: L("AWS_SECRET_ACCESS_KEY。"),
                    placeholder: "secret",
                    kind: .secure,
                    footer: "AWS_SECRET_ACCESS_KEY"),
                .init(
                    key: .extra("awsSessionToken"),
                    title: "Session Token",
                    subtitle: L("临时凭证可选。"),
                    placeholder: "optional",
                    kind: .secure,
                    footer: "AWS_SESSION_TOKEN"),
                .init(
                    key: .extra("awsRegion"),
                    title: L("区域"),
                    subtitle: L("Cost Explorer 默认 us-east-1。"),
                    placeholder: "us-east-1",
                    kind: .plain,
                    footer: "AWS_REGION"),
                .init(
                    key: .extra("awsBudget"),
                    title: L("预算"),
                    subtitle: L("可选月度预算，用于计算百分比。"),
                    placeholder: "100",
                    kind: .plain,
                    footer: "CODEXBAR_BEDROCK_BUDGET"),
            ])
        }

        if provider.id == "stepfun" {
            fields.append(contentsOf: [
                .init(
                    key: .extra("username"),
                    title: L("用户名"),
                    subtitle: L("未填 token 时用于登录换取 Oasis-Token。"),
                    placeholder: "email / phone",
                    kind: .plain,
                    footer: "STEPFUN_USERNAME"),
                .init(
                    key: .extra("password"),
                    title: L("密码"),
                    subtitle: L("仅保存在本机配置中。"),
                    placeholder: "password",
                    kind: .secure,
                    footer: "STEPFUN_PASSWORD"),
            ])
        }

        if provider.id == "glm" {
            fields.append(.init(
                key: .extra("quotaURL"),
                title: L("Quota URL"),
                subtitle: L("高级覆盖；通常只填基础 URL 即可。"),
                placeholder: "https://...",
                kind: .plain,
                footer: "Z_AI_QUOTA_URL"))
        }

        let cookieOptions: [ProviderOption] = (cookieProviders.contains(provider.id) || provider.id == "amp")
            ? [
                .init(id: "auto", title: L("自动")),
                .init(id: "browser", title: L("浏览器")),
                .init(id: "manual", title: L("手动")),
                .init(id: "off", title: L("关闭")),
            ]
            : []

        var toggles: [ProviderToggleDescriptor] = [
            .init(
                key: "historyTracking",
                title: L("记录趋势"),
                subtitle: L("刷新成功后保留趋势样本。"),
                defaultValue: true),
        ]
        if provider.id == "claude" {
            toggles.append(.init(
                key: "avoidKeychainPrompts",
                title: L("减少授权弹窗"),
                subtitle: L("优先使用本机登录文件，减少重复授权。"),
                defaultValue: false))
        }

        return UsageProviderProfile(
            subtitle: subtitle(for: provider),
            category: category(for: provider),
            credentialKind: credentialKind(for: provider, envVar: envVar, isCookie: isCookie, isLocal: isLocal),
            credentialHint: credentialHint(for: provider, envVar: envVar, isCookie: isCookie, isLocal: isLocal),
            setupHint: setupHint(for: provider, envVar: envVar, isCookie: isCookie, isLocal: isLocal),
            sourceSubtitle: L("自动模式会优先使用已检测到的登录态或应用内凭证。"),
            cookieSubtitle: L("默认从浏览器读取；失败时再手动粘贴 Cookie。"),
            sourceOptions: sourceOptions,
            cookieOptions: cookieOptions,
            fields: fields,
            toggles: toggles,
            actions: actions(for: provider))
    }

    private static let cookieProviders: Set<String> = [
        "cursor", "grok", "copilot", "mistral", "opencode", "ollama", "perplexity", "augment",
        "factory", "manus", "t3chat", "opencodego", "alibabatokenplan", "mimo",
        "abacus", "commandcode",
    ]

    private static let localCredentialProviders: Set<String> = [
        "codex", "claude", "vertexai", "windsurf", "kiro", "jetbrains", "bedrock",
    ]

    private static func subtitle(for provider: UsageProviderEntry) -> String {
        switch provider.id {
        case "codex": return L("ChatGPT / Codex 订阅额度与窗口。")
        case "claude": return L("Claude Code 本机登录态与订阅用量。")
        case "openai": return L("OpenAI API credit grants 与 billing 额度。")
        case "amp": return L("Amp 账号登录态与 API 用量。")
        case "bedrock": return L("AWS Bedrock 账号预算与凭证。")
        case "vertexai": return L("Google Vertex AI 本地凭证。")
        default: return L("%@ 账号级用量与凭证。", provider.name)
        }
    }

    private static func category(for provider: UsageProviderEntry) -> String {
        switch provider.id {
        case "codex", "claude", "gemini", "cursor", "amp", "opencode", "augment", "kiro":
            return L("AI 编码")
        case "openai", "azureopenai", "openrouter", "deepseek", "groq", "mistral", "moonshot", "llmproxy":
            return "API"
        case "bedrock", "vertexai":
            return L("云服务")
        default:
            return L("渠道")
        }
    }

    private static func credentialKind(
        for provider: UsageProviderEntry,
        envVar: String?,
        isCookie: Bool,
        isLocal: Bool) -> String
    {
        if provider.id == "claude" { return L("本机登录") }
        if provider.id == "codex" { return L("本机登录") }
        if envVar != nil, isCookie { return L("API 密钥 / Cookie") }
        if envVar != nil { return L("API 密钥") }
        if isCookie { return L("浏览器 Cookie") }
        if isLocal { return L("本地凭证") }
        return L("会话")
    }

    private static func credentialHint(
        for provider: UsageProviderEntry,
        envVar: String?,
        isCookie: Bool,
        isLocal: Bool) -> String
    {
        if let envVar { return L("可在这里填写 %@，刷新时优先使用这里的值。", envVar) }
        if provider.id == "codex" { return L("使用本机登录态自动检测。") }
        if provider.id == "claude" { return L("使用本机登录态自动检测。") }
        if isCookie { return L("默认从浏览器读取登录态。") }
        if isLocal { return L("使用本机 CLI 或云厂商登录态自动检测。") }
        return L("该渠道无需额外配置，检测到登录态即自动显示用量。")
    }

    private static func setupHint(
        for provider: UsageProviderEntry,
        envVar: String?,
        isCookie: Bool,
        isLocal: Bool) -> String
    {
        if let envVar { return L("填写 %@，或在本机 shell 配置后刷新。", envVar) }
        if provider.id == "codex" { return L("先完成 Codex CLI 登录，然后刷新。") }
        if provider.id == "claude" { return L("先完成 Claude Code 登录，然后刷新。") }
        if isCookie { return L("先在浏览器登录 %@，然后刷新。", provider.name) }
        if isLocal { return L("确认本机 CLI 或云厂商登录态可用。") }
        return L("该渠道通过本机登录态自动检测，无法自动获取时用量留空。")
    }

    private static func actions(for provider: UsageProviderEntry) -> [ProviderActionDescriptor] {
        switch provider.id {
        case "codex":
            return [
                .init(title: L("打开本机配置"), systemImage: "folder", help: L("打开 Codex 本机配置目录")) {
                    NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"))
                },
            ]
        case "claude":
            return [
                .init(title: L("打开本机配置"), systemImage: "folder", help: L("打开 Claude 本机配置目录")) {
                    NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude"))
                },
            ]
        case "openai":
            return [
                .init(title: L("账单"), systemImage: "safari", help: "OpenAI billing") {
                    openURL("https://platform.openai.com/settings/organization/billing/overview")
                },
                .init(title: L("项目"), systemImage: "safari", help: "OpenAI projects") {
                    openURL("https://platform.openai.com/settings/organization/projects")
                },
            ]
        case "amp":
            return [
                .init(title: L("Amp 设置"), systemImage: "safari", help: "ampcode.com") {
                    openURL("https://ampcode.com/settings")
                },
            ]
        default:
            return []
        }
    }

    private static func openURL(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct ProviderOption: Identifiable, Equatable {
    let id: String
    let title: String
}

private enum ProviderStringConfigKey: Hashable {
    case apiKey
    case sourceMode
    case cookieSource
    case cookieHeader
    case projectID
    case baseURL
    case organizationID
    case extra(String)
}

private struct ProviderFieldDescriptor: Identifiable {
    enum Kind {
        case plain
        case secure
    }

    let key: ProviderStringConfigKey
    let title: String
    let subtitle: String
    let placeholder: String
    let kind: Kind
    let footer: String?

    var id: String {
        switch key {
        case .apiKey: return "apiKey"
        case .sourceMode: return "sourceMode"
        case .cookieSource: return "cookieSource"
        case .cookieHeader: return "cookieHeader"
        case .projectID: return "projectID"
        case .baseURL: return "baseURL"
        case .organizationID: return "organizationID"
        case let .extra(key): return "extra.\(key)"
        }
    }
}

private struct ProviderToggleDescriptor: Identifiable {
    let key: String
    let title: String
    let subtitle: String
    let defaultValue: Bool

    var id: String { key }
}

private struct ProviderActionDescriptor: Identifiable {
    let title: String
    let systemImage: String
    let help: String
    let perform: () -> Void

    var id: String { "\(title)-\(systemImage)" }
}
