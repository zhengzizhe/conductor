@testable import ConductorApp
import ConductorCore
import XCTest

@MainActor
final class WorkspaceMetadataCenterTests: XCTestCase {
    private let ws = WorkspaceID("ws-1")
    private let other = WorkspaceID("ws-2")

    // MARK: - 状态 chip

    func testSetStatusUpsertsByKey() {
        let center = WorkspaceMetadataCenter()
        center.setStatus(workspace: ws, key: "build", text: "编译中", color: nil, icon: nil)
        center.setStatus(workspace: ws, key: "test", text: "待测", color: nil, icon: nil)
        XCTAssertEqual(center.statuses(for: ws).count, 2)

        // 同 key 覆盖而非新增，且保持顺序
        center.setStatus(workspace: ws, key: "build", text: "编译完成", color: "#34c759", icon: "hammer")
        let chips = center.statuses(for: ws)
        XCTAssertEqual(chips.count, 2)
        XCTAssertEqual(chips[0].key, "build")
        XCTAssertEqual(chips[0].text, "编译完成")
        XCTAssertEqual(chips[0].color, "#34c759")
        XCTAssertEqual(chips[0].icon, "hammer")
    }

    func testClearStatusByKeyThenAll() {
        let center = WorkspaceMetadataCenter()
        center.setStatus(workspace: ws, key: "a", text: "1", color: nil, icon: nil)
        center.setStatus(workspace: ws, key: "b", text: "2", color: nil, icon: nil)

        center.clearStatus(workspace: ws, key: "a")
        XCTAssertEqual(center.statuses(for: ws).map(\.key), ["b"])

        // 清掉最后一个 key 后该工作区整条目移除
        center.clearStatus(workspace: ws, key: "b")
        XCTAssertTrue(center.statuses(for: ws).isEmpty)
        XCTAssertNil(center.statusChips[ws])

        center.setStatus(workspace: ws, key: "x", text: "1", color: nil, icon: nil)
        center.setStatus(workspace: ws, key: "y", text: "2", color: nil, icon: nil)
        center.clearStatus(workspace: ws, key: nil)   // 清全部
        XCTAssertTrue(center.statuses(for: ws).isEmpty)
    }

    func testStatusesForUnknownWorkspaceIsEmpty() {
        let center = WorkspaceMetadataCenter()
        XCTAssertTrue(center.statuses(for: ws).isEmpty)
    }

    // MARK: - 进度

    func testSetProgressClampsToUnitInterval() {
        let center = WorkspaceMetadataCenter()
        center.setProgress(workspace: ws, value: -0.5, label: "下限")
        XCTAssertEqual(center.progress[ws]?.value, 0)

        center.setProgress(workspace: ws, value: 1.5, label: "上限")
        XCTAssertEqual(center.progress[ws]?.value, 1)

        center.setProgress(workspace: ws, value: 0.42, label: "中间")
        XCTAssertEqual(center.progress[ws]?.value, 0.42)
        XCTAssertEqual(center.progress[ws]?.label, "中间")
    }

    func testClearProgress() {
        let center = WorkspaceMetadataCenter()
        center.setProgress(workspace: ws, value: 0.5, label: nil)
        center.clearProgress(workspace: ws)
        XCTAssertNil(center.progress[ws])
    }

    // MARK: - 日志环形缓冲

    func testLogRingBufferTruncatesToMax() {
        let center = WorkspaceMetadataCenter()
        for i in 0..<600 {
            center.appendLog(workspace: ws, text: "line \(i)", level: "info", source: nil)
        }
        let all = center.logs(for: ws, limit: 10_000)
        XCTAssertEqual(all.count, 500)                 // 上限 500
        XCTAssertEqual(all.first?.text, "line 100")    // 最旧的 100 条被丢弃
        XCTAssertEqual(all.last?.text, "line 599")
    }

    func testLogsLimitReturnsSuffix() {
        let center = WorkspaceMetadataCenter()
        for i in 0..<5 {
            center.appendLog(workspace: ws, text: "l\(i)", level: "info", source: nil)
        }
        XCTAssertEqual(center.logs(for: ws, limit: 2).map(\.text), ["l3", "l4"])
        XCTAssertEqual(center.logs(for: ws, limit: 0).count, 0)
        XCTAssertEqual(center.logs(for: ws, limit: -1).count, 0)   // 负数不崩
    }

    // MARK: - forget

    func testForgetClearsOnlyTargetWorkspace() {
        let center = WorkspaceMetadataCenter()
        center.setStatus(workspace: ws, key: "a", text: "1", color: nil, icon: nil)
        center.setProgress(workspace: ws, value: 0.5, label: nil)
        center.appendLog(workspace: ws, text: "x", level: "info", source: nil)
        center.setStatus(workspace: other, key: "b", text: "2", color: nil, icon: nil)

        center.forget(workspace: ws)

        XCTAssertTrue(center.statuses(for: ws).isEmpty)
        XCTAssertNil(center.progress[ws])
        XCTAssertTrue(center.logs(for: ws, limit: 100).isEmpty)
        // 其它工作区不受影响
        XCTAssertEqual(center.statuses(for: other).map(\.key), ["b"])
    }
}
