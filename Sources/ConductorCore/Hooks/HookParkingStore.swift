import Foundation

/// 一条被停用的 hook。停用＝从 agent 的 settings.json 里移走、原样存到这里，
/// 重新启用时再写回。这样不依赖各 host 是否支持 `disabled` 字段，且可逆。
public struct ParkedHook: Codable, Sendable, Equatable {
    public let source: HookSource
    public let event: String
    public let command: String
    public let timeout: Int?

    public init(source: HookSource, event: String, command: String, timeout: Int?) {
        self.source = source
        self.event = event
        self.command = command
        self.timeout = timeout
    }
}

/// 停用 hook 的本地持久仓（conductor 自管，不碰 agent 配置文件）。
public struct HookParkingStore: Sendable {
    public let url: URL

    public init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL
    }

    public static var defaultURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("conductor", isDirectory: true)
        return base.appendingPathComponent("hooks-disabled.json", isDirectory: false)
    }

    public func load() -> [ParkedHook] {
        guard let data = try? Data(contentsOf: url),
              let parked = try? JSONDecoder().decode([ParkedHook].self, from: data)
        else { return [] }
        return parked
    }

    public func parked(for source: HookSource) -> [ParkedHook] {
        load().filter { $0.source == source }
    }

    /// 加一条停用 hook（同 source+event+command 已存在则覆盖 timeout）。
    public func add(_ hook: ParkedHook) throws {
        var all = load().filter { !($0.source == hook.source && $0.event == hook.event && $0.command == hook.command) }
        all.append(hook)
        try save(all)
    }

    /// 移除一条停用记录（重新启用后调用）。返回是否命中。
    @discardableResult
    public func remove(source: HookSource, event: String, command: String) throws -> Bool {
        let all = load()
        let kept = all.filter { !($0.source == source && $0.event == event && $0.command == command) }
        guard kept.count != all.count else { return false }
        try save(kept)
        return true
    }

    public func find(source: HookSource, event: String, command: String) -> ParkedHook? {
        load().first { $0.source == source && $0.event == event && $0.command == command }
    }

    private func save(_ parked: [ParkedHook]) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if parked.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(parked)
        try data.write(to: url)
    }
}
