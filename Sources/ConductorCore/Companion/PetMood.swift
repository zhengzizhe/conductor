import Foundation

/// 通知宠物的"心情"——内置 Agent 状态归约后的可视语义，直接对应精灵图集的动画行。
///
/// 抄 openpets 的精髓：agent 不发帧号、发**语义状态**，宠物自己映射动画行。
/// 这里的六态覆盖内置 Agent 的全状态：干活 / 等你批 / 跑完 / 挂了 / 待机 / 打盹。
public enum PetMood: String, CaseIterable, Equatable, Sendable {
    /// 静置过久 → 打盹（最低存在感）。
    case sleeping
    /// 待命微动：会话就绪、无事可做。
    case idle
    /// 干活中：流式生成 / 工具执行。
    case thinking
    /// 需要你：有待决的工具审批（最高优先级，盖过一切——"需要你"是宠物存在的第一理由）。
    case needsYou
    /// 一轮成功收尾的瞬态喜悦（蹦一下后回落）。
    case celebrating
    /// 出错 / 失败。
    case sad

    /// 优先级：多来源（将来多 session）并存时取最高者。数值越大越优先。
    /// needsYou > sad > thinking > celebrating > idle > sleeping。
    public var priority: Int {
        switch self {
        case .needsYou: return 5
        case .sad: return 4
        case .thinking: return 3
        case .celebrating: return 2
        case .idle: return 1
        case .sleeping: return 0
        }
    }
}
