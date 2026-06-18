@testable import ConductorCore
import Foundation
import XCTest

final class JSONLFramerTests: XCTestCase {
    private func feed(_ framer: inout JSONLFramer, _ s: String) -> [String] {
        framer.feed(Data(s.utf8))
    }

    func testSingleCompleteLine() {
        var f = JSONLFramer()
        XCTAssertEqual(feed(&f, "{\"a\":1}\n"), ["{\"a\":1}"])
    }

    func testPartialThenCompletedAcrossFeeds() {
        var f = JSONLFramer()
        XCTAssertEqual(feed(&f, "{\"a\":"), [])
        XCTAssertEqual(feed(&f, "1}\n"), ["{\"a\":1}"])
    }

    func testMultipleLinesInOneFeed() {
        var f = JSONLFramer()
        XCTAssertEqual(feed(&f, "a\nb\nc\n"), ["a", "b", "c"])
    }

    func testCoalescedPlusTrailingPartial() {
        var f = JSONLFramer()
        XCTAssertEqual(feed(&f, "a\nb\nhalf"), ["a", "b"])
        XCTAssertEqual(feed(&f, "rest\n"), ["halfrest"])
    }

    func testCRLFStripped() {
        var f = JSONLFramer()
        XCTAssertEqual(feed(&f, "x\r\ny\r\n"), ["x", "y"])
    }

    func testBlankLinesSkipped() {
        var f = JSONLFramer()
        XCTAssertEqual(feed(&f, "\n\n{}\n\n"), ["{}"])
    }

    /// 核心防坑：U+2028 在 JSON 字符串里合法，绝不能被当行分隔符切开。
    func testUnicodeLineSeparatorsNotSplit() {
        var f = JSONLFramer()
        let lines = feed(&f, "{\"t\":\"a\u{2028}b\u{2029}c\"}\n")
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("\u{2028}"))
        XCTAssertTrue(lines[0].contains("\u{2029}"))
    }

    func testFlushReturnsTrailingPartialOnce() {
        var f = JSONLFramer()
        XCTAssertEqual(feed(&f, "tail-no-newline"), [])
        XCTAssertEqual(f.flush(), "tail-no-newline")
        XCTAssertNil(f.flush())
    }

    func testFlushNilWhenEmpty() {
        var f = JSONLFramer()
        XCTAssertNil(f.flush())
    }

    /// 上限保护：无换行的洪流（坏 pi / 二进制垃圾）不该把内存撑爆——超限丢弃缓冲，
    /// 遇到下一条换行重新对齐。
    func testNoNewlineFloodDiscardsBufferAndRecovers() {
        var f = JSONLFramer()
        let flood = Data(repeating: 0x41, count: JSONLFramer.maxBuffer + 1)   // 'A'×(上限+1)，无 \n
        XCTAssertEqual(f.feed(flood), [])                 // 超限即丢弃，不无界增长
        XCTAssertEqual(feed(&f, "fresh\n"), ["fresh"])    // 丢弃后能重新对齐
    }
}
