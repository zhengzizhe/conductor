import Foundation

public enum ShellCommandQuoting {
    public static func singleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func token(_ value: String) -> String {
        let safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._/@:-")
        if !value.isEmpty, value.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return value
        }
        return singleQuote(value)
    }
}

public enum ShellWords {
    public static func split(_ command: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false

        for char in command {
            if escaping {
                current.append(char)
                escaping = false
                continue
            }
            if char == "\\" {
                escaping = true
                continue
            }
            if let active = quote {
                if char == active {
                    quote = nil
                } else {
                    current.append(char)
                }
                continue
            }
            if char == "'" || char == "\"" {
                quote = char
                continue
            }
            if char == " " || char == "\t" || char == "\n" {
                if !current.isEmpty {
                    words.append(current)
                    current.removeAll(keepingCapacity: true)
                }
                continue
            }
            current.append(char)
        }
        if escaping { current.append("\\") }
        if !current.isEmpty { words.append(current) }
        return words
    }
}
