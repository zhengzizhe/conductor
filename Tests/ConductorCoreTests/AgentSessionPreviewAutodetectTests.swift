import XCTest
@testable import ConductorCore

/// 未知/空 agent 时，transcript 仍能被自动探测格式读出真实回复（修"宠物只显示兜底文案"）。
final class AgentSessionPreviewAutodetectTests: XCTestCase {
    private func writeTemp(_ content: String) throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("transcript-\(UUID().uuidString).jsonl")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    func testUnknownAgentAutodetectsClaude() throws {
        let path = try writeTemp(#"""
        {"type":"user","message":{"content":"改一下"}}
        {"type":"assistant","message":{"content":[{"type":"text","text":"已经改好啦，跑通了"}]}}
        """#)
        let msgs = AgentSessionPreview.load(agent: "", filePath: path, limit: 4)
        XCTAssertEqual(msgs.last(where: { $0.role == .assistant })?.text, "已经改好啦，跑通了")
    }

    func testUnknownAgentAutodetectsCodex() throws {
        let path = try writeTemp(#"""
        {"type":"event_msg","payload":{"type":"user_message","message":"hi"}}
        {"type":"event_msg","payload":{"type":"agent_message","message":"done in codex"}}
        """#)
        let msgs = AgentSessionPreview.load(agent: "", filePath: path, limit: 4)
        XCTAssertEqual(msgs.last(where: { $0.role == .assistant })?.text, "done in codex")
    }

    func testKnownAgentStillWorks() throws {
        let path = try writeTemp(#"{"type":"assistant","message":{"content":[{"type":"text","text":"ok"}]}}"#)
        XCTAssertEqual(AgentSessionPreview.load(agent: "claude", filePath: path).last?.text, "ok")
    }
}
