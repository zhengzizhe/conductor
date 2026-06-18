import Combine
import ConductorCore
import Foundation

enum TaskCardExecutor: Codable, Equatable, Sendable {
    case shell
    case agent(String)

    var selectionID: String {
        switch self {
        case .shell:
            return "shell"
        case let .agent(id):
            return "agent:\(id)"
        }
    }

    var agentID: String? {
        guard case let .agent(id) = self else { return nil }
        return id
    }

    init(selectionID: String) {
        if selectionID.hasPrefix("agent:") {
            let id = String(selectionID.dropFirst("agent:".count))
            self = id.isEmpty ? .shell : .agent(id)
        } else {
            self = .shell
        }
    }
}

struct TaskCard: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var title: String
    var prompt: String
    var workspaceID: String?
    var executor: TaskCardExecutor
    var createdAt: Date
    var updatedAt: Date
    var lastRunAt: Date?
    var runCount: Int

    var displayTitle: String {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanTitle.isEmpty { return cleanTitle }
        let firstLine = prompt
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return firstLine?.isEmpty == false ? firstLine! : L("新任务")
    }

    static func fresh(workspaceID: String?) -> TaskCard {
        TaskCard(
            id: "task-\(UUID().uuidString)",
            title: "",
            prompt: "",
            workspaceID: workspaceID,
            executor: .shell,
            createdAt: Date(),
            updatedAt: Date(),
            lastRunAt: nil,
            runCount: 0)
    }
}

@MainActor
final class TaskCardStore: ObservableObject {
    @Published private(set) var cards: [TaskCard] = []

    private let fileURL: URL

    init(fileURL: URL = TaskCardStore.defaultFileURL) {
        self.fileURL = fileURL
        load()
    }

    @discardableResult
    func create(workspaceID: String?) -> TaskCard {
        let card = TaskCard.fresh(workspaceID: workspaceID)
        cards.insert(card, at: 0)
        persist()
        return card
    }

    func upsert(_ card: TaskCard) {
        var normalized = card
        normalized.title = normalized.title.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.prompt = normalized.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.updatedAt = Date()
        if let index = cards.firstIndex(where: { $0.id == card.id }) {
            cards[index] = normalized
        } else {
            cards.insert(normalized, at: 0)
        }
        persist()
    }

    func delete(_ id: String) {
        cards.removeAll { $0.id == id }
        persist()
    }

    func markRan(_ id: String, at date: Date = Date()) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[index].lastRunAt = date
        cards[index].runCount += 1
        cards[index].updatedAt = date
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? Self.decoder.decode([TaskCard].self, from: data)
        else {
            cards = []
            return
        }
        cards = decoded
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil)
            let data = try Self.encoder.encode(cards)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("[conductor] failed to save task cards: \(error)")
        }
    }

    nonisolated private static var defaultFileURL: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("conductor", isDirectory: true)
        return appSupport.appendingPathComponent("task-cards.json")
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}
