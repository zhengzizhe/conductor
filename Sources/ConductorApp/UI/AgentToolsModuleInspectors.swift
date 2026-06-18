import AppKit
import ConductorCore
import SwiftUI

struct AgentToolsMCPInspector: View {
    @ObservedObject var store: AgentToolsConsoleStore
    @State private var pendingDelete: AgentToolsMCPServerRecord?

    var body: some View {
        AgentToolsInspectorShell {
            if let server = store.selectedMCPServer {
                selectedServer(server)
            } else {
                defaultState
            }
        }
        .confirmationDialog(
            L("移除 MCP server？"),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { server in
            Button(L("移除 %@", server.name), role: .destructive) {
                store.removeMCPServer(server)
                pendingDelete = nil
            }
            Button(L("取消"), role: .cancel) { pendingDelete = nil }
        } message: { server in
            Text(L("将从 %@ 的配置文件删除该 server，不可撤销。如只想临时关闭，请改用「停用」。", server.client))
        }
    }

    private var defaultState: some View {
        VStack(alignment: .leading, spacing: 12) {
            AgentToolsSection("MCP") {
                AgentToolsInfoRow(label: "Servers", value: "\(store.mcpServers.count)")
                AgentToolsInfoRow(label: L("客户端"), value: "\(Set(store.mcpServers.map(\.client)).count)")
                AgentToolsInfoRow(
                    label: L("远程"),
                    value: "\(store.mcpServers.filter { $0.transport == .http || $0.transport == .sse }.count)")
            }
            Text(L("选择一个 MCP server 查看命令、URL、配置来源和诊断信息。"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppStyle.textTertiary)
                .lineSpacing(3)
        }
    }

    private func selectedServer(_ server: AgentToolsMCPServerRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: server.transport == .stdio ? "terminal" : "network")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(mcpInspectorTransportColor(server.transport))
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(mcpInspectorTransportColor(server.transport).opacity(0.12)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name)
                        .font(.system(size: 14.5, weight: .bold))
                        .foregroundStyle(AppStyle.textPrimary)
                        .lineLimit(1)
                    Text(server.client)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(AppStyle.textTertiary)
                }
            }

            AgentToolsSection(L("基础信息")) {
                AgentToolsInfoRow(label: L("状态"), value: server.enabled ? L("启用中") : L("已停用"))
                AgentToolsInfoRow(label: L("传输"), value: server.transport.title)
                AgentToolsInfoRow(label: L("命令"), value: server.command ?? "-", monospaced: true)
                AgentToolsInfoRow(label: "URL", value: server.url ?? "-", monospaced: true)
                AgentToolsInfoRow(label: "Env", value: L("%ld 个键", server.envKeyCount))
            }

            AgentToolsSection(L("配置来源")) {
                AgentToolsInfoRow(label: L("客户端"), value: server.client)
                AgentToolsInfoRow(label: L("路径"), value: server.configPath, monospaced: true)
                AgentToolsInfoRow(label: "Key", value: server.sourceKeyPath, monospaced: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                AgentToolsLinkButton(title: L("打开配置文件"), icon: "doc.text") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: server.configPath))
                }
                AgentToolsLinkButton(title: L("在 Finder 中显示"), icon: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: server.configPath)])
                }
                AgentToolsLinkButton(title: L("复制诊断信息"), icon: "doc.on.doc") {
                    store.copyText(diagnostics(for: server))
                }
                AgentToolsLinkButton(
                    title: server.enabled ? L("停用该 server") : L("启用该 server"),
                    icon: server.enabled ? "pause.circle" : "play.circle",
                    tint: server.enabled ? AppStyle.waitAmber : AppStyle.doneGreen) {
                        store.setMCPServerEnabled(server, enabled: !server.enabled)
                    }
                AgentToolsLinkButton(title: L("移除 MCP server"), icon: "trash", tint: AppStyle.errorRed) {
                    pendingDelete = server
                }
            }
        }
    }

    private func diagnostics(for server: AgentToolsMCPServerRecord) -> String {
        [
            "Conductor MCP Diagnostics",
            "name: \(server.name)",
            "client: \(server.client)",
            "transport: \(server.transport.title)",
            "command: \(server.command ?? "-")",
            "args: \(server.args.joined(separator: " "))",
            "url: \(server.url ?? "-")",
            "env.keys: \(server.envKeyCount)",
            "config.path: \(server.configPath)",
            "config.key: \(server.sourceKeyPath)",
        ].joined(separator: "\n")
    }
}

struct AgentToolsHooksInspector: View {
    @ObservedObject var store: AgentToolsConsoleStore
    @State private var pendingDelete: HookEntry?

