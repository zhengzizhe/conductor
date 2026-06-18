import Foundation

/// 读写持久化状态文件。写入原子化；读取对缺失/损坏/版本不符做兜底，绝不抛给上层。
public struct StateStore {
    public enum LoadOutcome: Equatable {
        case loaded       // 成功读到当前状态
        case fresh        // 文件不存在，返回空状态
        case recovered    // 文件损坏/版本不符，已备份坏文件并返回空状态
    }

    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// 原子写入（Foundation 的 .atomic 会先写临时文件再 rename）。
    public func save(_ state: PersistedState) throws {
        let data = try JSONEncoder().encode(state)
        try data.write(to: fileURL, options: .atomic)
    }

    /// 读取状态。返回状态 + 结果分类。
    /// 读不到文件（不存在或瞬时 I/O 错误）→ .fresh，不动任何文件。
    /// 读到了但无法解析或版本过高 → 备份坏文件并返回 .recovered。
    public func load() -> (state: PersistedState, outcome: LoadOutcome) {
        let fresh = PersistedState(store: WorkspaceStore(workspaces: [], activeWorkspace: nil))

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            // 文件不存在或暂时读不到 —— 全新开始，不移动任何文件。
            return (fresh, .fresh)
        }

        guard let decoded = try? JSONDecoder().decode(PersistedState.self, from: data),
              decoded.version <= PersistedState.currentVersion else {
            // 文件存在且可读，但内容损坏或来自更高版本 —— 备份后全新开始。
            backupCorruptFile()
            return (fresh, .recovered)
        }

        return (decoded, .loaded)
    }

    private func backupCorruptFile() {
        let backup = fileURL.appendingPathExtension("corrupt-\(UUID().uuidString)")
        try? FileManager.default.moveItem(at: fileURL, to: backup)
    }
}
