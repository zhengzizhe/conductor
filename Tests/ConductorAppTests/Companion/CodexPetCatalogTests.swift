@testable import ConductorApp
import AppKit
import ConductorCore
import SwiftUI
import XCTest

/// 端到端验 Codex Pets 管线（用合成图集，不依赖任何第三方美术）：
/// 造「pet.json + 8×9 PNG」宠物包 → 发现 → 加载 CGImage → 裁剪渲染。
final class CodexPetCatalogTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codexpet-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// 写一个宠物包：<root>/<id>/{pet.json, spritesheet.png}（8×9，每行一色）。
    private func makeBundle(id: String, name: String) throws -> URL {
        let dir = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = #"{"id":"\#(id)","displayName":"\#(name)","spritesheetPath":"spritesheet.png"}"#
        try manifest.write(to: dir.appendingPathComponent("pet.json"), atomically: true, encoding: .utf8)
        try writeAtlasPNG(to: dir.appendingPathComponent("spritesheet.png"))
        return dir
    }

    /// 8 列 × 9 行、每格 16px 的合成图集；第 r 行整行填 (r/9) 灰阶，便于断言裁到了哪行。
    private func writeAtlasPNG(to url: URL, cell: Int = 16) throws {
        let cols = 8, rows = 9
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: cols * cell, pixelsHigh: rows * cell,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        for r in 0..<rows {
            let gray = CGFloat(r) / CGFloat(rows - 1)
            NSColor(white: gray, alpha: 1).setFill()
            // 注意：NSBitmapImageRep 原点左下，行 0 在底部；裁剪用 CGImage 原点左上。测试只断言“能裁出非空”。
            NSBezierPath(rect: CGRect(x: 0, y: r * cell, width: cols * cell, height: cell)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let png = rep.representation(using: .png, properties: [:])!
        try png.write(to: url)
    }

    func testDiscoverFindsValidBundle() throws {
        _ = try makeBundle(id: "starcorn", name: "Starcorn")
        let pets = CodexPetCatalog.discover(in: [root])
        XCTAssertEqual(pets.count, 1)
        XCTAssertEqual(pets.first?.id, "starcorn")
        XCTAssertEqual(pets.first?.name, "Starcorn")
        if case .atlas = pets.first?.kind {} else { XCTFail("应是 atlas 宠物") }
    }

    func testCompanionCatalogDoesNotPrependBuiltinPlaceholders() {
        let pet = CompanionPet(
            id: "starcorn",
            name: "Starcorn",
            kind: .atlas(root.appendingPathComponent("starcorn/spritesheet.png"))
        )

        let pets = CompanionPetCatalog.all(discovered: [pet])

        XCTAssertEqual(pets.map(\.id), ["starcorn"])
        XCTAssertFalse(pets.map(\.id).contains(PetTemplateCatalog.default.id))
    }

    func testCompanionCatalogFallsBackFromBuiltinIDToFirstExternalPet() {
        let pet = CompanionPet(
            id: "starcorn",
            name: "Starcorn",
            kind: .atlas(root.appendingPathComponent("starcorn/spritesheet.png"))
        )

        XCTAssertEqual(CompanionPetCatalog.pet(id: PetTemplateCatalog.default.id, discovered: [pet]).id, "starcorn")
        XCTAssertEqual(CompanionPetCatalog.pet(id: "missing", discovered: []).id, PetTemplateCatalog.default.id)
    }

    func testDiscoverSkipsBundleWithoutSpritesheet() throws {
        let dir = root.appendingPathComponent("nosheet", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"id":"nosheet"}"#.write(to: dir.appendingPathComponent("pet.json"),
                                       atomically: true, encoding: .utf8)
        XCTAssertTrue(CodexPetCatalog.discover(in: [root]).isEmpty)   // 无图集 → 跳过
    }

    func testDiscoverDedupesByID() throws {
        _ = try makeBundle(id: "dup", name: "First")
        let other = root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        // 第二个目录里放同 id 的包
        let dir2 = other.appendingPathComponent("dup", isDirectory: true)
        try FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)
        try #"{"id":"dup","displayName":"Second","spritesheetPath":"spritesheet.png"}"#.write(
            to: dir2.appendingPathComponent("pet.json"), atomically: true, encoding: .utf8)
        try writeAtlasPNG(to: dir2.appendingPathComponent("spritesheet.png"))

        let pets = CodexPetCatalog.discover(in: [root, other])
        XCTAssertEqual(pets.filter { $0.id == "dup" }.count, 1)        // 去重，先见者胜
        XCTAssertEqual(pets.first { $0.id == "dup" }?.name, "First")
    }

    func testSheetLoadsAndCrops() throws {
        let dir = try makeBundle(id: "blob", name: "Blob")
        let sheet = try XCTUnwrap(CodexPetCatalog.sheet(at: dir.appendingPathComponent("spritesheet.png")))
        XCTAssertEqual(sheet.width, 8 * 16)
        XCTAssertEqual(sheet.height, 9 * 16)
        // 裁第 0 行第 0 列（idle 第 0 帧）应得 16×16。
        let atlas = SpriteAtlas()
        let cw = sheet.width / atlas.columns, ch = sheet.height / atlas.rows
        let cropped = try XCTUnwrap(sheet.cropping(to: CGRect(x: 0, y: 0, width: cw, height: ch)))
        XCTAssertEqual(cropped.width, 16)
        XCTAssertEqual(cropped.height, 16)
    }

    func testAnimationFramesDropsBlankCells() throws {
        // 8×9 图集：第 0 行只前 3 格不透明，第 1 行整行 8 格不透明，其余全透明。
        let cols = 8, rows = 9, cell = 16
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: cols * cell, pixelsHigh: rows * cell,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
        ctx.translateBy(x: 0, y: CGFloat(rows * cell)); ctx.scaleBy(x: 1, y: -1)  // 左上原点
        ctx.setFillColor(NSColor.red.cgColor)
        for c in 0..<3 { ctx.fill(CGRect(x: c * cell, y: 0, width: cell, height: cell)) }          // 行0：3 格
        for c in 0..<8 { ctx.fill(CGRect(x: c * cell, y: cell, width: cell, height: cell)) }       // 行1：8 格
        let sheet = try XCTUnwrap(rep.cgImage)

        let grid = CodexPetCatalog.animationFrames(of: sheet)
        XCTAssertEqual(grid[0].count, 3, "空格应被剔除")
        XCTAssertEqual(grid[1].count, 8)
        XCTAssertTrue(grid[2].isEmpty, "全透明行无帧")
    }

    @MainActor
    func testAtlasSpriteViewRenders() throws {
        let dir = try makeBundle(id: "blob", name: "Blob")
        let sheet = try XCTUnwrap(CodexPetCatalog.sheet(at: dir.appendingPathComponent("spritesheet.png")))
        let renderer = ImageRenderer(
            content: AtlasPetSprite(sheet: sheet, mood: .needsYou).frame(width: 84, height: 84))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage, "AtlasPetSprite 渲染返回 nil")
        XCTAssertGreaterThan(image.size.width, 0)
    }
}
