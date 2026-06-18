import Foundation

/// 喂给 `PetStateReducer` 的一帧观测快照。Core 层不反向依赖 App 类型——
/// App 侧 `CompanionController` 负责把 `BuiltinAgentSession.Phase` + `FeedCenter.pending`
/// 映射成这个结构，reducer 只认它，保证纯逻辑可单测。
public struct AgentSignal: Equatable, Sendable {
    /// agent 的原始可观测活动态（对应 `BuiltinAgentSession.Phase` 的归并）。
    public enum Activity: Equatable, Sendable {
        /// 从未开始 / 全新。
        case idle
        /// 正在干活：`.starting` 或 `.streaming`。
        case working
        /// 一轮收尾、待命接受输入：`.ready`。
        case ready
        /// 出错：`.failed`。
        case failed
        /// 被停止 / 进程退出：`.stopped`。
        case stopped
    }

    public var activity: Activity
    /// 待决的工具审批条数（`FeedCenter.pending.count`）。> 0 即"需要你"。
    public var pendingApprovals: Int

    public init(activity: Activity, pendingApprovals: Int = 0) {
        self.activity = activity
        self.pendingApprovals = pendingApprovals
    }
}
