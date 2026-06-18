import AppKit
import ConductorCore
import SwiftUI

/// 一个被检测的 CLI 工具的展示模型。Sendable + Codable（用于磁盘缓存）。
struct CLIToolStatus: Identifiable, Sendable, Codable {
    let id: String
    let name: String
    /// 资源里的品牌 logo 名（Resources/Logos/<logo>.png）。
    let logo: String
    /// 加载不到 logo 时的 SF Symbol 兜底。
    let fallbackSystemImage: String
    /// 用户可执行的真实命令；`id` 只作为稳定标识。
    let command: String
    let path: String?
    let version: String?

    var isInstalled: Bool { path != nil }
}

/// 加载并缓存品牌 logo（来自 SwiftPM 资源 bundle）。
enum CLIToolLogo {
    private static var cache: [String: NSImage?] = [:]
    private static var templateCache: [String: Bool] = [:]

    /// 单色（深色）品牌标，需作为模板图按主题着色，否则在深色界面里看不见。
    static let monochrome: Set<String> = ["cursor", "copilot"]

    static func isMonochrome(_ name: String) -> Bool {
        monochrome.contains(name) || templateCache[name] == true
    }

    static func image(named name: String) -> NSImage? {
        guard !name.isEmpty else { return nil }
        if let cached = cache[name] { return cached }

        let pngURL = appModuleResources.url(forResource: name, withExtension: "png", subdirectory: "Logos")
        let svgURL = appModuleResources.url(forResource: name, withExtension: "svg", subdirectory: "Logos")
        let image: NSImage?
        if let pngURL {
            image = NSImage(contentsOf: pngURL)
            templateCache[name] = monochrome.contains(name)
        } else if let svgURL {
            image = NSImage(contentsOf: svgURL)
            let template = shouldRenderSVGAsTemplate(svgURL)
            image?.isTemplate = template
            templateCache[name] = template
        } else {
            image = nil
            templateCache[name] = false
        }
        cache[name] = image
        return image
    }

    private static func shouldRenderSVGAsTemplate(_ url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8).lowercased() else { return false }
        if text.contains("currentcolor") { return true }
        guard text.contains("fill=\"white\"") || text.contains("stroke=\"white\"") || text.contains("#fff") else {
            return false
        }
        let pattern = #"#[0-9a-f]{3,8}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let colors = regex.matches(in: text, range: range).compactMap { match -> String? in
            guard let r = Range(match.range, in: text) else { return nil }
            return String(text[r])
        }
        return colors.allSatisfy { color in
            color == "#fff" || color == "#ffffff" || color == "#ffffffff"
        }
    }
}

/// 可一键启动的 Agent（已检测到安装）。`command` 即在终端里要执行的命令。
struct LaunchableAgent: Identifiable, Sendable {
    let id: String
    let title: String
    let command: String
    let logo: String
    let fallbackSystemImage: String
}

/// 一个受支持的 AI 编码 CLI 的静态描述 + 检测闭包。面板与右键菜单共用同一份定义，避免漂移。
struct AgentDescriptor: Sendable {
    let id: String
    let name: String
    let logo: String
    let fallbackSystemImage: String
    /// 在终端里启动它的命令（默认等于 id）。
    let command: String
    let resolveBinary: @Sendable () -> String?
    let readVersion: @Sendable () -> String?
}

