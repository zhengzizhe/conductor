import Foundation

/// 路径显示工具：把绝对路径压成给人看的短串。集中一处，避免各 UI 文件各写一版
/// （此前 compactPath / collapsedPath / 内联 abbreviatingWithTildeInPath 各有实现）。
public enum PathDisplay {
    /// 家目录前缀替换成 `~`，其余原样。
    public static func tilde(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// 末段目录名（家目录返回 `~`，空则原样）。供 pane 标题等用。
    public static func lastComponent(_ path: String) -> String {
        if path == FileManager.default.homeDirectoryForCurrentUser.path { return "~" }
        let base = (path as NSString).lastPathComponent
        return base.isEmpty ? path : base
    }
}
