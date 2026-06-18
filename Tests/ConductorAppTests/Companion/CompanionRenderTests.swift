@testable import ConductorApp
import ConductorCore
import SwiftUI
import XCTest

/// 把每个 `PetMood` 的真精灵视图离屏渲染成 PNG（不启 GUI、不碰用户状态），
/// 既断言渲染成功、也落盘供肉眼复核（`/tmp/conductor-pet/<mood>.png`）。
@MainActor
final class CompanionRenderTests: XCTestCase {
    func testRenderEachMoodToPNG() throws {
        let dir = URL(fileURLWithPath: "/tmp/conductor-pet")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // 默认模版的六态（含头顶辉光的发光取色由 CompanionView 负责，这里验本体）
        for mood in PetMood.allCases {
            try render(PetSprite(mood: mood, template: PetTemplateCatalog.default).frame(width: 84, height: 84),
                       size: 120, to: dir.appendingPathComponent("mood-\(mood.rawValue).png"))
        }
        // 每个模版的 idle 形象（验「模版列表」视觉）
        for t in PetTemplateCatalog.builtins {
            try render(PetSprite(mood: .idle, template: t).frame(width: 84, height: 84),
                       size: 120, to: dir.appendingPathComponent("template-\(t.id).png"))
        }
    }

    private func render<V: View>(_ content: V, size: CGFloat, to url: URL) throws {
        let view = ZStack {
            Color(white: 0.45)            // 中灰底，衬出身体/卡片
            content
        }
        .frame(width: size, height: size)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage, "ImageRenderer 返回 nil: \(url.lastPathComponent)")
        XCTAssertGreaterThan(image.size.width, 0)

        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: url)
    }
}
