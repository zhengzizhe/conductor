import Foundation

/// conductor 自动化协议：Unix socket 上的 NDJSON（一行一个 JSON）。
/// 请求 `{"id":1,"method":"workspace.list","params":{...}}`；
/// 响应 `{"id":1,"ok":true,"result":...}` 或 `{"id":1,"ok":false,"error":{"code":...,"message":...}}`。
/// CLI 与 app 内服务共用这套类型，确保两端永远同构。
public enum AutomationProtocol {
    /// 协议版本：破坏性改动时 +1，CLI 据此提示升级。
    public static let version = 1
    public static let socketPathEnvKey = "CONDUCTOR_SOCKET_PATH"

    /// Conductor app and CLI share one local automation socket.
    public static var defaultSocketURL: URL {
        if let override = ProcessInfo.processInfo.environment[socketPathEnvKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("conductor", isDirectory: true)
            .appendingPathComponent("automation.sock", isDirectory: false)
    }
}

public enum AutomationMethod {
    public static let appPing = "app.ping"
    public static let appStatus = "app.status"
    public static let appMethods = "app.methods"
    public static let appOpenTools = "app.open-tools"
    public static let appOpenTaskCards = "app.open-task-cards"

    public static let workspaceList = "workspace.list"
    public static let workspaceCurrent = "workspace.current"
    public static let workspaceSelect = "workspace.select"
    public static let workspaceCreate = "workspace.create"
    public static let workspaceRename = "workspace.rename"
    public static let workspaceClose = "workspace.close"
    public static let workspaceTree = "workspace.tree"
    public static let workspaceStatusSet = "workspace.status.set"
    public static let workspaceStatusList = "workspace.status.list"
    public static let workspaceStatusClear = "workspace.status.clear"
    public static let workspaceProgressSet = "workspace.progress.set"
    public static let workspaceProgressClear = "workspace.progress.clear"
    public static let workspaceLogAppend = "workspace.log.append"
    public static let workspaceLogList = "workspace.log.list"
    public static let workspaceLogClear = "workspace.log.clear"

    public static let tabList = "tab.list"
    public static let tabCreate = "tab.create"
    public static let tabSelect = "tab.select"
    public static let tabRename = "tab.rename"
    public static let tabClose = "tab.close"

    public static let paneList = "pane.list"
    public static let paneCreate = "pane.create"
    public static let paneSplit = "pane.split"
    public static let paneFocus = "pane.focus"
    public static let paneClose = "pane.close"
    public static let paneRead = "pane.read"
    public static let paneKeys = "pane.keys"
    public static let paneNotify = "pane.notify"
    public static let paneResumeSet = "pane.resume.set"
    public static let paneResumeShow = "pane.resume.show"
    public static let paneResumeClear = "pane.resume.clear"

    public static let agentSend = "agent.send"
    public static let agentRun = "agent.run"
    public static let agentStatus = "agent.status"
    public static let agentResult = "agent.result"

    public static let activityList = "activity.list"
    public static let eventsRecent = "events.recent"

    public static let feedRequest = "feed.request"
    public static let feedList = "feed.list"
    public static let feedApprove = "feed.approve"
    public static let feedDeny = "feed.deny"
    public static let feedAnswer = "feed.answer"

    public static let all: [String] = [
        appPing, appStatus, appMethods, appOpenTools, appOpenTaskCards,
        workspaceList, workspaceCurrent, workspaceSelect, workspaceCreate, workspaceRename, workspaceClose,
        workspaceTree, workspaceStatusSet, workspaceStatusList, workspaceStatusClear,
        workspaceProgressSet, workspaceProgressClear, workspaceLogAppend, workspaceLogList, workspaceLogClear,
        tabList, tabCreate, tabSelect, tabRename, tabClose,
        paneList, paneCreate, paneSplit, paneFocus, paneClose, paneRead, paneKeys, paneNotify,
        paneResumeSet, paneResumeShow, paneResumeClear,
        agentSend, agentRun, agentStatus, agentResult,
        activityList, eventsRecent,
        feedRequest, feedList, feedApprove, feedDeny, feedAnswer,
    ]
}

public struct AutomationRequest: Codable, Sendable {
    public var id: Int?
    public var method: String
    public var params: [String: JSONValue]?

    public init(id: Int? = nil, method: String, params: [String: JSONValue]? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }

    /// 参数访问（缺省空字典）。
    public var parameters: [String: JSONValue] { params ?? [:] }
}

public struct AutomationError: Codable, Sendable, Error {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public static func badRequest(_ message: String) -> AutomationError {
        AutomationError(code: "bad-request", message: message)
    }

    public static func notFound(_ message: String) -> AutomationError {
        AutomationError(code: "not-found", message: message)
    }

    public static func unknownMethod(_ method: String) -> AutomationError {
        AutomationError(code: "unknown-method", message: "未知方法：\(method)")
    }

    public static func internalError(_ message: String) -> AutomationError {
        AutomationError(code: "internal", message: message)
    }
}

public struct AutomationResponse: Codable, Sendable {
    public var id: Int?
    public var ok: Bool
    public var result: JSONValue?
    public var error: AutomationError?

    public init(id: Int?, result: JSONValue) {
        self.id = id
        self.ok = true
        self.result = result
        self.error = nil
    }

    public init(id: Int?, error: AutomationError) {
        self.id = id
        self.ok = false
        self.result = nil
        self.error = error
    }
}

public enum AutomationCodec {
    /// 单行请求 → 请求对象。
    public static func decodeRequest(_ line: Data) throws -> AutomationRequest {
        try JSONDecoder().decode(AutomationRequest.self, from: line)
    }

    public static func decodeResponse(_ line: Data) throws -> AutomationResponse {
        try JSONDecoder().decode(AutomationResponse.self, from: line)
    }

    public static func encode(_ response: AutomationResponse) -> Data {
        (try? JSONEncoder().encode(response)) ?? Data("{\"ok\":false}".utf8)
    }

    public static func encode(_ request: AutomationRequest) -> Data {
        (try? JSONEncoder().encode(request)) ?? Data("{}".utf8)
    }
}