enum AgentCatalog {
    static let all: [AgentDescriptor] = [
        AgentDescriptor(
            id: "codex", name: "Codex CLI", logo: "codex",
            fallbackSystemImage: "chevron.left.forwardslash.chevron.right", command: "codex",
            resolveBinary: { BinaryLocator.resolveCodexBinary() },
            readVersion: { ProviderVersionDetector.codexVersion() }),
        AgentDescriptor(
            id: "claude", name: "Claude Code", logo: "claude",
            fallbackSystemImage: "sparkles", command: "claude",
            resolveBinary: { BinaryLocator.resolveClaudeBinary() },
            readVersion: { ProviderVersionDetector.claudeVersion() }),
        AgentDescriptor(
            id: "gemini", name: "Gemini CLI", logo: "gemini",
            fallbackSystemImage: "diamond", command: "gemini",
            resolveBinary: { BinaryLocator.resolveGeminiBinary() },
            readVersion: { ProviderVersionDetector.geminiVersion() }),
        AgentDescriptor(
            id: "cursor", name: "Cursor Agent", logo: "cursor",
            fallbackSystemImage: "cursorarrow.rays", command: "cursor-agent",
            resolveBinary: { TTYCommandRunner.which("cursor-agent") },
            readVersion: { ProviderVersionDetector.genericVersion(command: "cursor-agent") }),
        AgentDescriptor(
            id: "copilot", name: "GitHub Copilot", logo: "copilot",
            fallbackSystemImage: "command", command: "copilot",
            resolveBinary: { TTYCommandRunner.which("copilot") },
            readVersion: { ProviderVersionDetector.genericVersion(command: "copilot") }),
        AgentDescriptor(
            id: "grok", name: "Grok CLI", logo: "grok",
            fallbackSystemImage: "bolt.fill", command: "grok",
            resolveBinary: { BinaryLocator.resolveGrokBinary() },
            readVersion: { ProviderVersionDetector.grokVersion() }),
        AgentDescriptor(
            id: "opencode", name: "opencode", logo: "opencode",
            fallbackSystemImage: "curlybraces", command: "opencode",
            resolveBinary: { TTYCommandRunner.which("opencode") },
            readVersion: { ProviderVersionDetector.genericVersion(command: "opencode") }),
        AgentDescriptor(
            id: "aider", name: "Aider", logo: "aider",
            fallbackSystemImage: "pencil.and.outline", command: "aider",
            resolveBinary: { TTYCommandRunner.which("aider") },
            readVersion: { ProviderVersionDetector.genericVersion(command: "aider") }),
        AgentDescriptor(
            id: "amp", name: "Amp", logo: "amp",
            fallbackSystemImage: "bolt.horizontal.circle", command: "amp",
            resolveBinary: { TTYCommandRunner.which("amp") },
            readVersion: { ProviderVersionDetector.genericVersion(command: "amp") }),
        AgentDescriptor(
            id: "auggie", name: "Augment", logo: "auggie",
            fallbackSystemImage: "puzzlepiece.extension", command: "auggie",
            resolveBinary: { BinaryLocator.resolveAuggieBinary() },
            readVersion: { ProviderVersionDetector.genericVersion(command: "auggie") }),
        AgentDescriptor(
            id: "qwen", name: "Qwen Code", logo: "qwen",
            fallbackSystemImage: "q.square", command: "qwen",
            resolveBinary: { TTYCommandRunner.which("qwen") },
            readVersion: { ProviderVersionDetector.genericVersion(command: "qwen") }),
    ]

    static func detectStatuses() -> [CLIToolStatus] {
        LoginShellPathCache.shared.captureOnce()
        _ = LoginShellPathCache.shared.currentOrCapture()
        return all.map { agent in
            let path = agent.resolveBinary()
            return CLIToolStatus(
                id: agent.id, name: agent.name,
                logo: agent.logo, fallbackSystemImage: agent.fallbackSystemImage,
                command: agent.command,
                path: path,
                version: path != nil ? agent.readVersion() : nil)
        }
    }
}

/// 某个工具的用量展示状态。
enum ToolUsageState {
    /// 该工具不支持用量查询。
    case unsupported
    case loading
    /// 已检测到凭证，但用量只在用户点击刷新时拉取。
    case manual
    /// 已启用但未检测到凭证（需在设置里填 API key）。
    case unconfigured
    case error(String)
    case loaded(UsageSnapshot)
}

private enum CLIInspectorMode: String, CaseIterable, Identifiable {
    case tools
    case providers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tools: return L("工具")
        case .providers: return L("渠道")
        }
    }

    var icon: String {
        switch self {
        case .tools: return "terminal"
        case .providers: return "slider.horizontal.3"
        }
    }
}

/// 独立面板：检测本机已安装的 AI 编码 CLI（codex / claude / gemini）。
/// 入口在 Tab 栏右侧、设置按钮旁边。检测走登录 Shell 的 PATH + 常见安装路径，
/// 因为是阻塞型 shell 探测，统一放到后台任务，避免卡主线程。
struct CLIToolsView: View {
    let coordinator: AppCoordinator
    var onClose: () -> Void = {}
    /// 主题变 → 重渲染（AppStyle 跟随）。不观察的话切主题后停在旧配色。
    @ObservedObject private var configStore = ConfigStore.shared

    @State private var results: [CLIToolStatus] = []
    @State private var detecting = false
    /// 上次检测时间（来自磁盘缓存或刚跑完的检测）。
    @State private var lastDetectedAt: Date?
    /// 账号级用量：本机已配置凭证的 provider 及其用量状态（与 CLI 检测解耦）。
    @State private var configuredProviders: [UsageProviderEntry] = []
    @State private var providerUsage: [String: ToolUsageState] = [:]
    /// 通知 hook 安装状态。
    @State private var feedHookStatus = FeedHookInstaller.status()
    @State private var feedHookError: String?
    @State private var inspectorMode: CLIInspectorMode = .tools
    @State private var selectedProviderID: String?