    var body: some View {
        AgentToolsInspectorShell {
            if let entry = store.selectedHookEntry {
                selectedHook(entry)
            } else {
                defaultState
            }
        }
        .confirmationDialog(
            L("移除 hook？"),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { entry in
            Button(L("移除"), role: .destructive) {
                store.removeHookEntry(entry)
                pendingDelete = nil
            }
            Button(L("取消"), role: .cancel) { pendingDelete = nil }
        } message: { entry in
            Text(L("将从 %@ 的 %@ 事件删除该 hook，不可撤销。如只想临时关闭，请改用「停用」。",
                   entry.source.displayName, entry.event))
        }
    }

    private var defaultState: some View {
        VStack(alignment: .leading, spacing: 12) {
            AgentToolsSection("Hooks") {
                AgentToolsInfoRow(label: L("总数"), value: "\(store.hookEntries.count)")
                AgentToolsInfoRow(label: "Conductor", value: "\(store.hookEntries.filter(\.managedByConductor).count)")
                AgentToolsInfoRow(label: L("配方"), value: "\(HookRecipes.all.count)")
                AgentToolsInfoRow(label: L("已安装"), value: "\(store.hookRecipeStates.values.reduce(0) { $0 + $1.count })")
            }

            AgentToolsSection(L("配置文件")) {
                ForEach(HookSource.allCases, id: \.self) { source in
                    AgentToolsLinkButton(title: L("%@ 配置", source.displayName), icon: "doc.text") {
                        NSWorkspace.shared.open(source.configURL)
                    }
                }
            }
        }
    }

    private func selectedHook(_ entry: HookEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: hooksInspectorEventIcon(entry.event))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(entry.managedByConductor ? AppStyle.accent : AppStyle.textTertiary)
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill((entry.managedByConductor ? AppStyle.accent : AppStyle.textTertiary).opacity(0.12)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(hooksInspectorTitle(entry))
                        .font(.system(size: 14.5, weight: .bold))
                        .foregroundStyle(AppStyle.textPrimary)
                        .lineLimit(1)
                    Text(entry.event)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(AppStyle.textTertiary)
                }
            }

            AgentToolsSection(L("基础信息")) {
                AgentToolsInfoRow(label: L("状态"), value: entry.enabled ? L("启用中") : L("已停用"))
                AgentToolsInfoRow(label: L("来源"), value: entry.source.displayName)
                AgentToolsInfoRow(label: L("事件"), value: entry.event, monospaced: true)
                AgentToolsInfoRow(label: L("超时"), value: entry.timeout.map { L("%ld ms", $0) } ?? "-")
                AgentToolsInfoRow(label: L("管理"), value: entry.managedByConductor ? "Conductor" : L("自定义"))
            }

            AgentToolsSection(L("命令")) {
                Text(entry.command)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppStyle.textSecondary)
                    .lineLimit(8)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: 8) {
                AgentToolsLinkButton(title: L("复制命令"), icon: "doc.on.doc") {
                    store.copyText(entry.command)
                }
                AgentToolsLinkButton(title: L("打开配置文件"), icon: "doc.text") {
                    NSWorkspace.shared.open(entry.source.configURL)
                }
                AgentToolsLinkButton(title: L("复制诊断信息"), icon: "doc.on.doc") {
                    store.copyText(diagnostics(for: entry))
                }
                AgentToolsLinkButton(
                    title: entry.enabled ? L("停用该 hook") : L("启用该 hook"),
                    icon: entry.enabled ? "pause.circle" : "play.circle",
                    tint: entry.enabled ? AppStyle.waitAmber : AppStyle.doneGreen) {
                        store.setHookEntryEnabled(entry, enabled: !entry.enabled)
                    }
                AgentToolsLinkButton(title: L("移除该 hook"), icon: "trash", tint: AppStyle.errorRed) {
                    pendingDelete = entry
                }
            }
        }
    }

    private func diagnostics(for entry: HookEntry) -> String {
        [
            "Conductor Hook Diagnostics",
            "source: \(entry.source.displayName)",
            "event: \(entry.event)",
            "managed: \(entry.managedByConductor)",
            "timeout: \(entry.timeout.map(String.init) ?? "-")",
            "config.path: \(entry.source.configURL.path)",
            "command: \(entry.command)",
        ].joined(separator: "\n")
    }
}

@MainActor private func mcpInspectorTransportColor(_ transport: AgentToolsMCPTransport) -> Color {
    switch transport {
    case .stdio: return AppStyle.accent
    case .http: return AppStyle.doneGreen
    case .sse: return AppStyle.waitAmber
    case .unknown: return AppStyle.textTertiary
    }
}

private func hooksInspectorEventIcon(_ event: String) -> String {
    switch event {
    case HookEventName.stop: return "stop.circle"
    case HookEventName.sessionStart: return "play.circle"
    case HookEventName.userPromptSubmit: return "paperplane"
    case HookEventName.subagentStop: return "person.2"
    case HookEventName.notification: return "bell"
    default: return "link"
    }
}

private func hooksInspectorTitle(_ entry: HookEntry) -> String {
    if entry.command.contains("#conductor:notify") { return L("完成通知") }
    if entry.command.contains("#conductor:sound") { return L("完成提示音") }
    if entry.command.contains("#conductor:banner") { return L("系统横幅") }
    if entry.command.contains("#conductor:log") { return L("完成日志") }
    if entry.managedByConductor { return L("Conductor hook") }
    return L("自定义命令")
}
