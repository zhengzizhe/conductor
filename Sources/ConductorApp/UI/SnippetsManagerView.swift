import SwiftUI
import UniformTypeIdentifiers

/// 片段管理面板：增删改命令片段，一键发送到当前终端。
/// 「执行」开关决定发送后是否直接回车（关掉则摆在提示符上可先编辑）。
/// 支持搜索过滤、拖拽排序；`{{占位符}}` 发送前先填值。
struct SnippetsManagerView: View {
    let coordinator: AppCoordinator
    @ObservedObject private var store = SnippetStore.shared
    @State private var editing: Snippet?
    @State private var isCreating = false
    @State private var search = ""
    @State private var draggingID: String?

    private var filtered: [Snippet] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return store.snippets }
        return store.snippets.filter {
            $0.name.lowercased().contains(q) || $0.command.lowercased().contains(q)
        }
    }

    /// 搜索过滤时顺序没意义，禁用拖拽排序。
    private var reorderEnabled: Bool {
        search.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    ToolsSectionLabel(L("命令片段"))
                    Spacer()
                    ToolActionButton(
                        title: L("新增片段"),
                        systemImage: "plus",
                        role: .secondary,
                        height: 26,
                        fontSize: 11,
                        horizontalPadding: 10) {
                            isCreating = true
                            editing = Snippet(name: "", command: "")
                        }
                }

                searchField

                if let editing {
                    SnippetEditor(
                        snippet: editing,
                        isNew: isCreating,
                        onSave: { saved in
                            if isCreating { store.add(saved) } else { store.update(saved) }
                            self.editing = nil
                        },
                        onCancel: { self.editing = nil }
                    )
                }

                if store.snippets.isEmpty, editing == nil {
                    ToolEmptyState(
                        icon: "text.badge.plus",
                        title: L("还没有片段"),
                        detail: L("新增一个常用命令片段。"),
                        compact: true)
                    .padding(.top, 8)
                } else if filtered.isEmpty {
                    ToolEmptyState(
                        icon: "magnifyingglass",
                        title: L("没有匹配结果"),
                        detail: search,
                        compact: true)
                    .padding(.top, 8)
                } else {
                    VStack(spacing: 4) {
                        ForEach(filtered) { snippet in
                            SnippetRow(
                                snippet: snippet,
                                isDragging: draggingID == snippet.id,
                                onSend: { coordinator.sendSnippet(snippet) },
                                onEdit: {
                                    isCreating = false
                                    editing = snippet
                                },
                                onDelete: { store.remove(snippet.id) }
                            )
                            .onDrag {
                                draggingID = snippet.id
                                return NSItemProvider(object: snippet.id as NSString)
                            }
                            .onDrop(of: [.text], delegate: SnippetReorderDelegate(
                                target: snippet,
                                draggingID: $draggingID,
                                store: store,
                                enabled: reorderEnabled))
                        }
                    }
                    // 拖拽排序时行位置交换用同一节奏过渡
                    .animation(.easeOut(duration: 0.16), value: store.snippets.map(\.id))
                }
            }
            .padding(16)
        }
        .scrollIndicators(.never)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppStyle.textTertiary)
            TextField(L("搜索片段…"), text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(AppStyle.textPrimary)
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(AppStyle.textTertiary)
                }
                .buttonStyle(.plain)
                .help(L("清空搜索"))
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(AppStyle.activeFill))
    }
}

/// 拖拽排序：拖到某行上方时实时挪位（搜索过滤时禁用）。
private struct SnippetReorderDelegate: DropDelegate {
    let target: Snippet
    @Binding var draggingID: String?
    let store: SnippetStore
    let enabled: Bool

    func dropEntered(info: DropInfo) {
        guard enabled,
              let dragging = draggingID, dragging != target.id,
              let from = store.snippets.firstIndex(where: { $0.id == dragging }),
              let to = store.snippets.firstIndex(where: { $0.id == target.id }) else { return }
        store.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: enabled ? .move : .forbidden)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingID = nil
        return true
    }
}

private struct SnippetRow: View {
    let snippet: Snippet
    let isDragging: Bool
    let onSend: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onSend) {
            HStack(spacing: 10) {
                Image(systemName: snippet.autoRun ? "bolt.fill" : "text.cursor")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(snippet.autoRun ? AppStyle.accent : AppStyle.textTertiary)
                    .frame(width: 16)
                    .help(snippet.autoRun ? L("发送后直接执行") : L("发送后摆在提示符上，可编辑"))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(snippet.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(AppStyle.textPrimary)
                            .lineLimit(1)
                        if !snippet.placeholders.isEmpty {
                            Image(systemName: "curlybraces")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(AppStyle.textTertiary)
                                .help(L("含 {{占位符}}，发送前会先弹窗填值"))
                        }
                    }
                    Text(snippet.command)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(AppStyle.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if hovering {
                    HStack(spacing: 2) {
                        IconOnlyButton(
                            systemName: "paperplane",
                            help: L("发送到当前终端"),
                            size: 22,
                            symbolSize: 10,
                            action: onSend)
                        IconOnlyButton(
                            systemName: "pencil",
                            help: L("编辑"),
                            size: 22,
                            symbolSize: 10,
                            action: onEdit)
                        IconOnlyButton(
                            systemName: "trash",
                            help: L("删除"),
                            size: 22,
                            symbolSize: 10,
                            tint: AppStyle.errorRed,
                            action: onDelete)
                    }
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .fill(hovering ? AppStyle.hoverFill : AppStyle.activeFill.opacity(0.5)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isDragging ? 0.45 : 1)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct SnippetEditor: View {
    @State var snippet: Snippet
    let isNew: Bool
    let onSave: (Snippet) -> Void
    let onCancel: () -> Void

    private var valid: Bool {
        !snippet.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !snippet.command.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isNew ? L("新增片段") : L("编辑片段"))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(AppStyle.textSecondary)
            TextField(L("名称（如：检查项目状态）"), text: $snippet.name)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(8)
                .background(RoundedRectangle(cornerRadius: Radius.sm).fill(AppStyle.activeFill))
            TextField(L("命令（如：git status）"), text: $snippet.command, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1...4)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: Radius.sm).fill(AppStyle.activeFill))
            Toggle(isOn: $snippet.autoRun) {
                Text(L("发送后执行"))
                    .font(.system(size: 11))
                    .foregroundStyle(AppStyle.textSecondary)
            }
            .toggleStyle(.checkbox)
            .help(L("关闭后会先放到提示符上"))
            HStack {
                Spacer()
                ToolActionButton(
                    title: L("取消"),
                    role: .secondary,
                    height: 26,
                    fontSize: 11,
                    horizontalPadding: 10,
                    action: onCancel)
                ToolActionButton(
                    title: L("保存"),
                    role: .primary,
                    height: 26,
                    fontSize: 11,
                    horizontalPadding: 10) {
                        onSave(snippet)
                    }
                    .disabled(!valid)
            }
        }
        .padding(12)
        .toolsCard()
    }
}