    private var installedTools: [CLIToolStatus] { results.filter(\.isInstalled) }
    private var missingTools: [CLIToolStatus] { results.filter { !$0.isInstalled } }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.md) {
                    embeddedToolbar
                    inspectorModePicker
                    if inspectorMode == .providers {
                        providerSettingsWorkbench
                    } else {
                        cliToolsWorkbench
                    }
                }
                .padding(.top, Space.sm)
                .padding(.horizontal, Space.lg)
                .padding(.bottom, Space.xl)
            }
            .scrollIndicators(.visible)
        }
        .frame(maxHeight: .infinity)
        .background(.clear)   // 内层透明：露出 ToolsPanel 的微玻璃
        .onAppear { loadOrDetect() }
        .onChange(of: inspectorMode) { _, mode in
            guard mode == .providers, providerUsage.isEmpty else { return }
            Task { await prepareProviderUsage() }
        }
    }

    @ViewBuilder
    private var cliToolsWorkbench: some View {
        cliInventoryStrip
        feedApprovalCard
        if results.isEmpty, detecting {
            loadingPlaceholder
        } else {
            accountUsageSection
            if !installedTools.isEmpty {
                ToolsSectionLabel(L("已安装"))
                ForEach(installedTools) { tool in
                    CLIToolRow(
                        tool: tool,
                        onLaunch: {
                            coordinator.launchAgent(command: tool.command)
                            onClose()
                        },
                        onCopyPath: { coordinator.copyToClipboard($0) },
                        onReveal: { coordinator.revealInFinder($0) }
                    )
                }
            }
            if !missingTools.isEmpty {
                ToolsSectionLabel(L("未检测到"))
                    .padding(.top, installedTools.isEmpty ? 0 : Space.xxs)
                missingList
            }
        }
    }

    private var cliInventoryStrip: some View {
        HStack(spacing: 8) {
            cliInventoryMetric(L("已安装"), "\(installedTools.count)", icon: "checkmark.circle.fill", color: AppStyle.doneGreen)
            cliInventoryMetric(L("未检测到"), "\(missingTools.count)", icon: "circle.dashed", color: AppStyle.textTertiary)
            cliInventoryMetric(L("可启动"), "\(installedTools.count)", icon: "play.fill", color: AppStyle.accent)
        }
    }

    private func cliInventoryMetric(_ title: String, _ value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 18, height: 18)
                .background(Circle().fill(color.opacity(0.13)))
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(AppStyle.textPrimary)
                Text(title)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(AppStyle.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity)
        .frame(height: 42)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppStyle.hoverFill.opacity(0.72)))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(color.opacity(0.10), lineWidth: 1))
    }

    private var providerSettingsWorkbench: some View {
        UsageProvidersSettingsView(
            providers: UsageProviderCatalog.all,
            tools: results,
            states: providerUsage,
            selectedID: $selectedProviderID,
            onApplyConfig: { coordinator.applyConfig($0) },
            onReload: { reloadProvider($0) })
    }

    /// 未安装的工具收成一张紧凑卡片：一行一个，不再占满版面的空框。
    private var missingList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(missingTools) { tool in
                HStack(spacing: 10) {
                    CLIToolLogoView(tool: tool)
                        .frame(width: 18, height: 18)
                        .opacity(0.45)
                        .saturation(0)
                    Text(tool.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppStyle.textSecondary)
                    Spacer()
                    Text(L("未检测到"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(AppStyle.textTertiary)
                }
                .padding(.horizontal, Space.sm)
                .frame(height: 36)
                .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .fill(AppStyle.hoverFill.opacity(0.46)))
            }
        }
        .padding(.vertical, 4)
        .toolsCard()
    }

    /// 打开面板：优先用磁盘缓存（不重新检测），仅在无缓存时才真正检测一次。
    private func loadOrDetect() {
        guard results.isEmpty else { return }
        if let cache = CLIDetectionStore.load() {
            results = cache.tools
            lastDetectedAt = cache.detectedAt
            pushLaunchableAgents(cache.tools)
            Task { await prepareProviderUsage() }
        } else {
            detect()
        }
    }

    private func pushLaunchableAgents(_ tools: [CLIToolStatus]) {
        coordinator.setLaunchableAgents(tools.filter(\.isInstalled).map {
            LaunchableAgent(
                id: $0.id, title: $0.name, command: $0.command,
                logo: $0.logo, fallbackSystemImage: $0.fallbackSystemImage)
        })
    }

    /// 嵌入模式头：标题 + 上次检测时间 + 重新检测，一行收掉，不再单独一段说明文。
    private var embeddedToolbar: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("AI 编码 CLI"))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(AppStyle.textPrimary)
                if let lastDetectedAt {
                    Text(L("上次检测 %@", UsageFormatting.agoText(lastDetectedAt)))
                        .font(.system(size: 10.5))
                        .foregroundStyle(AppStyle.textTertiary)
                        .help(lastDetectedAt.formatted(date: .abbreviated, time: .standard))
                } else {
                    Text(L("检测本机 AI CLI"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(AppStyle.textTertiary)
                        .help(L("会检查登录 Shell PATH 与常见安装位置"))
                }
            }
            Spacer()
            ToolActionButton(
                title: L("管理台"),
                systemImage: "rectangle.3.group",
                height: 26,
                fontSize: 11,
                horizontalPadding: 9,
                help: L("打开工具管理台")) {
                    coordinator.openAgentToolsManagement(inspectorMode == .providers ? .usage : .cli)
                }
            ToolActionButton(
                title: detecting ? L("检测中") : L("重新检测"),
                systemImage: detecting ? nil : "arrow.clockwise",
                height: 26,
                fontSize: 11,
                horizontalPadding: 10,
                help: L("重新扫描本机 CLI")) {
                    detect()
                }
            .disabled(detecting)
            .opacity(detecting ? 0.64 : 1)
        }
        .padding(.bottom, 2)
    }

    private var inspectorModePicker: some View {
        HStack(spacing: 2) {
            ForEach(CLIInspectorMode.allCases) { mode in
                let selected = inspectorMode == mode
                Button {
                    withAnimation(Motion.snappy) { inspectorMode = mode }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: mode.icon)
                            .font(.system(size: 10, weight: .semibold))
                        Text(mode.title)
                            .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                    }
                    .foregroundStyle(selected ? AppStyle.textPrimary : AppStyle.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                                .fill(AppStyle.elevated)
                                .shadow(color: .black.opacity(AppStyle.theme.isDark ? 0.30 : 0.08), radius: 3, y: 1)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppStyle.hoverFill))
    }

    private func hookBadge(_ label: String, _ on: Bool) -> some View {
        ToolBadge(
            text: label,
            icon: on ? "checkmark.circle.fill" : "circle.dashed",
            color: on ? AppStyle.doneGreen : AppStyle.textTertiary,
            style: on ? .soft : .muted,
            height: 22)
    }

    private var feedApprovalCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppStyle.accent)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                            .fill(AppStyle.accent.opacity(0.12)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("工具审批"))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(AppStyle.textPrimary)
                    Text(L("Claude 执行命令/改文件前先在 Conductor 审批，拒绝即拦截；socket 不可用时自动放行不卡 agent。仅作用于 Conductor 启动的 Claude。"))
                        .font(.system(size: 11))
                        .foregroundStyle(AppStyle.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                hookBadge(L("脚本"), feedHookStatus.scriptInstalled)
                hookBadge("Claude", feedHookStatus.claudeConfigured)
                Spacer()
            }

            HStack(spacing: 8) {
                if feedHookStatus.allDone {
                    ToolActionButton(title: L("停用工具审批"), role: .secondary, action: uninstallFeedHook)
                } else {
                    ToolActionButton(title: L("启用工具审批"), role: .primary, action: installFeedHook)
                }
                Spacer()
            }

            if let feedHookError {
                Text(feedHookError)
                    .font(.system(size: 10.5))
                    .foregroundStyle(AppStyle.errorRed)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .toolsCard()
    }

    private func installFeedHook() {
        feedHookError = nil
        do {
            feedHookStatus = try FeedHookInstaller.installAll()
        } catch {
            feedHookError = error.localizedDescription
            feedHookStatus = FeedHookInstaller.status()
        }
    }

    private func uninstallFeedHook() {
        feedHookError = nil
        do {
            try FeedHookInstaller.uninstall()
        } catch {
            feedHookError = error.localizedDescription
        }
        feedHookStatus = FeedHookInstaller.status()
    }


    private var loadingPlaceholder: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(L("正在检测…"))
                .font(.system(size: 12))
                .foregroundStyle(AppStyle.textSecondary)
            Spacer()
        }
        .padding(.vertical, 18)
    }

    private func detect() {
        guard !detecting else { return }
        detecting = true
        Task {
            let detected = await Task.detached(priority: .userInitiated) { () -> [CLIToolStatus] in
                AgentCatalog.detectStatuses()
            }.value
            let cache = CLIDetectionStore.save(detected)
            await MainActor.run {
                results = detected
                lastDetectedAt = cache.detectedAt
                detecting = false
                pushLaunchableAgents(detected)
            }
            await prepareProviderUsage()
        }
    }

    /// 账号用量区：列出全部渠道。已配置的（待手动刷新/有用量/加载中/出错）在「账号用量」组；
    /// 未配置的折叠进「其它渠道」组，点开可见全部并去设置填 key。
    @ViewBuilder
    private var accountUsageSection: some View {
        let active = configuredProviders.filter { !isUnconfigured(providerUsage[$0.id]) }
        let inactive = configuredProviders.filter { isUnconfigured(providerUsage[$0.id]) }
        if !active.isEmpty {
            ToolsSectionLabel(L("账号用量"))
            ForEach(active) { provider in
                ProviderUsageRow(
                    provider: provider,
                    state: providerUsage[provider.id] ?? .manual,
                    onConfigure: { openProviderSettings(provider.id) },
                    onReload: { reloadProvider(provider) })
            }
        }
        if !inactive.isEmpty {
            if active.isEmpty {
                ToolsSectionLabel(L("账号用量"))
            }
            Button(action: openProviderCatalog) {
                HStack(spacing: 10) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppStyle.accent)
                        .frame(width: 30, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                                .fill(AppStyle.accent.opacity(0.12)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("添加渠道"))
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(AppStyle.textPrimary)
                        Text(L("%ld 个可配置渠道", inactive.count))
                            .font(.system(size: 10.5))
                            .foregroundStyle(AppStyle.textTertiary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(AppStyle.textTertiary)
                }
                .padding(Space.sm)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleStyle())
            .toolsCard()
            .help(L("打开渠道配置"))
        }
    }

    private func openProviderSettings(_ id: String) {
        withAnimation(Motion.panel) {
            selectedProviderID = id
            inspectorMode = .providers
        }
    }

    private func openProviderCatalog() {
        withAnimation(Motion.panel) {
            selectedProviderID = nil
            inspectorMode = .providers
        }
    }

    /// 重新拉取单个 provider（用户填完 Key / 点刷新后调）。
    private func reloadProvider(_ provider: UsageProviderEntry) {
        let cfg = ConfigStore.shared.config
        Task {
            await MainActor.run { providerUsage[provider.id] = .loading }
            let configured = await Task.detached(priority: .userInitiated) { () -> Bool in
                UsageCredentials.apply(cfg)
                return provider.isConfigured()
            }.value
            guard configured else {
                await MainActor.run { providerUsage[provider.id] = .unconfigured }
                return
            }
            do {
                let snap = try await provider.fetch()
                await MainActor.run {
                    providerUsage[provider.id] = .loaded(snap)
                    if shouldRecordHistory(provider.id, config: cfg) {
                        UsageHistoryStore.shared.record(id: provider.id, snapshot: snap)
                        UsageHistoryStore.shared.persist()
                    }
                }
            } catch {
                await MainActor.run { providerUsage[provider.id] = .error(error.localizedDescription) }
            }
        }
    }

    private func isUnconfigured(_ state: ToolUsageState?) -> Bool {
        if case .unconfigured = state { return true }
        return false
    }

    /// 账号用量区：默认列出**全部**渠道（像 CodexBar），配置好的进入「待刷新」；
    /// 只有用户点刷新时才请求用量，避免打开面板就触发 CLI/账号访问。
    private func prepareProviderUsage() async {
        let cfg = ConfigStore.shared.config
        let resolved = await Task.detached(priority: .utility) { () -> [(UsageProviderEntry, Bool)] in
            UsageCredentials.apply(cfg)   // 注入 key 后 isConfigured() 才反映应用内配置
            return UsageProviderCatalog.all
                .filter { UsageCredentials.isVisible($0, config: cfg) }
                .map { ($0, $0.isConfigured()) }
        }.value
        // 已配置的排前面，组内保持目录顺序。
        let providers = resolved.filter { $0.1 }.map { $0.0 } + resolved.filter { !$0.1 }.map { $0.0 }
        let configuredIDs = Set(resolved.filter { $0.1 }.map { $0.0.id })
        let visibleIDs = Set(providers.map(\.id))
        await MainActor.run {
            configuredProviders = providers
            providerUsage = providerUsage.filter { visibleIDs.contains($0.key) }
            for provider in providers {
                if configuredIDs.contains(provider.id) {
                    switch providerUsage[provider.id] {
                    case .loaded, .loading, .error:
                        break
                    default:
                        providerUsage[provider.id] = .manual
                    }
                } else {
                    providerUsage[provider.id] = .unconfigured
                }
            }
        }
    }

    private func shouldRecordHistory(_ providerID: String, config: AppConfig) -> Bool {
        config.usage.providers[providerID]?.flags["historyTracking"] ?? true
    }
}

