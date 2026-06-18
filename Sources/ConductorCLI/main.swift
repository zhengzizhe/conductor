import ConductorCore
import Darwin
import Foundation

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct Options {
    var positional: [String] = []
    var values: [String: String] = [:]
    var flags: Set<String> = []

    func value(_ key: String) -> String? { values[key] }
    func has(_ key: String) -> Bool { flags.contains(key) || values[key] != nil }
}

func parseOptions(_ args: [String]) throws -> Options {
    let valueOptions: Set<String> = [
        "agent",
        "command",
        "cwd",
        "color",
        "direction",
        "host",
        "icon",
        "interval",
        "job",
        "jobId",
        "key",
        "label",
        "level",
        "limit",
        "name",
        "pane",
        "path",
        "poll",
        "port",
        "prompt",
        "source",
        "tab",
        "text",
        "title",
        "timeout",
        "value",
        "workspace",
    ]
    var options = Options()
    var index = 0
    while index < args.count {
        let arg = args[index]
        if arg == "--" {
            options.positional.append(contentsOf: args.dropFirst(index + 1))
            break
        }
        if arg.hasPrefix("--") {
            let raw = String(arg.dropFirst(2))
            if let equal = raw.firstIndex(of: "=") {
                let key = String(raw[..<equal])
                let value = String(raw[raw.index(after: equal)...])
                options.values[key] = value
            } else if valueOptions.contains(raw), index + 1 < args.count, !args[index + 1].hasPrefix("--") {
                options.values[raw] = args[index + 1]
                index += 1
            } else if valueOptions.contains(raw) {
                throw CLIError("--\(raw) requires a value")
            } else {
                options.flags.insert(raw)
            }
        } else {
            options.positional.append(arg)
        }
        index += 1
    }
    return options
}

final class SocketClient {
    private let socketURL: URL
    private var nextID = 1

    init(socketURL: URL = AutomationProtocol.defaultSocketURL) {
        self.socketURL = socketURL
    }

    func request(method: String, params: [String: JSONValue] = [:]) throws -> AutomationResponse {
        let automationRequest = AutomationRequest(id: nextID, method: method, params: params.isEmpty ? nil : params)
        nextID += 1
        return try request(automationRequest)
    }

    func request(_ request: AutomationRequest) throws -> AutomationResponse {
        try performRequest(request, throwOnRPCError: true)
    }

    func requestRaw(_ request: AutomationRequest) throws -> AutomationResponse {
        try performRequest(request, throwOnRPCError: false)
    }

    private func performRequest(_ request: AutomationRequest, throwOnRPCError: Bool) throws -> AutomationResponse {
        let response: AutomationResponse
        do {
            response = try send(request)
        } catch {
            AppLauncher.wake()
            let deadline = Date().addingTimeInterval(3)
            var lastError = error
            while Date() < deadline {
                usleep(150_000)
                let retryResponse: AutomationResponse
                do {
                    retryResponse = try send(request)
                } catch {
                    lastError = error
                    continue
                }
                if throwOnRPCError, let error = retryResponse.error {
                    throw CLIError("\(error.code): \(error.message)")
                }
                return retryResponse
            }
            throw CLIError("Could not connect to Conductor socket at \(socketURL.path): \(lastError)")
        }
        if throwOnRPCError, let error = response.error {
            throw CLIError("\(error.code): \(error.message)")
        }
        return response
    }

    private func send(_ request: AutomationRequest) throws -> AutomationResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CLIError("socket() failed: \(String(cString: strerror(errno)))") }
        defer { close(fd) }

        var noSigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))

        let path = socketURL.path
        guard path.utf8.count < 100 else { throw CLIError("Socket path is too long: \(path)") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            path.utf8CString.withUnsafeBytes { source in
                buffer.copyBytes(from: source.prefix(buffer.count - 1))
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, size)
            }
        }
        guard connected == 0 else {
            throw CLIError(String(cString: strerror(errno)))
        }

        var payload = AutomationCodec.encode(request)
        payload.append(0x0A)
        try writeAll(payload, fd: fd)
        let reply = try readLine(fd: fd)
        return try AutomationCodec.decodeResponse(reply)
    }

    private func writeAll(_ data: Data, fd: Int32) throws {
        try data.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let written = write(fd, pointer, remaining)
                guard written > 0 else {
                    throw CLIError("write() failed: \(String(cString: strerror(errno)))")
                }
                pointer += written
                remaining -= written
            }
        }
    }

    private func readLine(fd: Int32) throws -> Data {
        var data = Data()
        var byte: UInt8 = 0
        while true {
            let count = read(fd, &byte, 1)
            guard count > 0 else {
                throw CLIError("Socket closed before a response was received")
            }
            if byte == 0x0A { return data }
            data.append(byte)
        }
    }
}

