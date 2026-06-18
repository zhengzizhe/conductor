import Foundation

/// 内置 Agent 与打包的 `pi --mode rpc` 子进程之间的 JSONL 协议（stdin 发命令、stdout 收事件/响应/扩展 UI 请求）。
///
/// 设计取向：**只把协议信封 + 我们真正要消费的字段建成强类型**；深层载荷（完整 AgentMessage
/// 之类）保留为 `JSONValue` 原样透传，避免过度建模、随 pi 版本漂移而崩。未知顶层 type / 事件 type
/// 一律落 `.unknown`，永不 throw（向前兼容）。
public enum RPCProtocol {
    /// 协议对应的 pi 版本（钉版本用；破坏性变更时 +1）。
    public static let piVersion = "0.79.4"
}

// MARK: - 入站（pi → Conductor，stdout）

/// 从 pi stdout 读到的一条消息。
public enum RPCInbound: Equatable, Sendable {
    case response(RPCResponse)
    case event(RPCEvent)
    case uiRequest(ExtensionUIRequest)
    /// 合法 JSON 但没有可识别的顶层 `type`。
    case unknown(type: String?, raw: JSONValue)

    /// 解析一行 JSONL。非法 JSON / 非对象返回 nil（调用方记日志跳过）；合法但不认识的 type 落 `.unknown`/`.event(.unknown)`。
    public static func parse(_ data: Data) -> RPCInbound? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = value.objectValue else { return nil }
        switch object["type"]?.stringValue {
        case "response": return .response(RPCResponse(object: object))
        case "extension_ui_request": return .uiRequest(ExtensionUIRequest(object: object))
        case let .some(type): return .event(RPCEvent(type: type, object: object))
        case .none: return .unknown(type: nil, raw: value)
        }
    }

    public static func parse(line: String) -> RPCInbound? { parse(Data(line.utf8)) }
}

/// 对某条命令的响应（带 `id` 回执）。
public struct RPCResponse: Equatable, Sendable {
    public var id: String?
    public var command: String
    public var success: Bool
    public var data: JSONValue?
    public var error: String?

    public init(id: String?, command: String, success: Bool, data: JSONValue? = nil, error: String? = nil) {
        self.id = id; self.command = command; self.success = success; self.data = data; self.error = error
    }

    init(object: [String: JSONValue]) {
        self.id = object["id"]?.coercedString
        self.command = object["command"]?.stringValue ?? ""
        self.success = object["success"]?.boolValue ?? false
        self.data = object["data"]
        self.error = object["error"]?.stringValue
    }
}

/// agent 运行期事件（无 `id`）。只强类型化我们要渲染/响应的字段。
public enum RPCEvent: Equatable, Sendable {
    case agentStart
    case agentEnd(messages: JSONValue?)
    case turnStart
    case turnEnd(message: JSONValue?, toolResults: JSONValue?)
    case messageStart(message: JSONValue?)
    case messageUpdate(delta: AssistantDelta, message: JSONValue?)
    case messageEnd(message: JSONValue?)
    case toolExecutionStart(toolCallId: String, toolName: String, args: JSONValue?)
    case toolExecutionUpdate(toolCallId: String, toolName: String, partialResult: JSONValue?)
    case toolExecutionEnd(toolCallId: String, toolName: String, result: JSONValue?, isError: Bool)
    case queueUpdate(steering: [String], followUp: [String])
    case compactionStart(reason: String?)
    case compactionEnd(reason: String?, aborted: Bool)
    case autoRetryStart(attempt: Int?, maxAttempts: Int?, errorMessage: String?)
    case autoRetryEnd(success: Bool, attempt: Int?)
    case extensionError(extensionPath: String?, event: String?, error: String)
    /// 合法事件但 type 不在已知集（向前兼容）。
    case unknown(type: String, raw: JSONValue)

