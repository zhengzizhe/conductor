import Foundation

/// 把 pi stdout 的**字节流**切成一条条完整 JSONL 行。
///
/// 为什么不能直接用 `readLine` / 通用行读取器（pi `rpc.md` 明确点名的坑）：
/// 1. 管道一次 `read` 可能给半行、也可能多行粘连——必须自己缓冲、按 `\n` 切。
/// 2. 通用读取器会在 `U+2028`/`U+2029` 处断行，而这俩在 JSON 字符串里合法 → 会把一条 event 切坏。
///    这里只在**字节** `0x0A` 处切、并剥尾随 `\r`，其它分隔符一律不认。
public struct JSONLFramer: Sendable {
    private var buffer = Data()
    /// 单条未完成行的字节上限：畸形/无换行的洪流（坏 pi、二进制垃圾）不该把内存撑爆。
    /// pi 单行 JSONL event 远不及此；超限即丢弃缓冲（下一条 `\n` 后自动重新对齐）。
    static let maxBuffer = 16 * 1024 * 1024

    public init() {}

    /// 喂入新读到的字节，返回这次能凑齐的完整行（已剥 `\r`、跳过空行）。半包留在内部缓冲。
    public mutating func feed(_ data: Data) -> [String] {
        buffer.append(data)
        if buffer.count > Self.maxBuffer {       // 无换行洪流：丢弃，避免无界增长
            buffer.removeAll(keepingCapacity: false)
            return []
        }
        var lines: [String] = []
        var cursor = buffer.startIndex
        while let newline = buffer[cursor...].firstIndex(of: 0x0A) {
            if let line = Self.normalize(buffer[cursor..<newline]) { lines.append(line) }
            cursor = buffer.index(after: newline)
        }
        if cursor > buffer.startIndex {           // 一次性压缩已消费区段（而非每行 O(n) 删头）
            buffer.removeSubrange(buffer.startIndex..<cursor)
        }
        return lines
    }

    /// 流结束（EOF）时取出缓冲里残留的、没有尾随 `\n` 的最后一行（若有）。
    public mutating func flush() -> String? {
        defer { buffer.removeAll(keepingCapacity: false) }
        return Self.normalize(buffer)
    }

    private static func normalize<S: DataProtocol>(_ bytes: S) -> String? {
        var line = String(decoding: bytes, as: UTF8.self)
        if line.hasSuffix("\r") { line.removeLast() }
        return line.isEmpty ? nil : line
    }
}
