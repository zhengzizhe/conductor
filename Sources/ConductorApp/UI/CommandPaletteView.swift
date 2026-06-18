import SwiftUI

/// 命令面板的一项：命令 / 标签 / 工作区。
struct PaletteItem: Identifiable {
    let id: String
    let icon: String
    let title: String
    let subtitle: String
    let run: () -> Void
}

/// 最近执行过的面板条目 id（MRU 去重置顶，最多 6 条），UserDefaults 持久化。
enum PaletteRecents {
    private static let key = "palette.recents"
    private static let limit = 6

    static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func record(_ id: String) {
        var items = load()
        items.removeAll { $0 == id }
        items.insert(id, at: 0)
        UserDefaults.standard.set(Array(items.prefix(limit)), forKey: key)
    }
}

/// 命令面板（自绘，跟主题）：搜索框 + 模糊过滤列表，↑↓选、回车执行、Esc 关。
/// 空查询时最近执行过的条目浮顶；模糊匹配兼顾标题与副标题（可按路径搜工作区）。
struct CommandPaletteView: View {
    let items: [PaletteItem]
    let onClose: () -> Void

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var fieldFocused: Bool
    /// 打开面板那一刻的最近使用快照（面板生命周期内不变，避免执行后列表跳动）。
    private let recents = PaletteRecents.load()

    private var filtered: [PaletteItem] {
        guard !query.isEmpty else { return orderedForEmptyQuery }
        return items
            .compactMap { item -> (PaletteItem, Int)? in
                // 标题命中优先级远高于副标题（路径/键位）命中
                if let score = CommandPaletteView.fuzzy(query, item.title) { return (item, score + 1000) }
                if !item.subtitle.isEmpty,
                   let score = CommandPaletteView.fuzzy(query, item.subtitle) { return (item, score) }
                return nil
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// 空查询：最近使用的按其使用序浮顶，其余保持原序。
    private var orderedForEmptyQuery: [PaletteItem] {
        guard !recents.isEmpty else { return items }
        var byID: [String: PaletteItem] = [:]
        for item in items { byID[item.id] = item }
        let top = recents.compactMap { byID[$0] }
        guard !top.isEmpty else { return items }
        let topIDs = Set(top.map(\.id))
        return top + items.filter { !topIDs.contains($0.id) }
    }

    /// 该条目此刻是否以「最近使用」身份展示（空查询且在浮顶区）。
    private func isRecentRow(_ index: Int, _ item: PaletteItem) -> Bool {
        query.isEmpty && index < recents.count && recents.contains(item.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AppStyle.textTertiary)
                TextField(L("搜索命令、标签、工作区…"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundStyle(AppStyle.textPrimary)
                    .focused($fieldFocused)
                    .onSubmit { runSelected() }
                if !query.isEmpty {
                    Button {
                        query = ""
                        fieldFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(AppStyle.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help(L("清空搜索"))
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 52)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if filtered.isEmpty {
                            emptyState
                        } else {
                            ForEach(Array(filtered.enumerated()), id: \.element.id) { index, item in
                                row(item, selected: index == selection,
                                    recent: isRecentRow(index, item))
                                    .id(index)
                                    .contentShape(Rectangle())
                                    .onTapGesture { selection = index; runSelected() }
                            }
                        }
                    }
                    .padding(8)
                }
                .onChange(of: selection) { _, new in
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(new, anchor: .center) }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: 540, height: 420)
        .conductorFloatingPanel(cornerRadius: Radius.xl)
        .padding(Space.xl)   // 给阴影留出扩散空间，不被窗口裁掉
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.escape) { onClose(); return .handled }
        .onChange(of: query) { _, _ in selection = 0 }
        .onAppear { fieldFocused = true }
    }

    private func row(_ item: PaletteItem, selected: Bool, recent: Bool) -> some View {
        HStack(spacing: 11) {
            Image(systemName: item.icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selected ? AppStyle.accent : AppStyle.textTertiary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(AppStyle.textPrimary)
                    .lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(AppStyle.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if recent {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AppStyle.textTertiary.opacity(0.8))
                    .help(L("最近使用过"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .fill(selected ? AppStyle.activeFill : Color.clear))
    }

    private var emptyState: some View {
        ToolEmptyState(
            icon: "magnifyingglass",
            title: L("没有匹配「%@」的结果", query),
            compact: true)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private func move(_ d: Int) {
        let n = filtered.count
        guard n > 0 else { return }
        selection = min(max(selection + d, 0), n - 1)
    }

    private func runSelected() {
        guard filtered.indices.contains(selection) else { return }
        let item = filtered[selection]
        PaletteRecents.record(item.id)
        onClose()
        item.run()
    }

    /// 子序列模糊匹配：query 的字符按序出现在 text 中即命中；连续命中加分。无命中返回 nil。
    static func fuzzy(_ query: String, _ text: String) -> Int? {
        let q = Array(query.lowercased())
        let t = Array(text.lowercased())
        guard !q.isEmpty else { return 0 }
        var qi = 0, score = 0, last = -2
        for (ti, ch) in t.enumerated() where qi < q.count && ch == q[qi] {
            score += (ti == last + 1) ? 4 : 1
            if ti == 0 { score += 3 }
            last = ti
            qi += 1
        }
        return qi == q.count ? score : nil
    }
}
