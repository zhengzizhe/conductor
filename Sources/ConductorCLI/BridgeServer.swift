import ConductorCore
import CryptoKit
import Darwin
import Foundation

enum BridgeServer {
    private static let websocketGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    static func run(host: String, port: Int, interval: Double) throws {
        let server = socket(AF_INET, SOCK_STREAM, 0)
        guard server >= 0 else { throw CLIError("socket() failed: \(errnoText())") }
        var reuse: Int32 = 1
        setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
            close(server)
            throw CLIError("Invalid bridge host: \(host)")
        }

        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(server, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(server)
            throw CLIError("bind(\(host):\(port)) failed: \(errnoText())")
        }
        guard listen(server, 32) == 0 else {
            close(server)
            throw CLIError("listen() failed: \(errnoText())")
        }

        print("Conductor bridge listening on http://\(host):\(port)")
        print("  POST rpc:  http://\(host):\(port)/rpc")
        print("  SSE events: http://\(host):\(port)/events")
        print("  WS rpc:    ws://\(host):\(port)/rpc")
        print("  WS events: ws://\(host):\(port)/events")

        while true {
            let client = accept(server, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                throw CLIError("accept() failed: \(errnoText())")
            }
            DispatchQueue.global(qos: .userInitiated).async {
                handle(client: client, interval: interval)
            }
        }
    }

    private static func handle(client fd: Int32, interval: Double) {
        defer { close(fd) }
        do {
            let request = try HTTPRequest.read(from: fd)
            if request.method == "OPTIONS" {
                try writeHTTP(fd: fd, status: "204 No Content", body: Data())
                return
            }
            if request.isWebSocket, request.path == "/rpc" {
                try acceptWebSocket(request, fd: fd)
                try rpcWebSocketLoop(fd: fd)
            } else if request.isWebSocket, request.path == "/events" {
                try acceptWebSocket(request, fd: fd)
                eventsWebSocketLoop(
                    fd: fd,
                    interval: request.queryDouble("interval") ?? interval,
                    limit: request.queryInt("limit") ?? 100)
            } else if request.method == "POST", request.path == "/rpc" {
                try writeHTTP(fd: fd, status: "200 OK", body: proxyData(body: request.body))
            } else if request.method == "POST", request.path == "/batch" {
                try writeHTTP(
                    fd: fd,
                    status: "200 OK",
                    contentType: "application/x-ndjson",
                    body: proxyBatchData(body: request.body))
            } else if request.method == "GET", request.path == "/status" {
                try writeHTTP(fd: fd, status: "200 OK", body: proxyData(
                    body: AutomationCodec.encode(AutomationRequest(id: 1, method: AutomationMethod.appStatus))))
            } else if request.method == "GET", request.path == "/methods" {
                try writeHTTP(fd: fd, status: "200 OK", body: proxyData(
                    body: AutomationCodec.encode(AutomationRequest(id: 1, method: AutomationMethod.appMethods))))
            } else if request.method == "GET", request.path == "/health" {
                try writeHTTP(fd: fd, status: "200 OK", body: healthData())
            } else if request.method == "GET", request.path == "/openapi.json" {
                try writeHTTP(fd: fd, status: "200 OK", body: openAPIData())
            } else if request.method == "GET", request.path == "/events" {
                try writeSSEHeader(fd: fd)
                eventsSSELoop(
                    fd: fd,
                    interval: request.queryDouble("interval") ?? interval,
                    limit: request.queryInt("limit") ?? 100)
            } else {
                try writeHTTP(fd: fd, status: "200 OK", body: docsData())
            }
        } catch {
            let body = jsonData(.object([
                "ok": .bool(false),
                "error": .string("\(error)"),
            ]))
            try? writeHTTP(fd: fd, status: "500 Internal Server Error", body: body)
        }
    }

    private static func rpcWebSocketLoop(fd: Int32) throws {
        while true {
            let frame = try readFrame(fd: fd)
            switch frame.opcode {
            case 0x1:
                let response = proxyData(body: frame.payload)
                try sendFrame(fd: fd, opcode: 0x1, payload: response)
            case 0x8:
                try sendFrame(fd: fd, opcode: 0x8, payload: Data())
                return
            case 0x9:
                try sendFrame(fd: fd, opcode: 0xA, payload: frame.payload)
            default:
                break
            }
        }
    }

    private static func eventsWebSocketLoop(fd: Int32, interval: Double, limit: Int) {
        eventPollLoop(interval: interval, limit: limit) { event in
            try sendFrame(fd: fd, opcode: 0x1, payload: jsonData(event))
        }
    }

    private static func eventsSSELoop(fd: Int32, interval: Double, limit: Int) {
        eventPollLoop(interval: interval, limit: limit) { event in
            let item = object(event)
            let id = item["id"]?.stringValue
            let type = item["type"]?.stringValue ?? item["topic"]?.stringValue ?? "message"
            var payload = Data()
            if let id { payload.append(Data("id: \(id)\n".utf8)) }
            payload.append(Data("event: \(type)\n".utf8))
            payload.append(Data("data: ".utf8))
            payload.append(jsonData(event))
            payload.append(Data("\n\n".utf8))
            try writeAll(payload, fd: fd)
        }
    }

    private static func eventPollLoop(interval: Double, limit: Int, emit: (JSONValue) throws -> Void) {
        var seen = Set<String>()
        let sleepMicros = useconds_t(max(250_000, Int((interval * 1_000_000).rounded())))
        let limit = max(1, min(limit, 500))
        while true {
            guard let response = try? SocketClient().request(
                method: AutomationMethod.eventsRecent,
                params: ["limit": .int(limit)])
            else {
                usleep(sleepMicros)
                continue
            }
            do {
                for event in array(response.result).reversed() {
                    let item = object(event)
                    guard let id = item["id"]?.stringValue, !seen.contains(id) else { continue }
                    seen.insert(id)
                    try emit(event)
                }
            } catch {
                return
            }
            usleep(sleepMicros)
        }
    }

    private static func acceptWebSocket(_ request: HTTPRequest, fd: Int32) throws {
        guard let key = request.headers["sec-websocket-key"] else {
            throw CLIError("Missing Sec-WebSocket-Key")
        }
        let accept = websocketAccept(key)
        let response = [
            "HTTP/1.1 101 Switching Protocols",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Accept: \(accept)",
            "Access-Control-Allow-Origin: *",
            "",
            "",
        ].joined(separator: "\r\n")
        try writeAll(Data(response.utf8), fd: fd)
    }

    private static func websocketAccept(_ key: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((key + websocketGUID).utf8))
        return Data(digest).base64EncodedString()
    }

    private static func proxyData(body: Data) -> Data {
        do {
            let request = try AutomationCodec.decodeRequest(body)
            let response = try SocketClient().requestRaw(request)
            return AutomationCodec.encode(response)
        } catch {
            return AutomationCodec.encode(AutomationResponse(
                id: nil,
                error: .badRequest("\(error)")))
        }
    }

    private static func proxyBatchData(body: Data) -> Data {
        guard let text = String(data: body, encoding: .utf8) else {
            return AutomationCodec.encode(AutomationResponse(
                id: nil,
                error: .badRequest("batch body must be UTF-8"))) + Data([0x0A])
        }
        var output = Data()
        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let response: AutomationResponse
            do {
                let request = try AutomationCodec.decodeRequest(Data(line.utf8))
                response = try SocketClient().requestRaw(request)
            } catch {
                response = AutomationResponse(
                    id: nil,
                    error: .badRequest("batch line \(index + 1): \(error)"))
            }
            output.append(AutomationCodec.encode(response))
            output.append(0x0A)
        }
        return output
    }

    private static func healthData() -> Data {
        do {
            let status = try SocketClient().request(method: AutomationMethod.appStatus)
            var payload = object(status.result)
            payload["ok"] = .bool(true)
            payload["bridge"] = .object([
                "transport": .string("http-websocket"),
                "rpc": .string("/rpc"),
                "events": .string("/events"),
            ])
            return jsonData(.object(payload))
        } catch {
            return jsonData(.object([
                "ok": .bool(false),
                "error": .string("\(error)"),
                "socket": .string(AutomationProtocol.defaultSocketURL.path),
            ]))
        }
    }

    private static func docsData() -> Data {
        jsonData(.object([
            "app": .string("Conductor Bridge"),
            "endpoints": .object([
                "health": .string("GET /health"),
                "status": .string("GET /status"),
                "methods": .string("GET /methods"),
                "openapi": .string("GET /openapi.json"),
                "rpcHTTP": .string("POST /rpc"),
                "batchHTTP": .string("POST /batch"),
                "rpcWebSocket": .string("WS /rpc"),
                "eventsWebSocket": .string("WS /events"),
                "eventsSSE": .string("GET /events"),
            ]),
        ]))
    }

    private static func openAPIData() -> Data {
        jsonData(.object([
            "openapi": .string("3.1.0"),
            "info": .object([
                "title": .string("Conductor Bridge"),
                "version": .string("1.0.0"),
            ]),
            "paths": .object([
                "/health": .object([
                    "get": .object([
                        "summary": .string("Bridge and app health"),
                        "responses": okJSONResponse(),
                    ]),
                ]),
                "/status": .object([
                    "get": .object([
                        "summary": .string("Proxy app.status"),
                        "responses": automationResponseSpec(),
                    ]),
                ]),
                "/methods": .object([
                    "get": .object([
                        "summary": .string("Proxy app.methods"),
                        "responses": automationResponseSpec(),
                    ]),
                ]),
                "/rpc": .object([
                    "post": .object([
                        "summary": .string("Proxy one AutomationRequest"),
                        "requestBody": jsonRequestBody(description: "AutomationRequest JSON"),
                        "responses": automationResponseSpec(),
                    ]),
                ]),
                "/batch": .object([
                    "post": .object([
                        "summary": .string("Proxy newline-delimited AutomationRequest messages"),
                        "requestBody": .object([
                            "required": .bool(true),
                            "content": .object([
                                "application/x-ndjson": .object([
                                    "schema": .object(["type": .string("string")]),
                                ]),
                            ]),
                        ]),
                        "responses": .object([
                            "200": .object([
                                "description": .string("AutomationResponse NDJSON stream"),
                                "content": .object([
                                    "application/x-ndjson": .object([
                                        "schema": .object(["type": .string("string")]),
                                    ]),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
                "/events": .object([
                    "get": .object([
                        "summary": .string("Server-Sent Events stream for events.recent"),
                        "parameters": .array([
                            queryParameter("limit", type: "integer"),
                            queryParameter("interval", type: "number"),
                        ]),
                        "responses": .object([
                            "200": .object([
                                "description": .string("SSE event stream"),
                                "content": .object([
                                    "text/event-stream": .object([
                                        "schema": .object(["type": .string("string")]),
                                    ]),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
            ]),
        ]))
    }

    private static func automationResponseSpec() -> JSONValue {
        .object([
            "200": .object([
                "description": .string("AutomationResponse"),
                "content": .object([
                    "application/json": .object([
                        "schema": .object([
                            "type": .string("object"),
                            "required": .array([.string("ok")]),
                            "properties": .object([
                                "id": .object(["type": .array([.string("integer"), .string("null")])]),
                                "ok": .object(["type": .string("boolean")]),
                                "result": .object(["description": .string("Method result")]),
                                "error": .object(["description": .string("AutomationError")]),
                            ]),
                        ]),
                    ]),
                ]),
            ]),
        ])
    }

    private static func okJSONResponse() -> JSONValue {
        .object([
            "200": .object([
                "description": .string("JSON response"),
                "content": .object([
                    "application/json": .object([
                        "schema": .object(["type": .string("object")]),
                    ]),
                ]),
            ]),
        ])
    }

    private static func jsonRequestBody(description: String) -> JSONValue {
        .object([
            "required": .bool(true),
            "description": .string(description),
            "content": .object([
                "application/json": .object([
                    "schema": .object(["type": .string("object")]),
                ]),
            ]),
        ])
    }

    private static func queryParameter(_ name: String, type: String) -> JSONValue {
        .object([
            "name": .string(name),
            "in": .string("query"),
            "required": .bool(false),
            "schema": .object(["type": .string(type)]),
        ])
    }

    private static func jsonData(_ value: JSONValue) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data("null".utf8)
    }

    private static func writeHTTP(
        fd: Int32,
        status: String,
        contentType: String = "application/json",
        body: Data
    ) throws {
        let header = [
            "HTTP/1.1 \(status)",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Connection: close",
            "Access-Control-Allow-Origin: *",
            "Access-Control-Allow-Headers: Content-Type, Authorization",
            "Access-Control-Allow-Methods: GET, POST, OPTIONS",
            "Access-Control-Allow-Private-Network: true",
            "",
            "",
        ].joined(separator: "\r\n")
        try writeAll(Data(header.utf8) + body, fd: fd)
    }

    private static func writeSSEHeader(fd: Int32) throws {
        let header = [
            "HTTP/1.1 200 OK",
            "Content-Type: text/event-stream",
            "Cache-Control: no-cache",
            "Connection: keep-alive",
            "Access-Control-Allow-Origin: *",
            "",
            "",
        ].joined(separator: "\r\n")
        try writeAll(Data(header.utf8), fd: fd)
    }

    private static func readFrame(fd: Int32) throws -> WebSocketFrame {
        let head = try readExactly(fd: fd, count: 2)
        let first = head[0]
        let second = head[1]
        let opcode = first & 0x0F
        let masked = (second & 0x80) != 0
        var length = UInt64(second & 0x7F)
        if length == 126 {
            let data = try readExactly(fd: fd, count: 2)
            length = UInt64(UInt16(data[0]) << 8 | UInt16(data[1]))
        } else if length == 127 {
            let data = try readExactly(fd: fd, count: 8)
            length = data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }
        let mask = masked ? try readExactly(fd: fd, count: 4) : []
        var payload = try readExactly(fd: fd, count: Int(length))
        if masked {
            for index in payload.indices {
                payload[index] ^= mask[index % 4]
            }
        }
        return WebSocketFrame(opcode: opcode, payload: Data(payload))
    }

    private static func sendFrame(fd: Int32, opcode: UInt8, payload: Data) throws {
        var header = Data()
        header.append(0x80 | opcode)
        if payload.count < 126 {
            header.append(UInt8(payload.count))
        } else if payload.count <= UInt16.max {
            header.append(126)
            header.append(UInt8((payload.count >> 8) & 0xFF))
            header.append(UInt8(payload.count & 0xFF))
        } else {
            header.append(127)
            let length = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) {
                header.append(UInt8((length >> UInt64(shift)) & 0xFF))
            }
        }
        try writeAll(header + payload, fd: fd)
    }

    private static func readExactly(fd: Int32, count: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let readCount = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return read(fd, base.advanced(by: offset), count - offset)
            }
            guard readCount > 0 else { throw CLIError("connection closed") }
            offset += readCount
        }
        return buffer
    }

    private static func writeAll(_ data: Data, fd: Int32) throws {
        try data.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let written = write(fd, pointer, remaining)
                guard written > 0 else { throw CLIError("write() failed: \(errnoText())") }
                pointer += written
                remaining -= written
            }
        }
    }

    private static func errnoText() -> String {
        String(cString: strerror(errno))
    }
}

private struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data

    var isWebSocket: Bool {
        headers["upgrade"]?.lowercased() == "websocket"
    }

    func queryInt(_ key: String) -> Int? {
        query[key].flatMap(Int.init)
    }

    func queryDouble(_ key: String) -> Double? {
        query[key].flatMap(Double.init)
    }

    static func read(from fd: Int32) throws -> HTTPRequest {
        var data = Data()
        var scratch = [UInt8](repeating: 0, count: 4096)
        while !data.containsHeaderTerminator {
            let count = Darwin.read(fd, &scratch, scratch.count)
            guard count > 0 else { throw CLIError("connection closed") }
            data.append(contentsOf: scratch[0..<count])
            guard data.count < 1_048_576 else { throw CLIError("HTTP header too large") }
        }
        guard let split = data.headerTerminatorRange else {
            throw CLIError("Invalid HTTP request")
        }
        let headerData = data.subdata(in: data.startIndex..<split.lowerBound)
        var body = data.subdata(in: split.upperBound..<data.endIndex)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw CLIError("HTTP request is not UTF-8")
        }
        let lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ").map(String.init) ?? []
        guard requestLine.count >= 2 else { throw CLIError("Invalid HTTP request line") }
        let (path, query) = parseTarget(requestLine[1])
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }
        let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
        while body.count < contentLength {
            let count = Darwin.read(fd, &scratch, min(scratch.count, contentLength - body.count))
            guard count > 0 else { throw CLIError("connection closed") }
            body.append(contentsOf: scratch[0..<count])
        }
        if body.count > contentLength {
            body = body.subdata(in: 0..<contentLength)
        }
        return HTTPRequest(method: requestLine[0], path: path, query: query, headers: headers, body: body)
    }

    private static func parseTarget(_ target: String) -> (String, [String: String]) {
        let pieces = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = pieces.first.map(String.init) ?? "/"
        guard pieces.count == 2 else { return (path, [:]) }
        var query: [String: String] = [:]
        for pair in pieces[1].split(separator: "&", omittingEmptySubsequences: true) {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = percentDecoded(String(kv[0]))
            let value = kv.count == 2 ? percentDecoded(String(kv[1])) : ""
            query[key] = value
        }
        return (path, query)
    }

    private static func percentDecoded(_ value: String) -> String {
        value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? value
    }
}

private struct WebSocketFrame {
    var opcode: UInt8
    var payload: Data
}

private extension Data {
    var containsHeaderTerminator: Bool {
        headerTerminatorRange != nil
    }

    var headerTerminatorRange: Range<Data.Index>? {
        range(of: Data([13, 10, 13, 10]))
    }
}
