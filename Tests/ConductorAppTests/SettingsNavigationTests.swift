@testable import ConductorApp
import XCTest

final class SettingsNavigationTests: XCTestCase {
    func testDefaultSectionIsAppearance() {
        XCTAssertEqual(SettingsSectionID.default, .appearance)
    }

    func testTopLevelSectionsHaveStableOrder() {
        XCTAssertEqual(
            SettingsSectionID.allCases.map(\.title),
            ["外观", "终端", "高级", "行为", "伙伴", "快捷键"]
        )
    }
}
