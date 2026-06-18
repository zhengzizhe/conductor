import ConductorCore

/// 由配置(主题名/自定义色)解析出一组终端配色(hex，不带 #)。
/// 数据驱动:dark/light 内置，custom 用用户 colors，缺项回退 dark。给 ghostty 配置串与(将来)AppStyle 共用。
struct ThemePalette: Equatable {
    let background: String
    let foreground: String
    let cursor: String
    let selection: String
    let selectionForeground: String
    let ansi: [String]

    static let dark = ThemePalette(
        background: "1b1c22", foreground: "d7d8e0", cursor: "8aa9ff",
        selection: "33406b", selectionForeground: "ffffff",
        ansi: [
            "1b1c22", "ff6b6b", "6fda8c", "ffd166",
            "8aa9ff", "c792ea", "6bdde8", "d7d8e0",
            "6c7086", "ff8f8f", "8af2a5", "ffe08a",
            "a8bdff", "dda6f2", "8cecf3", "ffffff",
        ])

    static let light = ThemePalette(
        background: "f8f8f8", foreground: "26272c", cursor: "2b6cff",
        selection: "d4e2ff", selectionForeground: "15161a",
        ansi: [
            "26272c", "d1242f", "1a7f37", "9a6700",
            "0969da", "8250df", "1b7f88", "6e7781",
            "57606a", "a40e26", "2da44e", "bf8700",
            "218bff", "a475f9", "3192aa", "ffffff",
        ])

    // Tokyo Night（night）：官方终端配色。
    static let tokyoNight = ThemePalette(
        background: "1a1b26", foreground: "c0caf5", cursor: "c0caf5",
        selection: "283457", selectionForeground: "c0caf5",
        ansi: [
            "15161e", "f7768e", "9ece6a", "e0af68",
            "7aa2f7", "bb9af7", "7dcfff", "a9b1d6",
            "414868", "ff899d", "9fe044", "faba4a",
            "8db0ff", "c7a9ff", "a4daff", "c0caf5",
        ])

    // Catppuccin Mocha：官方 ANSI 映射（magenta=Pink, cyan=Teal）。
    static let catppuccin = ThemePalette(
        background: "1e1e2e", foreground: "cdd6f4", cursor: "f5e0dc",
        selection: "414458", selectionForeground: "cdd6f4",
        ansi: [
            "45475a", "f38ba8", "a6e3a1", "f9e2af",
            "89b4fa", "f5c2e7", "94e2d5", "bac2de",
            "585b70", "f38ba8", "a6e3a1", "f9e2af",
            "89b4fa", "f5c2e7", "94e2d5", "a6adc8",
        ])

    // Nord：官方 16 色映射。
    static let nord = ThemePalette(
        background: "2e3440", foreground: "d8dee9", cursor: "d8dee9",
        selection: "434c5e", selectionForeground: "eceff4",
        ansi: [
            "3b4252", "bf616a", "a3be8c", "ebcb8b",
            "81a1c1", "b48ead", "88c0d0", "e5e9f0",
            "4c566a", "bf616a", "a3be8c", "ebcb8b",
            "81a1c1", "b48ead", "8fbcbb", "eceff4",
        ])

    // Rosé Pine（main）：官方终端映射。
    static let rosePine = ThemePalette(
        background: "191724", foreground: "e0def4", cursor: "e0def4",
        selection: "403d52", selectionForeground: "e0def4",
        ansi: [
            "26233a", "eb6f92", "31748f", "f6c177",
            "9ccfd8", "c4a7e7", "ebbcba", "e0def4",
            "6e6a86", "eb6f92", "31748f", "f6c177",
            "9ccfd8", "c4a7e7", "ebbcba", "e0def4",
        ])

    /// 渐变主题的终端配色：底色贴合各自卡底、光标取 accent，ANSI 复用中性深色 16 色（任何深底都耐看）。
    private static func gradientTerminal(bg: String, fg: String, cursor: String) -> ThemePalette {
        ThemePalette(background: bg, foreground: fg, cursor: cursor,
                     selection: "3a3d52", selectionForeground: "ffffff", ansi: dark.ansi)
    }
    static let midnight = gradientTerminal(bg: "141b30", fg: "eaf0fb", cursor: "6ea8ff")
    static let orchidDusk = gradientTerminal(bg: "20162e", fg: "f0e7f7", cursor: "c792ea")
    static let ember = gradientTerminal(bg: "241410", fg: "f5e9e1", cursor: "ff9466")
    static let graphite = gradientTerminal(bg: "191c22", fg: "eaecf0", cursor: "7fb0ff")
    static let deepSea = gradientTerminal(bg: "0d2236", fg: "dcebf6", cursor: "4cc2ff")
    // 底色取各主题 card（与磨砂 header 同色系 → 终端体与卡片不脱节）。
    static let blossom = gradientTerminal(bg: "2a2348", fg: "f4eff8", cursor: "ecbfe0")
    static let nebula = gradientTerminal(bg: "1a1636", fg: "ece7f9", cursor: "c39bf2")
    static let mojave = gradientTerminal(bg: "241a11", fg: "f3ecdf", cursor: "e3ab5e")
    static let bordeaux = gradientTerminal(bg: "241019", fg: "f4e7ec", cursor: "e58da8")
    static let slate = gradientTerminal(bg: "172230", fg: "e9eef6", cursor: "92b8e2")

    static func resolve(_ appearance: Appearance) -> ThemePalette {
        switch appearance.theme {
        case "light":
            return .light
        case "tokyo-night":
            return .tokyoNight
        case "catppuccin":
            return .catppuccin
        case "nord":
            return .nord
        case "rose-pine":
            return .rosePine
        case "midnight": return .midnight
        case "orchid-dusk": return .orchidDusk
        case "ember": return .ember
        case "graphite": return .graphite
        case "deep-sea": return .deepSea
        case "blossom": return .blossom
        case "nebula": return .nebula
        case "mojave": return .mojave
        case "bordeaux": return .bordeaux
        case "slate": return .slate
        case "custom":
            let d = ThemePalette.dark
            let c = appearance.colors
            return ThemePalette(
                background: hex(c?.background) ?? d.background,
                foreground: hex(c?.foreground) ?? d.foreground,
                cursor: hex(c?.cursor) ?? d.cursor,
                selection: hex(c?.selection) ?? d.selection,
                selectionForeground: "ffffff",
                ansi: mergedANSI(c?.ansi, fallback: d.ansi))
        default:
            return .dark
        }
    }

    /// 终端底色是否偏深。custom 主题也按实际背景亮度判断，
    /// 用于告知 TUI（mode 2031）当前是深色还是浅色方案。
    var isDark: Bool {
        guard background.count >= 6,
              let r = UInt8(background.prefix(2), radix: 16),
              let g = UInt8(background.dropFirst(2).prefix(2), radix: 16),
              let b = UInt8(background.dropFirst(4).prefix(2), radix: 16)
        else { return true }
        // ITU-R BT.601 亮度
        let luma = 0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)
        return luma < 128
    }

    /// "#1b1c22" / "1b1c22" → "1b1c22"；nil/空 → nil。
    private static func hex(_ s: String?) -> String? {
        guard let s else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let value = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard value.count == 6, value.allSatisfy(\.isHexDigit) else { return nil }
        return value.lowercased()
    }

    private static func mergedANSI(_ custom: [String]?, fallback: [String]) -> [String] {
        var colors = fallback
        for (index, raw) in (custom ?? []).prefix(16).enumerated() {
            if let color = hex(raw) { colors[index] = color }
        }
        return colors
    }
}
