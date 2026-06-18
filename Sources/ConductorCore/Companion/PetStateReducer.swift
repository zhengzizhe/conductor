import Foundation

/// 把 `AgentSignal` 流归约成 `PetMood` 的纯状态机。
///
/// 含两处**时序**状态（最易出错、所以抽到 Core 单测）：
/// - `celebrating` 是瞬态——侦测 `working → ready` 上升沿（= 一轮成功）后开庆祝窗，窗满回落；
/// - `sleeping` 靠静置计时——安静（ready/idle/stopped 且无审批）超过 `sleepAfter` 才打盹。
///
/// **不读时钟**：`now` 由调用方传入，保证测试确定性。time-based 的回落（庆祝→idle、idle→打盹）
/// 不会自己发生——`CompanionController` 须在信号变化时 **和** 周期性 tick 时都以最新信号重算。
public struct PetStateReducer {
    /// 一轮成功收尾后蹦跶多久回落（秒）。
    public var celebrateWindow: TimeInterval
    /// 安静多久后打盹（秒）。
    public var sleepAfter: TimeInterval

    private var previousActivity: AgentSignal.Activity?
    private var celebrateUntil: TimeInterval?
    private var quietSince: TimeInterval?

    public init(celebrateWindow: TimeInterval = 4, sleepAfter: TimeInterval = 90) {
        self.celebrateWindow = celebrateWindow
        self.sleepAfter = sleepAfter
    }

    public mutating func reduce(_ signal: AgentSignal, now: TimeInterval) -> PetMood {
        // 1) working → ready 上升沿 = 一轮成功 → 开庆祝窗。
        if previousActivity == .working, signal.activity == .ready {
            celebrateUntil = now + celebrateWindow
        }
        previousActivity = signal.activity

        // 2) 审批永远最高——盖过 thinking / celebrating，甚至 sad。
        if signal.pendingApprovals > 0 {
            quietSince = nil
            return .needsYou
        }
        // 3) 失败。
        if signal.activity == .failed {
            quietSince = nil
            celebrateUntil = nil
            return .sad
        }
        // 4) 干活中。
        if signal.activity == .working {
            quietSince = nil
            return .thinking
        }
        // 5) 庆祝窗内（瞬态）。
        if let until = celebrateUntil, now < until {
            quietSince = nil
            return .celebrating
        }
        celebrateUntil = nil
        // 6) 安静态：idle / ready / stopped → 计时打盹。
        if quietSince == nil { quietSince = now }
        if let since = quietSince, now - since >= sleepAfter {
            return .sleeping
        }
        return .idle
    }
}
