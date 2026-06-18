@testable import ConductorCore
import Foundation
import XCTest

final class RPCProtocolTests: XCTestCase {
    private func object(_ line: String) -> [String: JSONValue]? {
        (try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)))?.objectValue
    }

    // MARK: 入站解析

    func testParseResponse() {
        guard case let .response(r)? = RPCInbound.parse(line:
            #"{"id":"req-1","type":"response","command":"get_state","success":true,"data":{"x":1}}"#)
        else { return XCTFail("应解析为 response") }
        XCTAssertEqual(r.id, "req-1")
        XCTAssertEqual(r.command, "get_state")
        XCTAssertTrue(r.success)
        XCTAssertEqual(r.data?.objectValue?["x"]?.intValue, 1)
    }

    func testParseResponseNumericIdCoerced() {
        guard case let .response(r)? = RPCInbound.parse(line:
            #"{"id":5,"type":"response","command":"abort","success":false}"#)
        else { return XCTFail() }
        XCTAssertEqual(r.id, "5")
        XCTAssertFalse(r.success)
    }

    func testParseToolExecutionStart() {
        guard case let .event(.toolExecutionStart(id, name, args))? = RPCInbound.parse(line:
            #"{"type":"tool_execution_start","toolCallId":"c1","toolName":"bash","args":{"command":"ls"}}"#)
        else { return XCTFail() }
        XCTAssertEqual(id, "c1")
        XCTAssertEqual(name, "bash")
        XCTAssertEqual(args?.objectValue?["command"]?.stringValue, "ls")
    }

    func testParseMessageUpdateTextDelta() {
        guard case let .event(.messageUpdate(delta, _))? = RPCInbound.parse(line:
            #"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":2,"delta":"Hi"}}"#)
        else { return XCTFail() }
        XCTAssertEqual(delta, .textDelta(contentIndex: 2, delta: "Hi"))
    }

    func testParseExtensionUIRequestConfirm() {
        guard case let .uiRequest(ui)? = RPCInbound.parse(line:
            #"{"type":"extension_ui_request","id":"u1","method":"confirm","title":"conductor-feed","message":"{}"}"#)
        else { return XCTFail() }
        XCTAssertEqual(ui.id, "u1")
        XCTAssertEqual(ui.method, .confirm)
        XCTAssertTrue(ui.method.isDialog)
        XCTAssertEqual(ui.title, "conductor-feed")
    }

    func testParseUnknownEventTypeDoesNotCrash() {
        guard case let .event(.unknown(type, _))? = RPCInbound.parse(line:
            #"{"type":"banana_event","foo":1}"#)
        else { return XCTFail("未知事件应落 .event(.unknown)") }
        XCTAssertEqual(type, "banana_event")
    }

    func testParseMissingTypeIsUnknown() {
        guard case let .unknown(type, _)? = RPCInbound.parse(line: #"{"foo":1}"#) else { return XCTFail() }
        XCTAssertNil(type)
    }

    func testParseInvalidJSONReturnsNil() {
        XCTAssertNil(RPCInbound.parse(line: "not json at all"))
        XCTAssertNil(RPCInbound.parse(line: "[1,2,3]"))  // 合法 JSON 但非对象
    }

    func testParseAutoRetryStart() {
        guard case let .event(.autoRetryStart(attempt, maxAttempts, msg))? = RPCInbound.parse(line:
            #"{"type":"auto_retry_start","attempt":1,"maxAttempts":3,"delayMs":2000,"errorMessage":"overloaded"}"#)
        else { return XCTFail() }
        XCTAssertEqual(attempt, 1)
        XCTAssertEqual(maxAttempts, 3)
        XCTAssertEqual(msg, "overloaded")
    }

    // MARK: 出站编码（往返）

    func testPromptLine() {
        let o = object(RPCCommand.prompt(message: "hi").line(id: "1"))
        XCTAssertEqual(o?["type"]?.stringValue, "prompt")
        XCTAssertEqual(o?["message"]?.stringValue, "hi")
        XCTAssertEqual(o?["id"]?.stringValue, "1")
        XCTAssertNil(o?["streamingBehavior"])
    }

    func testPromptWithStreamingBehavior() {
        let o = object(RPCCommand.prompt(message: "x", streamingBehavior: .steer).line())
        XCTAssertEqual(o?["streamingBehavior"]?.stringValue, "steer")
    }

    func testAbortLine() {
        let o = object(RPCCommand.abort.line())
        XCTAssertEqual(o?["type"]?.stringValue, "abort")
        XCTAssertNil(o?["id"])
    }

    func testSetModelLine() {
        let o = object(RPCCommand.setModel(provider: "anthropic", modelId: "claude-x").line(id: "7"))
        XCTAssertEqual(o?["type"]?.stringValue, "set_model")
        XCTAssertEqual(o?["provider"]?.stringValue, "anthropic")
        XCTAssertEqual(o?["modelId"]?.stringValue, "claude-x")
        XCTAssertEqual(o?["id"]?.stringValue, "7")
    }

    func testExtensionUIResponseLine() {
        let o = object(ExtensionUIResponse(id: "u1", confirmed: true).line())
        XCTAssertEqual(o?["type"]?.stringValue, "extension_ui_response")
        XCTAssertEqual(o?["id"]?.stringValue, "u1")
        XCTAssertEqual(o?["confirmed"]?.boolValue, true)
        XCTAssertNil(o?["value"])
    }
}