/// 品牌 logo（带 SF Symbol 兜底），CLI 行与「未检测到」列表共用。
struct CLIToolLogoView: View {
    let tool: CLIToolStatus
    /// 主题变 → 重渲染（字段不变时 SwiftUI 会跳过 body）。
    @ObservedObject private var configStore = ConfigStore.shared

    var body: some View {
        if let logo = CLIToolLogo.image(named: tool.logo) {
            if CLIToolLogo.isMonochrome(tool.logo) {
                Image(nsImage: logo)
                    .resizable()
                    .renderingMode(.template)
                    .interpolation(.high)
                    .scaledToFit()
                    .foregroundStyle(tool.isInstalled ? AppStyle.textPrimary : AppStyle.textTertiary)
            } else {
                Image(nsImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            }
        } else {
            Image(systemName: tool.fallbackSystemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tool.isInstalled ? AppStyle.accent : AppStyle.textTertiary)
        }
    }
}

private struct CLIToolRow: View {
    let tool: CLIToolStatus
    let onLaunch: () -> Void
    let onCopyPath: (String) -> Void
    let onReveal: (String) -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            headerRow
            if let path = tool.path {
                HStack(spacing: 7) {
                    Image(systemName: "folder")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(AppStyle.textTertiary)
                    Text(path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(AppStyle.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .fill(AppStyle.hoverFill.opacity(0.48)))
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(hovering ? AppStyle.hoverFill : AppStyle.theme.isDark ? Color.white.opacity(0.045) : .white))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(tool.isInstalled ? AppStyle.doneGreen : AppStyle.textTertiary.opacity(0.45))
                .frame(width: 3)
                .padding(.vertical, 10)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(hovering ? AppStyle.accent.opacity(0.22) : AppStyle.theme.isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.05), lineWidth: 1))
        .shadow(color: Color.black.opacity(AppStyle.theme.isDark ? 0 : 0.05), radius: 8, y: 3)
        .onHover { inside in
            withAnimation(Motion.hover) { hovering = inside }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 10) {
            CLIToolLogoView(tool: tool)
                .frame(width: 22, height: 22)
                .frame(width: 38, height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill((tool.isInstalled ? AppStyle.accent : AppStyle.textTertiary).opacity(0.12)))
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(tool.isInstalled ? AppStyle.doneGreen : AppStyle.textTertiary)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().stroke(AppStyle.windowBackground, lineWidth: 1.5))
                        .offset(x: 1, y: 1)
                }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(tool.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(AppStyle.textPrimary)
                        .lineLimit(1)
                    CLIToolStatusPill(installed: tool.isInstalled)
                    if let version = tool.version {
                        CLIInfoChip(icon: "number", text: version, monospaced: true)
                    }
                }
                HStack(spacing: 5) {
                    CLIInfoChip(icon: "terminal", text: tool.command, monospaced: true)
                    if let path = tool.path {
                        CLIInfoChip(icon: "externaldrive", text: installRootLabel(path))
                    } else {
                        CLIInfoChip(icon: "questionmark.folder", text: L("未检测到位置"))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let path = tool.path {
                IconOnlyButton(
                    systemName: "doc.on.doc",
                    help: L("复制路径"),
                    size: 24,
                    symbolSize: 10.5,
                    weight: .semibold,
                    tint: AppStyle.textTertiary) {
                        onCopyPath(path)
                    }
                IconOnlyButton(
                    systemName: "folder",
                    help: L("在 Finder 中显示"),
                    size: 24,
                    symbolSize: 10.5,
                    weight: .semibold,
                    tint: AppStyle.textTertiary) {
                        onReveal(path)
                    }
                ToolActionButton(
                    title: L("启动"),
                    systemImage: "play.fill",
                    role: .primary,
                    height: 25,
                    fontSize: 11,
                    horizontalPadding: 10,
                    help: L("在新标签页启动 %@", tool.name),
                    action: onLaunch)
            } else {
                ToolBadge(
                    text: L("未安装"),
                    color: AppStyle.textTertiary,
                    style: .muted,
                    height: 22)
            }
        }
    }