enum AppLauncher {
    static func wake() {
        if let path = ProcessInfo.processInfo.environment["CONDUCTOR_APP_PATH"], !path.isEmpty {
            runOpen(["-g", path])
        } else {
            runOpen(["-g", "-a", "Conductor"])
        }
    }

    private static func runOpen(_ args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}

func pretty(_ value: JSONValue?) -> String {
    guard let value else { return "null" }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) {
        return text
    }
    return "\(value)"
}

func jsonLine(_ value: JSONValue) -> String {
    let encoder = JSONEncoder()
    if let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) {
        return text
    }
    return "null"
}

func object(_ value: JSONValue?) -> [String: JSONValue] {
    value?.objectValue ?? [:]
}

func array(_ value: JSONValue?) -> [JSONValue] {
    value?.arrayValue ?? []
}

func printResult(_ response: AutomationResponse, json: Bool = false) {
    if json {
        print(pretty(response.result))
    } else if let result = response.result {
        print(pretty(result))
    }
}

func paramsFromJSONString(_ raw: String?) throws -> [String: JSONValue] {
    guard let raw, !raw.isEmpty else { return [:] }
    guard let data = raw.data(using: .utf8) else { throw CLIError("Invalid JSON text") }
    let value = try JSONDecoder().decode(JSONValue.self, from: data)
    guard let object = value.objectValue else { throw CLIError("Raw params must be a JSON object") }
    return object
}

func usage() -> String {
    """
    conductorctl: control Conductor over its local Unix socket

    Usage:
      conductorctl ping
      conductorctl status [--json]
      conductorctl taskcards [--json]
      conductorctl raw METHOD '{"key":"value"}'
      conductorctl batch < requests.ndjson
      conductorctl methods
      conductorctl workspace list|current|tree [--json]
      conductorctl workspace select WORKSPACE
      conductorctl workspace create PATH [--name NAME] [--json]
      conductorctl workspace rename WORKSPACE NAME
      conductorctl workspace close WORKSPACE
      conductorctl workspace status set KEY TEXT [--workspace WORKSPACE] [--color HEX] [--icon SF_SYMBOL]
      conductorctl workspace status list [--workspace WORKSPACE] [--json]
      conductorctl workspace status clear [KEY] [--workspace WORKSPACE]
      conductorctl workspace progress set VALUE [--workspace WORKSPACE] [--label TEXT]
      conductorctl workspace progress clear [--workspace WORKSPACE]
      conductorctl workspace log append TEXT [--workspace WORKSPACE] [--level LEVEL] [--source SOURCE]
      conductorctl workspace log list [--workspace WORKSPACE] [--limit N] [--json]
      conductorctl workspace log clear [--workspace WORKSPACE]
      conductorctl tab list [--workspace WORKSPACE] [--json]
      conductorctl tab select TAB [--workspace WORKSPACE]
      conductorctl tab rename TAB TITLE [--workspace WORKSPACE]
      conductorctl tab close TAB [--workspace WORKSPACE]
      conductorctl pane list [--json]
      conductorctl pane create [--cwd PATH] [--json]
      conductorctl pane split [--pane PANE] [--direction right|down] [--cwd PATH] [--json]
      conductorctl pane focus PANE
      conductorctl pane close [PANE]
      conductorctl screen [--pane PANE] [--scrollback]
      conductorctl send [--pane PANE] [--no-submit] [--stdin] TEXT
      conductorctl run AGENT [--cwd PATH] [--prompt TEXT|--stdin] [--command COMMAND] [--no-submit] [--wait] [--timeout SECONDS] [--poll SECONDS] [--json]
      conductorctl agent status [JOB] [--json]
      conductorctl agent wait [JOB] [--timeout SECONDS] [--poll SECONDS] [--json]
      conductorctl agent result [JOB] [--json]
      conductorctl activity [--limit N] [--json]
      conductorctl events [--limit N] [--interval SECONDS] [--jsonl]
      conductorctl watch [--interval SECONDS] [--jsonl]
      conductorctl bridge [--host 127.0.0.1] [--port 17373] [--interval SECONDS]

    Environment:
      CONDUCTOR_APP_PATH=/path/to/Conductor.app  app to wake when socket is absent
      CONDUCTOR_SOCKET_PATH=/path/to/socket      override local socket path
    """
}

