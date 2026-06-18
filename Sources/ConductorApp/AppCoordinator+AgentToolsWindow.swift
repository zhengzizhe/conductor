import AppKit
import Combine
import ConductorCore
import SwiftUI

// Agent Tools 管理台的独立窗口承载。
// 单独成文件：这里要 import SwiftUI（NSHostingController），而 AppCoordinator.swift 里有自定义
// `Tab` 模型，import SwiftUI 会和 SwiftUI.Tab 撞名，故把 SwiftUI 相关逻辑隔到本扩展。
@MainActor
extension AppCoordinator {
    /// 构造管理台 SwiftUI 视图（每次取最新运行时快照，配合 objectWillChange 订阅保持实时）。
    func makeAgentToolsConsoleView() -> AgentToolsManagementConsoleView {
        AgentToolsManagementConsoleView(
            initialModule: agentToolsManagementModule,
            onLaunchCLI: { [weak self] command in
                self?.launchAgent(command: command)
                self?.closeAgentToolsManagement()
            },
            onApplyConfig: { [weak self] in self?.applyConfig($0) },
            onClose: { [weak self] in self?.closeAgentToolsManagement() })
    }

    func showAgentToolsWindow() {
        let hosting: NSHostingController<AgentToolsManagementConsoleView>
        if let controller = agentToolsWindowController,
           let existing = controller.contentViewController as? NSHostingController<AgentToolsManagementConsoleView> {
            existing.rootView = makeAgentToolsConsoleView()   // 切到选中模块
            hosting = existing
        } else {
            hosting = NSHostingController(rootView: makeAgentToolsConsoleView())
            let size = AgentToolsConsoleLayout.modalSize()
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.contentViewController = hosting
            window.title = L("Agent Tools 管理台")
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.setContentSize(size)
            window.center()
            window.setFrameAutosaveName("AgentToolsConsoleWindow")
            agentToolsWindowController = NSWindowController(window: window)
            // 点窗口红灯关闭 → 同步状态、停订阅。
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.handleAgentToolsWindowClosed() }
            }
        }
        // 每次打开都(重)绑实时刷新：窗口开着时 coordinator 状态变化 → 重建 rootView，
        // 运行时数据保持实时；@State（选中模块等）随 rootView 原地更新得以保留。
        agentToolsRefreshCancellable = objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self, weak hosting] _ in
                guard let self, let hosting, self.agentToolsWindowController != nil else { return }
                hosting.rootView = self.makeAgentToolsConsoleView()
            }
        agentToolsWindowController?.showWindow(nil)
        agentToolsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