    private func installRootLabel(_ path: String) -> String {
        if path.hasPrefix("/opt/homebrew") { return "Homebrew" }
        if path.hasPrefix("/usr/local") { return "usr/local" }
        if path.hasPrefix(NSHomeDirectory()) { return "~" + path.dropFirst(NSHomeDirectory().count) }
        return URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
    }
}

private struct CLIToolStatusPill: View {
    let installed: Bool

    var body: some View {
        let color = installed ? AppStyle.doneGreen : AppStyle.textTertiary
        ToolBadge(
            text: installed ? L("可用") : L("缺失"),
            color: color,
            style: installed ? .soft : .muted,
            height: 18)
    }
}

private struct CLIInfoChip: View {
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

/// 账号用量区里的一行 provider：合并「用量展示 + 内联配置」于一处（对齐 CodexBar）。
/// 收起：logo + 名字 + 状态摘要 + 用量条；展开：趋势图 + 配置块（显示开关 + API Key + 刷新）。
private struct ProviderUsageRow: View {
    let provider: UsageProviderEntry
    let state: ToolUsageState
    /// 打开右侧 provider 配置详情。
    let onConfigure: () -> Void
    /// 重新拉取该 provider。
    let onReload: () -> Void
    @ObservedObject private var history = UsageHistoryStore.shared
    @State private var expanded = false

