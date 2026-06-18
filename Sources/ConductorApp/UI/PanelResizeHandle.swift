import AppKit
import SwiftUI

/// 侧栏与右侧各面板的宽度（可拖拽分隔条调整，UserDefaults 持久化）。
@MainActor
final class PanelWidthStore: ObservableObject {
    static let shared = PanelWidthStore()

    @Published var sidebar: CGFloat { didSet { save("panelWidth.sidebar", sidebar) } }
    @Published var settings: CGFloat { didSet { save("panelWidth.settings", settings) } }
    @Published var tools: CGFloat { didSet { save("panelWidth.tools", tools) } }
    @Published var session: CGFloat { didSet { save("panelWidth.session", session) } }

    static let sidebarRange: ClosedRange<CGFloat> = 160...340
    static let settingsRange: ClosedRange<CGFloat> = 480...760
    static let toolsRange: ClosedRange<CGFloat> = 340...680
    static let sessionRange: ClosedRange<CGFloat> = 320...600

    static let settingsDefault: CGFloat = 560
    static let toolsDefault: CGFloat = 374
    static let sessionDefault: CGFloat = 400

    private init() {
        sidebar = Self.loadMigratedSidebar()
        settings = Self.load("panelWidth.settings", Self.settingsDefault, Self.settingsRange)
        tools = Self.loadMigratedTools()
        session = Self.load("panelWidth.session", Self.sessionDefault, Self.sessionRange)
    }

    private static func loadMigratedSidebar() -> CGFloat {
        let key = "panelWidth.sidebar"
        let migrationKey = "panelWidth.sidebar.compactV2Applied"
        let raw = UserDefaults.standard.double(forKey: key)
        guard raw > 0 else { return AppStyle.sidebarWidth }
        guard !UserDefaults.standard.bool(forKey: migrationKey) else {
            return min(max(CGFloat(raw), sidebarRange.lowerBound), sidebarRange.upperBound)
        }
        let compact = min(max(CGFloat(raw) * 0.85, sidebarRange.lowerBound), sidebarRange.upperBound)
        UserDefaults.standard.set(Double(compact), forKey: key)
        UserDefaults.standard.set(true, forKey: migrationKey)
        return compact
    }

    private static func loadMigratedTools() -> CGFloat {
        let key = "panelWidth.tools"
        let migrationKey = "panelWidth.tools.compactV2Applied"
        let raw = UserDefaults.standard.double(forKey: key)
        guard raw > 0 else { return toolsDefault }
        guard !UserDefaults.standard.bool(forKey: migrationKey) else {
            return min(max(CGFloat(raw), toolsRange.lowerBound), toolsRange.upperBound)
        }
        let compact = min(max(CGFloat(raw) * 0.85, toolsRange.lowerBound), toolsRange.upperBound)
        UserDefaults.standard.set(Double(compact), forKey: key)
        UserDefaults.standard.set(true, forKey: migrationKey)
        return compact
    }

    private static func load(_ key: String, _ fallback: CGFloat, _ range: ClosedRange<CGFloat>) -> CGFloat {
        let raw = UserDefaults.standard.double(forKey: key)
        guard raw > 0 else { return fallback }
        return min(max(CGFloat(raw), range.lowerBound), range.upperBound)
    }

    private func save(_ key: String, _ value: CGFloat) {
        UserDefaults.standard.set(Double(value), forKey: key)
    }
}

/// 面板边缘的拖拽把手：横向拖动调宽度，双击恢复默认。
/// 作为 overlay 贴在面板的分隔条一侧，完全落在面板自身 bounds 内
/// （终端区是 AppKit 视图，伸出去会和它抢命中）。
struct PanelResizeHandle: View {
    /// 把手贴在面板的哪条边（也决定拖动方向语义）。
    enum Edge { case leading, trailing }

    let edge: Edge
    @Binding var width: CGFloat
    let range: ClosedRange<CGFloat>
    let defaultWidth: CGFloat
    @State private var dragStartWidth: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 8)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let base = dragStartWidth ?? width
                        dragStartWidth = base
                        let dx = value.translation.width
                        let proposed = edge == .trailing ? base + dx : base - dx
                        width = min(max(proposed, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
            .onTapGesture(count: 2) { width = defaultWidth }
    }
}
