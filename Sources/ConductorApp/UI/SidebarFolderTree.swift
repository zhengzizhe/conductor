import AppKit
import SwiftUI

// MARK: - 纯逻辑（可单测）

/// 侧栏文件夹树拍平后的一行。
struct FolderTreeRow: Identifiable, Equatable {
    let name: String
    let path: String
    let depth: Int
    let isExpanded: Bool
    var isDirectory: Bool = true
    var isGitRepo: Bool = false

    var id: String { path }
}

/// 树 → 行数组的拍平逻辑：根路径 + 已展开集合 + 子项缓存（按需加载，可含文件）。
enum FolderTreeFlattener {
    static func rows(root: String, rootName: String,
                     expanded: Set<String>,
                     children: [String: [FileBrowserEntry]],
                     rootIsGitRepo: Bool = false) -> [FolderTreeRow] {
        var out: [FolderTreeRow] = []
        func visit(name: String, path: String, depth: Int, isDirectory: Bool, isGitRepo: Bool) {
            // 文件不可展开，永远是叶子
            let isExpanded = isDirectory && expanded.contains(path)
            out.append(FolderTreeRow(name: name, path: path, depth: depth,
                                     isExpanded: isExpanded,
                                     isDirectory: isDirectory, isGitRepo: isGitRepo))
            guard isExpanded else { return }
            for child in children[path] ?? [] {
                visit(name: child.name, path: child.path, depth: depth + 1,
                      isDirectory: child.isDirectory, isGitRepo: child.isGitRepo)
            }
        }
        visit(name: rootName, path: root, depth: 0, isDirectory: true, isGitRepo: rootIsGitRepo)
        return out
    }
}

// MARK: - 状态

/// 侧栏文件夹树状态：展开集合（跨启动持久化）+ 子项懒加载缓存 + 隐藏项/文件开关。
@MainActor
final class FolderTreeModel: ObservableObject {
    private static let expandedKey = "sidebar.folderTree.expanded"
    private static let showHiddenKey = "sidebar.folderTree.showHidden"
    private static let showFilesKey = "sidebar.folderTree.showFiles"

    /// 一次「定位」请求：目标路径 + 单调递增 tick（同一路径连点两次也要再滚一次）。
    struct RevealRequest: Equatable {
        let path: String
        let tick: Int
    }

    let root = FileManager.default.homeDirectoryForCurrentUser.path
    @Published private(set) var expanded: Set<String>
    @Published private(set) var children: [String: [FileBrowserEntry]] = [:]
    @Published private(set) var showHidden: Bool
    @Published private(set) var showFiles: Bool
    /// 待滚动到的目标（视图侧 onChange 消费）。
    @Published private(set) var revealRequest: RevealRequest?
    /// 定位后短暂高亮的行路径。
    @Published private(set) var highlighted: String?
    private var highlightClearWork: DispatchWorkItem?

    /// 根目录的 git 标记算一次缓存住（rows 每次 body 求值都会跑，别反复 stat）。
    private let rootIsGitRepo: Bool

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: Self.expandedKey) ?? []
        showHidden = UserDefaults.standard.bool(forKey: Self.showHiddenKey)
        // 默认显示文件（object(forKey:) 为 nil 时取 true，bool(forKey:) 默认 false 不合适）
        showFiles = UserDefaults.standard.object(forKey: Self.showFilesKey) as? Bool ?? true
        rootIsGitRepo = FileManager.default.fileExists(
            atPath: (root as NSString).appendingPathComponent(".git"))
        // 只恢复仍然存在的目录（被删/改名的丢弃），根目录始终展开。
        var restored = Set(saved.filter { FileManager.default.fileExists(atPath: $0) })
        restored.insert(root)
        expanded = restored
        for path in restored { loadChildren(of: path) }
    }

    var rows: [FolderTreeRow] {
        FolderTreeFlattener.rows(root: root, rootName: "~", expanded: expanded,
                                 children: children, rootIsGitRepo: rootIsGitRepo)
    }

    func toggle(_ path: String) {
        if expanded.contains(path), path != root {
            expanded.remove(path)
        } else {
            expanded.insert(path)
            // 重新进入时刷新一次，目录内容可能已变
            loadChildren(of: path)
        }
        persistExpanded()
    }

    /// 重新读取某目录（及其已展开后代）的子项列表。
    func refresh(_ path: String) {
        loadChildren(of: path)
        for sub in expanded where sub.hasPrefix(path + "/") {
            loadChildren(of: sub)
        }
    }

    func setShowHidden(_ show: Bool) {
        guard show != showHidden else { return }
        showHidden = show
        UserDefaults.standard.set(show, forKey: Self.showHiddenKey)
        // 开关影响所有已加载目录，全部重读
        for path in children.keys { loadChildren(of: path) }
    }

    /// 在树里定位一个目录：展开整条祖先链、滚动到该行并短暂高亮。
    /// 目录不在家目录下（树根之外）返回 false，调用方给提示。
    @discardableResult
    func reveal(_ rawPath: String) -> Bool {
        let path = (rawPath as NSString).standardizingPath
        guard path == root || path.hasPrefix(root + "/") else { return false }
        let components = path == root
            ? []
            : String(path.dropFirst(root.count + 1)).split(separator: "/").map(String.init)
        // 链上有隐藏目录而当前没显示 → 先打开「显示隐藏」，否则目标行根本不存在
        if !showHidden, components.contains(where: { $0.hasPrefix(".") }) {
            setShowHidden(true)
        }
        // 展开除目标自身外的所有祖先（定位不该顺手把目标也展开）
        var ancestor = root
        var chain: [String] = [root]
        for component in components {
            ancestor += "/" + component
            chain.append(ancestor)
        }
        for dir in chain.dropLast() {
            expanded.insert(dir)
            loadChildren(of: dir)
        }
        persistExpanded()

        highlighted = path
        revealRequest = RevealRequest(path: path, tick: (revealRequest?.tick ?? 0) + 1)
        highlightClearWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.highlighted = nil }
        highlightClearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
        return true
    }

    func setShowFiles(_ show: Bool) {
        guard show != showFiles else { return }
        showFiles = show
        UserDefaults.standard.set(show, forKey: Self.showFilesKey)
        for path in children.keys { loadChildren(of: path) }
    }

    private func persistExpanded() {
        UserDefaults.standard.set(Array(expanded).sorted(), forKey: Self.expandedKey)
    }

    private func loadChildren(of path: String) {
        let all = FileBrowserLister.list(directory: path, showHidden: showHidden)
        children[path] = showFiles ? all : all.filter(\.isDirectory)
    }
}

