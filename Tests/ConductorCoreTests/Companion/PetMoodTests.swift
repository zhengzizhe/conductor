@testable import ConductorCore
import XCTest

final class PetMoodTests: XCTestCase {
    func testPriorityOrdering() {
        // needsYou > sad > thinking > celebrating > idle > sleeping
        let ordered: [PetMood] = [.needsYou, .sad, .thinking, .celebrating, .idle, .sleeping]
        let priorities = ordered.map(\.priority)
        XCTAssertEqual(priorities, priorities.sorted(by: >))
        XCTAssertEqual(Set(priorities).count, ordered.count, "优先级不应有并列")
    }

    func testNeedsYouIsHighest() {
        let top = PetMood.allCases.max(by: { $0.priority < $1.priority })
        XCTAssertEqual(top, .needsYou)
    }

    func testSleepingIsLowest() {
        let bottom = PetMood.allCases.min(by: { $0.priority < $1.priority })
        XCTAssertEqual(bottom, .sleeping)
    }

    func testAllCasesCovered() {
        XCTAssertEqual(PetMood.allCases.count, 6)
    }
}
