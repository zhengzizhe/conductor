import AppKit
import SwiftUI

private enum AgentToolsMCPWorkbenchSection: String, CaseIterable, Identifiable {
    case library
    case install
    case clients
    case servers
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: return L("中央库")
        case .install: return L("导入")
        case .clients: return L("应用")
        case .servers: return L("已配置")
        case .diagnostics: return L("诊断")
        }
    }

    var subtitle: String {
        switch self {
        case .library: return L("精选 MCP server 模板")
        case .install: return L("自定义 stdio / HTTP / SSE")
        case .clients: return L("直接编辑各应用配置 / 选择安装目标")
        case .servers: return L("本机配置里已存在的 servers")
        case .diagnostics: return L("配置文件、错误和导出")
        }
    }

    var sidebarHint: String {
        switch self {
        case .library: return L("模板")
        case .install: return L("写入")
        case .clients: return L("安装到")
        case .servers: return L("清单")
        case .diagnostics: return L("文件/日志")
        }
    }

    var icon: String {
        switch self {
        case .library: return "square.stack.3d.up"
        case .install: return "plus.app"
        case .clients: return "cpu"
        case .servers: return "list.bullet.rectangle"
        case .diagnostics: return "wrench.and.screwdriver"
        }
    }
}

private enum AgentToolsMCPWorkbenchFilter: String, CaseIterable, Identifiable {
    case all
    case stdio
    case remote
    case withEnv

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return L("全部")
        case .stdio: return "stdio"
        case .remote: return L("远程")
        case .withEnv: return "env"
        }
    }
}

private enum AgentToolsMCPAddTab: String, CaseIterable, Identifiable {
    case template, custom
    var id: String { rawValue }
    var title: String { self == .template ? L("模板库") : L("自定义") }
}

struct AgentToolsMCPWorkbenchView: View {
    @ObservedObject var store: AgentToolsConsoleStore

    @State private var selectedSection: AgentToolsMCPWorkbenchSection = {
        #if DEBUG
        if let forced = AgentToolsDebugUI.mcpSection,
           let section = AgentToolsMCPWorkbenchSection(rawValue: forced) { return section }
        #endif
        return .servers   // 列表优先：进来先看到已配置的 servers，而不是 dashboard
    }()
    @State private var query = ""
    @State private var serverFilter: AgentToolsMCPWorkbenchFilter = .all
    // 默认不预选任何应用——安装必须由用户显式选目标，绝不一键群发。
    @State private var selectedTargetIDs = Set<String>()
    /// 非 nil＝正在用原生 JSON 编辑器编辑该 client 的配置文件。
    @State private var editingClientJSON: AgentToolsMCPClientAdapter?
    /// 自定义 server 直接编辑 JSON（键=名称，值=command/args/env 或 url），不再拆成一堆输入框。
    @State private var customJSON = ""
    /// 非 nil＝编辑模式，composer 回填该 server 并改为「保存修改」。
    @State private var editingServer: AgentToolsMCPServerRecord?
    /// 待确认删除的 server（驱动 confirmationDialog）。
    @State private var serverPendingDelete: AgentToolsMCPServerRecord?
    /// 添加 server 的 sheet——把 模板库 / 自定义 / 选应用 合进一个流程，取代分散的分区。
    @State private var showAddSheet = false
    @State private var addTab: AgentToolsMCPAddTab = .template

    private var filteredServers: [AgentToolsMCPServerRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return store.mcpServers.filter { server in
            let matchesQuery = trimmed.isEmpty
                || server.name.lowercased().contains(trimmed)
                || server.client.lowercased().contains(trimmed)
                || server.endpointLabel.lowercased().contains(trimmed)
                || server.configPath.lowercased().contains(trimmed)
            guard matchesQuery else { return false }
            switch serverFilter {
            case .all: return true
            case .stdio: return server.transport == .stdio
            case .remote: return server.transport == .http || server.transport == .sse
            case .withEnv: return server.envKeyCount > 0
            }
        }
    }