func main() throws {
    var args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first else {
        print(usage())
        return
    }
    args.removeFirst()
    let client = SocketClient()

    switch command {
    case "help", "-h", "--help":
        print(usage())

    case "ping":
        let response = try client.request(method: AutomationMethod.appPing)
        let result = object(response.result)
        print("Conductor OK protocol=\(result["protocol"]?.intValue ?? 0) socket=\(result["socket"]?.stringValue ?? "")")

    case "status":
        let options = try parseOptions(args)
        let response = try client.request(method: AutomationMethod.appStatus)
        if options.has("json") {
            printResult(response, json: true)
        } else {
            printStatus(object(response.result))
        }

    case "methods":
        let response = try client.request(method: AutomationMethod.appMethods)
        for item in array(response.result) {
            if let name = item.stringValue { print(name) }
        }

    case "taskcards", "task-cards":
        let options = try parseOptions(args)
        let response = try client.request(method: AutomationMethod.appOpenTaskCards)
        if options.has("json") {
            printResult(response, json: true)
        } else {
            print("Opened task cards")
        }

    case "raw":
        guard let method = args.first else { throw CLIError("raw requires METHOD") }
        let params = try paramsFromJSONString(args.dropFirst().first)
        printResult(try client.request(method: method, params: params), json: true)

    case "batch":
        try runBatch(client: client)

    case "workspace":
        guard let subcommand = args.first else { throw CLIError("workspace requires a subcommand") }
        let options = try parseOptions(Array(args.dropFirst()))
        switch subcommand {
        case "list", "ls":
            let response = try client.request(method: AutomationMethod.workspaceList)
            if options.has("json") {
                printResult(response, json: true)
            } else {
                printWorkspaces(array(response.result))
            }
        case "current":
            let response = try client.request(method: AutomationMethod.workspaceCurrent)
            if options.has("json") {
                printResult(response, json: true)
            } else {
                printWorkspaces([response.result ?? .null])
            }
        case "select":
            let workspace = try requiredValue(options, key: "workspace", positionalIndex: 0, label: "WORKSPACE")
            _ = try client.request(method: AutomationMethod.workspaceSelect, params: ["workspace": .string(workspace)])
        case "create", "new":
            let path = try requiredValue(options, key: "path", positionalIndex: 0, label: "PATH")
            var params: [String: JSONValue] = ["path": .string(path)]
            if let name = options.value("name") { params["name"] = .string(name) }
            let response = try client.request(method: AutomationMethod.workspaceCreate, params: params)
            if options.has("json") {
                printResult(response, json: true)
            } else {
                printWorkspaces([response.result ?? .null])
            }
        case "rename":
            let workspace = try requiredValue(options, key: "workspace", positionalIndex: 0, label: "WORKSPACE")
            let name = try requiredValue(options, key: "name", positionalIndex: 1, label: "NAME")
            _ = try client.request(method: AutomationMethod.workspaceRename, params: [
                "workspace": .string(workspace),
                "name": .string(name),
            ])
        case "close":
            let workspace = try requiredValue(options, key: "workspace", positionalIndex: 0, label: "WORKSPACE")
            _ = try client.request(method: AutomationMethod.workspaceClose, params: ["workspace": .string(workspace)])
        case "tree":
            var params: [String: JSONValue] = [:]
            if let workspace = options.value("workspace") ?? options.positional.first {
                params["workspace"] = .string(workspace)
            }
            printResult(try client.request(method: AutomationMethod.workspaceTree, params: params), json: true)
        case "status":
            let action = options.positional.first ?? "list"
            var params = workspaceScopedParams(options)
            switch action {
            case "set":
                params["key"] = .string(try requiredValue(options, key: "key", positionalIndex: 1, label: "KEY"))
                params["text"] = .string(try requiredJoinedText(options, key: "text", from: 2, label: "TEXT"))
                if let color = options.value("color") { params["color"] = .string(color) }
                if let icon = options.value("icon") { params["icon"] = .string(icon) }
                _ = try client.request(method: AutomationMethod.workspaceStatusSet, params: params)
            case "list", "ls":
                let response = try client.request(method: AutomationMethod.workspaceStatusList, params: params)
                if options.has("json") {
                    printResult(response, json: true)
                } else {
                    printStatusChips(array(response.result))
                }
            case "clear":
                if let key = options.value("key") ?? options.positional.dropFirst().first {
                    params["key"] = .string(key)
                }
                _ = try client.request(method: AutomationMethod.workspaceStatusClear, params: params)
            default:
                throw CLIError("Unknown workspace status subcommand: \(action)")
            }
        case "progress":
            let action = options.positional.first ?? "set"
            var params = workspaceScopedParams(options)
            switch action {
            case "set":
                let raw = try requiredValue(options, key: "value", positionalIndex: 1, label: "VALUE")
                guard let value = Double(raw) else { throw CLIError("Invalid VALUE: \(raw)") }
                params["value"] = .double(value)
                if let label = options.value("label") { params["label"] = .string(label) }
                _ = try client.request(method: AutomationMethod.workspaceProgressSet, params: params)
            case "clear":
                _ = try client.request(method: AutomationMethod.workspaceProgressClear, params: params)
            default:
                throw CLIError("Unknown workspace progress subcommand: \(action)")
            }
        case "log":
            let action = options.positional.first ?? "list"
            var params = workspaceScopedParams(options)
            switch action {
            case "append", "add":
                params["text"] = .string(try requiredJoinedText(options, key: "text", from: 1, label: "TEXT"))
                if let level = options.value("level") { params["level"] = .string(level) }
                if let source = options.value("source") { params["source"] = .string(source) }
                _ = try client.request(method: AutomationMethod.workspaceLogAppend, params: params)
            case "list", "ls":
                if let limit = options.value("limit").flatMap(Int.init) { params["limit"] = .int(limit) }
                let response = try client.request(method: AutomationMethod.workspaceLogList, params: params)
                if options.has("json") {
                    printResult(response, json: true)
                } else {
                    printWorkspaceLogs(array(response.result))
                }
            case "clear":
                _ = try client.request(method: AutomationMethod.workspaceLogClear, params: params)
            default:
                throw CLIError("Unknown workspace log subcommand: \(action)")
            }
        default:
            throw CLIError("Unknown workspace subcommand: \(subcommand)")
        }

    case "tab":
        guard let subcommand = args.first else { throw CLIError("tab requires a subcommand") }
        let options = try parseOptions(Array(args.dropFirst()))
        switch subcommand {
        case "list", "ls":
            var params: [String: JSONValue] = [:]
            if let workspace = options.value("workspace") { params["workspace"] = .string(workspace) }
            let response = try client.request(method: AutomationMethod.tabList, params: params)
            if options.has("json") {
                printResult(response, json: true)
            } else {
                printTabs(array(response.result))
            }
        case "select":
            let tab = try requiredValue(options, key: "tab", positionalIndex: 0, label: "TAB")
            var params: [String: JSONValue] = ["tab": .string(tab)]
            if let workspace = options.value("workspace") { params["workspace"] = .string(workspace) }
            _ = try client.request(method: AutomationMethod.tabSelect, params: params)
        case "rename":
            let tab = try requiredValue(options, key: "tab", positionalIndex: 0, label: "TAB")
            let title = try requiredValue(options, key: "title", positionalIndex: 1, label: "TITLE")
            var params: [String: JSONValue] = ["tab": .string(tab), "title": .string(title)]
            if let workspace = options.value("workspace") { params["workspace"] = .string(workspace) }
            _ = try client.request(method: AutomationMethod.tabRename, params: params)
        case "close":
            let tab = try requiredValue(options, key: "tab", positionalIndex: 0, label: "TAB")
            var params: [String: JSONValue] = ["tab": .string(tab)]
            if let workspace = options.value("workspace") { params["workspace"] = .string(workspace) }
            _ = try client.request(method: AutomationMethod.tabClose, params: params)
        default:
            throw CLIError("Unknown tab subcommand: \(subcommand)")
        }

    case "pane":
        guard let subcommand = args.first else { throw CLIError("pane requires a subcommand") }
        let options = try parseOptions(Array(args.dropFirst()))
        switch subcommand {
        case "list", "ls":
            let response = try client.request(method: AutomationMethod.paneList, params: [:])
            if options.has("json") {
                printResult(response, json: true)
            } else {
                for item in array(response.result) {
                    let pane = object(item)
                    let active = pane["active"]?.boolValue == true ? "*" : " "
                    let id = pane["id"]?.stringValue ?? "-"
                    let agent = pane["agent"]?.stringValue ?? "-"
                    let cwd = pane["cwd"]?.stringValue ?? ""
                    let title = pane["title"]?.stringValue ?? ""
                    print("\(active) \(id)  agent=\(agent)  \(title)  \(cwd)")
                }
            }
        case "create", "new":
            var params: [String: JSONValue] = [:]
            if let cwd = options.value("cwd") { params["cwd"] = .string(cwd) }
            printResult(try client.request(method: AutomationMethod.paneCreate, params: params), json: options.has("json"))
        case "split":
            var params: [String: JSONValue] = [:]
            if let pane = options.value("pane") ?? options.positional.first { params["pane"] = .string(pane) }
            if let direction = options.value("direction") { params["direction"] = .string(direction) }
            if let cwd = options.value("cwd") { params["cwd"] = .string(cwd) }
            printResult(try client.request(method: AutomationMethod.paneSplit, params: params), json: options.has("json"))
        case "focus":
            guard let pane = options.positional.first else { throw CLIError("pane focus requires PANE") }
            _ = try client.request(method: AutomationMethod.paneFocus, params: ["pane": .string(pane)])
        case "close":
            var params: [String: JSONValue] = [:]
            if let pane = options.value("pane") ?? options.positional.first { params["pane"] = .string(pane) }
            _ = try client.request(method: AutomationMethod.paneClose, params: params)
        default:
            throw CLIError("Unknown pane subcommand: \(subcommand)")
        }

    case "screen":
        let options = try parseOptions(args)
        var params: [String: JSONValue] = [:]
        if let pane = options.value("pane") ?? options.positional.first { params["pane"] = .string(pane) }
        if options.has("scrollback") { params["scrollback"] = .bool(true) }
        let response = try client.request(method: AutomationMethod.paneRead, params: params)
        print(object(response.result)["text"]?.stringValue ?? "")

    case "send":
        let options = try parseOptions(args)
        if options.has("stdin"), options.value("text") != nil || !options.positional.isEmpty {
            throw CLIError("send accepts either TEXT or --stdin, not both")
        }
        let text: String
        if options.has("stdin") {
            text = try readStdin()
        } else {
            text = options.value("text") ?? options.positional.joined(separator: " ")
        }
        guard !text.isEmpty else { throw CLIError("send requires TEXT") }
        var params: [String: JSONValue] = [
            "text": .string(text),
            "submit": .bool(!options.has("no-submit")),
        ]
        if let pane = options.value("pane") { params["pane"] = .string(pane) }
        _ = try client.request(method: AutomationMethod.agentSend, params: params)

    case "run":
        let options = try parseOptions(args)
        guard let agent = options.positional.first ?? options.value("agent") else {
            throw CLIError("run requires AGENT")
        }
        let timeout = try doubleOption(options, "timeout", default: 600)
        let poll = try doubleOption(options, "poll", default: 2)
        guard poll > 0 else { throw CLIError("--poll must be greater than 0") }
        if options.has("stdin"), options.value("prompt") != nil {
            throw CLIError("run accepts either --prompt or --stdin, not both")
        }
        var params: [String: JSONValue] = [
            "agent": .string(agent),
            "submit": .bool(!options.has("no-submit")),
        ]
        if let command = options.value("command") { params["command"] = .string(command) }
        if let cwd = options.value("cwd") { params["cwd"] = .string(cwd) }
        if options.has("stdin") {
            params["prompt"] = .string(try readStdin())
        } else if let prompt = options.value("prompt") {
            params["prompt"] = .string(prompt)
        }
        let response = try client.request(method: AutomationMethod.agentRun, params: params)
        let result = object(response.result)
        let job = result["jobId"]?.stringValue ?? result["pane"]?.stringValue
        if options.has("wait") {
            guard let job, !job.isEmpty else {
                throw CLIError("agent.run did not return a jobId")
            }
            let completed = try waitForAgentResult(client: client, job: job, timeout: timeout, poll: poll)
            if options.has("json") {
                printResult(completed, json: true)
            } else {
                printAgentResult(object(completed.result))
            }
            return
        }
        if options.has("json") {
            printResult(response, json: true)
        } else {
            print("pane=\(result["pane"]?.stringValue ?? "-") agent=\(result["agent"]?.stringValue ?? agent)")
        }

    case "agent":
        guard let subcommand = args.first else { throw CLIError("agent requires a subcommand") }
        let options = try parseOptions(Array(args.dropFirst()))
        let job = options.value("job") ?? options.value("jobId") ?? options.value("pane") ?? options.positional.first
        var params: [String: JSONValue] = [:]
        if let job { params["job"] = .string(job) }
        switch subcommand {
        case "status":
            let response = try client.request(method: AutomationMethod.agentStatus, params: params)
            if options.has("json") {
                printResult(response, json: true)
            } else {
                printAgentStatus(object(response.result))
            }
        case "wait":
            let timeout = try doubleOption(options, "timeout", default: 600)
            let poll = try doubleOption(options, "poll", default: 2)
            guard poll > 0 else { throw CLIError("--poll must be greater than 0") }
            let completed = try waitForAgentResult(client: client, job: job, timeout: timeout, poll: poll)
            if options.has("json") {
                printResult(completed, json: true)
            } else {
                printAgentResult(object(completed.result))
            }
        case "result":
            let response = try client.request(method: AutomationMethod.agentResult, params: params)
            if options.has("json") {
                printResult(response, json: true)
            } else {
                printAgentResult(object(response.result))
            }
        default:
            throw CLIError("Unknown agent subcommand: \(subcommand)")
        }

    case "activity":
        let options = try parseOptions(args)
        let limit = options.value("limit").flatMap(Int.init) ?? 20
        let response = try client.request(method: AutomationMethod.activityList, params: ["limit": .int(limit)])
        if options.has("json") {
            printResult(response, json: true)
        } else {
            printActivity(array(response.result))
        }

    case "events":
        let options = try parseOptions(args)
        let limit = options.value("limit").flatMap(Int.init) ?? 20
        let interval = max(0.5, options.value("interval").flatMap(Double.init) ?? 2.0)
        var seen = Set<String>()
        while true {
            let response = try client.request(method: AutomationMethod.eventsRecent, params: ["limit": .int(limit)])
            for event in array(response.result).reversed() {
                let item = object(event)
                guard let id = item["id"]?.stringValue, !seen.contains(id) else { continue }
                seen.insert(id)
                print(options.has("jsonl") ? jsonLine(event) : pretty(event))
                fflush(stdout)
            }
            Thread.sleep(forTimeInterval: interval)
        }

    case "watch":
        let options = try parseOptions(args)
        let interval = max(0.5, options.value("interval").flatMap(Double.init) ?? 2.0)
        var seen = Set<String>()
        while true {
            let response = try client.request(method: AutomationMethod.activityList, params: ["limit": .int(20)])
            let entries = array(response.result)
            for entry in entries.reversed() {
                let item = object(entry)
                guard let id = item["id"]?.stringValue, !seen.contains(id) else { continue }
                seen.insert(id)
                if options.has("jsonl") {
                    print(jsonLine(entry))
                } else {
                    printActivity([entry])
                }
                fflush(stdout)
            }
            Thread.sleep(forTimeInterval: interval)
        }

    case "bridge":
        let options = try parseOptions(args)
        let host = options.value("host") ?? "127.0.0.1"
        let port = options.value("port").flatMap(Int.init) ?? 17_373
        let interval = max(0.5, options.value("interval").flatMap(Double.init) ?? 1.0)
        try BridgeServer.run(host: host, port: port, interval: interval)

    default:
        throw CLIError("Unknown command: \(command)\n\n\(usage())")
    }
}

