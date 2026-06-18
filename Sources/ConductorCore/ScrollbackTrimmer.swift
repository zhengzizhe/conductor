import Foundation

/// 终端内容快照的截尾：只保留末尾 N 行 / M 字节，并收掉屏幕底部的成片空行。
/// 纯函数，便于单测；落盘/回放由 app 层负责。
public enum ScrollbackTrimmer {
    public static let defaultMaxLines = 4000
    public static let defaultMaxBytes = 400_000

    public static func trim(
        _ text: String,
        maxLines: Int = defaultMaxLines,
        maxBytes: Int = defaultMaxBytes
    ) -> String {
        var lines = stripTerminalColorOSC(text)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        lines.removeAll(where: isDecorativeHorizontalRule)
        // 屏幕底部（提示符以下）是成片空行：全部收掉，回放时不顶出一大段空白。
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
        var result = lines.joined(separator: "\n")
        // 字节上限：超了就从头按行丢，直到装下（保留最新内容）。
        while result.utf8.count > maxBytes, !lines.isEmpty {
            let overshoot = result.utf8.count - maxBytes
            var dropped = 0
            var cut = 0
            for (index, line) in lines.enumerated() {
                dropped += line.utf8.count + 1
                if dropped >= overshoot { cut = index + 1; break }
            }
            lines.removeFirst(max(cut, 1))
            result = lines.joined(separator: "\n")
        }
        return wrapWithANSIResetIfNeeded(result)
    }

    /// 去掉修改终端调色板/前背景色的 OSC 序列。它们是 UI 状态，不是会话内容。
    public static func stripTerminalColorOSC(_ text: String) -> String {
        let scalars = text.unicodeScalars
        var output = String.UnicodeScalarView()
        var index = scalars.startIndex
        let esc: UnicodeScalar = "\u{1B}"
        let bel: UnicodeScalar = "\u{07}"
        let osc: UnicodeScalar = "]"
        let semicolon: UnicodeScalar = ";"
        let st: UnicodeScalar = "\\"

        mainLoop: while index < scalars.endIndex {
            if scalars[index] == esc {
                let next = scalars.index(after: index)
                if next < scalars.endIndex, scalars[next] == osc {
                    var cursor = scalars.index(after: next)
                    var codeScalars = String.UnicodeScalarView()
                    while cursor < scalars.endIndex {
                        let scalar = scalars[cursor]
                        if scalar == semicolon || scalar == bel || scalar == esc { break }
                        codeScalars.append(scalar)
                        cursor = scalars.index(after: cursor)
                    }
                    if shouldStripOSCCode(String(codeScalars)) {
                        var scan = cursor
                        while scan < scalars.endIndex {
                            let scalar = scalars[scan]
                            scan = scalars.index(after: scan)
                            if scalar == bel {
                                index = scan
                                continue mainLoop
                            }
                            if scalar == esc, scan < scalars.endIndex, scalars[scan] == st {
                                index = scalars.index(after: scan)
                                continue mainLoop
                            }
                        }
                    }
                }
            }
            output.append(scalars[index])
            index = scalars.index(after: index)
        }
        return String(output)
    }

    private static func shouldStripOSCCode(_ code: String) -> Bool {
        guard let value = Int(code) else { return false }
        return value == 4
            || value == 5
            || value == 104
            || value == 105
            || (10...19).contains(value)
            || (110...119).contains(value)
    }

    private static func isDecorativeHorizontalRule(_ line: String) -> Bool {
        let plain = stripSGR(line).trimmingCharacters(in: .whitespaces)
        guard plain.count >= 16 else { return false }
        return plain.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x2500, 0x2501, 0x2550: // ─, ━, ═
                return true
            default:
                return false
            }
        }
    }

    private static func stripSGR(_ text: String) -> String {
        let scalars = text.unicodeScalars
        var output = String.UnicodeScalarView()
        var index = scalars.startIndex
        let esc: UnicodeScalar = "\u{1B}"
        let csi: UnicodeScalar = "["

        while index < scalars.endIndex {
            // 整段跳过 CSI 转义：ESC [ … 终止字节(0x40–0x7E，含 'm')。
            if scalars[index] == esc {
                let next = scalars.index(after: index)
                if next < scalars.endIndex, scalars[next] == csi {
                    var cursor = scalars.index(after: next)
                    while cursor < scalars.endIndex {
                        let value = scalars[cursor].value
                        cursor = scalars.index(after: cursor)
                        if value >= 0x40, value <= 0x7E { break }   // 终止字节
                    }
                    index = cursor          // 跳到转义序列之后
                    continue                // 继续**外层**循环，别 append（之前的 bug：可能越界）
                }
            }
            output.append(scalars[index])
            index = scalars.index(after: index)
        }
        return String(output)
    }

    private static func wrapWithANSIResetIfNeeded(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        let reset = "\u{1B}[0m"
        var result = text
        if !result.hasPrefix(reset) { result = reset + result }
        result += reset   // 末尾无条件补 reset：保证回放内容的转义状态被收口（即便已以 reset 结尾）
        return result
    }
}