    private var filteredTemplates: [AgentToolsMCPTemplate] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return AgentToolsMCPScanner.templates }
        return AgentToolsMCPScanner.templates.filter { template in
            template.name.lowercased().contains(trimmed)
                || template.description.lowercased().contains(trimmed)
                || template.tags.contains { $0.lowercased().contains(trimmed) }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 208)

            VStack(spacing: 0) {
                header
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .agentToolsPage()
        .overlay(alignment: .top) { AgentToolsNoticeBanner(text: store.mcpNotice) { store.mcpNotice = nil } }
        .sheet(isPresented: $showAddSheet) { addSheet }
        .sheet(item: $editingClientJSON) { adapter in
            AgentToolsJSONEditorSheet(
                title: L("编辑 %@ 的 MCP 配置", adapter.displayName),
                subtitle: adapter.path,
                hint: L("直接编辑该应用的 mcpServers：形如 { \"my-server\": { \"command\": \"npx\", \"args\": [...] } }。保存即写入文件。"),
                initialText: store.mcpClientJSON(for: adapter),
                onSave: { store.saveMCPClientJSON($0, for: adapter) },
                onClose: { editingClientJSON = nil })
        }
        .onAppear {
            if store.mcpServers.isEmpty { store.refreshMCP() }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            AgentToolsWorkbenchBrand(
                icon: "point.3.connected.trianglepath.dotted",
                title: "MCP Manager",
                subtitle: L("Servers / Clients"))

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    AgentToolsWorkbenchRailSection("Servers") {
                        railButton(.servers)
                        railButton(.clients)
                    }

                    AgentToolsWorkbenchRailSection(L("维护")) {
                        railButton(.diagnostics)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
            .scrollIndicators(.never)

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 6) {
                Text("MCP")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(AppStyle.textTertiary)
                HStack(spacing: 6) {
                    ToolBadge(text: L("%ld Servers", store.mcpServers.count), color: AppStyle.textTertiary, style: .muted, height: 20)
                    ToolBadge(text: L("%ld 目标", selectedTargetIDs.count), color: selectedTargetIDs.isEmpty ? AppStyle.waitAmber : AppStyle.accent, style: .muted, height: 20)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .background(AppStyle.hoverFill.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    }

    private func railButton(_ section: AgentToolsMCPWorkbenchSection) -> some View {
        AgentToolsWorkbenchRailButton(
            icon: section.icon,
            title: section.title,
            subtitle: section.sidebarHint,
            badge: badge(for: section),
            selected: selectedSection == section) {
                withAnimation(AgentToolsMotion.route) { selectedSection = section }
            }
    }

    private func badge(for section: AgentToolsMCPWorkbenchSection) -> String? {
        switch section {
        case .library: return "\(AgentToolsMCPScanner.templates.count)"
        case .install: return nil
        case .clients: return "\(AgentToolsMCPScanner.writableClients.count)"
        case .servers: return store.mcpServers.isEmpty ? nil : "\(store.mcpServers.count)"
        case .diagnostics: return store.mcpScanError == nil ? nil : "!"
        }
    }

    private var header: some View {
        AgentToolsModuleHeader(
            title: selectedSection.title,
            subtitle: selectedSection.subtitle,
            icon: selectedSection.icon) {
                HStack(spacing: 8) {
                    if selectedSection == .library || selectedSection == .servers {
                        AgentToolsSearchField(placeholder: L("搜索 server / client / command / path"), text: $query)
                            .frame(minWidth: 240, idealWidth: 320, maxWidth: 420)
                    }

                    ToolActionButton(
                        title: L("添加"),
                        systemImage: "plus",
                        role: .primary,
                        height: 34,
                        fontSize: 11.5,
                        horizontalPadding: 12) {
                            editingServer = nil
                            resetComposer()
                            addTab = .template
                            showAddSheet = true
                        }

                    if selectedSection == .servers {
                        AgentToolsMenuButton(title: serverFilter.title, icon: "line.3.horizontal.decrease.circle") {
                            ForEach(AgentToolsMCPWorkbenchFilter.allCases) { option in
                                Button(option.title) {
                                    withAnimation(AgentToolsMotion.selection) { serverFilter = option }
                                }
                            }
                        }
                    }

                    ToolActionButton(
                        title: store.isScanningMCP ? L("扫描中") : L("重新扫描"),
                        systemImage: store.isScanningMCP ? nil : "arrow.clockwise",
                        height: 34,
                        fontSize: 11.5,
                        horizontalPadding: 12,
                        help: L("重新扫描本机 MCP 配置")) {
                            store.refreshMCP()
                        }
                        .disabled(store.isScanningMCP)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 2)
            .padding(.bottom, 10)
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                switch selectedSection {
                case .library:
                    libraryContent
                case .install:
                    installContent
                case .clients:
                    clientsContent
                case .servers:
                    serversContent
                case .diagnostics:
                    diagnosticsContent
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.never)
    }

    @ViewBuilder
    private var libraryContent: some View {
        targetSummaryBar

        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 8)], spacing: 8) {
            ForEach(filteredTemplates) { template in
                templateCard(template)
            }
        }
    }

    private func templateCard(_ template: AgentToolsMCPTemplate) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: template.transport == .stdio ? "terminal" : "network")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(mcpWorkbenchTransportColor(template.transport))
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(mcpWorkbenchTransportColor(template.transport).opacity(0.12)))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(template.name)
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(AppStyle.textPrimary)
                            .lineLimit(1)
                        if template.requiresEnv {
                            ToolBadge(text: "env", color: AppStyle.waitAmber, height: 16)
                        }
                    }
                    Text(template.transport.title)
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(AppStyle.textTertiary)
                }
                Spacer(minLength: 0)
            }

            Text(template.description)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(AppStyle.textTertiary)
                .lineLimit(3)

            Text(template.workbenchEndpointPreview)
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(AppStyle.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 5) {
                ForEach(template.tags.prefix(3), id: \.self) { tag in
                    ToolBadge(text: tag, color: AppStyle.textTertiary, style: .muted, height: 17)
                }
                Spacer(minLength: 0)
                ToolActionButton(
                    title: selectedTargetIDs.isEmpty ? L("选择应用") : L("安装到 %ld 个应用", selectedTargetIDs.count),
                    systemImage: "square.and.arrow.down",
                    height: 25,
                    fontSize: 11,
                    horizontalPadding: 10) {
                        store.installMCPTemplate(template, to: selectedTargetIDs)
                        showAddSheet = false
                    }
                    .disabled(selectedTargetIDs.isEmpty)
            }
        }
        .padding(11)
        .agentToolsGlass(cornerRadius: Radius.sm)
    }

    @ViewBuilder
    private var installContent: some View {
        targetSummaryBar
        customComposer
    }

    @ViewBuilder
    private var clientsContent: some View {
        targetSummaryBar
        targetApplicationList(compact: false)
    }

    private var targetSummaryBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "macwindow")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(AppStyle.accent)
            Text(selectedTargetSummary)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(AppStyle.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            ToolActionButton(title: L("全选"), systemImage: "checklist", height: 24, fontSize: 10.5, horizontalPadding: 8) {
                selectedTargetIDs = Set(AgentToolsMCPScanner.writableClients.map(\.id))
            }
            ToolActionButton(title: L("清空"), systemImage: "xmark.circle", height: 24, fontSize: 10.5, horizontalPadding: 8) {
                selectedTargetIDs.removeAll()
            }
            ToolActionButton(title: L("管理应用"), systemImage: "slider.horizontal.3", height: 24, fontSize: 10.5, horizontalPadding: 8) {
                withAnimation(AgentToolsMotion.route) { selectedSection = .clients }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .agentToolsGlass()
    }

    private var selectedTargetSummary: String {
        let names = AgentToolsMCPScanner.writableClients
            .filter { selectedTargetIDs.contains($0.id) }
            .map(\.displayName)
        if names.isEmpty { return L("还没有选择安装应用") }
        if names.count <= 3 { return L("安装到 %@", names.joined(separator: "、")) }
        return L("安装到 %@ 等 %ld 个应用", names.prefix(3).joined(separator: "、"), names.count)
    }

    private func targetApplicationList(compact: Bool) -> some View {
        LazyVStack(spacing: 7) {
            ForEach(AgentToolsMCPScanner.writableClients) { client in
                targetApplicationRow(client, compact: compact)
            }
        }
    }

    private func targetApplicationRow(_ client: AgentToolsMCPClientAdapter, compact: Bool) -> some View {
        let selected = selectedTargetIDs.contains(client.id)
        let count = configuredCount(for: client)
        let exists = FileManager.default.fileExists(atPath: client.expandedPath)
        return HStack(spacing: 10) {
            Image(systemName: mcpTargetIcon(client))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(selected ? AppStyle.accent : AppStyle.textTertiary)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill((selected ? AppStyle.accent : AppStyle.textTertiary).opacity(0.11)))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(client.displayName)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(AppStyle.textPrimary)
                        .lineLimit(1)
                    ToolBadge(text: exists ? L("已检测") : L("未创建"), color: exists ? AppStyle.doneGreen : AppStyle.textTertiary, style: .muted, height: 18)
                    ToolBadge(text: L("%ld Servers", count), color: count > 0 ? AppStyle.accent : AppStyle.textTertiary, style: .muted, height: 18)
                }
                if !compact {
                    Text(client.path)
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(AppStyle.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 0)

            if !compact {
                ToolActionButton(
                    title: L("编辑配置"),
                    systemImage: "curlybraces",
                    role: .primary,
                    height: 26, fontSize: 11, horizontalPadding: 11) {
                        editingClientJSON = client
                    }
                IconOnlyButton(systemName: "doc.text", help: L("打开配置文件"), size: 24, symbolSize: 10.5) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: client.expandedPath))
                }
                IconOnlyButton(systemName: "folder", help: L("在 Finder 中显示"), size: 24, symbolSize: 10.5) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: client.expandedPath)])
                }
            }

            Toggle(isOn: Binding(
                get: { selectedTargetIDs.contains(client.id) },
                set: { enabled in
                    if enabled { selectedTargetIDs.insert(client.id) }
                    else { selectedTargetIDs.remove(client.id) }
                }
            )) {
                Text(L("用于安装"))
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .toggleStyle(.switch)
            .labelsHidden()
            .help(selected ? L("会安装到 %@", client.displayName) : L("不会安装到 %@", client.displayName))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, compact ? 8 : 10)
        .agentToolsGlass(cornerRadius: Radius.sm)
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .stroke(selected ? AppStyle.accent.opacity(0.30) : Color.clear, lineWidth: 1))
    }

    private var targetPicker: some View {
        AgentToolsSection(L("部署目标")) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 7)], spacing: 7) {
                ForEach(AgentToolsMCPScanner.writableClients) { client in
                    Toggle(isOn: Binding(
                        get: { selectedTargetIDs.contains(client.id) },
                        set: { enabled in
                            if enabled { selectedTargetIDs.insert(client.id) }
                            else { selectedTargetIDs.remove(client.id) }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(client.displayName)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(AppStyle.textSecondary)
                            Text(client.path)
                                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(AppStyle.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .padding(10)
            .agentToolsGlass(cornerRadius: Radius.sm)
        }
    }

    private var customComposer: some View {
        let editing = editingServer != nil
        return AgentToolsSection(editing ? L("编辑 server（JSON）") : L("自定义 server（JSON）")) {
            VStack(alignment: .leading, spacing: 9) {
                if let editingServer {
                    ToolBadge(text: L("正在编辑 %@ · %@", editingServer.name, editingServer.client),
                              color: AppStyle.accent, style: .muted, height: 20)
                }
                Text(L("键是 server 名称，值是 command/args/env 或 url —— 直接贴 / 改这段 JSON。"))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(AppStyle.textTertiary)
                TextEditor(text: $customJSON)
                    .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(AppStyle.textPrimary)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 190)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                            .fill(AppStyle.hoverFill.opacity(0.82)))
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                            .strokeBorder(AppStyle.separator.opacity(0.16), lineWidth: 1))
                HStack(spacing: 8) {
                    if !editing {
                        ToolBadge(text: L("%ld 个应用", selectedTargetIDs.count), color: selectedTargetIDs.isEmpty ? AppStyle.waitAmber : AppStyle.accent, style: .muted, height: 20)
                    }
                    if parseCustomServerJSON() == nil && !customJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ToolBadge(text: L("JSON 无效"), color: AppStyle.errorRed, style: .muted, height: 20)
                    }
                    Spacer(minLength: 0)
                    if editing {
                        ToolActionButton(
                            title: L("取消"),
                            systemImage: "xmark",
                            height: 28, fontSize: 11, horizontalPadding: 10) {
                                cancelEditing()
                            }
                        ToolActionButton(
                            title: L("保存修改"),
                            systemImage: "checkmark",
                            height: 28, fontSize: 11, horizontalPadding: 10) {
                                saveEdit()
                            }
                            .disabled(!canSaveCustom)
                    } else {
                        ToolActionButton(
                            title: L("安装到选中应用"),
                            systemImage: "plus",
                            height: 28, fontSize: 11, horizontalPadding: 10) {
                                installCustomFromJSON()
                            }
                            .disabled(!canInstallCustom)
                    }
                }
            }
            .padding(10)
            .agentToolsGlass(cornerRadius: Radius.sm)
        }
    }

    /// 进入编辑：把该 server 的原始配置序列化成 `{ 名称: 配置 }` 回填 JSON 编辑器。
    private func beginEditing(_ server: AgentToolsMCPServerRecord) {
        let raw = store.mcpRawConfig(for: server) ?? [:]
        customJSON = Self.prettyJSON([server.name: raw]) ?? "{\n  \"\(server.name)\": {}\n}"
        editingServer = server
        addTab = .custom
        showAddSheet = true
    }

    private func saveEdit() {
        guard let editingServer, let parsed = parseCustomServerJSON() else { return }
        store.updateMCPServer(
            editingServer,
            newName: parsed.name,
            transport: parsed.transport,
            command: parsed.command,
            args: parsed.args,
            url: parsed.url,
            env: parsed.env)
        cancelEditing()
    }

    private func cancelEditing() {
        editingServer = nil
        resetComposer()
        showAddSheet = false
    }

    private func resetComposer() {
        customJSON = Self.customServerTemplate
    }

    /// 编辑模式：JSON 能解析出一个 server 即可（就地编辑在自己的 client，不要求选目标）。
    private var canSaveCustom: Bool { parseCustomServerJSON() != nil }

    private func textInput(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(AppStyle.textPrimary)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .fill(AppStyle.hoverFill.opacity(0.82)))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .strokeBorder(AppStyle.separator.opacity(0.16), lineWidth: 1))
    }

    private var canInstallCustom: Bool {
        !selectedTargetIDs.isEmpty && parseCustomServerJSON() != nil
    }

    /// 解析 JSON 编辑器：`{ "名称": { command/args/env… | url } }`，取首个条目。无效返回 nil。
    private typealias CustomServerSpec =
        (name: String, transport: AgentToolsMCPTransport, command: String, args: [String], url: String, env: [String: String])

    /// 解析自定义 JSON 里的**全部** server：支持裸 `{name:{}}`、也支持整块复制的
    /// `{"mcpServers": {...多条...}}` / `{"servers": {...}}` 信封。（旧实现取 `object.first`——
    /// 字典无序 → 多 server 时只随机装一条、静默丢其余。）
    private func parseAllCustomServers() -> [CustomServerSpec] {
        guard let data = customJSON.data(using: .utf8),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        for key in ["mcpServers", "servers"] {     // 信封：单键且内层是表 → 取内层
            if object.count == 1, let inner = object[key] as? [String: Any] { object = inner; break }
        }
        return object
            .compactMap { name, value -> CustomServerSpec? in
                guard let body = value as? [String: Any] else { return nil }
                return Self.parseServerEntry(name: name, body: body)
            }
            .sorted { $0.name < $1.name }           // 稳定顺序（字典无序 → 装入次序可预期）
    }

    /// 单条解析（编辑/校验/单装用）：取首条。
    private func parseCustomServerJSON() -> CustomServerSpec? { parseAllCustomServers().first }

    private static func parseServerEntry(name rawName: String, body: [String: Any]) -> CustomServerSpec? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let command = (body["command"] as? String) ?? ""
        let url = (body["url"] as? String) ?? ""
        let args = (body["args"] as? [Any])?.compactMap { $0 as? String } ?? []
        var env: [String: String] = [:]
        if let rawEnv = body["env"] as? [String: Any] {
            for (key, value) in rawEnv { env[key] = "\(value)" }
        }
        let typeHint = ((body["type"] as? String) ?? (body["transport"] as? String) ?? "").lowercased()
        let transport: AgentToolsMCPTransport = typeHint == "sse" ? .sse
            : (!url.isEmpty || typeHint == "http") ? .http : .stdio
        guard !command.isEmpty || !url.isEmpty else { return nil }
        return (name, transport, command, args, url, env)
    }

    private func installCustomFromJSON() {
        let servers = parseAllCustomServers()
        guard !servers.isEmpty else { return }
        for s in servers {
            store.installCustomMCPServer(
                name: s.name, transport: s.transport, command: s.command,
                args: s.args, url: s.url, env: s.env, to: selectedTargetIDs)
        }
        resetComposer()
        showAddSheet = false
    }

    private static let customServerTemplate = """
    {
      "my-server": {
        "command": "npx",
        "args": ["-y", "@modelcontextprotocol/server-name"]
      }
    }
    """

    private static func prettyJSON(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private var addSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text(editingServer == nil ? L("添加 MCP Server") : L("编辑 MCP Server"))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(AppStyle.textPrimary)
                Spacer()
                IconOnlyButton(systemName: "xmark", help: L("关闭"), size: 28, symbolSize: 12, weight: .bold) {
                    showAddSheet = false
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if editingServer == nil {
                Picker("", selection: $addTab) {
                    ForEach(AgentToolsMCPAddTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if editingServer == nil { targetPicker }
                    if editingServer == nil && addTab == .template {
                        libraryContent
                    } else {
                        customComposer
                    }
                }
                .padding(16)
            }
            .scrollIndicators(.never)
        }
        .frame(width: 640, height: 580)
        .background(AppStyle.windowBackground)
    }

    private var serverMetricLine: String {
        let total = store.mcpServers.count
        let clients = Set(store.mcpServers.map(\.client)).count
        let remote = store.mcpServers.filter { $0.transport == .http || $0.transport == .sse }.count
        let env = store.mcpServers.filter { $0.envKeyCount > 0 }.count
        return "\(total) servers · \(clients) " + L("应用") + " · \(remote) " + L("远程") + " · \(env) env"
    }

    private var serversContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ToolsSectionLabel("MCP Servers")
                Spacer()
                Text(serverMetricLine)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(AppStyle.textTertiary)
            }

            VStack(spacing: 0) {
                tableHeader
                LazyVStack(spacing: 1) {
                    ForEach(filteredServers) { server in
                        serverRow(server)
                    }
                    if filteredServers.isEmpty {
                        emptyState
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .agentToolsGlass()

            if let error = store.mcpScanError {
                ToolBadge(text: error, color: AppStyle.errorRed, style: .muted, height: 22)
            }
        }
        .confirmationDialog(
            L("移除 MCP server？"),
            isPresented: Binding(
                get: { serverPendingDelete != nil },
                set: { if !$0 { serverPendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: serverPendingDelete
        ) { server in
            Button(L("移除 %@", server.name), role: .destructive) {
                if editingServer?.id == server.id { cancelEditing() }
                store.removeMCPServer(server)
                serverPendingDelete = nil
            }
            Button(L("取消"), role: .cancel) { serverPendingDelete = nil }
        } message: { server in
            Text(L("将从 %@ 的配置文件删除该 server，不可撤销。如只想临时关闭，请改用「停用」。", server.client))
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 8) {
            Text("Server").frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
            Text(L("客户端")).frame(width: 112, alignment: .leading)
            Text(L("传输")).frame(width: 70, alignment: .leading)
            Text(L("入口")).frame(width: 150, alignment: .leading)
            Text(L("操作")).frame(width: 96, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(AppStyle.textTertiary)
        .padding(.horizontal, 9)
        .frame(height: 28)
    }

    private func serverRow(_ server: AgentToolsMCPServerRecord) -> some View {
        let selected = store.selectedMCPServerID == server.id
        return Button {
            withAnimation(AgentToolsMotion.selection) { store.selectedMCPServerID = server.id }
        } label: {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: server.transport == .stdio ? "terminal" : "network")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(mcpWorkbenchTransportColor(server.transport))
                        .frame(width: 24, height: 24)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(mcpWorkbenchTransportColor(server.transport).opacity(0.12)))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(server.name)
                                .font(.system(size: 12.5, weight: .bold))
                                .foregroundStyle(AppStyle.textPrimary)
                                .lineLimit(1)
                            if !server.enabled {
                                ToolBadge(text: L("已停用"), color: AppStyle.textTertiary, style: .muted, height: 15)
                            }
                        }
                        Text(server.sourceKeyPath)
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(AppStyle.textTertiary)
                            .lineLimit(1)
                    }
                }
                .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)

                Text(server.client)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppStyle.textSecondary)
                    .lineLimit(1)
                    .frame(width: 112, alignment: .leading)

                ToolBadge(text: server.transport.title, color: mcpWorkbenchTransportColor(server.transport), style: .muted, height: 18)
                    .frame(width: 70, alignment: .leading)

                Text(server.endpointLabel)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppStyle.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 150, alignment: .leading)

                HStack(spacing: 2) {
                    IconOnlyButton(
                        systemName: server.enabled ? "pause.circle" : "play.circle",
                        help: server.enabled ? L("停用") : L("启用"),
                        size: 24,
                        symbolSize: 11.5,
                        tint: server.enabled ? AppStyle.waitAmber : AppStyle.doneGreen) {
                            store.setMCPServerEnabled(server, enabled: !server.enabled)
                        }
                    IconOnlyButton(
                        systemName: "square.and.pencil",
                        help: L("编辑"),
                        size: 24,
                        symbolSize: 10.5) {
                            beginEditing(server)
                        }
                        .disabled(!server.enabled)
                    IconOnlyButton(
                        systemName: "trash",
                        help: L("移除 MCP server"),
                        size: 24,
                        symbolSize: 10.5,
                        tint: AppStyle.errorRed) {
                            serverPendingDelete = server
                        }
                }
                .frame(width: 96, alignment: .trailing)
            }
            .padding(.horizontal, 9)
            .frame(height: AgentToolsChrome.rowHeight)
            .opacity(server.enabled ? 1 : 0.55)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .fill(selected ? AppStyle.accent.opacity(0.12) : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(AppStyle.textTertiary)
            Text(L("未发现 MCP servers"))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(AppStyle.textPrimary)
            Text(L("支持扫描 Claude Desktop、Claude Code、Codex、Cursor、VS Code 和 Windsurf 的常见 MCP 配置。"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppStyle.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }

    @ViewBuilder
    private var diagnosticsContent: some View {
        AgentToolsSection(L("配置文件")) {
            LazyVStack(spacing: 7) {
                ForEach(AgentToolsMCPScanner.writableClients) { client in
                    configFileRow(client)
                }
            }
            .padding(10)
            .agentToolsGlass(cornerRadius: Radius.sm)
        }

        AgentToolsSection(L("诊断")) {
            VStack(alignment: .leading, spacing: 9) {
                AgentToolsInfoRow(label: "Servers", value: "\(store.mcpServers.count)")
                AgentToolsInfoRow(label: L("客户端"), value: "\(Set(store.mcpServers.map(\.client)).count)")
                AgentToolsInfoRow(label: L("远程"), value: "\(store.mcpServers.filter { $0.transport == .http || $0.transport == .sse }.count)")
                AgentToolsInfoRow(label: "Env", value: "\(store.mcpServers.filter { $0.envKeyCount > 0 }.count)")
                if let error = store.mcpScanError {
                    Text(error)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(AppStyle.errorRed)
                        .lineLimit(6)
                        .textSelection(.enabled)
                }
                HStack(spacing: 8) {
                    ToolActionButton(title: L("复制摘要"), systemImage: "doc.on.doc", height: 28, fontSize: 11, horizontalPadding: 10) {
                        store.copyText(mcpSummaryText)
                    }
                    ToolActionButton(title: L("重新扫描"), systemImage: "arrow.clockwise", height: 28, fontSize: 11, horizontalPadding: 10) {
                        store.refreshMCP()
                    }
                    .disabled(store.isScanningMCP)
                }
            }
            .padding(10)
            .agentToolsGlass(cornerRadius: Radius.sm)
        }
    }

    private var mcpSummaryText: String {
        var lines = [
            "Conductor MCP Summary",
            "servers: \(store.mcpServers.count)",
            "clients: \(Set(store.mcpServers.map(\.client)).count)",
            "targets.selected: \(selectedTargetIDs.count)",
        ]
        for server in store.mcpServers {
            lines.append("- \(server.client) / \(server.name) / \(server.transport.title) / \(server.endpointLabel)")
        }
        if let error = store.mcpScanError {
            lines.append("error: \(error)")
        }
        return lines.joined(separator: "\n")
    }

    private func configFileRow(_ client: AgentToolsMCPClientAdapter) -> some View {
        let exists = FileManager.default.fileExists(atPath: client.expandedPath)
        return HStack(spacing: 8) {
            Image(systemName: exists ? "doc.text" : "doc.badge.plus")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(exists ? AppStyle.accent : AppStyle.textTertiary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(client.displayName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(AppStyle.textSecondary)
                Text(client.path)
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppStyle.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            ToolBadge(text: exists ? L("存在") : L("未创建"), color: exists ? AppStyle.doneGreen : AppStyle.textTertiary, style: .muted, height: 18)
            IconOnlyButton(systemName: "folder", help: L("在 Finder 中显示"), size: 24, symbolSize: 10.5) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: client.expandedPath)])
            }
        }
    }

    private func configuredCount(for client: AgentToolsMCPClientAdapter) -> Int {
        store.mcpServers.filter { $0.client == client.displayName }.count
    }

    private func mcpTargetIcon(_ client: AgentToolsMCPClientAdapter) -> String {
        switch client.id {
        case "claude_desktop", "claude_code": return "sparkles"
        case "codex": return "terminal"
        case "cursor": return "cursorarrow"
        case "vscode": return "chevron.left.forwardslash.chevron.right"
        case "windsurf": return "wind"
        default: return "macwindow"
        }
    }
}

