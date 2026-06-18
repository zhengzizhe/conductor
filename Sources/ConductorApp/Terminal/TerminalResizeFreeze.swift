import AppKit

/// 冻结期间被跳过真实 resize 的参与者；解冻时收到一次补偿同步。
@MainActor
protocol TerminalResizeFreezeParticipant: AnyObject {
    func resizeFreezeDidEnd()
}

/// 面板/侧栏开合这类"可预期的布局动画"期间，冻结 libghostty 的真实 resize。
///
/// 动画的每一帧都会改终端 NSView 的 frame；如果每帧都跟着调
/// `ghostty_surface_set_size`，就是 N 个 pane × 120Hz 的网格重排 + 渲染器
/// resize + drawable 重分配，动画必卡。冻结期间 Metal 层只随 frame 拉伸
/// （内容短暂缩放），动画结束后一次性按最终尺寸补一帧清晰的 resize。
///
/// 窗口 live resize 和分隔条拖动不走冻结——那是用户实时操作，需要内容跟手。
@MainActor
final class TerminalResizeFreeze {
    static let shared = TerminalResizeFreeze()

    private(set) var isFrozen = false
    private let participants = NSHashTable<AnyObject>.weakObjects()
    private var unfreezeTask: Task<Void, Never>?

    func register(_ participant: TerminalResizeFreezeParticipant) {
        participants.add(participant)
    }

    /// 冻结 `duration` 秒（应覆盖动画时长 + 收尾余量）；动画期间重复触发会顺延。
    func freeze(for duration: TimeInterval) {
        isFrozen = true
        unfreezeTask?.cancel()
        unfreezeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.unfreeze()
        }
    }

    private func unfreeze() {
        unfreezeTask = nil
        isFrozen = false
        for case let participant as TerminalResizeFreezeParticipant in participants.allObjects {
            participant.resizeFreezeDidEnd()
        }
    }
}