func doubleOption(_ options: Options, _ key: String, default defaultValue: Double) throws -> Double {
    guard let raw = options.value(key) else { return defaultValue }
    guard let value = Double(raw), value >= 0 else {
        throw CLIError("Invalid --\(key): \(raw)")
    }
    return value
}

func requiredValue(_ options: Options, key: String, positionalIndex: Int, label: String) throws -> String {
    if let value = options.value(key), !value.isEmpty { return value }
    if positionalIndex < options.positional.count {
        let value = options.positional[positionalIndex]
        if !value.isEmpty { return value }
    }
    throw CLIError("Missing \(label)")
}

func requiredJoinedText(_ options: Options, key: String, from index: Int, label: String) throws -> String {
    if let value = options.value(key), !value.isEmpty { return value }
    if index < options.positional.count {
        let value = options.positional.dropFirst(index).joined(separator: " ")
        if !value.isEmpty { return value }
    }
    throw CLIError("Missing \(label)")
}

func workspaceScopedParams(_ options: Options) -> [String: JSONValue] {
    guard let workspace = options.value("workspace") else { return [:] }
    return ["workspace": .string(workspace)]
}

func readStdin() throws -> String {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let text = String(data: data, encoding: .utf8) else {
        throw CLIError("stdin is not valid UTF-8")
    }
    return text
}

