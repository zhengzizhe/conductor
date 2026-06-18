@testable import ConductorApp
import XCTest

final class PaneHeaderActionPresentationTests: XCTestCase {
    func testPromotesFrequentPaneActionsToHeaderButtons() {
        XCTAssertEqual(PaneHeaderActionPresentation.primaryActions, [.splitRight, .splitDown, .zoom, .close])
    }

    func testKeepsTextAndPathActionsInMoreMenu() {
        XCTAssertEqual(PaneHeaderActionPresentation.moreActions, [.copy, .paste, .selectAll, .clear, .copyCwd, .openInFinder, .exportText])
    }
}
