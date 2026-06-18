import AppKit
import ConductorCore
import SwiftUI

/// "1e1e2e" → Color；非法值回落近黑（仅用于内置主题字面量，恒合法）。
private func gc(_ hex: String) -> Color { Color(hex: hex) ?? .black }

/// 背景光晕：暗底之上的一团彩色 radial bloom（screen 叠加，像有光打进来）。
struct ThemeGlow {
    let color: Color
    let center: UnitPoint
    let radius: CGFloat     // 半径 = × 窗口长边
    let intensity: Double   // 中心 alpha
}

/// 外壳(侧栏/Tab栏/卡片/文字/强调)的一整套色，按主题数据驱动。对标 Craft：柔和、暖、卡片浮起无硬线。
/// 与 `ThemePalette`(终端配色，喂 ghostty)互补:这套给 SwiftUI/AppKit 外壳用。
struct Theme {
    let windowBackground: Color      // 画布（比卡片略深，卡片浮其上）
    let sidebarBackground: Color
    let cardBackground: NSColor      // 终端卡片底（与终端配色一致）
    let elevated: Color
    let activeFill: Color
    let separator: Color
    let hoverFill: Color
    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color
    let accent: Color
    let isDark: Bool
    // 卡片立体感：浅色用柔阴影，深色用极淡边框 + 弱阴影
    let cardShadowColor: NSColor
    let cardShadowOpacity: Float
    let cardShadowRadius: CGFloat
    let cardBorder: NSColor           // 静态卡片的细边（可近乎透明）

    // 浮层质感（毛玻璃面板 + 高光/边框）与主操作（石墨实心，收敛蓝色）。
    let primarySolid: Color           // 主按钮底（高对比、近黑/近白）
    let primarySolidText: Color       // 主按钮文字
    let panelTint: Color              // 压在毛玻璃上的半透明色调
    let panelHairline: Color          // 浮层细边
    let panelHighlight: Color         // 浮层顶部 1px 高光
    /// 背景光晕（暗底之上的彩色 radial bloom，screen 叠加）。nil = 纯色 / 玻璃主题（走 windowBackground）。
    var backgroundGlows: [ThemeGlow]? = nil

    /// 终端正文是否半透明（ghostty 0.8 + 卡片清空，透出后方光晕暗底）：**仅光晕主题**。
    /// 纯色主题透出的是半透磨砂 + 模糊桌面，会压低终端文字对比度，故保持实底。
    var terminalTranslucent: Bool { backgroundGlows != nil }

    static let dark = Theme(
        windowBackground: Color(red: 0.055, green: 0.057, blue: 0.066),
        sidebarBackground: Color(red: 0.055, green: 0.057, blue: 0.066),
        cardBackground: NSColor(red: 0.106, green: 0.110, blue: 0.133, alpha: 1),
        elevated: Color(red: 0.16, green: 0.16, blue: 0.185),
        activeFill: Color.white.opacity(0.09),
        separator: Color.white.opacity(0.06),
        hoverFill: Color.white.opacity(0.05),
        textPrimary: Color(red: 0.93, green: 0.93, blue: 0.95),   // off-white：纯白在深色上会光晕/发糊
        textSecondary: Color.white.opacity(0.62),
        textTertiary: Color.white.opacity(0.38),
        accent: Color(red: 0.45, green: 0.58, blue: 0.86),   // 收敛：去掉霓虹蓝的廉价感
        isDark: true,
        cardShadowColor: .black,
        cardShadowOpacity: 0.38,
        cardShadowRadius: 11,
        cardBorder: NSColor.white.withAlphaComponent(0.14),   // 边缘高光 rim：玻璃质感主要靠它（调研结论）
        primarySolid: Color(red: 0.95, green: 0.95, blue: 0.96),
        primarySolidText: Color(red: 0.08, green: 0.08, blue: 0.10),
        panelTint: Color.white.opacity(0.04),
        panelHairline: Color.white.opacity(0.10),
        panelHighlight: Color.white.opacity(0.22))

