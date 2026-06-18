import SwiftUI

/// 「AI 正在思考」动效：一颗亮 accent 圆点带两颗渐淡尾巴绕圈（彗星式）。
/// 比平转的圆弧更灵动，且在 7px 这种极小尺寸下也干净（圆弧小了会糊成"逗号"）。
/// 数据源是 coordinator.thinkingPanes。
struct ThinkingIndicator: View {
    var size: CGFloat = 7
    @State private var angle = 0.0

    /// 头亮、尾渐淡——绕起来就是一道彗星拖尾。
    private let trail: [Double] = [1.0, 0.5, 0.26]
    /// 尾巴相邻间隔（度）。小一点显得是"一束"而不是散开的三点。
    private let trailGap = 32.0

    private var dot: CGFloat { max(1.8, size * 0.30) }
    private var radius: CGFloat { (size - dot) / 2 }   // 圆点边缘正好贴外框，不溢出相邻 UI

    var body: some View {
        ZStack {
            ForEach(Array(trail.enumerated()), id: \.offset) { index, opacity in
                Circle()
                    .fill(AppStyle.accent)
                    .frame(width: dot, height: dot)
                    .opacity(opacity)
                    .offset(y: -radius)
                    .rotationEffect(.degrees(Double(index) * -trailGap))   // 尾巴落在头后面
            }
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(angle))
        .onAppear {
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                angle = 360
            }
        }
        .help(L("AI 正在思考"))
        .accessibilityLabel(L("AI 正在思考"))
    }
}
