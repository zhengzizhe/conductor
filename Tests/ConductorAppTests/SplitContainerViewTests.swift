@testable import ConductorApp
import ConductorCore
import XCTest

@MainActor
final class SplitContainerViewTests: XCTestCase {
    func testRatioSplitViewRestyleUsesClearBackground() {
        // 终端画布透明：split 背景恒为 clear（露出窗口毛玻璃，pane 卡片自带实色保可读），与主题无关。
        let split = RatioSplitView()
        split.restyleForCurrentTheme()
        XCTAssertEqual(split.layer?.backgroundColor?.alpha, 0)
    }

    func testRatioSplitViewDividerUsesThemeDividerToken() {
        let split = RatioSplitView()
        XCTAssertEqual(components(of: split.dividerColor), components(of: AppStyle.splitDivider))
        XCTAssertNotEqual(components(of: split.dividerColor), components(of: NSColor(AppStyle.windowBackground)))
        XCTAssertLessThan(split.dividerColor.alphaComponent, 0.7)
    }

    private func components(of color: NSColor) -> [CGFloat] {
        guard let converted = color.usingColorSpace(.sRGB) else {
            XCTFail("Expected color to convert to sRGB")
            return []
        }
        return [
            converted.redComponent,
            converted.greenComponent,
            converted.blueComponent,
            converted.alphaComponent,
        ]
    }
}