func runBatch(client: SocketClient) throws {
    let input = try readStdin()
    let encoder = JSONEncoder()
    for (index, rawLine) in input.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { continue }
        guard let data = line.data(using: .utf8) else {
            throw CLIError("batch line \(index + 1) is not valid UTF-8")
        }
        let request: AutomationRequest
        do {
            request = try JSONDecoder().decode(AutomationRequest.self, from: data)
        } catch {
            throw CLIError("batch line \(index + 1) is not an AutomationRequest: \(error.localizedDescription)")
        }
        let response = try client.requestRaw(request)
        guard let encoded = String(data: try encoder.encode(response), encoding: .utf8) else {
            throw CLIError("Could not encode batch response")
        }
        print(encoded)
        fflush(stdout)
    }
}

func waitForAgentResult(client: SocketClient, job: String?, timeout: Double, poll: Double) throws -> AutomationResponse {
    let started = Date()
    while true {
        let statusParams: [String: JSONValue] = job.map { ["job": .string($0)] } ?? [:]
        let statusResponse = try client.request(method: AutomationMethod.agentStatus, params: statusParams)
        let statusObject = object(statusResponse.result)
        let status = statusObject["status"]?.stringValue ?? "unknown"
        let resolvedJob = statusObject["jobId"]?.stringValue ?? job
        if status == "completed" {
            let resultParams: [String: JSONValue] = resolvedJob.map { ["job": .string($0)] } ?? [:]
            return try client.request(method: AutomationMethod.agentResult, params: resultParams)
        }
        if timeout > 0, Date().timeIntervalSince(started) >= timeout {
            let label = resolvedJob ?? "-"
            throw CLIError("Timed out waiting for job \(label) after \(Int(timeout))s (last status=\(status))")
        }
        Thread.sleep(forTimeInterval: max(0.25, poll))
    }
}

