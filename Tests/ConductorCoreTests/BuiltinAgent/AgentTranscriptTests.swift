@testable import ConductorCore
import Foundation
import XCTest

final class AgentTranscriptTests: XCTestCase {
    private func textDelta(_ s: String, _ i: Int = 0) -> RPCEvent {
        .messageUpdate(delta: .textDelta(contentIndex: i, delta: s), message: nil)
    }
    private func thinkingDelta(_ s: String) -> RPCEvent {
        .messageUpdate(delta: .thinkingDelta(contentIndex: 0, delta: s), message: nil)
    }
    private func toolResult(_ text: String) -> JSONValue {
        .object(["content": .array([.object(["type": "text", "text": .string(text)])])])
    }

    func testStreamingFlag() {
        var t = AgentTranscript()
        XCTAssertFalse(t.isStreaming)
        t.apply(.agentStart)
        XCTAssertTrue(t.isStreaming)
        t.apply(.agentEnd(messages: nil))
        XCTAssertFalse(t.isStreaming)
    }

    func testTextDeltaAccumulation() {
        var t = AgentTranscript()
        t.apply(.agentStart)
        t.apply(textDelta("Hello "))
        t.apply(textDelta("world"))
        XCTAssertEqual(t.items, [.assistant(text: "Hello world")])
    }

    func testThinkingThenTextAreSeparateBubbles() {
        var t = AgentTranscript()
        t.apply(thinkingDelta("let me think"))
        t.apply(textDelta("the answer"))
        XCTAssertEqual(t.items, [.thinking(text: "let me think"), .assistant(text: "the answer")])
    }

    func testToolLifecycleRunningToDone() {
        var t = AgentTranscript()
        t.apply(.toolExecutionStart(toolCallId: "c1", toolName: "bash", args: .object(["command": "ls"])))
        guard case let .tool(running) = t.items.first else { return XCTFail() }
        XCTAssertEqual(running.status, .running)
        XCTAssertEqual(running.toolName, "bash")

        t.apply(.toolExecutionUpdate(toolCallId: "c1", toolName: "bash", partialResult: toolResult("partial")))
        t.apply(.toolExecutionEnd(toolCallId: "c1", toolName: "bash", result: toolResult("final out"), isError: false))
        guard case let .tool(done) = t.items.first else { return XCTFail() }
        XCTAssertEqual(done.status, .done)
        XCTAssertEqual(done.output, "final out")
        XCTAssertEqual(t.items.count, 1)
    }

    func testToolErrorEnd() {
        var t = AgentTranscript()
        t.apply(.toolExecutionStart(toolCallId: "c1", toolName: "bash", args: nil))
        t.apply(.toolExecutionEnd(toolCallId: "c1", toolName: "bash",
                                  result: toolResult("Denied via Conductor Feed"), isError: true))
        guard case let .tool(tc) = t.items.first else { return XCTFail() }
        XCTAssertEqual(tc.status, .error)
        XCTAssertEqual(tc.output, "Denied via Conductor Feed")
    }

    func testMissingEndKeepsRunningNoCrash() {
        var t = AgentTranscript()
        t.apply(.toolExecutionStart(toolCallId: "c1", toolName: "bash", args: nil))
        t.apply(.toolExecutionStart(toolCallId: "c2", toolName: "read", args: nil))
        t.apply(.toolExecutionEnd(toolCallId: "c1", toolName: "bash", result: toolResult("ok"), isError: false))
        XCTAssertEqual(t.items.count, 2)
        guard case let .tool(a) = t.items[0], case let .tool(b) = t.items[1] else { return XCTFail() }
        XCTAssertEqual(a.status, .done)
        XCTAssertEqual(b.status, .running)
    }

    func testUpdateForUnknownToolIdIgnored() {
        var t = AgentTranscript()
        t.apply(.toolExecutionEnd(toolCallId: "ghost", toolName: "bash", result: toolResult("x"), isError: false))
        XCTAssertTrue(t.items.isEmpty)  // 没有对应 start，安静忽略，不崩
    }

    func testTextInterruptedByToolStartsNewBubble() {
        var t = AgentTranscript()
        t.apply(textDelta("before"))
        t.apply(.toolExecutionStart(toolCallId: "c1", toolName: "bash", args: nil))
        t.apply(textDelta("after"))
        XCTAssertEqual(t.items.count, 3)
        XCTAssertEqual(t.items[0], .assistant(text: "before"))
        if case .tool = t.items[1] {} else { XCTFail("中间应是工具") }
        XCTAssertEqual(t.items[2], .assistant(text: "after"))
    }

    func testExtensionErrorBecomesNotice() {
        var t = AgentTranscript()
        t.apply(.extensionError(extensionPath: "/x/bridge.ts", event: "tool_call", error: "boom"))
        guard case let .notice(text) = t.items.first else { return XCTFail() }
        XCTAssertTrue(text.contains("boom"))
    }

    func testUserAppend() {
        var t = AgentTranscript()
        t.appendUser("改一下登录逻辑")
        XCTAssertEqual(t.items, [.user(text: "改一下登录逻辑")])
    }

    func testEmptyDeltaDoesNotCreateBubble() {
        var t = AgentTranscript()
        t.apply(textDelta(""))
        XCTAssertTrue(t.items.isEmpty)
    }

    /// 空 toolCallId 不入索引：两个缺 id 的并发工具不该共用 key ""、塌成一条
    /// （后者覆盖前者索引、前者的 end 改到后者）。各自独立、互不串改。
    func testEmptyToolCallIdDoesNotCollapseConcurrentTools() {
        var t = AgentTranscript()
        t.apply(.toolExecutionStart(toolCallId: "", toolName: "bash", args: nil))
        t.apply(.toolExecutionStart(toolCallId: "", toolName: "read", args: nil))
        XCTAssertEqual(t.items.count, 2)   // 两条独立气泡，没塌成一条
        t.apply(.toolExecutionEnd(toolCallId: "", toolName: "bash", result: toolResult("x"), isError: false))
        guard case let .tool(a) = t.items[0], case let .tool(b) = t.items[1] else { return XCTFail() }
        XCTAssertEqual(a.status, .running)   // 空 id 不配对，保持 running——但绝不串改另一条
        XCTAssertEqual(b.status, .running)
    }
}