private extension AgentToolsMCPTemplate {
    var workbenchEndpointPreview: String {
        if let url, !url.isEmpty { return url }
        if let command, !command.isEmpty {
            return ([command] + args).joined(separator: " ")
        }
        return "-"
    }
}

@MainActor private func mcpWorkbenchTransportColor(_ transport: AgentToolsMCPTransport) -> Color {
    switch transport {
    case .stdio: return AppStyle.accent
    case .http: return AppStyle.doneGreen
    case .sse: return AppStyle.waitAmber
    case .unknown: return AppStyle.textTertiary
    }
}

func mcpWorkbenchSplitArgs(_ text: String) -> [String] {
    text.split(whereSeparator: \.isWhitespace).map(String.init)
}

/// 把原始 env 字典格式化回 "KEY=value, KEY2=value2"（编辑回填用）。
func mcpWorkbenchFormatEnv(_ env: [String: Any]) -> String {
    env.keys.sorted().map { key in
        let value = env[key]
        return "\(key)=\(value.map { "\($0)" } ?? "")"
    }.joined(separator: ", ")
}

func mcpWorkbenchParseEnv(_ text: String) -> [String: String] {
    var result: [String: String] = [:]
    for raw in text.split(separator: ",") {
        let pair = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let equals = pair.firstIndex(of: "=") else { continue }
        let key = String(pair[..<equals]).trimmingCharacters(in: .whitespacesAndNewlines)
        let value = String(pair[pair.index(after: equals)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { continue }
        result[key] = value
    }
    return result
}
