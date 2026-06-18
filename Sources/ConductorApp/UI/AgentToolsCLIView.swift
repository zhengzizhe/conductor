import AppKit
import SwiftUI

private enum AgentToolsCLIFilter: String, CaseIterable, Identifiable {
    case all
    case installed
    case missing
    case credentials
    case usage
    case skills

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return L("全部")
        case .installed: return L("已安装")
        case .missing: return L("未检测")
        case .credentials: return L("已配置")
        case .usage: return "Usage"
        case .skills: return "Skills"
        }
    }
}

private enum AgentToolsCLISort: String, CaseIterable, Identifiable {
    case status
    case name
    case capability

    var id: String { rawValue }

    var title: String {
        switch self {
        case .status: return L("状态")
        case .name: return L("名称")
        case .capability: return L("能力")
        }
    }
}

private struct AgentToolsCLITableLayout {
    let showVersion: Bool
    let capabilityWidth: CGFloat
    let minToolWidth: CGFloat
}

struct AgentToolsCLIView: View {
    @ObservedObject var store: AgentToolsConsoleStore
    @ObservedObject private var configStore = ConfigStore.shared
    let onLaunch: (String) -> Void
    let onOpenModule: (AgentToolsManagementModule) -> Void

    @State private var query = ""
    @State private var filter: AgentToolsCLIFilter = .all
    @State private var sort: AgentToolsCLISort = .status
    @State private var tableWidth: CGFloat = 0

