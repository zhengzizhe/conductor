import ConductorCore

/// 小队成员：一个**在线会话**的可视快照——一只迷你宠物 + 它自己的状态与动作。
/// 多会话各占一行、各弹各的（审批 / 跑完 / 干活互不抢占），这是"只认一个会话"的根治。
/// 纯值类型，由 `CompanionController.buildRoster` 从 pane 世界合并而来，可单测。
struct CompanionMember: Identifiable, Equatable {
    enum State: Equatable {
        /// 干活中（流式生成 / 工具执行）。
        case working
        /// 一轮收尾。可带 agent 的真实回复全文——点这一行跳到那个会话看全文。
        case done(reply: String?)
        /// 待你批准。携带原始请求 + 是否来自终端嗅探（决定走 `FeedCenter` 还是给终端发按键）。
        case needsApproval(request: FeedRequest, terminal: Bool)
    }

    let id: String
    /// 关联的 pane（跳转用）；feed 来的审批可能无 pane。
    let paneID: String?
    let title: String
    let state: State

    /// 这只迷你宠物的表情：由成员状态直接映射，保证一眼可读。
    var mood: PetMood {
        switch state {
        case .working: return .thinking
        case .done: return .celebrating
        case .needsApproval: return .needsYou
        }
    }

    /// 展示排序：干活在最外、跑完居中、审批贴着队长（最靠近头顶）。数值越大越贴队长。
    var displayRank: Int {
        switch state {
        case .working: return 0
        case .done: return 1
        case .needsApproval: return 2
        }
    }

    /// 抢占优先级（窗口放不下时谁先被折叠进 "+N"）：审批 > 跑完 > 干活，越大越保。
    var keepPriority: Int {
        switch state {
        case .needsApproval: return 2
        case .done: return 1
        case .working: return 0
        }
    }
}

/// 一帧小队快照：已按容量裁剪 + 展示排序的成员，加上被折叠掉的会话数。
struct CompanionRoster: Equatable {
    var members: [CompanionMember]
    var overflow: Int

    static let empty = CompanionRoster(members: [], overflow: 0)
}
