import AppKit
import ConductorCore
import SwiftUI

struct AgentToolsUsageView: View {
    @ObservedObject var store: AgentToolsConsoleStore
    let onApplyConfig: (AppConfig) -> Void
    let onOpenModule: (AgentToolsManagementModule) -> Void

    @ObservedObject private var configStore = ConfigStore.shared

    private var providers: [UsageProviderEntry] { UsageProviderCatalog.all }
    private var selectedProviderBinding: Binding<String?> {
        Binding(
            get: { store.selectedUsageProviderID },
            set: { store.selectedUsageProviderID = $0 })
    }

    private var enabledCount: Int {
        providers.filter { isEnabled($0) }.count
    }

    private var loadedCount: Int {
        providers.filter {
            if case .loaded = store.usageState(for: $0) { return true }
            return false
        }.count
    }

    private var manualCount: Int {
        providers.filter {
            if case .manual = store.usageState(for: $0) { return true }
            return false
        }.count
    }

    private var setupCount: Int {
        providers.filter {
            if case .unconfigured = store.usageState(for: $0) { return true }
            return false
        }.count
    }

    private var errorCount: Int {
        providers.filter {
            if case .error = store.usageState(for: $0) { return true }
            return false
        }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            metricStrip
            workbench
        }
        .agentToolsPage()
        .onAppear {
            store.start()
            selectDefaultProviderIfNeeded()
        }
        .onChange(of: store.providerStates.count) { _, _ in
            selectDefaultProviderIfNeeded()
        }
    }

    private var header: some View {
        AgentToolsModuleHeader(
            title: L("用量"),
            subtitle: L("账号渠道、凭证来源、额度窗口和本机用量记录"),
            icon: "chart.bar.xaxis") {
            ToolActionButton(
                title: L("刷新已配置"),
                systemImage: "arrow.clockwise",
                height: 34,
                fontSize: 11.5,
                horizontalPadding: 12,
                help: L("手动刷新所有已配置渠道")) {
                    refreshConfiguredProviders()
                }
            ToolActionButton(
                title: store.isScanningLocalUsage ? L("读取中") : L("刷新本地用量"),
                systemImage: store.isScanningLocalUsage ? nil : "externaldrive",
                height: 34,
                fontSize: 11.5,
                horizontalPadding: 12,
                help: L("扫描本机会话记录，不请求账号接口")) {
                    store.refreshLocalUsage()
                }
            .disabled(store.isScanningLocalUsage)
        }
    }

    private var metricStrip: some View {
        HStack(alignment: .top, spacing: 30) {
            AgentToolsStat(value: "\(providers.count)", title: L("全部渠道"))
            AgentToolsStat(value: "\(enabledCount)", title: L("启用"))
            AgentToolsStat(value: "\(loadedCount)", title: L("已取数"), valueColor: AppStyle.doneGreen)
            AgentToolsStat(value: "\(manualCount)", title: L("待刷新"))
            AgentToolsStat(value: "\(setupCount)", title: L("待配置"), valueColor: setupCount == 0 ? AppStyle.textPrimary : AppStyle.waitAmber)
            AgentToolsStat(value: "\(errorCount)", title: L("错误"), valueColor: errorCount == 0 ? AppStyle.textPrimary : AppStyle.errorRed)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, 14)
        .agentToolsGlass()
    }

    private var workbench: some View {
        ScrollView {
            UsageProvidersSettingsView(
                providers: providers,
                tools: store.cliTools,
                states: store.providerStates,
                selectedID: selectedProviderBinding,
                onApplyConfig: onApplyConfig,
                onReload: { store.refreshProvider($0) })
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
                .agentToolsGlass()
        }
        .scrollIndicators(.visible)
    }

    private func refreshConfiguredProviders() {
        providers.forEach { provider in
            switch store.usageState(for: provider) {
            case .manual, .loaded, .error:
                store.refreshProvider(provider)
            default:
                break
            }
        }
    }

    private func selectDefaultProviderIfNeeded() {
        guard store.selectedUsageProviderID == nil else { return }
        let preferred = providers.first { provider in
            switch store.usageState(for: provider) {
            case .loaded, .manual, .error: return true
            default: return false
            }
        } ?? providers.first
        store.selectedUsageProviderID = preferred?.id
    }

    private func isEnabled(_ provider: UsageProviderEntry) -> Bool {
        configStore.config.usage.providers[provider.id]?.enabled ?? true
    }
}

struct AgentToolsUsageInspector: View {
    @ObservedObject var store: AgentToolsConsoleStore
    @ObservedObject private var configStore = ConfigStore.shared

    var body: some View {
        AgentToolsInspectorShell {
            if let provider = store.selectedUsageProvider {
                selectedProvider(provider)
            } else {
                defaultState
            }
        }
    }

