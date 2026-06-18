import Foundation

/// 把一条待审批请求压成宠物气泡放得下的**紧凑按钮集**——快速「允许一次/拒绝」就地处理，
/// 细粒度（总是允许某工具/某类别、多选项）留给右侧 Feed 面板。纯派生，可单测。
public enum CompanionApproval {
    public struct Compact: Equatable, Sendable {
        /// 气泡里直接渲染的按钮（已截断）。
        public var buttons: [FeedActionButton]
        /// 是否还有更多选项（→ 引导点宠物开右侧 Feed 面板细调）。
        public var hasMore: Bool
    }

    /// 复用 `FeedPresentation.actions` 的权威按钮，再按请求类型压缩：
    /// - question：最多前 3 个选项；
    /// - permission/exitPlan：首个「允许」+「拒绝」两个，其余算 more。
    public static func compact(for request: FeedRequest) -> Compact {
        let all = FeedPresentation.actions(for: request)

        if case .question = request.kind {
            return Compact(buttons: Array(all.prefix(3)), hasMore: all.count > 3)
        }

        if all.count <= 2 {
            return Compact(buttons: all, hasMore: false)
        }
        let allow = all.first { $0.role == .allow }
        let deny = all.first { $0.role == .deny }
        let picked = [allow, deny].compactMap { $0 }
        return Compact(buttons: picked, hasMore: all.count > picked.count)
    }
}