    private var rows: [CLIToolStatus] {
        var tools = store.cliTools
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !trimmed.isEmpty {
            tools = tools.filter { tool in
                tool.name.lowercased().contains(trimmed)
                    || tool.id.lowercased().contains(trimmed)
                    || tool.command.lowercased().contains(trimmed)
                    || (tool.path ?? "").lowercased().contains(trimmed)
                    || (tool.version ?? "").lowercased().contains(trimmed)
            }
        }

        tools = tools.filter { tool in
            guard let row = store.overviewRow(for: tool) else { return filter == .all }
            switch filter {
            case .all: return true
            case .installed: return tool.isInstalled
            case .missing: return !tool.isInstalled
            case .credentials:
                switch row.credentialSignal {
                case .ready, .warning, .loading, .error: return row.provider != nil
                default: return false
                }
            case .usage:
                if case .unavailable = row.usageSignal { return false }
                return true
            case .skills:
                if case .unavailable = row.skillSignal { return false }
                return true
            }
        }

        switch sort {
        case .status:
            tools.sort {
                if $0.isInstalled != $1.isInstalled { return $0.isInstalled && !$1.isInstalled }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .name:
            tools.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .capability:
            tools.sort {
                capabilityScore($0) == capabilityScore($1)
                    ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    : capabilityScore($0) > capabilityScore($1)
            }
        }
        return tools
    }

    var body: some View {
        let visibleRows = rows
        VStack(alignment: .leading, spacing: 14) {
            header
            toolbar
            inventoryStrip(visibleRows)
            table(visibleRows)
        }
        .agentToolsPage()
        .onAppear {
            store.start()
            if store.selectedCLIToolID == nil {
                store.selectedCLIToolID = store.cliTools.first(where: \.isInstalled)?.id ?? store.cliTools.first?.id
            }
        }
    }

    private var header: some View {
        AgentToolsModuleHeader(
            title: "CLI",
            subtitle: L("本机命令、版本、路径和能力适配"),
            icon: "terminal") {
            ToolBadge(
                text: store.cliDetectedAt.map { UsageFormatting.agoText($0) } ?? L("未扫描"),
                icon: "clock",
                color: AppStyle.textTertiary,
                style: .muted,
                height: 22)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            AgentToolsSearchField(placeholder: L("搜索 CLI / path / version"), text: $query)

            AgentToolsMenuButton(title: filter.title, icon: "line.3.horizontal.decrease.circle") {
                ForEach(AgentToolsCLIFilter.allCases) { option in
                    Button(option.title) {
                        withAnimation(AgentToolsMotion.selection) { filter = option }
                    }
                }
            }

            AgentToolsMenuButton(title: sort.title, icon: "arrow.up.arrow.down") {
                ForEach(AgentToolsCLISort.allCases) { option in
                    Button(option.title) {
                        withAnimation(AgentToolsMotion.selection) { sort = option }
                    }
                }
            }

            ToolActionButton(
                title: store.isScanningCLI ? L("扫描中") : L("重新扫描"),
                systemImage: store.isScanningCLI ? nil : "arrow.clockwise",
                height: 34,
                fontSize: 11.5,
                horizontalPadding: 12,
                help: L("重新扫描本机 CLI")) {
                    store.scanCLI()
                }
            .disabled(store.isScanningCLI)
        }
    }

    private func inventoryStrip(_ visibleRows: [CLIToolStatus]) -> some View {
        HStack(alignment: .top, spacing: 30) {
            AgentToolsStat(value: "\(store.installedCLICount)", title: L("已安装"))
            AgentToolsStat(value: "\(store.missingCLICount)", title: L("未检测"))
            AgentToolsStat(value: "\(store.installedCLICount)", title: L("可启动"))
            AgentToolsStat(value: "\(visibleRows.reduce(0) { $0 + capabilityScore($1) })", title: L("支持能力"))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, 14)
        .agentToolsGlass()
    }

    private func table(_ visibleRows: [CLIToolStatus]) -> some View {
        let layout = tableLayout
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                ToolsSectionLabel(L("工具表"))
                Spacer()
                Text(L("%ld 个工具", visibleRows.count))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(AppStyle.textTertiary)
            }
            VStack(spacing: 0) {
                tableWidthReader
                tableHeader(layout)
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(visibleRows) { tool in
                            toolRow(tool, layout: layout)
                        }
                        if visibleRows.isEmpty {
                            Text(L("无匹配结果"))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(AppStyle.textTertiary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 24)
                        }
                    }
                }
                .scrollIndicators(.visible)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .agentToolsGlass()
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var tableWidthReader: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear {
                    updateTableWidth(proxy.size.width)
                }
                .onChange(of: proxy.size.width) { _, newWidth in
                    updateTableWidth(newWidth)
                }
        }
        .frame(height: 0)
    }

    private func updateTableWidth(_ width: CGFloat) {
        let roundedWidth = width.rounded()
        guard roundedWidth > 0,
              abs(roundedWidth - tableWidth) >= 1 else { return }
        tableWidth = roundedWidth
    }

    private var tableLayout: AgentToolsCLITableLayout {
        tableWidth >= 620
            ? AgentToolsCLITableLayout(showVersion: true, capabilityWidth: 180, minToolWidth: 210)
            : AgentToolsCLITableLayout(showVersion: false, capabilityWidth: 146, minToolWidth: 170)
    }

    private func tableHeader(_ layout: AgentToolsCLITableLayout) -> some View {
        tableHeaderRow(
            showVersion: layout.showVersion,
            capabilityWidth: layout.capabilityWidth,
            minToolWidth: layout.minToolWidth)
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(AppStyle.textTertiary)
        .padding(.horizontal, 9)
        .frame(height: 28)
    }

    private func tableHeaderRow(showVersion: Bool,
                                capabilityWidth: CGFloat,
                                minToolWidth: CGFloat) -> some View {
        HStack(spacing: 8) {
            Text(L("工具"))
                .frame(minWidth: minToolWidth, maxWidth: .infinity, alignment: .leading)
            Text(L("状态")).frame(width: 74)
            if showVersion {
                Text(L("版本")).frame(width: 110, alignment: .leading)
            }
            Text(L("能力")).frame(width: capabilityWidth, alignment: .leading)
        }
    }

    private func toolRow(_ tool: CLIToolStatus, layout: AgentToolsCLITableLayout) -> some View {
        let selected = store.selectedCLIToolID == tool.id
        let overview = store.overviewRow(for: tool)
        return Button {
            withAnimation(AgentToolsMotion.selection) { store.selectedCLIToolID = tool.id }
        } label: {
            toolRowContent(
                tool,
                overview: overview,
                showVersion: layout.showVersion,
                capabilityWidth: layout.capabilityWidth,
                minToolWidth: layout.minToolWidth)
            .padding(.horizontal, 9)
            .frame(height: AgentToolsChrome.rowHeight)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .fill(selected ? AppStyle.accent.opacity(0.12) : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .animation(AgentToolsMotion.selection, value: selected)
        }
        .buttonStyle(PressScaleStyle())
        .contextMenu {
            if tool.isInstalled {
                Button(L("启动")) { onLaunch(tool.command) }
            }
            Button(L("复制命令")) { store.copyText(tool.command) }
            if let path = tool.path {
                Button(L("复制路径")) { store.copyText(path) }
                Button(L("在 Finder 中显示")) { reveal(path) }
            }
            Button(L("打开用量详情")) { onOpenModule(.usage) }
            if let overview {
                Button(L("复制诊断信息")) { store.copyDiagnostics(for: overview) }
            }
            Button(L("重新检测 CLI")) { store.scanCLI() }
        }
    }

    private func toolRowContent(_ tool: CLIToolStatus,
                                overview: AgentToolsOverviewRow?,
                                showVersion: Bool,
                                capabilityWidth: CGFloat,
                                minToolWidth: CGFloat) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 10) {
                CLIToolLogoView(tool: tool)
                    .frame(width: 22, height: 22)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill((tool.isInstalled ? AppStyle.accent : AppStyle.textTertiary).opacity(0.12)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.name)
                        .font(.system(size: 12.4, weight: .semibold))
                        .foregroundStyle(AppStyle.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text(tool.command)
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        if let path = tool.path {
                            Text(shortPath(path))
                                .font(.system(size: 9.5, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Text(L("未检测到位置"))
                                .font(.system(size: 9.5, weight: .medium))
                        }
                    }
                    .foregroundStyle(AppStyle.textTertiary)
                }
                Spacer(minLength: 0)
            }
            .frame(minWidth: minToolWidth, maxWidth: .infinity, alignment: .leading)

            Image(systemName: tool.isInstalled ? "checkmark" : "minus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tool.isInstalled ? AppStyle.doneGreen : AppStyle.textTertiary)
                .frame(width: 74)
                .help(tool.isInstalled ? L("可用") : L("缺失"))

            if showVersion {
                Text(tool.version ?? "-")
                    .font(.system(size: 10.5, weight: .medium, design: tool.version == nil ? .default : .monospaced))
                    .foregroundStyle(tool.version == nil ? AppStyle.textTertiary : AppStyle.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 110, alignment: .leading)
            }

            HStack(spacing: 5) {
                capabilityChip("Usage", overview?.usageSignal)
                capabilityChip("Skills", overview?.skillSignal)
            }
            .frame(width: capabilityWidth, alignment: .leading)
        }
    }

    private func capabilityChip(_ title: String, _ signal: AgentToolsSignal?) -> some View {
        let signal = signal ?? .unknown(L("未知"))
        let active: Bool = {
            if case .unavailable = signal { return false }
            if case .unknown = signal { return false }
            return true
        }()
        return Text(title)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(active ? signal.color : AppStyle.textTertiary)
            .help(signal.shortLabel)
    }

    private func capabilityScore(_ tool: CLIToolStatus) -> Int {
        guard let row = store.overviewRow(for: tool) else { return 0 }
        return [row.usageSignal, row.skillSignal].reduce(0) { partial, signal in
            if case .unavailable = signal { return partial }
            if case .unknown = signal { return partial }
            return partial + 1
        }
    }

    private func shortPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }

    private func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