    private var defaultState: some View {
        VStack(alignment: .leading, spacing: 12) {
            AgentToolsSection(L("用量概览")) {
                AgentToolsInfoRow(label: L("全部渠道"), value: "\(UsageProviderCatalog.all.count)")
                AgentToolsInfoRow(label: L("已取数"), value: "\(loadedCount)")
                AgentToolsInfoRow(label: L("待刷新"), value: "\(manualCount)")
                AgentToolsInfoRow(label: L("本地用量"), value: store.usageReport.map { UsageFormatting.agoText($0.generatedAt) } ?? L("未扫描"))
            }

            Text(L("选择一个渠道查看账号、套餐、刷新状态和诊断信息。"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppStyle.textTertiary)
                .lineSpacing(3)
        }
    }

    private func selectedProvider(_ provider: UsageProviderEntry) -> some View {
        let state = store.usageState(for: provider)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AgentToolsUsageProviderLogo(provider: provider)
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.name)
                        .font(.system(size: 14.5, weight: .bold))
                        .foregroundStyle(AppStyle.textPrimary)
                        .lineLimit(1)
                    Text(provider.id)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(AppStyle.textTertiary)
                        .lineLimit(1)
                }
            }

            AgentToolsSection(L("基础信息")) {
                AgentToolsInfoRow(label: L("状态"), value: statusLabel(state))
                AgentToolsInfoRow(label: L("凭证"), value: credentialLabel(state))
                AgentToolsInfoRow(label: L("本地 CLI"), value: cliLabel(provider))
                AgentToolsInfoRow(label: L("更新"), value: updatedLabel(state))
            }

            if case let .loaded(snapshot) = state {
                AgentToolsSection(L("账号")) {
                    AgentToolsInfoRow(label: L("账号"), value: snapshot.accountLabel ?? "-")
                    AgentToolsInfoRow(label: L("套餐"), value: snapshot.planName ?? "-")
                    AgentToolsInfoRow(label: L("窗口"), value: L("%ld 个", snapshot.allWindows.count))
                    if let cost = snapshot.providerCost {
                        AgentToolsInfoRow(label: L("成本"), value: AgentToolsUsageFormatting.costText(cost))
                    }
                }
                if !snapshot.allWindows.isEmpty {
                    AgentToolsSection(L("额度窗口")) {
                        ForEach(snapshot.allWindows.prefix(4), id: \.title) { item in
                            usageWindowRow(item.title, item.window)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                ToolActionButton(
                    title: L("刷新这个渠道用量"),
                    systemImage: "arrow.clockwise",
                    height: 28,
                    fontSize: 11,
                    horizontalPadding: 10) {
                        store.refreshProvider(provider)
                    }

                ToolActionButton(
                    title: L("复制渠道 ID"),
                    systemImage: "doc.on.doc",
                    height: 28,
                    fontSize: 11,
                    horizontalPadding: 10) {
                        store.copyText(provider.id)
                    }

                ToolActionButton(
                    title: L("复制诊断信息"),
                    systemImage: "doc.text",
                    height: 28,
                    fontSize: 11,
                    horizontalPadding: 10) {
                        store.copyDiagnostics(for: provider)
                    }
            }
        }
    }

    private var loadedCount: Int {
        UsageProviderCatalog.all.filter {
            if case .loaded = store.usageState(for: $0) { return true }
            return false
        }.count
    }

    private var manualCount: Int {
        UsageProviderCatalog.all.filter {
            if case .manual = store.usageState(for: $0) { return true }
            return false
        }.count
    }

    private func usageWindowRow(_ title: String, _ window: RateWindow) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(AppStyle.textSecondary)
                Spacer()
                Text("\(Int(window.usedPercent.rounded()))%")
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(statusColor(forPercent: window.usedPercent))
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(AppStyle.hoverFill)
                    Capsule()
                        .fill(statusColor(forPercent: window.usedPercent))
                        .frame(width: max(4, proxy.size.width * CGFloat(window.usedPercent / 100)))
                }
            }
            .frame(height: 6)
            Text(resetLabel(window))
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(AppStyle.textTertiary)
                .lineLimit(1)
        }
    }

    private func statusLabel(_ state: ToolUsageState?) -> String {
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

    private func credentialLabel(_ state: ToolUsageState?) -> String {
        switch state {
        case .loaded, .manual, .loading: return L("已配置")
        case .unconfigured: return L("未配置")
        case .error: return L("异常")
        case .unsupported: return L("不支持")
        case .none: return L("未知")
        }
    }

    private func cliLabel(_ provider: UsageProviderEntry) -> String {
        guard let tool = store.cliTools.first(where: { $0.id == provider.id }) else { return "-" }
        return tool.version ?? (tool.isInstalled ? L("已安装") : L("未安装"))
    }

    private func updatedLabel(_ state: ToolUsageState?) -> String {
        if case let .loaded(snapshot) = state { return UsageFormatting.agoText(snapshot.updatedAt) }
        if case .manual = state { return L("待刷新") }
        if case .loading = state { return L("刷新中") }
        return L("未获取")
    }

    private func statusColor(forPercent percent: Double) -> Color {
        if percent >= 90 { return AppStyle.errorRed }
        if percent >= 70 { return AppStyle.waitAmber }
        return AppStyle.doneGreen
    }

    private func resetLabel(_ window: RateWindow) -> String {
        if let description = window.resetDescription, !description.isEmpty { return description }
        if let resetsAt = window.resetsAt { return UsageFormatting.resetText(resetsAt) }
        if let minutes = window.windowMinutes { return L("%ld 分钟窗口", minutes) }
        return L("无固定周期")
    }
}

private struct AgentToolsUsageProviderLogo: View {
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

private enum AgentToolsUsageFormatting {
    static func costText(_ cost: ProviderCostSnapshot) -> String {
        if cost.hasLimit {
            return "\(money(cost.used, cost.currencyCode)) / \(money(cost.limit, cost.currencyCode))"
        }
        return money(cost.used, cost.currencyCode)
    }

    private static func money(_ value: Double, _ currencyCode: String) -> String {
        let symbol: String
        switch currencyCode.uppercased() {
        case "USD": symbol = "$"
        case "CNY", "RMB": symbol = "¥"
        case "EUR": symbol = "€"
        case "GBP": symbol = "£"
        default: symbol = currencyCode + " "
        }
        return "\(symbol)\(String(format: "%.2f", value))"
    }
}
