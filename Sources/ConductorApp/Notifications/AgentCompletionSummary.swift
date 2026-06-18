import Foundation

enum AgentCompletionSummary {
    private static let fallbackMessages: Set<String> = [
        "可以查看结果了",
        "有新结果，点击查看",
        "AI 已完成",
    ]

    static func directMessage(_ raw: String) -> String? {
        let text = normalized(raw)
        guard !text.isEmpty, !fallbackMessages.contains(text) else { return nil }
        return truncate(text, limit: 360)
    }

    static func transcriptSummary(path: String?) -> String? {
        transcriptText(path: path).flatMap(directMessage)
    }

    static func transcriptText(path: String?) -> String? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else { return nil }
        return transcriptText(url: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
    }

    static func transcriptSummary(url: URL) -> String? {
        transcriptText(url: url).flatMap(directMessage)
    }

    static func transcriptText(url: URL) -> String? {
        guard let data = tailData(url: url),
              let raw = String(data: data, encoding: .utf8)
        else { return nil }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = assistantText(from: object),
                  !normalized(text).isEmpty
            else { continue }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    static func terminalSummary(_ raw: String) -> String? {
        terminalText(raw).flatMap(directMessage)
    }

    static func terminalText(_ raw: String) -> String? {
        let ignoredPrefixes = [
            "OpenAI Codex", "model:", "directory:", "permissions:", "Tip:",
            "Run npm", "See full release notes:", "https://github.com/openai/codex",
        ]
        let lines = raw
            .components(separatedBy: .newlines)
            .map { normalized($0) }
            .filter { line in
                guard !line.isEmpty else { return false }
                if fallbackMessages.contains(line) { return false }
                if line.hasPrefix(">") || line.hasPrefix("›") { return false }
                if line.contains(" · ~/") || line.contains(" xhigh") { return false }
                return !ignoredPrefixes.contains { line.hasPrefix($0) }
            }
        guard !lines.isEmpty else { return nil }
        return lines.suffix(12).joined(separator: "\n")
    }

    private static func tailData(url: URL, maxBytes: UInt64 = 2_000_000) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > maxBytes ? size - maxBytes : 0
        try? handle.seek(toOffset: offset)
        return try? handle.readToEnd()
    }

    private static func assistantText(from object: [String: Any]) -> String? {
        if object["type"] as? String == "response_item",
           let payload = object["payload"] as? [String: Any],
           payload["role"] as? String == "assistant" {
            return text(from: payload["content"])
        }

        if object["type"] as? String == "assistant",
           let message = object["message"] as? [String: Any],
           message["role"] as? String == "assistant" {
            return text(from: message["content"])
        }

        if object["role"] as? String == "assistant" {
            return text(from: object["content"])
        }

        return nil
    }

    private static func text(from value: Any?) -> String? {
        if let string = value as? String { return string }
        guard let items = value as? [Any] else { return nil }
        let parts = items.compactMap { item -> String? in
            if let string = item as? String { return string }
            guard let dict = item as? [String: Any] else { return nil }
            let type = dict["type"] as? String
            guard type == nil || type == "text" || type == "output_text" || type == "input_text" else {
                return nil
            }
            if let text = dict["text"] as? String { return text }
            return dict["content"] as? String
        }
        let joined = parts.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    private static func normalized(_ raw: String) -> String {
        raw.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }
}