    var body: some View {
        let samples = history.samples(for: provider.id)
        VStack(alignment: .leading, spacing: 9) {
            header
            usageBody
            if expanded {
                if samples.count >= 2 { UsageTrendChart(samples: samples, compact: false) }
                quickActions
            }
        }
        .padding(Space.sm)
        .toolsCard()
    }

    private var header: some View {
        Button { withAnimation(Motion.snappy) { expanded.toggle() } } label: {
            HStack(spacing: 10) {
                logo
                    .frame(width: 22, height: 22)
                    .frame(width: 38, height: 38)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(statusColor.opacity(0.13)))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(provider.name)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(AppStyle.textPrimary)
                            .lineLimit(1)
                        ProviderUsageStateBadge(label: stateLabel, color: statusColor)
                    }
                    if let sub = headerSubtitle {
                        Text(sub)
                            .font(.system(size: 10))
                            .foregroundStyle(AppStyle.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                trailingStatus
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(AppStyle.textTertiary)
                    .frame(width: 18, height: 18)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var headerSubtitle: String? {
        switch state {
        case let .loaded(snap):
            let rawParts: [String?] = [snap.accountLabel, snap.planName]
            let parts = rawParts
                .compactMap { (value: String?) -> String? in
                    guard let value, !value.isEmpty else { return nil }
                    return value
                }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .manual:
            return L("已配置，等待手动刷新")
        case let .error(message):
            return message
        case .loading:
            return L("正在刷新用量…")
        case .unconfigured:
            return L("需要配置凭证")
        case .unsupported:
            return L("暂不支持用量")
        }
    }

    private var stateLabel: String {
        switch state {
        case .loaded: return L("就绪")
        case .loading: return L("刷新中")
        case .manual: return L("待刷新")
        case .unconfigured: return L("待配置")
        case .error: return L("错误")
        case .unsupported: return L("不支持")
        }
    }

    private var statusColor: Color {
        switch state {
        case .loaded: return AppStyle.doneGreen
        case .loading, .manual: return AppStyle.accent
        case .unconfigured: return AppStyle.waitAmber
        case .error: return AppStyle.errorRed
        case .unsupported: return AppStyle.textTertiary
        }
    }

    @ViewBuilder
    private var trailingStatus: some View {
        switch state {
        case .loading:
            ProgressView().controlSize(.small).scaleEffect(0.7)
        case .manual:
            ToolBadge(text: L("手动"), color: AppStyle.accent, height: 18)
        case .unconfigured:
            EmptyView()
        case .error:
            ToolBadge(text: L("失败"), color: AppStyle.errorRed, height: 18)
        case let .loaded(snap):
            if let summary = compactSummary(snap) {
                Text(summary)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit().foregroundStyle(AppStyle.textSecondary)
            }
        case .unsupported:
            EmptyView()
        }
    }

    private func compactSummary(_ snap: UsageSnapshot) -> String? {
        if let w = snap.primary ?? snap.secondary ?? snap.tertiary {
            return L("剩 %ld%%", Int(w.remainingPercent.rounded()))
        }
        if let c = snap.providerCost {
            return CostLine.shortText(c)
        }
        return nil
    }

    @ViewBuilder
    private var logo: some View {
        let logoName = provider.logoName
        if let image = CLIToolLogo.image(named: logoName) {
            if CLIToolLogo.isMonochrome(logoName) {
                Image(nsImage: image).resizable().renderingMode(.template).interpolation(.high)
                    .scaledToFit().foregroundStyle(AppStyle.textPrimary)
            } else {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            }
        } else {
            Image(systemName: provider.fallbackSystemImage)
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(AppStyle.accent)
        }
    }

    @ViewBuilder
    private var usageBody: some View {
        switch state {
        case .unsupported, .loading, .unconfigured:
            EmptyView()
        case .manual:
            ProviderUsageHint(icon: "hand.tap", text: L("不会自动请求账号；点击刷新获取用量。"), color: AppStyle.accent)
        case let .error(message):
            ProviderUsageHint(icon: "exclamationmark.triangle.fill", text: message, color: AppStyle.errorRed)
        case let .loaded(snap):
            if snap.isEmpty {
                ProviderUsageHint(icon: "chart.bar.xaxis", text: L("暂无用量数据"), color: AppStyle.textTertiary)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(snap.allWindows.enumerated()), id: \.offset) { _, item in
                        UsageBar(title: item.title, window: item.window)
                    }
                    if let cost = snap.providerCost { CostLine(cost: cost) }
                }
                .padding(.top, 9).padding(.leading, 44)
            }
        }
    }

    // MARK: 展开动作

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ToolActionButton(
                    title: L("打开配置"),
                    systemImage: "slider.horizontal.3",
                    role: .secondary,
                    height: 26,
                    fontSize: 11,
                    horizontalPadding: 10,
                    action: onConfigure)
                ToolActionButton(
                    title: L("刷新"),
                    systemImage: "arrow.clockwise",
                    role: .secondary,
                    height: 26,
                    fontSize: 11,
                    horizontalPadding: 10,
                    action: onReload)
                Spacer(minLength: 0)
            }
        }
        .padding(.top, 4)
        .padding(.horizontal, 2)
    }
}