    init(type: String, object: [String: JSONValue]) {
        func strings(_ key: String) -> [String] {
            (object[key]?.arrayValue ?? []).compactMap { $0.stringValue }
        }
        switch type {
        case "agent_start": self = .agentStart
        case "agent_end": self = .agentEnd(messages: object["messages"])
        case "turn_start": self = .turnStart
        case "turn_end": self = .turnEnd(message: object["message"], toolResults: object["toolResults"])
        case "message_start": self = .messageStart(message: object["message"])
        case "message_update":
            self = .messageUpdate(
                delta: AssistantDelta(object: object["assistantMessageEvent"]?.objectValue ?? [:]),
                message: object["message"])
        case "message_end": self = .messageEnd(message: object["message"])
        case "tool_execution_start":
            self = .toolExecutionStart(
                toolCallId: object["toolCallId"]?.stringValue ?? "",
                toolName: object["toolName"]?.stringValue ?? "",
                args: object["args"])
        case "tool_execution_update":
            self = .toolExecutionUpdate(
                toolCallId: object["toolCallId"]?.stringValue ?? "",
                toolName: object["toolName"]?.stringValue ?? "",
                partialResult: object["partialResult"])
        case "tool_execution_end":
            self = .toolExecutionEnd(
                toolCallId: object["toolCallId"]?.stringValue ?? "",
                toolName: object["toolName"]?.stringValue ?? "",
                result: object["result"],
                isError: object["isError"]?.boolValue ?? false)
        case "queue_update":
            self = .queueUpdate(steering: strings("steering"), followUp: strings("followUp"))
        case "compaction_start": self = .compactionStart(reason: object["reason"]?.stringValue)
        case "compaction_end":
            self = .compactionEnd(reason: object["reason"]?.stringValue,
                                  aborted: object["aborted"]?.boolValue ?? false)
        case "auto_retry_start":
            self = .autoRetryStart(attempt: object["attempt"]?.intValue,
                                   maxAttempts: object["maxAttempts"]?.intValue,
                                   errorMessage: object["errorMessage"]?.stringValue)
        case "auto_retry_end":
            self = .autoRetryEnd(success: object["success"]?.boolValue ?? false,
                                 attempt: object["attempt"]?.intValue)
        case "extension_error":
            self = .extensionError(extensionPath: object["extensionPath"]?.stringValue,
                                   event: object["event"]?.stringValue,
                                   error: object["error"]?.stringValue ?? "")
        default:
            self = .unknown(type: type, raw: .object(object))
        }
    }
}

/// `message_update` 里的流式增量（`assistantMessageEvent`）。
public enum AssistantDelta: Equatable, Sendable {
    case start
    case textStart(contentIndex: Int)
    case textDelta(contentIndex: Int, delta: String)
    case textEnd(contentIndex: Int)
    case thinkingStart(contentIndex: Int)
    case thinkingDelta(contentIndex: Int, delta: String)
    case thinkingEnd(contentIndex: Int)
    case toolcallStart(contentIndex: Int)
    case toolcallDelta(contentIndex: Int, delta: String)
    case toolcallEnd(contentIndex: Int)
    case done(reason: String?)
    case error(reason: String?)
    case unknown(type: String)

    init(object: [String: JSONValue]) {
        let index = object["contentIndex"]?.intValue ?? 0
        let delta = object["delta"]?.stringValue ?? ""
        switch object["type"]?.stringValue {
        case "start": self = .start
        case "text_start": self = .textStart(contentIndex: index)
        case "text_delta": self = .textDelta(contentIndex: index, delta: delta)
        case "text_end": self = .textEnd(contentIndex: index)
        case "thinking_start": self = .thinkingStart(contentIndex: index)
        case "thinking_delta": self = .thinkingDelta(contentIndex: index, delta: delta)
        case "thinking_end": self = .thinkingEnd(contentIndex: index)
        case "toolcall_start": self = .toolcallStart(contentIndex: index)
        case "toolcall_delta": self = .toolcallDelta(contentIndex: index, delta: delta)
        case "toolcall_end": self = .toolcallEnd(contentIndex: index)
        case "done": self = .done(reason: object["reason"]?.stringValue)
        case "error": self = .error(reason: object["reason"]?.stringValue)
        case let .some(other): self = .unknown(type: other)
        case .none: self = .unknown(type: "")
        }
    }
}

/// 扩展（含我们的 conductor-bridge）发起的 UI 请求。对话方法（select/confirm/input/editor）需回 `ExtensionUIResponse`。
public struct ExtensionUIRequest: Equatable, Sendable {
    public var id: String
    public var method: Method
    public var title: String?
    public var message: String?
    public var options: [String]?
    public var notifyType: String?
    public var timeoutMs: Int?
    public var raw: JSONValue

    public enum Method: Equatable, Sendable {
        case select, confirm, input, editor, notify, setStatus, setWidget, setTitle, setEditorText
        case other(String)

        /// 需要宿主回 `extension_ui_response` 才解阻塞的对话方法。
        public var isDialog: Bool {
            switch self {
            case .select, .confirm, .input, .editor: return true
            default: return false
            }
        }

        init(_ raw: String) {
            switch raw {
            case "select": self = .select
            case "confirm": self = .confirm
            case "input": self = .input
            case "editor": self = .editor
            case "notify": self = .notify
            case "setStatus": self = .setStatus
            case "setWidget": self = .setWidget
            case "setTitle": self = .setTitle
            case "set_editor_text": self = .setEditorText
            default: self = .other(raw)
            }
        }
    }

