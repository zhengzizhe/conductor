import Foundation

enum SkillsshClient {
    static func fetchLeaderboard(board: String) throws -> [SkillsShSkill] {
        let urlString: String
        switch board {
        case "trending":
            urlString = "https://skills.sh/trending"
        case "hot":
            urlString = "https://skills.sh/hot"
        default:
            urlString = "https://skills.sh/"
        }
        let html = try httpGetString(urlString)
        return parseLeaderboardHTML(html)
    }

    static func search(query: String, limit: Int) throws -> [SkillsShSkill] {
        var components = URLComponents(string: "https://skills.sh/api/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: "\(max(1, min(limit, 200)))")
        ]
        guard let url = components?.url else {
            throw SkillManagerError.networkFailed("Invalid skills.sh search URL.")
        }
        let data = try httpGetData(url)
        let json = try JSONSerialization.jsonObject(with: data)
        if let array = json as? [[String: Any]] {
            return parseSkillsArray(array)
        }
        if let object = json as? [String: Any],
           let array = object["skills"] as? [[String: Any]] {
            return parseSkillsArray(array)
        }
        return []
    }

    static func parseLeaderboardHTML(_ html: String) -> [SkillsShSkill] {
        if let parsed = parseNextData(html), !parsed.isEmpty {
            return parsed
        }
        return parseEmbeddedSkillObjects(html)
    }

    private static func httpGetString(_ urlString: String) throws -> String {
        guard let url = URL(string: urlString) else {
            throw SkillManagerError.networkFailed("Invalid URL: \(urlString)")
        }
        let data = try httpGetData(url)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func httpGetData(_ url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw SkillManagerError.networkFailed(error.localizedDescription)
        }
    }

    private static func parseNextData(_ html: String) -> [SkillsShSkill]? {
        let marker = #"<script id="__NEXT_DATA__" type="application/json">"#
        guard let startRange = html.range(of: marker),
              let endRange = html[startRange.upperBound...].range(of: "</script>") else {
            return nil
        }
        let jsonString = String(html[startRange.upperBound..<endRange.lowerBound])
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        for path in [
            ["props", "pageProps", "initialSkills"],
            ["props", "pageProps", "skills"],
            ["props", "pageProps", "items"]
        ] {
            if let array = value(at: path, in: json) as? [[String: Any]] {
                return parseSkillsArray(array)
            }
        }
        return nil
    }

    private static func parseEmbeddedSkillObjects(_ html: String) -> [SkillsShSkill] {
        let pattern = #"(?:\\)?"source(?:\\)?"\s*:\s*(?:\\)?"([^"\\]+)(?:\\)?".{0,800}?(?:(?:\\)?"skillId(?:\\)?"|(?:\\)?"skill_id(?:\\)?")\s*:\s*(?:\\)?"([^"\\]+)(?:\\)?".{0,800}?(?:\\)?"name(?:\\)?"\s*:\s*(?:\\)?"([^"\\]*)(?:\\)?".{0,800}?(?:\\)?"installs(?:\\)?"\s*:\s*(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        var seen = Set<String>()
        var out: [SkillsShSkill] = []
        regex.enumerateMatches(in: html, range: nsRange) { match, _, _ in
            guard let match,
                  let sourceRange = Range(match.range(at: 1), in: html),
                  let skillRange = Range(match.range(at: 2), in: html) else {
                return
            }
            let source = html[sourceRange].replacingOccurrences(of: #"\""#, with: #"""#)
            let skillID = html[skillRange].replacingOccurrences(of: #"\""#, with: #"""#)
            let id = "\(source)/\(skillID)"
            guard seen.insert(id).inserted else { return }
            let name: String
            if let range = Range(match.range(at: 3), in: html) {
                let parsed = html[range].replacingOccurrences(of: #"\""#, with: #"""#)
                name = parsed.isEmpty ? skillID : parsed
            } else {
                name = skillID
            }
            let installs: UInt64
            if let range = Range(match.range(at: 4), in: html) {
                installs = UInt64(html[range]) ?? 0
            } else {
                installs = 0
            }
            out.append(SkillsShSkill(
                id: id,
                skillID: skillID,
                name: name,
                source: String(source),
                installs: installs))
        }
        return out
    }

    private static func parseSkillsArray(_ array: [[String: Any]]) -> [SkillsShSkill] {
        var seen = Set<String>()
        var out: [SkillsShSkill] = []
        for item in array {
            let source = item["source"] as? String ?? ""
            let skillID = item["skillId"] as? String ??
                item["skill_id"] as? String ??
                item["id"] as? String ??
                ""
            guard !source.isEmpty, !skillID.isEmpty else { continue }
            let id = "\(source)/\(skillID)"
            guard seen.insert(id).inserted else { continue }
            let name = (item["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? skillID
            let installs = (item["installs"] as? NSNumber)?.uint64Value ??
                UInt64(item["installs"] as? Int ?? 0)
            out.append(SkillsShSkill(
                id: id,
                skillID: skillID,
                name: name,
                source: source,
                installs: installs))
        }
        return out
    }

    private static func value(at path: [String], in json: Any) -> Any? {
        var current: Any? = json
        for key in path {
            current = (current as? [String: Any])?[key]
        }
        return current
    }
}