func printActivity(_ entries: [JSONValue]) {
    for entry in entries {
        let item = object(entry)
        let time = item["time"]?.doubleValue.map { Date(timeIntervalSince1970: $0) } ?? Date()
        let formatter = ISO8601DateFormatter()
        let stamp = formatter.string(from: time)
        let title = item["title"]?.stringValue ?? "-"
        let agent = item["agent"]?.stringValue ?? "-"
        let pane = item["pane"]?.stringValue ?? "-"
        let message = item["message"]?.stringValue ?? ""
        print("[\(stamp)] \(title) agent=\(agent) pane=\(pane)")
        if !message.isEmpty {
            print("  \(message)")
        }
    }
}

func printWorkspaces(_ entries: [JSONValue]) {
    for entry in entries {
        let item = object(entry)
        let active = item["active"]?.boolValue == true ? "*" : " "
        let id = item["id"]?.stringValue ?? "-"
        let name = item["name"]?.stringValue ?? "-"
        let tabs = item["tabs"]?.intValue ?? 0
        let path = item["path"]?.stringValue ?? ""
        print("\(active) \(id)  tabs=\(tabs)  \(name)  \(path)")
    }
}

func printTabs(_ entries: [JSONValue]) {
    for entry in entries {
        let item = object(entry)
        let active = item["active"]?.boolValue == true ? "*" : " "
        let id = item["id"]?.stringValue ?? "-"
        let index = item["index"]?.intValue ?? 0
        let title = item["title"]?.stringValue ?? ""
        let panes = item["panes"]?.arrayValue?.count ?? 0
        print("\(active) \(id)  index=\(index)  panes=\(panes)  \(title)")
    }
}

