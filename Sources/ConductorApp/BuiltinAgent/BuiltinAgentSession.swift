import Combine
import ConductorCore
import Foundation

/// 一个内置 Agent 会话：驱动打包的 `pi --mode rpc` 子进程（非 PTY），把事件归约进 `transcript`，
/// 把工具审批经 `FeedCenter` 处置后回写。纯编排——协议/分帧/归约/审批映射的逻辑都在 `ConductorCore`。
///
/// 进程↔FeedCenter 的实时回合已由独立探针证过；本类的决策逻辑（`ApprovalMapper.dialogAction`、
/// `AgentTranscript`）有 ConductorCore 单测覆盖。这里不写易挂的进程时序集成测试（铁律：稳定优先）。
@MainActor
final class BuiltinAgentSession: ObservableObject {
    enum Phase: Equatable {
        case idle, starting, ready, streaming, stopped
        case failed(String)
        var isFailed: Bool { if case .failed = self { return true }; return false }
    }

    @Published private(set) var transcript = AgentTranscript()
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var modelLabel: String?

    private let feedCenter: FeedCenter
    private let piURL: URL
    private let bridgeURL: URL
    private let cwd: String?

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    /// 必须强引用：reader 的 readabilityHandler 用 [weak self] 不持有它，
    /// 不存就会在 start() 返回时析构 → 回调里 self 为 nil → stdout 永不解析（整个 agent 哑火）。
    private var reader: PipeLineReader?
    /// 进程代际：每次 start() 自增；terminationHandler 捕获启动时的代号，
    /// 回调时与当前代号不符即忽略（旧进程的终止不该污染重启后的新会话）。
    private var generation = 0
    /// 已挂起、等用户决策的 Feed 请求 id：stop/退出时全部 cancel，免得 continuation 永挂。
    private var pendingFeedIDs: Set<String> = []
    private let writeQueue = DispatchQueue(label: "dev.conductor.builtin-agent.write")
    private var requestSeq = 0

    init(feedCenter: FeedCenter, piURL: URL, bridgeURL: URL, cwd: String?) {
        self.feedCenter = feedCenter
        self.piURL = piURL
        self.bridgeURL = bridgeURL
        self.cwd = cwd
    }

    // MARK: 生命周期

    func start(model: (provider: String, id: String)? = nil, extraEnv: [String: String] = [:]) {
        guard process == nil else { return }
        generation += 1
        let gen = generation
        phase = .starting

        let proc = Process()
        proc.executableURL = piURL
        var args = ["--mode", "rpc", "--no-session", "-e", bridgeURL.path]
        if let model { args += ["--provider", model.provider, "--model", model.id] }
        proc.arguments = args
        if let cwd { proc.currentDirectoryURL = URL(fileURLWithPath: cwd) }

        // 凭据已由 UsageCredentials 注入进程 env（pi-ai 从 env 读 key），子进程直接继承。
        var env = ProcessInfo.processInfo.environment
        env["CONDUCTOR_BUILTIN_AGENT"] = "1"
        for (key, value) in extraEnv { env[key] = value }
        proc.environment = env

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        stdinHandle = inPipe.fileHandleForWriting
        stdoutHandle = outPipe.fileHandleForReading
        stderrHandle = errPipe.fileHandleForReading

        // stdout：字节流 → JSONL 行（framer 只在这个串行回调里被碰）→ 解析 → 跳主线程处置。
        let reader = PipeLineReader { [weak self] line in
            guard let inbound = RPCInbound.parse(line: line) else { return }
            Task { @MainActor in self?.handle(inbound) }
        }
        reader.attach(stdoutHandle!)
        self.reader = reader     // 强引用：见属性注释，不存则立刻析构、stdout 永不解析
        stderrHandle?.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            FileHandle.standardError.write(Data("[pi] ".utf8))
            FileHandle.standardError.write(data)
        }
        proc.terminationHandler = { [weak self] proc in
            Task { @MainActor in self?.handleTermination(proc.terminationStatus, generation: gen) }
        }

