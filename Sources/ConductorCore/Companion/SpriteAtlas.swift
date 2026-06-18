import Foundation

/// 精灵图集的网格映射：心情 → 行，帧号 → 列（行内回绕成循环动画）。
///
/// 采用 openpets 的 **Codex Pets 8×9 格式**（8 列 = 每态动画帧数，9 行 = 固定状态序）。
/// 抄的是**格式/行序**（规范，可用），不是它的图（美术授权不清，不打包）——这样任何 Codex Pets
/// 宠物包（`~/.codex/pets/` 等）都能 drop-in 渲染。行→心情映射默认按 Codex 行序（`codexRows`）。
public struct SpriteAtlas: Equatable, Sendable {
    /// Codex Pets 图集的固定行序（9 行）。
    public enum CodexRow: Int, CaseIterable, Sendable {
        case idle = 0, runningRight, runningLeft, waving, jumping, failed, waiting, running, review
    }

    /// 每行帧数（动画长度）。
    public let columns: Int
    /// 状态行数。
    public let rows: Int
    private let rowForMood: [PetMood: Int]

    public init(columns: Int = 8, rows: Int = 9, rowForMood: [PetMood: Int] = SpriteAtlas.codexRows) {
        self.columns = columns
        self.rows = rows
        self.rowForMood = rowForMood
    }

    /// 心情 → Codex 行映射：idle→idle、思考→running、需要你→review、庆祝→jumping、
    /// 失败→failed、打盹→idle（Codex 无睡眠行，回落 idle）。
    public static let codexRows: [PetMood: Int] = [
        .idle: CodexRow.idle.rawValue,
        .thinking: CodexRow.running.rawValue,
        .needsYou: CodexRow.review.rawValue,
        .celebrating: CodexRow.jumping.rawValue,
        .sad: CodexRow.failed.rawValue,
        .sleeping: CodexRow.idle.rawValue,
    ]

    /// 某心情对应的行（缺失落 0，越界 clamp 进 `0..<rows`）。
    public func row(for mood: PetMood) -> Int {
        let r = rowForMood[mood] ?? 0
        return min(max(r, 0), rows - 1)
    }

    /// 某心情第 `frame` 帧的图集格子。`frame` 在该行内回绕（含负数），形成循环动画。
    public func cell(for mood: PetMood, frame: Int) -> (row: Int, column: Int) {
        let column = ((frame % columns) + columns) % columns
        return (row(for: mood), column)
    }
}