private struct ProviderUsageStateBadge: View {
    let label: String
    let color: Color

    var body: some View {
        ToolBadge(text: label, color: color, height: 18)
    }
}

private struct ProviderUsageHint: View {
    let icon: String
    let text: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 18, height: 18)
                .background(Circle().fill(color.opacity(0.12)))
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(AppStyle.textTertiary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.leading, 44)
    }
}

/// 单个用量窗口的展示：标题 + 进度条 + 剩余百分比 + 重置倒计时。
private struct UsageBar: View {
    let title: String
    let window: RateWindow
    /// 主题变 → 重渲染（字段不变时 SwiftUI 会跳过 body）。
    @ObservedObject private var configStore = ConfigStore.shared

    private var fraction: Double { window.usedPercent / 100.0 }

    /// 用量越高越警示：<70 绿、70-90 橙、>90 红。
    private var barColor: Color {
        switch window.usedPercent {
        case ..<70: AppStyle.accent
        case 70..<90: AppStyle.waitAmber
        default: AppStyle.errorRed
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(AppStyle.textPrimary)
                        .lineLimit(1)
                    Text(resetText)
                        .font(.system(size: 9.5))
                        .foregroundStyle(AppStyle.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(L("剩 %ld%%", Int(window.remainingPercent.rounded())))
                        .font(.system(size: 11.5, weight: .bold, design: .rounded))
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
                    Capsule()
                        .fill(AppStyle.subtleFill)
                    Capsule()
                        .fill(barColor)
                        .frame(width: max(3, geo.size.width * fraction))
                }
            }
            .frame(height: 5)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .fill(AppStyle.hoverFill.opacity(0.54)))
    }

    private var resetText: String {
        if let reset = window.resetsAt { return UsageFormatting.resetText(reset) }
        if let description = window.resetDescription, !description.isEmpty { return description }
        return L("无固定重置")
    }
}

