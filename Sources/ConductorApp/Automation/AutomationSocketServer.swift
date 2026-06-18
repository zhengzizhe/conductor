import Darwin
import ConductorCore
import Foundation

/// 自动化入口：Unix domain socket 上的 NDJSON 服务器。
/// `conductor` CLI 与任意脚本（nc/python）都能连：一行请求、一行响应。
/// 监听与读写都在专用串行队列；业务处理跳回 MainActor（handler 负责）。
final class AutomationSocketServer: @unchecked Sendable {
    /// 一行请求（不含换行）→ 一行响应（不含换行）。
    typealias LineHandler = @Sendable (Data) async -> Data

    /// 约定的 socket 路径（pane 环境变量 `CONDUCTOR_SOCKET_PATH` 同源）。
    static var defaultSocketURL: URL {
        AutomationProtocol.defaultSocketURL
    }

    private let socketURL: URL
    private let handler: LineHandler
    private let queue = DispatchQueue(label: "conductor.automation.socket")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [Int32: ClientConnection] = [:]

    init(socketURL: URL = AutomationSocketServer.defaultSocketURL,
         handler: @escaping LineHandler) {
        self.socketURL = socketURL
        self.handler = handler
    }

    deinit { stop() }

    /// 启动监听。已有活着的实例占用该 socket 时返回 false（双开保护）。
    @discardableResult
    func start() -> Bool {
        let path = socketURL.path
        guard path.utf8.count < 100 else {
            NSLog("[conductor] 自动化 socket 路径过长：\(path)")
            return false
        }
        try? FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // 残留 socket 文件处理：能连通说明另一实例在跑 → 放弃；连不通则清掉。
        if FileManager.default.fileExists(atPath: path) {
            if Self.canConnect(path: path) {
                NSLog("[conductor] 另一个 Conductor 实例已在监听自动化 socket，跳过启动")
                return false
            }
            unlink(path)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        guard Self.setNonBlocking(fd) else {
            close(fd)
            return false
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            path.utf8CString.withUnsafeBytes { source in
                buffer.copyBytes(from: source.prefix(buffer.count - 1))
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            return false
        }
        chmod(path, 0o600)   // 仅本用户可连

        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.resume()
        acceptSource = source
        NSLog("[conductor] 自动化 socket 监听：\(path)")
        return true
    }

    func stop() {
        queue.sync {
            acceptSource?.cancel()
            acceptSource = nil
            connections.values.forEach { $0.cancel() }
            connections.removeAll()
            if listenFD >= 0 {
                close(listenFD)
                listenFD = -1
                unlink(socketURL.path)
            }
        }
    }

    private static func canConnect(path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            path.utf8CString.withUnsafeBytes { source in
                buffer.copyBytes(from: source.prefix(buffer.count - 1))
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        return result == 0
    }

    private static func setNonBlocking(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0 else { return false }
        return fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0
    }

    private func acceptPending() {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return }
                return
            }
            var noSigpipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
            let connection = ClientConnection(fd: fd, queue: queue, handler: handler) { [weak self] fd in
                self?.connections.removeValue(forKey: fd)
            }
            connections[fd] = connection
            connection.start()
        }
    }
}

/// 单个客户端连接：缓冲读取、按行切分、逐行应答。
private final class ClientConnection: @unchecked Sendable {
    private let fd: Int32
    private let queue: DispatchQueue
    private let handler: AutomationSocketServer.LineHandler
    private let onClose: (Int32) -> Void
    private var readSource: DispatchSourceRead?
    private var buffer = Data()
    /// 单行上限（4MB）：防御失控客户端撑爆内存。
    private static let maxLineBytes = 4 << 20

    init(fd: Int32, queue: DispatchQueue,
         handler: @escaping AutomationSocketServer.LineHandler,
         onClose: @escaping (Int32) -> Void) {
        self.fd = fd
        self.queue = queue
        self.handler = handler
        self.onClose = onClose
    }

    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readPending() }
        source.setCancelHandler { [fd] in close(fd) }
        source.resume()
        readSource = source
    }

    func cancel() {
        readSource?.cancel()
        readSource = nil
    }

    private func readPending() {
        var scratch = [UInt8](repeating: 0, count: 64 * 1024)
        let count = read(fd, &scratch, scratch.count)
        if count <= 0 {
            cancel()
            onClose(fd)
            return
        }
        buffer.append(contentsOf: scratch[0..<count])
        guard buffer.count <= Self.maxLineBytes else {
            cancel()
            onClose(fd)
            return
        }
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty else { continue }
            let fd = fd
            let queue = queue
            let handler = handler
            Task {
                var reply = await handler(line)
                reply.append(0x0A)
                queue.async {
                    reply.withUnsafeBytes { raw in
                        var remaining = raw.count
                        var pointer = raw.baseAddress!
                        while remaining > 0 {
                            let written = write(fd, pointer, remaining)
                            guard written > 0 else { return }
                            pointer += written
                            remaining -= written
                        }
                    }
                }
            }
        }
    }
}
