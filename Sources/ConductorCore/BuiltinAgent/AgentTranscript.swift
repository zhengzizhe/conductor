import Foundation

/// 内置 Agent 的会话转写：把 `RPCEvent` 流归约成可渲染的有序条目。纯值类型、可单测。
///
/// 归约规则要点：流式文本/思考增量累积成同一气泡；工具调用按 `toolCallId` 配对 start→update→end；
/// 工具或思考插入会"打断"当前文本气泡（其后的文本起新气泡）；缺失 end 不崩（保持 running）。
public struct AgentTranscript: Equatable, Sendable {
    public struct ToolCall: Equatable, Sendable {
        public enum Status: String, Equatable, Sendable { case running, done, error }
        public var toolCallId: String
        public var toolName: String
        public var args: JSONValue?
        public var status: Status
        public var output: String

        public init(toolCallId: String, toolName: String, args: JSONValue?,
                    status: Status, output: String = "") {
            self.toolCallId = toolCallId; self.toolName = toolName; self.args = args
            self.status = status; self.output = output
        }
    }

    public enum Item: Equatable, Sendable {
        case user(text: String)
        case assistant(text: String)
        case thinking(text: String)
        case tool(ToolCall)
        case notice(text: String)
    }

    public private(set) var items: [Item] = []
    public private(set) var isStreaming = false

    private var openTextIndex: Int?
    private var openThinkingIndex: Int?
    private var toolIndexByID: [String: Int] = [:]

    public init() {}

    /// 用户提交的 prompt（不是 pi 事件，由 session 在发送时调用）。
    public mutating func appendUser(_ text: String) {
        closeOpenBlocks()
        items.append(.user(text: text))
    }

    public mutating func apply(_ event: RPCEvent) {
        switch event {
        case .agentStart:
            isStreaming = true
        case .agentEnd:
            isStreaming = false
            closeOpenBlocks()
        case .turnStart, .turnEnd:
            closeOpenBlocks()

        case let .messageUpdate(delta, _):
            switch delta {
            case let .textDelta(_, text): appendAssistantText(text)
            case let .thinkingDelta(_, text): appendThinkingText(text)
            case .textEnd: openTextIndex = nil
            case .thinkingEnd: openThinkingIndex = nil
            default: break  // toolcall 增量由 tool_execution_* 事件承载
            }

        case let .toolExecutionStart(id, name, args):
            closeOpenBlocks()
            items.append(.tool(ToolCall(toolCallId: id, toolName: name, args: args, status: .running)))
            // 空 id 不入索引：否则两个缺 id 的并发工具会共用 key ""，后者覆盖前者、
            // 前者的 end 改到后者气泡、前者永远 .running。空 id 的工具就让它独立、不配对。
            if !id.isEmpty { toolIndexByID[id] = items.count - 1 }
        case let .toolExecutionUpdate(id, _, partial):
            updateTool(id) { $0.output = Self.extractText(partial) ?? $0.output }
        case let .toolExecutionEnd(id, _, result, isError):
            updateTool(id) {
                $0.status = isError ? .error : .done
                if let text = Self.extractText(result) { $0.output = text }
            }

        case let .extensionError(path, ev, error):
            let where_ = [path, ev].compactMap { $0 }.joined(separator: " · ")
            items.append(.notice(text: where_.isEmpty ? "扩展错误：\(error)" : "扩展错误（\(where_)）：\(error)"))
        case let .autoRetryStart(attempt, maxAttempts, message):
            let n = attempt.map(String.init) ?? "?"
            let m = maxAttempts.map(String.init) ?? "?"
            items.append(.notice(text: "重试 \(n)/\(m)" + (message.map { "：\($0)" } ?? "")))
        case let .compactionStart(reason):
            items.append(.notice(text: "压缩上下文" + (reason.map { "（\($0)）" } ?? "")))

        default:
            break  // messageStart/End、compactionEnd、autoRetryEnd、queueUpdate、unknown 等 M1 不进转写
        }
    }

    // MARK: - 私有

    private mutating func appendAssistantText(_ text: String) {
        guard !text.isEmpty else { return }
        openThinkingIndex = nil
        if let i = openTextIndex, case let .assistant(existing) = items[i] {
            items[i] = .assistant(text: existing + text)
        } else {
            items.append(.assistant(text: text))
            openTextIndex = items.count - 1
        }
    }

    private mutating func appendThinkingText(_ text: String) {
        guard !text.isEmpty else { return }
        openTextIndex = nil
        if let i = openThinkingIndex, case let .thinking(existing) = items[i] {
            items[i] = .thinking(text: existing + text)
        } else {
            items.append(.thinking(text: text))
            openThinkingIndex = items.count - 1
        }
    }

    private mutating func updateTool(_ id: String, _ mutate: (inout ToolCall) -> Void) {
        guard let i = toolIndexByID[id], case .tool(var tc) = items[i] else { return }
        mutate(&tc)
        items[i] = .tool(tc)
    }

    private mutating func closeOpenBlocks() {
        openTextIndex = nil
        openThinkingIndex = nil
    }

    /// 从工具结果/部分结果里抽取可见文本：`{content:[{type:"text",text:...}]}`。
    static func extractText(_ value: JSONValue?) -> String? {
        guard let content = value?.objectValue?["content"]?.arrayValue else { return nil }
        let texts = content.compactMap { block -> String? in
            guard block.objectValue?["type"]?.stringValue == "text" else { return nil }
            return block.objectValue?["text"]?.stringValue
        }
        return texts.isEmpty ? nil : texts.joined()
    }
}
