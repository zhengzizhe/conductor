import XCTest
@testable import ConductorCore

@MainActor
final class SessionRegistryTests: XCTestCase {
    func testCreateSurfaceUsesFactoryAndStartsAtCwd() {
        var made: [PaneID: FakeSurface] = [:]
        let registry = SessionRegistry { _ in
            let s = FakeSurface(); return s
        } onPaneExited: { _ in }
        // 用一个能捕获实例的工厂
        let reg2 = SessionRegistry(factory: { pane in
            let s = FakeSurface(); made[pane] = s; return s
        }, onPaneExited: { _ in })
        reg2.apply([.createSurface(pane: PaneID("p1"), cwd: "/proj")])
        XCTAssertEqual(made[PaneID("p1")]?.startedCwd, URL(fileURLWithPath: "/proj"))
        XCTAssertNotNil(reg2.surface(for: PaneID("p1")))
        _ = registry // 避免未使用告警
    }

    func testFocusEffectFocusesSurface() {
        var made: [PaneID: FakeSurface] = [:]
        let registry = SessionRegistry(factory: { pane in
            let s = FakeSurface(); made[pane] = s; return s
        }, onPaneExited: { _ in })
        registry.apply([.createSurface(pane: PaneID("p1"), cwd: "/proj")])
        registry.apply([.focusSurface(pane: PaneID("p1"))])
        XCTAssertEqual(made[PaneID("p1")]?.focusCount, 1)
    }

    func testCloseEffectClosesAndForgets() {
        var made: [PaneID: FakeSurface] = [:]
        let registry = SessionRegistry(factory: { pane in
            let s = FakeSurface(); made[pane] = s; return s
        }, onPaneExited: { _ in })
        registry.apply([.createSurface(pane: PaneID("p1"), cwd: "/proj")])
        registry.apply([.closeSurface(pane: PaneID("p1"))])
        XCTAssertTrue(made[PaneID("p1")]?.closed ?? false)
        XCTAssertNil(registry.surface(for: PaneID("p1")))
    }

    func testSurfaceExitInvokesOnPaneExited() {
        var made: [PaneID: FakeSurface] = [:]
        var exited: [PaneID] = []
        let registry = SessionRegistry(factory: { pane in
            let s = FakeSurface(); made[pane] = s; return s
        }, onPaneExited: { exited.append($0) })
        registry.apply([.createSurface(pane: PaneID("p1"), cwd: "/proj")])
        made[PaneID("p1")]?.simulateExit(0)
        XCTAssertEqual(exited, [PaneID("p1")])
    }
}
