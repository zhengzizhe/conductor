import Foundation

/// 一条命令片段：一键发到当前终端，免去反复敲长命令。
struct Snippet: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var command: String
    /// true = 发出后直接回车执行；false = 只摆在提示符上（可改完再回车）。
    var autoRun: Bool = false
}

extension Snippet {
    /// 命令里的 `{{占位符}}`，按出现顺序去重。发送时弹小面板逐个填值。
    var placeholders: [String] {
        Self.placeholders(in: command)
    }

    static func placeholders(in command: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\{\{([^{}\n]+)\}\}"#) else { return [] }
        let range = NSRange(command.startIndex..., in: command)
        var seen = Set<String>()
        var names: [String] = []
        regex.enumerateMatches(in: command, range: range) { match, _, _ in
            guard let match, let r = Range(match.range(at: 1), in: command) else { return }
            let name = String(command[r]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, seen.insert(name).inserted else { return }
            names.append(name)
        }
        return names
    }

    /// 用填好的值替换全部同名占位符；没提供值的占位符原样保留。
    static func fill(_ command: String, values: [String: String]) -> String {
        var result = command
        for (name, value) in values {
            // 占位符两侧花括号内允许留空格：{{ name }} 与 {{name}} 等价
            guard let regex = try? NSRegularExpression(
                pattern: #"\{\{\s*"# + NSRegularExpression.escapedPattern(for: name) + #"\s*\}\}"#) else { continue }
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result),
                withTemplate: NSRegularExpression.escapedTemplate(for: value))
        }
        return result
    }
}

/// 片段库：JSON 持久化在 Application Support/conductor/snippets.json。
@MainActor
final class SnippetStore: ObservableObject {
    static let shared = SnippetStore()

    @Published private(set) var snippets: [Snippet] = []

    private static var fileURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("conductor", isDirectory: true)
            .appendingPathComponent("snippets.json")
    }

    private init() {
        load()
    }

    func add(_ snippet: Snippet) {
        snippets.append(snippet)
        save()
    }

    func update(_ snippet: Snippet) {
        guard let i = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        snippets[i] = snippet
        save()
    }

    func remove(_ id: String) {
        snippets.removeAll { $0.id == id }
        save()
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        snippets.move(fromOffsets: fromOffsets, toOffset: toOffset)
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let decoded = try? JSONDecoder().decode([Snippet].self, from: data) else {
            snippets = []
            return
        }
        snippets = decoded
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snippets)
            try data.write(to: Self.fileURL, options: .atomic)
        } catch {
            NSLog("[conductor] 写 snippets.json 失败：\(error)")
        }
    }

}