    public init(id: String, method: Method, title: String? = nil, message: String? = nil,
                options: [String]? = nil, notifyType: String? = nil, timeoutMs: Int? = nil,
                raw: JSONValue = .object([:])) {
        self.id = id; self.method = method; self.title = title; self.message = message
        self.options = options; self.notifyType = notifyType; self.timeoutMs = timeoutMs; self.raw = raw
    }

    init(object: [String: JSONValue]) {
        self.id = object["id"]?.stringValue ?? ""
        self.method = Method(object["method"]?.stringValue ?? "")
        self.title = object["title"]?.stringValue
        self.message = object["message"]?.stringValue
        self.options = object["options"]?.arrayValue?.compactMap { $0.stringValue }
        self.notifyType = object["notifyType"]?.stringValue
        self.timeoutMs = object["timeout"]?.intValue
        self.raw = .object(object)
    }
}

// MARK: - 出站（Conductor → pi，stdin）

/// 发给 pi 的命令。`line(id:)` 产出可直接写进 stdin 的一行 JSONL（不含尾随换行）。
public enum RPCCommand: Equatable, Sendable {
    case prompt(message: String, streamingBehavior: StreamingBehavior? = nil)
    case steer(message: String)
    case followUp(message: String)
    case abort
    case newSession
    case getState
    case getMessages
    case setModel(provider: String, modelId: String)
    case cycleModel
    case getAvailableModels
    case setThinkingLevel(String)
    case compact(customInstructions: String? = nil)
    case fork(entryId: String)
    case clone
    case switchSession(path: String)
    case getForkMessages
    case setSessionName(String)
    case getSessionStats

    public enum StreamingBehavior: String, Equatable, Sendable {
        case steer, followUp
    }

    /// 该命令的 `type` 与字段（不含 `id`）。
    public var object: [String: JSONValue] {
        switch self {
        case let .prompt(message, behavior):
            var o: [String: JSONValue] = ["type": "prompt", "message": .string(message)]
            if let behavior { o["streamingBehavior"] = .string(behavior.rawValue) }
            return o
        case let .steer(message): return ["type": "steer", "message": .string(message)]
        case let .followUp(message): return ["type": "follow_up", "message": .string(message)]
        case .abort: return ["type": "abort"]
        case .newSession: return ["type": "new_session"]
        case .getState: return ["type": "get_state"]
        case .getMessages: return ["type": "get_messages"]
        case let .setModel(provider, modelId):
            return ["type": "set_model", "provider": .string(provider), "modelId": .string(modelId)]
        case .cycleModel: return ["type": "cycle_model"]
        case .getAvailableModels: return ["type": "get_available_models"]
        case let .setThinkingLevel(level): return ["type": "set_thinking_level", "level": .string(level)]
        case let .compact(instructions):
            var o: [String: JSONValue] = ["type": "compact"]
            if let instructions { o["customInstructions"] = .string(instructions) }
            return o
        case let .fork(entryId): return ["type": "fork", "entryId": .string(entryId)]
        case .clone: return ["type": "clone"]
        case let .switchSession(path): return ["type": "switch_session", "sessionPath": .string(path)]
        case .getForkMessages: return ["type": "get_fork_messages"]
        case let .setSessionName(name): return ["type": "set_session_name", "name": .string(name)]
        case .getSessionStats: return ["type": "get_session_stats"]
        }
    }

    /// 序列化成一行 JSONL（不含换行）。`id` 用于请求/响应配对。
    public func line(id: String? = nil) -> String {
        var object = self.object
        if let id { object["id"] = .string(id) }
        return RPCLineCoder.encode(.object(object))
    }
}

/// 对扩展 UI 对话请求的应答（也走 stdin）。
public struct ExtensionUIResponse: Equatable, Sendable {
    public var id: String
    public var value: String?
    public var confirmed: Bool?
    public var cancelled: Bool?

    public init(id: String, value: String? = nil, confirmed: Bool? = nil, cancelled: Bool? = nil) {
        self.id = id; self.value = value; self.confirmed = confirmed; self.cancelled = cancelled
    }

    public func line() -> String {
        var object: [String: JSONValue] = ["type": "extension_ui_response", "id": .string(id)]
        if let value { object["value"] = .string(value) }
        if let confirmed { object["confirmed"] = .bool(confirmed) }
        if let cancelled { object["cancelled"] = .bool(cancelled) }
        return RPCLineCoder.encode(.object(object))
    }
}

/// JSONL 单行编码（紧凑、无换行）。
enum RPCLineCoder {
    static func encode(_ value: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

extension JSONValue {
    /// `id` 字段在 pi 里多为字符串，但也可能是数字——统一取成字符串。
    var coercedString: String? {
        switch self {
        case let .string(s): return s
        case let .int(i): return String(i)
        case let .double(d): return String(d)
        default: return nil
        }
    }
}
