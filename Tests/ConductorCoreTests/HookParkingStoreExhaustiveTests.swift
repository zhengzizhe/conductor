import XCTest
@testable import ConductorCore

final class HookParkingStoreExhaustiveTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("conductor-hookparking-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
        dir = nil
        try super.tearDownWithError()
    }

    private func storeURL() -> URL {
        dir.appendingPathComponent("hooks-disabled.json", isDirectory: false)
    }

    /// 全新（不存在的文件）load 返回空，且不创建文件。
    func testEmptyLoadOnFreshUrl() {
        let url = storeURL()
        let store = HookParkingStore(url: url)
        XCTAssertTrue(store.load().isEmpty)
        XCTAssertNil(store.find(source: .claude, event: "Stop", command: "x"))
        XCTAssertTrue(store.parked(for: .claude).isEmpty)
        XCTAssertTrue(store.parked(for: .codex).isEmpty)
        // load 不应有副作用：仍然没有落盘文件
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// add 之后 find 命中、字段保真，且文件落盘。
    func testAddThenFindAndPersists() throws {
        let url = storeURL()
        let store = HookParkingStore(url: url)
        try store.add(ParkedHook(source: .claude, event: "Stop", command: "cmd-a", timeout: 7))

        let found = store.find(source: .claude, event: "Stop", command: "cmd-a")
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.source, .claude)
        XCTAssertEqual(found?.event, "Stop")
        XCTAssertEqual(found?.command, "cmd-a")
        XCTAssertEqual(found?.timeout, 7)
        XCTAssertEqual(store.load().count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    /// nil timeout 也能往返保真。
    func testAddPreservesNilTimeout() throws {
        let store = HookParkingStore(url: storeURL())
        try store.add(ParkedHook(source: .codex, event: "SessionStart", command: "no-timeout", timeout: nil))
        let found = store.find(source: .codex, event: "SessionStart", command: "no-timeout")
        XCTAssertNotNil(found)
        XCTAssertNil(found?.timeout)
    }

    /// 同 (source,event,command) 再 add 覆盖 timeout，不新增条目，保留最新值。
    func testDedupOverwriteKeepsLatestTimeout() throws {
        let store = HookParkingStore(url: storeURL())
        try store.add(ParkedHook(source: .claude, event: "Stop", command: "dup", timeout: 1))
        XCTAssertEqual(store.load().count, 1)
        XCTAssertEqual(store.find(source: .claude, event: "Stop", command: "dup")?.timeout, 1)

        try store.add(ParkedHook(source: .claude, event: "Stop", command: "dup", timeout: 2))
        XCTAssertEqual(store.load().count, 1)
        XCTAssertEqual(store.find(source: .claude, event: "Stop", command: "dup")?.timeout, 2)

        // 覆盖为 nil 也生效
        try store.add(ParkedHook(source: .claude, event: "Stop", command: "dup", timeout: nil))
        XCTAssertEqual(store.load().count, 1)
        XCTAssertNil(store.find(source: .claude, event: "Stop", command: "dup")?.timeout)
    }

    /// 去重的 key 必须三元组全等：event 不同、command 不同、source 不同都各自独立成条。
    func testDedupKeyDistinguishesEachComponent() throws {
        let store = HookParkingStore(url: storeURL())
        try store.add(ParkedHook(source: .claude, event: "Stop", command: "c", timeout: nil))
        try store.add(ParkedHook(source: .claude, event: "SessionStart", command: "c", timeout: nil)) // event 不同
        try store.add(ParkedHook(source: .claude, event: "Stop", command: "c2", timeout: nil))        // command 不同
        try store.add(ParkedHook(source: .codex, event: "Stop", command: "c", timeout: nil))          // source 不同
        XCTAssertEqual(store.load().count, 4)
    }

    /// parked(for:) 按 source 过滤。
    func testParkedFiltersBySource() throws {
        let store = HookParkingStore(url: storeURL())
        try store.add(ParkedHook(source: .claude, event: "Stop", command: "a", timeout: nil))
        try store.add(ParkedHook(source: .claude, event: "SessionStart", command: "b", timeout: nil))
        try store.add(ParkedHook(source: .codex, event: "Stop", command: "c", timeout: nil))

        let claudeParked = store.parked(for: .claude)
        XCTAssertEqual(claudeParked.count, 2)
        XCTAssertTrue(claudeParked.allSatisfy { $0.source == .claude })
        XCTAssertTrue(claudeParked.contains { $0.command == "a" })
        XCTAssertTrue(claudeParked.contains { $0.command == "b" })

        let codexParked = store.parked(for: .codex)
        XCTAssertEqual(codexParked.count, 1)
        XCTAssertEqual(codexParked.first?.command, "c")

        XCTAssertEqual(store.load().count, 3)
    }

    /// 两个指向同一 url 的 store 实例之间持久化可见。
    func testPersistenceAcrossTwoStoreInstances() throws {
        let url = storeURL()
        let writer = HookParkingStore(url: url)
        try writer.add(ParkedHook(source: .claude, event: "Stop", command: "persisted", timeout: 33))
        try writer.add(ParkedHook(source: .codex, event: "Notification", command: "persisted2", timeout: nil))

        let reader = HookParkingStore(url: url)
        XCTAssertEqual(reader.load().count, 2)
        XCTAssertEqual(reader.find(source: .claude, event: "Stop", command: "persisted")?.timeout, 33)
        let p2 = reader.find(source: .codex, event: "Notification", command: "persisted2")
        XCTAssertNotNil(p2)
        XCTAssertNil(p2?.timeout)
        XCTAssertEqual(reader.parked(for: .codex).count, 1)
    }

    /// 移除最后一条时删除落盘文件。
    func testRemoveLastEntryDeletesFile() throws {
        let url = storeURL()
        let store = HookParkingStore(url: url)
        try store.add(ParkedHook(source: .claude, event: "Stop", command: "only", timeout: nil))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let removed = try store.remove(source: .claude, event: "Stop", command: "only")
        XCTAssertTrue(removed)
        XCTAssertTrue(store.load().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// 多条时移除一条保留其余，且文件仍在。
    func testRemoveOneKeepsOthers() throws {
        let url = storeURL()
        let store = HookParkingStore(url: url)
        try store.add(ParkedHook(source: .claude, event: "Stop", command: "keep", timeout: nil))
        try store.add(ParkedHook(source: .claude, event: "Stop", command: "drop", timeout: nil))

        XCTAssertTrue(try store.remove(source: .claude, event: "Stop", command: "drop"))
        XCTAssertEqual(store.load().count, 1)
        XCTAssertNil(store.find(source: .claude, event: "Stop", command: "drop"))
        XCTAssertNotNil(store.find(source: .claude, event: "Stop", command: "keep"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    /// 移除不存在的记录返回 false，不影响已有数据，也不删文件。
    func testRemoveNonExistentReturnsFalse() throws {
        let url = storeURL()
        let store = HookParkingStore(url: url)
        // 空仓上移除
        XCTAssertFalse(try store.remove(source: .claude, event: "Stop", command: "nope"))

        try store.add(ParkedHook(source: .claude, event: "Stop", command: "real", timeout: nil))
        // 非空仓上移除不匹配项：source/event/command 各自不匹配
        XCTAssertFalse(try store.remove(source: .codex, event: "Stop", command: "real"))
        XCTAssertFalse(try store.remove(source: .claude, event: "SessionStart", command: "real"))
        XCTAssertFalse(try store.remove(source: .claude, event: "Stop", command: "other"))
        XCTAssertEqual(store.load().count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    /// 完整生命周期：add -> find -> overwrite -> remove -> 空。
    func testFullRoundTripLifecycle() throws {
        let url = storeURL()
        let store = HookParkingStore(url: url)
        XCTAssertTrue(store.load().isEmpty)

        try store.add(ParkedHook(source: .claude, event: "Stop", command: "lc", timeout: 5))
        XCTAssertEqual(store.find(source: .claude, event: "Stop", command: "lc")?.timeout, 5)

        try store.add(ParkedHook(source: .claude, event: "Stop", command: "lc", timeout: 50))
        XCTAssertEqual(store.parked(for: .claude).count, 1)
        XCTAssertEqual(store.find(source: .claude, event: "Stop", command: "lc")?.timeout, 50)

        XCTAssertTrue(try store.remove(source: .claude, event: "Stop", command: "lc"))
        XCTAssertTrue(store.load().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(try store.remove(source: .claude, event: "Stop", command: "lc"))
    }
}