/// 额度 / 消费行：「已用 $X / $Y · 周期」或仅「余额 $X」。
struct CostLine: View {
    let cost: ProviderCostSnapshot
    @ObservedObject private var configStore = ConfigStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "creditcard")
                    .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(AppStyle.textTertiary)
                Text(text)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(AppStyle.textPrimary)
                if let period = cost.period, !period.isEmpty {
                    Text(period).font(.system(size: 10)).foregroundStyle(AppStyle.textTertiary)
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
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .fill(AppStyle.hoverFill.opacity(0.54)))
    }

    private var text: String {
        if cost.hasLimit {
            return "\(Self.money(cost.used, cost.currencyCode)) / \(Self.money(cost.limit, cost.currencyCode))"
        }
        return L("余额 %@", Self.money(cost.used, cost.currencyCode))
    }

    /// 收起态的紧凑摘要：有上限显示已用，否则显示余额金额。
    static func shortText(_ cost: ProviderCostSnapshot) -> String {
        money(cost.used, cost.currencyCode)
    }

    static func money(_ v: Double, _ currencyCode: String) -> String {
        let symbol: String
        switch currencyCode.uppercased() {
        case "USD": symbol = "$"
        case "CNY", "RMB": symbol = "¥"
        case "EUR": symbol = "€"
        case "GBP": symbol = "£"
        default: symbol = currencyCode + " "
        }
        return symbol + String(format: "%.2f", v)
    }
}

enum UsageFormatting {
    /// 把过去时间格式化成「刚刚」「8 分钟前」「3 小时前」「2 天前」。
    static func agoText(_ date: Date) -> String {
        let seconds = -date.timeIntervalSinceNow
        guard seconds > 0 else { return L("刚刚") }
        if seconds < 60 { return L("刚刚") }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return L("%ld 分钟前", minutes) }
        let hours = minutes / 60
        if hours < 24 { return L("%ld 小时前", hours) }
        let days = hours / 24
        if days < 30 { return L("%ld 天前", days) }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    /// 把重置时间格式化成「4 小时后重置」「2 天后重置」「8 分钟后重置」。
    static func resetText(_ date: Date) -> String {
        let seconds = date.timeIntervalSinceNow
        guard seconds > 0 else { return L("已重置") }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return L("%ld 分钟后重置", max(1, minutes)) }
        let hours = minutes / 60
        if hours < 24 {
            let remMin = minutes % 60
            return remMin > 0 ? L("%1$ld 小时 %2$ld 分后重置", hours, remMin) : L("%ld 小时后重置", hours)
        }
        let days = hours / 24
        let remHours = hours % 24
        return remHours > 0 ? L("%1$ld 天 %2$ld 小时后重置", days, remHours) : L("%ld 天后重置", days)
    }
}