func printStatusChips(_ entries: [JSONValue]) {
    for entry in entries {
        let item = object(entry)
        let key = item["key"]?.stringValue ?? "-"
        let text = item["text"]?.stringValue ?? ""
        let color = item["color"]?.stringValue ?? "-"
        let icon = item["icon"]?.stringValue ?? "-"
        print("\(key)  color=\(color) icon=\(icon)  \(text)")
    }
}

func printWorkspaceLogs(_ entries: [JSONValue]) {
    let formatter = ISO8601DateFormatter()
    for entry in entries {
        let item = object(entry)
        let time = item["time"]?.doubleValue.map { Date(timeIntervalSince1970: $0) } ?? Date()
        let stamp = formatter.string(from: time)
        let level = item["level"]?.stringValue ?? "info"
        let source = item["source"]?.stringValue ?? "-"
        let text = item["text"]?.stringValue ?? ""
        print("[\(stamp)] \(level) source=\(source) \(text)")
    }
}

func printStatus(_ status: [String: JSONValue]) {
    let active = object(status["active"])
    print("app=\(status["app"]?.stringValue ?? "Conductor") version=\(status["version"]?.stringValue ?? "") protocol=\(status["protocol"]?.intValue ?? 0)")
    print("active workspace=\(active["workspace"]?.stringValue ?? "-") tab=\(active["tab"]?.stringValue ?? "-") pane=\(active["pane"]?.stringValue ?? "-")")
}

func printAgentStatus(_ status: [String: JSONValue]) {
    print("job=\(status["jobId"]?.stringValue ?? "-") status=\(status["status"]?.stringValue ?? "-") agent=\(status["agent"]?.stringValue ?? "-") pane=\(status["pane"]?.stringValue ?? "-")")
}

func printAgentResult(_ result: [String: JSONValue]) {
    printAgentStatus(result)
    if let summary = result["summary"]?.stringValue, !summary.isEmpty {
        print("\nSummary:\n\(summary)")
    }
    if let markdown = result["markdown"]?.stringValue, !markdown.isEmpty {
        print("\nResult:\n\(markdown)")
    }
    if let path = result["transcriptPath"]?.stringValue, !path.isEmpty {
        print("\nTranscript: \(path)")
    }
}

do {
    try main()
} catch let error as CLIError {
    fputs("conductorctl: \(error.description)\n", stderr)
    exit(1)
} catch {
    fputs("conductorctl: \(error)\n", stderr)
    exit(1)
}