struct AgentToolsCLIInspector: View {
    @ObservedObject var store: AgentToolsConsoleStore
    @ObservedObject private var configStore = ConfigStore.shared
    let onLaunch: (String) -> Void
    let onOpenModule: (AgentToolsManagementModule) -> Void

    var body: some View {
        AgentToolsInspectorShell {
            if let tool = store.selectedCLITool {
                selectedTool(tool)
            } else {
                defaultState
            }
        }
    }

    private var defaultState: some View {
        VStack(alignment: .leading, spacing: 12) {
            AgentToolsSection(L("CLI 概览")) {
                AgentToolsInfoRow(label: L("已安装"), value: "\(store.installedCLICount)")
                AgentToolsInfoRow(label: L("未检测"), value: "\(store.missingCLICount)")
                AgentToolsInfoRow(label: L("上次扫描"), value: store.cliDetectedAt.map { UsageFormatting.agoText($0) } ?? L("未扫描"))
            }

            Text(L("选择一个 CLI 查看路径、版本、能力和启动动作。"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppStyle.textTertiary)
                .lineSpacing(3)

            ToolActionButton(
                title: L("重新扫描 CLI"),
                systemImage: "arrow.clockwise",
                height: 28,
                fontSize: 11,
                horizontalPadding: 10,
                action: { store.scanCLI() })
        }
    }

    private func selectedTool(_ tool: CLIToolStatus) -> some View {
        let row = store.overviewRow(for: tool)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                CLIToolLogoView(tool: tool)
                    .frame(width: 26, height: 26)
                    .frame(width: 42, height: 42)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill((tool.isInstalled ? AppStyle.accent : AppStyle.textTertiary).opacity(0.12)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.name)
                        .font(.system(size: 14.5, weight: .bold))
                        .foregroundStyle(AppStyle.textPrimary)
                        .lineLimit(1)
                    Text(tool.command)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(AppStyle.textTertiary)
                        .lineLimit(1)
                }
            }