        do {
            try proc.run()
            process = proc
            phase = .ready
        } catch {
            phase = .failed("pi 启动失败：\(error.localizedDescription)")
            cleanup()
        }
    }

    func stop() {
        process?.terminate()
        if !phase.isFailed { phase = .stopped }
        cleanup()
    }

    // MARK: 发送

    /// 提交一条用户 prompt（流式中自动以 steer 排队）。
    func prompt(_ text: String) {
        guard !text.isEmpty else { return }
        transcript.appendUser(text)
        let behavior: RPCCommand.StreamingBehavior? = (phase == .streaming) ? .steer : nil
        send(.prompt(message: text, streamingBehavior: behavior))
    }

    func abort() { writeLine(RPCCommand.abort.line()) }

    func send(_ command: RPCCommand) {
        requestSeq += 1
        writeLine(command.line(id: "r\(requestSeq)"))
    }

    // MARK: 接收处置（主线程）

    private func handle(_ inbound: RPCInbound) {
        switch inbound {
        case let .event(event):
            switch event {
            case .agentStart: phase = .streaming
            case .agentEnd: phase = .ready
            default: break
            }
            transcript.apply(event)

        case let .uiRequest(ui):
            switch ApprovalMapper.dialogAction(for: ui, cwd: cwd) {
            case let .approveViaFeed(request):
                pendingFeedIDs.insert(request.id)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let decision = await self.feedCenter.submit(request)
                    self.pendingFeedIDs.remove(request.id)
                    self.sendUIResponse(ApprovalMapper.response(for: decision, requestID: ui.id))
                }
            case let .respondCancelled(id):
                sendUIResponse(ExtensionUIResponse(id: id, cancelled: true))
            case .ignore:
                break
            }

        case let .response(response):
            applyResponse(response)

        case .unknown:
            break
        }
    }

    private func applyResponse(_ response: RPCResponse) {
        guard response.success, let data = response.data?.objectValue else { return }
        // get_state → data.model.name；set_model/cycle_model → data 本身（或 data.model）是 model 对象。
        let modelObject = data["model"]?.objectValue ?? data
        if let name = modelObject["name"]?.stringValue { modelLabel = name }
    }

    private func handleTermination(_ code: Int32, generation gen: Int) {
        guard gen == generation else { return }   // 旧进程的终止回调：已重启成新会话，忽略
        switch phase {
        case .stopped, .failed: break             // 已是终态（含用户主动 stop()）：不覆盖成"退出码 15"
        default: phase = (code == 0) ? .stopped : .failed("pi 退出码 \(code)")
        }
        cleanup()
    }

    // MARK: 私有

    private func sendUIResponse(_ response: ExtensionUIResponse) { writeLine(response.line()) }

    private func writeLine(_ line: String) {
        guard let handle = stdinHandle else { return }
        let data = Data((line + "\n").utf8)
        writeQueue.async { try? handle.write(contentsOf: data) }
    }

    private func cleanup() {
        // 挂起的审批必须 cancel：否则 await feedCenter.submit 的 continuation 永不 resume、Task 永挂。
        for id in pendingFeedIDs { feedCenter.cancel(id: id, reason: "agent 已停止") }
        pendingFeedIDs.removeAll()
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        reader = nil
        stdinHandle = nil
        stdoutHandle = nil
        stderrHandle = nil
        process = nil
    }
}

/// 把 `FileHandle` 的字节流切成 JSONL 行。非主隔离——`framer` 只在串行的 readability 回调里被碰。
private final class PipeLineReader {
    private var framer = JSONLFramer()
    private let onLine: (String) -> Void

    init(onLine: @escaping (String) -> Void) { self.onLine = onLine }

    func attach(_ handle: FileHandle) {
        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            for line in self.framer.feed(data) { self.onLine(line) }
        }
    }
}