    // 中性浅主题（不带暖色：略偏冷的中性灰白）
    static let light = Theme(
        windowBackground: Color(red: 248.0 / 255.0, green: 248.0 / 255.0, blue: 248.0 / 255.0),
        sidebarBackground: Color(red: 248.0 / 255.0, green: 248.0 / 255.0, blue: 248.0 / 255.0),
        cardBackground: NSColor(red: 0.987, green: 0.989, blue: 0.994, alpha: 1),  // 中性近白
        elevated: Color(red: 1.0, green: 1.0, blue: 1.0),       // 纯白抬起胶囊
        activeFill: Color.black.opacity(0.05),
        separator: Color.black.opacity(0.065),
        hoverFill: Color.black.opacity(0.042),
        textPrimary: Color(red: 0.12, green: 0.13, blue: 0.15),
        textSecondary: Color.black.opacity(0.55),
        textTertiary: Color.black.opacity(0.38),
        accent: Color(red: 0.20, green: 0.40, blue: 0.78),   // 收敛：略去饱和，更克制
        isDark: false,
        cardShadowColor: NSColor(red: 0.13, green: 0.15, blue: 0.20, alpha: 1),    // 中性冷灰阴影
        cardShadowOpacity: 0.11,
        cardShadowRadius: 15,                                                        // 柔阴影（收紧一点）
        cardBorder: NSColor.black.withAlphaComponent(0.035),
        primarySolid: Color(red: 0.12, green: 0.12, blue: 0.13),                     // 近黑主操作（对标 Craft 黑胶囊）
        primarySolidText: .white,
        panelTint: Color.white.opacity(0.55),                                        // 毛玻璃上压一层近白，定调亮净
        panelHairline: Color.black.opacity(0.06),
        panelHighlight: Color.white.opacity(0.75))

    /// 由一组深色配色派生整套外壳主题：沿用深色主题成熟的层级/高光规则，
    /// 只替换底色、文字与强调色。让加新主题=填几个 hex，不再手调二十个字段。
    /// 画布、终端卡底、侧栏/状态栏统一用同一个 `base`——终端不再是一块浮起的异色卡，
    /// 与四周完全融为一色（这些配色本就是为单底色设计的）。
    /// - base:    全局底色（= 该主题终端配色的 background，整窗一色）
    /// - surface: 抬起表面（选中胶囊/分段指示器底）
    /// - text:    主文字（次/三级文字按其透明度派生）
    /// - accent:  强调色（链接/选中描边/开关）
    private static func darkVariant(
        base: String, surface: String, text: String, accent: String
    ) -> Theme {
        Theme(
            windowBackground: gc(base),
            sidebarBackground: gc(base),
            cardBackground: NSColor(gc(base)),
            elevated: gc(surface),
            activeFill: Color.white.opacity(0.09),
            separator: Color.white.opacity(0.07),
            hoverFill: Color.white.opacity(0.05),
            textPrimary: gc(text),
            textSecondary: gc(text).opacity(0.64),
            textTertiary: gc(text).opacity(0.40),
            accent: gc(accent),
            isDark: true,
            cardShadowColor: .black,
            cardShadowOpacity: 0,               // 整窗一色，终端不再浮起 → 无阴影、无异色块
            cardShadowRadius: 0,
            cardBorder: NSColor.white.withAlphaComponent(0.14),   // 边缘高光 rim：玻璃质感主要靠它（调研结论）
            primarySolid: gc(text),            // 主按钮：近白前景实心
            primarySolidText: gc(base),        // 文字：取底色深色
            panelTint: Color.white.opacity(0.04),
            panelHairline: Color.white.opacity(0.10),
            panelHighlight: Color.white.opacity(0.20))
    }

    // 以下四款为社区公认耐看的配色，hex 取自各自官方调色板（整窗单底色）。
    static let tokyoNight = darkVariant(
        base: "1a1b26", surface: "292e42", text: "c0caf5", accent: "7aa2f7")
    static let catppuccin = darkVariant(   // Mocha
        base: "1e1e2e", surface: "313244", text: "cdd6f4", accent: "cba6f7")
    static let nord = darkVariant(
        base: "2e3440", surface: "3b4252", text: "d8dee9", accent: "88c0d0")
    static let rosePine = darkVariant(
        base: "191724", surface: "26233a", text: "e0def4", accent: "c4a7e7")

    /// 光晕主题：暗底 + 若干彩色 radial 光晕（screen 叠加，像有光打进来），外壳/终端卡片浮其上。
    /// 深→深的线性渐变跨整窗几乎看不出，等于一块闷死的纯色；光晕才有空间感与层级。
    private static func auroraVariant(
        base: String, card: String, text: String, accent: String, glows: [ThemeGlow]
    ) -> Theme {
        Theme(
            windowBackground: gc(base),
            sidebarBackground: gc(base),
            cardBackground: NSColor(gc(card)),
            elevated: gc(card),
            activeFill: Color.white.opacity(0.10),
            separator: Color.white.opacity(0.08),
            hoverFill: Color.white.opacity(0.06),
            textPrimary: gc(text),
            textSecondary: gc(text).opacity(0.64),
            textTertiary: gc(text).opacity(0.40),
            accent: gc(accent),
            isDark: true,
            cardShadowColor: .black,
            cardShadowOpacity: 0.30,
            cardShadowRadius: 12,
            cardBorder: NSColor.white.withAlphaComponent(0.16),
            primarySolid: gc(text),
            primarySolidText: gc(base),
            panelTint: Color.white.opacity(0.05),
            panelHairline: Color.white.opacity(0.10),
            panelHighlight: Color.white.opacity(0.20),
            backgroundGlows: glows)
    }

