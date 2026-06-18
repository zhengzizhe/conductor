import ConductorCore
import SwiftUI

/// 从一张 8×9 Codex Pets 图集渲染宠物：按 `PetMood` 选行，循环该行的**非空帧**。
///
/// 关键（修"整体闪动"）：
/// - 帧由 `CodexPetCatalog.animationFrames` **预切 + 剔除全透明空格**（真图每行帧数不齐，
///   循环到空格会整只闪没）——不再每帧裁剪；
/// - 用 `TimelineView(.animation)`（与不闪的程序化精灵一致），不是 `.periodic`；
/// - `.transaction { $0.animation = nil }` 关掉父层隐式动画，逐帧硬切不淡入淡出。
struct AtlasPetSprite: View {
    let sheet: CGImage
    let mood: PetMood
    var atlas = SpriteAtlas()
    var fps: Double = 8
    /// false = 静态首帧（无 TimelineView）。设置里的模版列表用它，避免一排图集宠物同时跑动画卡顿。
    var animated = true

    var body: some View {
        if animated {
            let frames = framesForMood(in: CodexPetCatalog.animationFrames(of: sheet))
            TimelineView(.animation) { context in
                content(frames, at: context.date.timeIntervalSinceReferenceDate)
            }
            .transaction { $0.animation = nil }
        } else {
            still(CodexPetCatalog.staticPreviewFrame(of: sheet, mood: mood, atlas: atlas))
        }
    }

    @ViewBuilder
    private func still(_ frame: CGImage?) -> some View {
        if let frame {
            Image(decorative: frame, scale: 1, orientation: .up)
                .resizable().interpolation(.none).scaledToFit()
        } else {
            Color.clear
        }
    }

    /// 当前心情对应行的帧；该行无帧则回落到第一个有帧的行（通常 idle）。
    private func framesForMood(in grid: [[CGImage]]) -> [CGImage] {
        let row = atlas.row(for: mood)
        if grid.indices.contains(row), !grid[row].isEmpty { return grid[row] }
        return grid.first(where: { !$0.isEmpty }) ?? []
    }

    @ViewBuilder
    private func content(_ frames: [CGImage], at time: TimeInterval) -> some View {
        if frames.isEmpty {
            Color.clear
        } else {
            let i = Int(time * fps) % frames.count
            Image(decorative: frames[i], scale: 1, orientation: .up)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
        }
    }
}
