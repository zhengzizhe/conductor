import AppKit

@MainActor
enum WindowChromePolicy {
    static func applyMainWindowChrome(to window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        // 外壳毛玻璃：窗口本身透明，背后的 NSVisualEffectView 透出模糊桌面；
        // 终端区由其 AppKit 容器画实色覆盖，保持可读。
        window.isOpaque = false
        window.backgroundColor = .clear
    }
}
