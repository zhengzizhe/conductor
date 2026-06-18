import Foundation

/// 持有 PaneID→TerminalSurface 的映射，并把 SessionEffect 翻译成真实生命周期调用。
/// 泛型/可注入工厂，使其在 ConductorCore 中可用 FakeSurface 单测；app 注入 GhosttySurface 工厂。
@MainActor
public final class SessionRegistry {
    private var surfaces: [PaneID: TerminalSurface] = [:]
    private let factory: (PaneID) -> TerminalSurface
    private let onPaneExited: (PaneID) -> Void

    public init(factory: @escaping (PaneID) -> TerminalSurface,
                onPaneExited: @escaping (PaneID) -> Void) {
        self.factory = factory
        self.onPaneExited = onPaneExited
    }

    public func surface(for pane: PaneID) -> TerminalSurface? { surfaces[pane] }

    public func apply(_ effects: [SessionEffect]) {
        for effect in effects { apply(effect) }
    }

    private func apply(_ effect: SessionEffect) {
        switch effect {
        case let .createSurface(pane, cwd):
            guard surfaces[pane] == nil else { return }
            let surface = factory(pane)
            surface.onExit = { [weak self] _ in self?.onPaneExited(pane) }
            surfaces[pane] = surface
            surface.start(cwd: URL(fileURLWithPath: cwd))
        case let .closeSurface(pane):
            surfaces[pane]?.close()
            surfaces[pane] = nil
        case let .focusSurface(pane):
            surfaces[pane]?.focus()
        }
    }
}
