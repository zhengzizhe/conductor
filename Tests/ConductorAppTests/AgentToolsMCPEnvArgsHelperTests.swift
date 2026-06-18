import XCTest
@testable import ConductorApp

/// MCP 工作台的 env / args 文本辅助函数单测（纯函数，无磁盘依赖）。
/// 注意：本机若只装了 Command Line Tools（无 Xcode）跑不了 XCTest；需在 CI 或带 Xcode 的机器上跑。
final class AgentToolsMCPEnvArgsHelperTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("conductor-mcp-envargs-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - mcpWorkbenchParseEnv

    func testParseEnvBasicTwoPairs() {
        let parsed = mcpWorkbenchParseEnv("A=1, B=2")
        XCTAssertEqual(parsed, ["A": "1", "B": "2"])
    }

    func testParseEnvTrimsSpacesAroundKeyAndValue() {
        let parsed = mcpWorkbenchParseEnv("  A =  1  ,  B  = 2 ")
        XCTAssertEqual(parsed["A"], "1", "键两侧空白应被裁掉")
        XCTAssertEqual(parsed["B"], "2", "值两侧空白应被裁掉")
        XCTAssertEqual(parsed.count, 2)
    }

    func testParseEnvIgnoresEntriesWithoutEquals() {
        let parsed = mcpWorkbenchParseEnv("A=1, JUSTAKEY, B=2")
        XCTAssertEqual(parsed, ["A": "1", "B": "2"], "无 '=' 的段应被忽略")
        XCTAssertNil(parsed["JUSTAKEY"])
    }

    func testParseEnvKeepsEqualsInValueAfterFirst() {
        let parsed = mcpWorkbenchParseEnv("TOKEN=a=b=c")
        XCTAssertEqual(parsed["TOKEN"], "a=b=c", "首个 '=' 之后的内容（含 '='）应整体作为值")
    }

    func testParseEnvIgnoresEmptyKey() {
        let parsed = mcpWorkbenchParseEnv("=novalue, A=1")
        XCTAssertNil(parsed[""], "空键应被忽略")
        XCTAssertEqual(parsed["A"], "1")
        XCTAssertEqual(parsed.count, 1)
    }

    func testParseEnvAllowsEmptyValue() {
        let parsed = mcpWorkbenchParseEnv("EMPTY=, A=1")
        XCTAssertEqual(parsed["EMPTY"], "", "'KEY=' 形式应得到空值")
        XCTAssertEqual(parsed["A"], "1")
        XCTAssertEqual(parsed.count, 2)
    }

    func testParseEnvEmptyTextYieldsEmptyDict() {
        XCTAssertTrue(mcpWorkbenchParseEnv("").isEmpty)
        XCTAssertTrue(mcpWorkbenchParseEnv("   ").isEmpty, "全空白应得到空字典")
    }

    func testParseEnvSinglePair() {
        XCTAssertEqual(mcpWorkbenchParseEnv("ONLY=value"), ["ONLY": "value"])
    }

    func testParseEnvDuplicateKeyLastWins() {
        let parsed = mcpWorkbenchParseEnv("A=1, A=2")
        XCTAssertEqual(parsed["A"], "2", "重复键后者覆盖前者")
        XCTAssertEqual(parsed.count, 1)
    }

    // MARK: - mcpWorkbenchSplitArgs

    func testSplitArgsBasicWhitespace() {
        XCTAssertEqual(mcpWorkbenchSplitArgs("a b c"), ["a", "b", "c"])
    }

    func testSplitArgsDropsEmptyFromExtraSpaces() {
        XCTAssertEqual(mcpWorkbenchSplitArgs("  a   b  "), ["a", "b"], "多余空白产生的空段应被丢弃")
    }

    func testSplitArgsHandlesTabsAndNewlines() {
        XCTAssertEqual(mcpWorkbenchSplitArgs("a\tb\nc"), ["a", "b", "c"], "制表/换行也算空白分隔")
    }

    func testSplitArgsEmptyAndBlankYieldEmpty() {
        XCTAssertTrue(mcpWorkbenchSplitArgs("").isEmpty)
        XCTAssertTrue(mcpWorkbenchSplitArgs("    ").isEmpty, "全空白应得到空数组")
    }

    func testSplitArgsSingleToken() {
        XCTAssertEqual(mcpWorkbenchSplitArgs("solo"), ["solo"])
    }

    // MARK: - mcpWorkbenchFormatEnv

    func testFormatEnvSortsKeys() {
        let formatted = mcpWorkbenchFormatEnv(["B": "2", "A": "1", "C": "3"])
        XCTAssertEqual(formatted, "A=1, B=2, C=3", "键应按字典序排序输出")
    }

    func testFormatEnvEmptyDictYieldsEmptyString() {
        XCTAssertEqual(mcpWorkbenchFormatEnv([:]), "")
    }

    func testFormatEnvSinglePair() {
        XCTAssertEqual(mcpWorkbenchFormatEnv(["KEY": "value"]), "KEY=value")
    }

    func testFormatEnvCoercesNonStringValues() {
        let formatted = mcpWorkbenchFormatEnv(["N": 42, "B": true])
        // 键排序：B 在 N 之前
        XCTAssertEqual(formatted, "B=true, N=42", "非字符串值应被字符串化")
    }

    // MARK: - round trip

    func testFormatThenParseRoundTrip() {
        let original = ["A": "1", "B": "2", "C": "three"]
        let formatted = mcpWorkbenchFormatEnv(original)
        let parsed = mcpWorkbenchParseEnv(formatted)
        XCTAssertEqual(parsed, original, "format 再 parse 应还原原始字典")
    }

    func testParseThenFormatRoundTrip() {
        let text = "A=1, B=2"
        let parsed = mcpWorkbenchParseEnv(text)
        let formatted = mcpWorkbenchFormatEnv(parsed)
        // format 会排序，所以 A 在 B 前，正好与输入一致
        XCTAssertEqual(formatted, "A=1, B=2")
        XCTAssertEqual(mcpWorkbenchParseEnv(formatted), parsed, "再 parse 应稳定")
    }
}
