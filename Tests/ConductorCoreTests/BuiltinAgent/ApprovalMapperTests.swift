@testable import ConductorCore
import Foundation
import XCTest

final class ApprovalMapperTests: XCTestCase {
    private func confirm(title: String, message: String) -> ExtensionUIRequest {
        ExtensionUIRequest(id: "u1", method: .confirm, title: title, message: message)
    }

    // MARK: pi 工具名 → 类别（修正 infer 的盲区）

    func testCategoryExecuteAndWrite() {
        XCTAssertEqual(ApprovalMapper.category(forPiTool: "bash"), .executeCommand)
        XCTAssertEqual(ApprovalMapper.category(forPiTool: "write"), .writeFile)
        XCTAssertEqual(ApprovalMapper.category(forPiTool: "edit"), .writeFile)
    }

    func testCategoryReadIncludingInferGaps() {
        XCTAssertEqual(ApprovalMapper.category(forPiTool: "read"), .readFile)
        XCTAssertEqual(ApprovalMapper.category(forPiTool: "grep"), .readFile)
        // 关键：infer 对这两个会落 .other（只读却误弹）；mapper 必须修正成 .readFile。
        XCTAssertEqual(FeedActionCategory.infer(toolName: "find"), .other)
        XCTAssertEqual(FeedActionCategory.infer(toolName: "ls"), .other)
        XCTAssertEqual(ApprovalMapper.category(forPiTool: "find"), .readFile)
        XCTAssertEqual(ApprovalMapper.category(forPiTool: "ls"), .readFile)
    }

    func testCategoryNetwork() {
        XCTAssertEqual(ApprovalMapper.category(forPiTool: "webfetch"), .network)
    }

    func testCategoryFallsBackToInferForUnknown() {
        XCTAssertEqual(ApprovalMapper.category(forPiTool: "run_shell_command"), .executeCommand)
        XCTAssertEqual(ApprovalMapper.category(forPiTool: "Frobnicate"), .other)
    }

    // MARK: confirm → FeedRequest

    func testFeedRequestFromTaggedConfirm() {
        let ui = confirm(title: ApprovalMapper.bridgeTag,
                         message: #"{"tool":"bash","command":"echo hi","cwd":"/repo"}"#)
        guard let req = ApprovalMapper.feedRequest(for: ui, agent: "builtin", paneID: "p1") else {
            return XCTFail("应解析出 FeedRequest")
        }
        XCTAssertEqual(req.tool, "bash")
        XCTAssertEqual(req.category, .executeCommand)
        XCTAssertEqual(req.detail, "echo hi")
        XCTAssertEqual(req.agent, "builtin")
        XCTAssertEqual(req.paneID, "p1")
        XCTAssertEqual(req.cwd, "/repo")
    }

    func testFeedRequestFindMapsToReadFile() {
        let ui = confirm(title: ApprovalMapper.bridgeTag, message: #"{"tool":"find","command":"find . -name x"}"#)
        XCTAssertEqual(ApprovalMapper.feedRequest(for: ui)?.category, .readFile)
    }

    func testFeedRequestEmptyCommandYieldsNilDetail() {
        let ui = confirm(title: ApprovalMapper.bridgeTag, message: #"{"tool":"ls","command":""}"#)
        let req = ApprovalMapper.feedRequest(for: ui)
        XCTAssertNotNil(req)
        XCTAssertNil(req?.detail)
    }

    func testFeedRequestRejectsUntaggedDialog() {
        let ui = confirm(title: "Clear session?", message: #"{"tool":"bash"}"#)
        XCTAssertNil(ApprovalMapper.feedRequest(for: ui))
    }

    func testFeedRequestRejectsNonConfirmMethod() {
        let ui = ExtensionUIRequest(id: "u1", method: .input, title: ApprovalMapper.bridgeTag,
                                    message: #"{"tool":"bash"}"#)
        XCTAssertNil(ApprovalMapper.feedRequest(for: ui))
    }

    func testFeedRequestRejectsBadMessageJSON() {
        XCTAssertNil(ApprovalMapper.feedRequest(for: confirm(title: ApprovalMapper.bridgeTag, message: "not json")))
        // 缺 tool 字段
        XCTAssertNil(ApprovalMapper.feedRequest(for: confirm(title: ApprovalMapper.bridgeTag, message: #"{"command":"x"}"#)))
    }

    // MARK: FeedDecision → 应答

    func testResponseAllow() {
        let r = ApprovalMapper.response(for: .allow(.once), requestID: "u1")
        XCTAssertEqual(r.id, "u1")
        XCTAssertEqual(r.confirmed, true)
    }

    func testResponseDeny() {
        XCTAssertEqual(ApprovalMapper.response(for: .deny(.tool), requestID: "u1").confirmed, false)
    }

    // MARK: dialogAction（session 决策逻辑，纯函数）

    func testDialogActionTaggedConfirmGoesToFeed() {
        let ui = confirm(title: ApprovalMapper.bridgeTag, message: #"{"tool":"bash","command":"ls"}"#)
        guard case let .approveViaFeed(req) = ApprovalMapper.dialogAction(for: ui) else {
            return XCTFail("应走 Feed")
        }
        XCTAssertEqual(req.tool, "bash")
    }

    func testDialogActionUnrecognizedDialogRespondsCancelled() {
        // 非我们 tag 的真对话（input）→ 必须回 cancelled，避免 pi 永久阻塞
        let ui = ExtensionUIRequest(id: "u9", method: .input, title: "Enter value", message: nil)
        XCTAssertEqual(ApprovalMapper.dialogAction(for: ui), .respondCancelled(id: "u9"))
    }

    func testDialogActionFireAndForgetIgnored() {
        let ui = ExtensionUIRequest(id: "u3", method: .notify, title: nil, message: "done")
        XCTAssertEqual(ApprovalMapper.dialogAction(for: ui), .ignore)
        let status = ExtensionUIRequest(id: "u4", method: .setStatus, title: nil, message: nil)
        XCTAssertEqual(ApprovalMapper.dialogAction(for: status), .ignore)
    }

    /// 带 bridgeTag 的 confirm 但 message 解析失败（桥协议漂移/字段类型不对）：
    /// 兜底仍走 Feed surface 给用户，而不是静默 cancel(=拒) 掉每个工具调用、无痕迹。
    func testBridgeTaggedButUnparsableStillSurfacesViaFeed() {
        let bad = confirm(title: ApprovalMapper.bridgeTag, message: "not json")
        guard case let .approveViaFeed(req) = ApprovalMapper.dialogAction(for: bad) else {
            return XCTFail("带 tag 的 confirm 解析失败也应兜底走 Feed，而非 cancel")
        }
        XCTAssertEqual(req.tool, "unknown")
        // 缺 tool 字段同理（之前会落到 respondCancelled）
        let noTool = confirm(title: ApprovalMapper.bridgeTag, message: #"{"command":"x"}"#)
        guard case .approveViaFeed = ApprovalMapper.dialogAction(for: noTool) else {
            return XCTFail("缺 tool 的 bridge confirm 也应兜底走 Feed")
        }
    }
}