            AgentToolsSection(L("基础信息")) {
                AgentToolsInfoRow(label: L("状态"), value: tool.isInstalled ? L("可用") : L("缺失"))
                AgentToolsInfoRow(label: L("命令"), value: tool.command, monospaced: true)
                AgentToolsInfoRow(label: L("版本"), value: tool.version ?? "-")
                AgentToolsInfoRow(label: L("安装来源"), value: tool.path.map(installRootLabel) ?? L("未检测到位置"))
            }

            if let path = tool.path {
                AgentToolsSection(L("路径")) {
                    Text(path)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(AppStyle.textSecondary)
                        .textSelection(.enabled)
                        .lineLimit(4)
                        .truncationMode(.middle)
                }
            }

            AgentToolsSection(L("能力")) {
                signalRow("Usage", row?.usageSignal ?? .unknown(L("未知")))
                signalRow("Skills", row?.skillSignal ?? .unknown(L("未知")))
            }

            VStack(alignment: .leading, spacing: 8) {
                ToolActionButton(
                    title: L("启动到新标签"),
                    systemImage: "play.fill",
                    role: .primary,
                    height: 28,
                    fontSize: 11,
                    horizontalPadding: 10) {
                        onLaunch(tool.command)
                    }
                    .disabled(!tool.isInstalled)
                    .opacity(tool.isInstalled ? 1 : 0.55)

                VStack(alignment: .leading, spacing: 7) {
                    AgentToolsLinkButton(title: L("复制命令"), icon: "doc.on.doc") {
                        store.copyText(tool.command)
                    }

                    if let path = tool.path {
                        AgentToolsLinkButton(title: L("复制路径"), icon: "doc.on.doc") {
                            store.copyText(path)
                        }
                        AgentToolsLinkButton(title: L("在 Finder 中显示"), icon: "folder") {
                            reveal(path)
                        }
                    }

                    AgentToolsLinkButton(title: L("打开用量详情"), icon: "chart.bar.xaxis") {
                        onOpenModule(.usage)
                    }

                    if let row {
                        AgentToolsLinkButton(title: L("复制诊断信息"), icon: "doc.text") {
                            store.copyDiagnostics(for: row)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private func signalRow(_ label: String, _ signal: AgentToolsSignal) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(AppStyle.textTertiary)
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                Image(systemName: signal.icon)
                    .font(.system(size: 8.5, weight: .bold))
                Text(signal.shortLabel)
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(signal.color)
        }
    }

    private func installRootLabel(_ path: String) -> String {
        if path.hasPrefix("/opt/homebrew") { return "Homebrew" }
        if path.hasPrefix("/usr/local") { return "usr/local" }
        if path.hasPrefix(NSHomeDirectory()) { return "~" }
        return URL(fileURLWithPath: path).deletingLastPathComponent().path
    }

    private func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
