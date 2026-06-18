@testable import ConductorCore
import XCTest

final class SpriteAtlasTests: XCTestCase {
    func testDefaultRowsFollowCodexOrder() {
        let atlas = SpriteAtlas()
        XCTAssertEqual(atlas.row(for: .idle), SpriteAtlas.CodexRow.idle.rawValue)        // 0
        XCTAssertEqual(atlas.row(for: .thinking), SpriteAtlas.CodexRow.running.rawValue) // 7
        XCTAssertEqual(atlas.row(for: .needsYou), SpriteAtlas.CodexRow.review.rawValue)  // 8
        XCTAssertEqual(atlas.row(for: .celebrating), SpriteAtlas.CodexRow.jumping.rawValue) // 4
        XCTAssertEqual(atlas.row(for: .sad), SpriteAtlas.CodexRow.failed.rawValue)       // 5
        XCTAssertEqual(atlas.row(for: .sleeping), SpriteAtlas.CodexRow.idle.rawValue)    // 0
    }

    func testDefaultDimensions() {
        let atlas = SpriteAtlas()
        XCTAssertEqual(atlas.columns, 8)
        XCTAssertEqual(atlas.rows, 9)
    }

    func testFrameWrapsWithinRow() {
        let atlas = SpriteAtlas(columns: 8, rows: 9)
        XCTAssertEqual(atlas.cell(for: .thinking, frame: 0).column, 0)
        XCTAssertEqual(atlas.cell(for: .thinking, frame: 7).column, 7)
        XCTAssertEqual(atlas.cell(for: .thinking, frame: 8).column, 0)   // 回绕
        XCTAssertEqual(atlas.cell(for: .thinking, frame: 17).column, 1)
    }

    func testNegativeFrameWraps() {
        let atlas = SpriteAtlas(columns: 8, rows: 9)
        XCTAssertEqual(atlas.cell(for: .idle, frame: -1).column, 7)
        XCTAssertEqual(atlas.cell(for: .idle, frame: -8).column, 0)
    }

    func testCellRowMatchesMood() {
        let atlas = SpriteAtlas()
        XCTAssertEqual(atlas.cell(for: .sad, frame: 3).row, SpriteAtlas.CodexRow.failed.rawValue)
    }

    func testMissingMoodFallsToRowZero() {
        let atlas = SpriteAtlas(columns: 4, rows: 4, rowForMood: [.thinking: 2])
        XCTAssertEqual(atlas.row(for: .idle), 0)       // 未映射 → 0
        XCTAssertEqual(atlas.row(for: .thinking), 2)
    }

    func testOutOfRangeRowClamped() {
        let atlas = SpriteAtlas(columns: 4, rows: 3, rowForMood: [.sad: 99, .idle: -5])
        XCTAssertEqual(atlas.row(for: .sad), 2)    // clamp 到 rows-1
        XCTAssertEqual(atlas.row(for: .idle), 0)   // clamp 到 0
    }

    func testCustomMapping() {
        let atlas = SpriteAtlas(columns: 6, rows: 6,
                                rowForMood: [.idle: 5, .needsYou: 0])
        XCTAssertEqual(atlas.row(for: .idle), 5)
        XCTAssertEqual(atlas.cell(for: .needsYou, frame: 6).column, 0)
    }
}
