import Foundation
import ConductorCore

/// 工作区侧栏元数据中枢：自动化（socket `workspace.status.*` / `workspace.progress.*` / `workspace.log.*`）写入的
/// 状态指示 / 进度条 / 日志流，按 WorkspaceID 组织，供侧栏行与自动化读回。
@MainActor
final class WorkspaceMetadataCenter: ObservableObject {
    struct StatusChip: Equatable, Identifiable {
        var key: String
        var text: String
        var color: String?      // 十六进制 "#34c759"，nil 用主题色
        var icon: String?       // SF Symbol 名
        var updatedAt: Date
        var id: String { key }
    }

    struct ProgressInfo: Equatable {
        var value: Double       // 0–1
        var label: String?
        var updatedAt: Date
    }

    struct LogEntry: Equatable, Identifiable {
        let id = UUID()
        var time: Date
        var level: String       // info | warn | error | debug
        var source: String?
        var text: String

        static func == (lhs: LogEntry, rhs: LogEntry) -> Bool { lhs.id == rhs.id }
    }

    @Published private(set) var statusChips: [WorkspaceID: [StatusChip]] = [:]
    @Published private(set) var progress: [WorkspaceID: ProgressInfo] = [:]
    @Published private(set) var logs: [WorkspaceID: [LogEntry]] = [:]
    /// 每个工作区的日志上限（环形截断）。
    private static let maxLogEntries = 500

    func setStatus(workspace: WorkspaceID, key: String, text: String,
                   color: String?, icon: String?) {
        var chips = statusChips[workspace] ?? []
        let chip = StatusChip(key: key, text: text, color: color, icon: icon, updatedAt: Date())
        if let index = chips.firstIndex(where: { $0.key == key }) {
            chips[index] = chip
        } else {
            chips.append(chip)
        }
        statusChips[workspace] = chips
    }

    func clearStatus(workspace: WorkspaceID, key: String?) {
        if let key {
            statusChips[workspace]?.removeAll { $0.key == key }
            if statusChips[workspace]?.isEmpty == true { statusChips.removeValue(forKey: workspace) }
        } else {
            statusChips.removeValue(forKey: workspace)
        }
    }

    func statuses(for workspace: WorkspaceID) -> [StatusChip] {
        statusChips[workspace] ?? []
    }

    func setProgress(workspace: WorkspaceID, value: Double, label: String?) {
        progress[workspace] = ProgressInfo(value: min(max(value, 0), 1),
                                           label: label, updatedAt: Date())
    }

    func clearProgress(workspace: WorkspaceID) {
        progress.removeValue(forKey: workspace)
    }

    func appendLog(workspace: WorkspaceID, text: String, level: String, source: String?) {
        var entries = logs[workspace] ?? []
        entries.append(LogEntry(time: Date(), level: level, source: source, text: text))
        if entries.count > Self.maxLogEntries {
            entries.removeFirst(entries.count - Self.maxLogEntries)
        }
        logs[workspace] = entries
    }

    func logs(for workspace: WorkspaceID, limit: Int) -> [LogEntry] {
        let all = logs[workspace] ?? []
        return Array(all.suffix(max(0, limit)))
    }

    func clearLog(workspace: WorkspaceID) {
        logs.removeValue(forKey: workspace)
    }

    /// 工作区被删除时清掉它名下所有元数据。
    func forget(workspace: WorkspaceID) {
        statusChips.removeValue(forKey: workspace)
        progress.removeValue(forKey: workspace)
        logs.removeValue(forKey: workspace)
    }
}
