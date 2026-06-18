import AppKit
import ConductorCore
import Foundation
import UserNotifications

/// 原生通知封装，分层降级：
/// - 已授权 `UNUserNotificationCenter`：富通知 + 点击回调跳回对应 pane（最佳）；
/// - 未授权 / 无 bundle id（swift run）：回退 `osascript` 横幅，仍能看到提醒（无法点击跳转）。
///
/// 注意：ad-hoc 签名的本地 app 在部分 macOS 上会被自动拒绝通知授权（不弹框）。
/// 这时用户可在「系统设置 › 通知 › conductor」手动打开，即可恢复点击跳转。
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    /// 点击通知后请求聚焦的 pane（paneID 字符串）。由 AppCoordinator 注入。
    var onActivatePane: ((String) -> Void)?

    /// 每条通知的旁路出口（原始 paneID/title/body，未清洗）——给桌宠等消费者用来
    /// 显示「AI 会话通知」的真实内容（系统通知本身仍走清洗后的 title/body）。
    /// `@MainActor`：调用方编译期就被钉在主线程，消费者无需 `assumeIsolated`（那是会崩的硬前置）。
    var onNotify: (@MainActor (_ paneID: String?, _ title: String, _ body: String) -> Void)?

    /// 是否有 bundle id（能用 UNUserNotificationCenter）。
    private var hasBundle = false
    /// 最近一次已知的授权状态。
    private(set) var authStatus: UNAuthorizationStatus = .notDetermined

    /// 能否用富通知（点击跳转）。
    var canDeliverRich: Bool {
        hasBundle && (authStatus == .authorized || authStatus == .provisional)
    }

    func configure() {
        guard Bundle.main.bundleIdentifier != nil else {
            hasBundle = false
            NSLog("[conductor] 无 bundle id（裸二进制），通知走 osascript 回退。打包成 conductor.app 可启用点击跳转。")
            return
        }
        hasBundle = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            if let error { NSLog("[conductor] 通知授权请求出错：\(error.localizedDescription)") }
            Task { @MainActor in self?.refreshAuthStatus() }
        }
        refreshAuthStatus()
    }

    func refreshAuthStatus() {
        guard hasBundle else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor in self.authStatus = settings.authorizationStatus }
        }
    }

    /// 发送一条通知。优先富通知（带 paneID 用于点击跳转），否则回退 osascript 横幅。
    /// 文案统一清洗：标题截断；body 若是成段内容（agent 把整段回复经 OSC 塞进来）
    /// 则换成通用提示——内容本身留在终端和活动账本里，通知只负责提醒。
    func notify(paneID: String?, title rawTitle: String, body rawBody: String,
                bodyFallback: String? = nil) {
        onNotify?(paneID, rawTitle, rawBody)   // 旁路：桌宠拿原始内容显示真实会话通知
        // 系统横幅：系统通知开则发；系统关但伙伴开且宠物隐藏 → 回退横幅别丢通知；都关 → 静默。
        let companion = ConfigStore.shared.config.companion
        guard CompanionConfig.shouldDeliverSystemBanner(
            notifySystem: companion.notifySystem, notifyPet: companion.notifyPet,
            petVisible: companion.enabled) else { return }
        let title = NotificationText.title(rawTitle)
        let body = NotificationText.body(rawBody, fallback: bodyFallback ?? L("有新结果，点击查看"))
        if canDeliverRich {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            if let paneID, !paneID.isEmpty { content.userInfo = ["paneID": paneID] }
            let request = UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { [weak self] error in
                if error != nil {
                    Task { @MainActor in self?.deliverFallback(title: title, body: body) }
                }
            }
        } else {
            deliverFallback(title: title, body: body)
        }
    }

    /// osascript 横幅回退（无点击跳转）。
    private func deliverFallback(title: String, body: String) {
        let script = "display notification \"\(Self.escape(body))\" with title \"\(Self.escape(title))\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        DispatchQueue.global(qos: .utility).async { try? process.run() }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// 打开「系统设置 › 通知」，引导用户为 conductor 开启通知（恢复点击跳转）。
    func openSystemNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void)
    {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void)
    {
        let paneID = response.notification.request.content.userInfo["paneID"] as? String
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            if let paneID { self.onActivatePane?(paneID) }
        }
        completionHandler()
    }
}
