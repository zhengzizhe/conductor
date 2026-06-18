import ConductorCore
import Foundation

/// 手动拉取 Codex 用量，供状态栏常驻显示。启动应用不会主动请求账号数据。
@MainActor
final class UsageMonitor: ObservableObject {
    @Published private(set) var codex: CodexUsageSnapshot?
    @Published private(set) var codexError: String?
    @Published private(set) var isRefreshing = false

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            do {
                let snap = try await CodexUsageFetcher.fetch()
                self.codex = snap
                self.codexError = nil
            } catch {
                self.codexError = error.localizedDescription
            }
            self.isRefreshing = false
        }
    }

}