// MARK: - 视图

/// 侧栏「文件夹」模式：从家目录开始的目录树，点击展开/收起下级，可显示文件。
/// 行内悬停按钮或右键「在此开终端」→ 新标签在该目录起 shell；行可拖到终端里粘贴路径。
struct SidebarFolderTree: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var model: FolderTreeModel

    var body: some View {
        let thinkingCwds = coordinator.thinkingCwds
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(model.rows) { row in
                FolderTreeRowView(
                    row: row,
                    // 已加载且无子项 → 不画箭头（叶子目录），视觉更干净
                    isKnownLeaf: row.isDirectory && model.children[row.path]?.isEmpty == true,
                    // 思考中 pane 的 cwd 等于该目录或在其之下 → 整条祖先链都有动效，折叠时也能看见
                    isThinking: row.isDirectory && thinkingCwds.contains {
                        $0 == row.path || $0.hasPrefix(row.path + "/")
                    },
                    isHighlighted: model.highlighted == row.path,
                    onToggle: {
                        guard row.isDirectory else { return }
                        withAnimation(Motion.expand) {
                            model.toggle(row.path)
                        }
                    },
                    onOpenTerminal: { coordinator.newTab(atDirectory: row.path) },
                    onCdHere: { coordinator.cdActivePane(to: row.path) },
                    onOpenFile: { NSWorkspace.shared.open(URL(fileURLWithPath: row.path)) }
                )
                // 拖出去：文件 URL（终端 drop 收到后粘贴转义路径；Finder/编辑器也认）
                .onDrag { NSItemProvider(object: URL(fileURLWithPath: row.path) as NSURL) }
                .contextMenu {
                    if row.isDirectory {
                        Button { coordinator.newTab(atDirectory: row.path) } label: {
                            Label(L("在此目录打开终端"), systemImage: "terminal")
                        }
                        Button { coordinator.cdActivePane(to: row.path) } label: {
                            Label(L("当前终端 cd 到这里"), systemImage: "arrow.right.to.line")
                        }
                        Divider()
                    }
                    if !row.isDirectory {
                        Button { NSWorkspace.shared.open(URL(fileURLWithPath: row.path)) } label: {
                            Label(L("打开文件"), systemImage: "arrow.up.forward.app")
                        }
                    }
                    Button { coordinator.revealInFinder(row.path) } label: {
                        Label(L("在 Finder 中显示"), systemImage: "folder")
                    }
                    Button { coordinator.copyToClipboard(row.path) } label: {
                        Label(L("复制路径"), systemImage: "doc.on.doc")
                    }
                    Divider()
                    if row.isDirectory {
                        Button { model.refresh(row.path) } label: {
                            Label(L("刷新"), systemImage: "arrow.clockwise")
                        }
                    }
                    Button { model.setShowFiles(!model.showFiles) } label: {
                        Label(L("显示文件"),
                              systemImage: model.showFiles ? "checkmark" : "doc")
                    }
                    Button { model.setShowHidden(!model.showHidden) } label: {
                        Label(L("显示隐藏文件夹"),
                              systemImage: model.showHidden ? "checkmark" : "eye.slash")
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

private struct FolderTreeRowView: View {
    let row: FolderTreeRow
    let isKnownLeaf: Bool
    let isThinking: Bool
    let isHighlighted: Bool
    let onToggle: () -> Void
    let onOpenTerminal: () -> Void
    let onCdHere: () -> Void
    let onOpenFile: () -> Void
    @State private var hovering = false

    /// 每级缩进宽度（仅留白，不画竖线）。
    private static let indentWidth: CGFloat = 14
    private var isRoot: Bool { row.depth == 0 }

    var body: some View {
        Button {
            if row.isDirectory {
                onToggle()
            } else if NSApp.currentEvent?.clickCount == 2 {
                // 文件双击系统打开（双击会触发两次 action：第一次 clickCount=1 是 no-op）
                onOpenFile()
            }
        } label: {
            HStack(spacing: 6) {
                indentGuides
                disclosure
                glyph
                Text(row.name)
                    .font(.system(size: 12.5, weight: isRoot ? .semibold : .regular))
                    .foregroundStyle(isRoot || hovering ? AppStyle.textPrimary : AppStyle.textSecondary)
                    .lineLimit(1)
                if row.isGitRepo {
                    gitBadge
                }
                if isThinking {
                    ThinkingIndicator(size: 7)
                }
                Spacer(minLength: 0)
                if hovering, row.isDirectory {
                    HStack(spacing: 3) {
                        IconOnlyButton(
                            systemName: "arrow.right.to.line",
                            help: L("当前终端 cd 到这里"),
                            size: 22,
                            symbolSize: 10,
                            weight: .semibold,
                            tint: AppStyle.textSecondary,
                            action: onCdHere)
                        IconOnlyButton(
                            systemName: "terminal",
                            help: L("在此目录开终端"),
                            size: 22,
                            symbolSize: 10.5,
                            weight: .semibold,
                            tint: AppStyle.accent,
                            action: onOpenTerminal)
                    }
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 6)
            .frame(height: 27)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .fill(isHighlighted
                        ? AppStyle.accent.opacity(0.18)
                        : (hovering ? AppStyle.hoverFill : Color.clear)))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .strokeBorder(isHighlighted ? AppStyle.accent.opacity(0.5) : Color.clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.3), value: isHighlighted)
        .help(row.isDirectory ? row.path : L("双击打开文件"))
    }

    /// git 仓库小徽标：分叉图形，一眼认出「这是个仓库」。
    private var gitBadge: some View {
        Image(systemName: "arrow.triangle.branch")
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundStyle(AppStyle.waitAmber.opacity(0.9))
            .help(L("Git 仓库"))
    }

    /// 层级缩进：只用留白表达层级，不画硬竖线（用户强烈反感硬线条）。
    @ViewBuilder
    private var indentGuides: some View {
        if row.depth > 0 {
            Spacer()
                .frame(width: Self.indentWidth * CGFloat(row.depth), height: 27)
        }
    }

    /// 展开箭头；文件和已知叶子目录画一个小圆点占位，避免箭头点了没反应的困惑。
    @ViewBuilder
    private var disclosure: some View {
        ZStack {
            if isKnownLeaf || !row.isDirectory {
                Circle()
                    .fill(AppStyle.textTertiary.opacity(row.isDirectory ? 0.45 : 0.25))
                    .frame(width: 3, height: 3)
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(hovering ? AppStyle.textSecondary : AppStyle.textTertiary)
                    .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
            }
        }
        .frame(width: 12, height: 12)
    }

    /// 图标：根目录小房子；目录按展开态着色；文件按扩展名给个朴素的 doc 图形。
    @ViewBuilder
    private var glyph: some View {
        if row.isDirectory {
            Image(systemName: isRoot ? "house.fill" : (row.isExpanded ? "folder.fill" : "folder"))
                .font(.system(size: isRoot ? 11.5 : 12, weight: .medium))
                .foregroundStyle(
                    row.isExpanded || isRoot
                        ? AnyShapeStyle(LinearGradient(
                            colors: [AppStyle.accent, AppStyle.accent.opacity(0.7)],
                            startPoint: .top, endPoint: .bottom))
                        : AnyShapeStyle(AppStyle.textTertiary))
                .frame(width: 17, height: 16)
        } else {
            Image(systemName: Self.fileGlyph(for: row.name))
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(AppStyle.textTertiary.opacity(0.85))
                .frame(width: 17, height: 16)
        }
    }

    /// 常见扩展名 → 更贴切的 SF Symbol（不求全，求一眼能分清大类）。
    static func fileGlyph(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift", "c", "h", "cpp", "hpp", "m", "mm", "rs", "go", "py", "rb", "js", "ts",
             "tsx", "jsx", "sh", "zsh", "bash", "fish", "lua", "java", "kt":
            return "chevron.left.forwardslash.chevron.right"
        case "md", "txt", "rtf", "doc", "docx", "pages":
            return "doc.text"
        case "json", "yaml", "yml", "toml", "xml", "plist", "ini", "conf":
            return "curlybraces.square"
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "icns":
            return "photo"
        case "mp4", "mov", "mkv", "avi":
            return "film"
        case "mp3", "wav", "flac", "aac", "m4a":
            return "waveform"
        case "zip", "tar", "gz", "bz2", "xz", "7z", "rar", "dmg":
            return "shippingbox"
        case "pdf":
            return "doc.richtext"
        default:
            return "doc"
        }
    }
}