    /// 光晕构造糖：色 + 中心(x,y 单位坐标) + 半径(× 窗口长边) + 中心强度(alpha)。
    private static func glow(_ hex: String, _ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ i: Double) -> ThemeGlow {
        ThemeGlow(color: gc(hex), center: UnitPoint(x: x, y: y), radius: r, intensity: i)
    }

    // 暗底 + 2–3 团不同 hue 的彩色光，对角铺开 → 一眼有光感、有层级（screen 叠加）。
    static let midnight = auroraVariant(
        base: "0a0f1e", card: "141b30", text: "eaf0fb", accent: "6ea8ff",
        glows: [glow("3f6dff", 0.12, 0.10, 1.15, 0.55), glow("7a4dff", 0.90, 0.92, 1.00, 0.42)])
    static let nebula = auroraVariant(      // 星云：靛蓝 + 紫 + 品红
        base: "0c0a1e", card: "1a1636", text: "ece7f9", accent: "c39bf2",
        glows: [glow("7c4dff", 0.14, 0.16, 0.95, 0.60), glow("e0379a", 0.90, 0.88, 0.95, 0.50),
                glow("2e6bff", 0.82, 0.08, 0.70, 0.32)])
    static let orchidDusk = auroraVariant(  // 兰紫暮色：紫 + 粉
        base: "120c1c", card: "20162e", text: "f0e7f7", accent: "c792ea",
        glows: [glow("b06bff", 0.88, 0.12, 1.00, 0.52), glow("ff7eb3", 0.12, 0.90, 0.95, 0.44)])
    static let ember = auroraVariant(       // 余烬：橙 + 红
        base: "140a08", card: "241410", text: "f5e9e1", accent: "ff9466",
        glows: [glow("ff7a3c", 0.14, 0.90, 1.05, 0.55), glow("ff4d5e", 0.90, 0.12, 0.90, 0.40)])
    static let deepSea = auroraVariant(     // 深海：青 + 蓝
        base: "04101c", card: "0d2236", text: "dcebf6", accent: "4cc2ff",
        glows: [glow("1fb6ff", 0.88, 0.14, 1.00, 0.50), glow("2563eb", 0.12, 0.90, 1.00, 0.44)])
    static let blossom = auroraVariant(     // 蓝 → 粉对角双光
        base: "120f26", card: "2a2348", text: "f4eff8", accent: "ecbfe0",
        glows: [glow("5a78ff", 0.12, 0.12, 1.05, 0.50), glow("ff8fc7", 0.90, 0.90, 1.05, 0.50)])
    static let bordeaux = auroraVariant(    // 波尔多：玫红 + 梅紫
        base: "140810", card: "241019", text: "f4e7ec", accent: "e58da8",
        glows: [glow("e0567a", 0.88, 0.12, 1.00, 0.48), glow("7e2a52", 0.12, 0.90, 1.00, 0.42)])
    static let mojave = auroraVariant(      // 沙漠夜：琥珀 + 赤陶
        base: "130d07", card: "241a11", text: "f3ecdf", accent: "e3ab5e",
        glows: [glow("e0a85c", 0.90, 0.90, 1.05, 0.50), glow("c4582f", 0.12, 0.14, 0.95, 0.42)])
    static let slate = auroraVariant(       // 冷中性：钢蓝双光（克制）
        base: "0b0f16", card: "172230", text: "e9eef6", accent: "92b8e2",
        glows: [glow("5e8fd6", 0.14, 0.12, 1.15, 0.40), glow("3a6fae", 0.90, 0.90, 1.00, 0.30)])
    static let graphite = auroraVariant(    // 石墨：极克制冷光（中性首选）
        base: "0d0e11", card: "191c22", text: "eaecf0", accent: "7fb0ff",
        glows: [glow("6f8db5", 0.88, 0.12, 1.05, 0.26), glow("4a5a72", 0.12, 0.90, 0.95, 0.20)])

    static func resolve(_ appearance: Appearance) -> Theme {
        switch appearance.theme {
        case "light": return .light
        case "tokyo-night": return .tokyoNight
        case "catppuccin": return .catppuccin
        case "nord": return .nord
        case "rose-pine": return .rosePine
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
        default: return .dark   // dark / custom: 外壳走深色(custom 仅终端用自定义色)
        }
    }

    @MainActor static var current: Theme { resolve(ConfigStore.shared.config.appearance) }
}
