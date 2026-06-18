import SwiftUI

enum SettingsSectionID: String, CaseIterable, Identifiable {
    case appearance
    case terminal
    case ghostty
    case behavior
    case companion
    case keybindings

    static let `default`: SettingsSectionID = .appearance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: L("外观")
        case .terminal: L("终端")
        case .ghostty: L("高级")
        case .behavior: L("行为")
        case .companion: L("伙伴")
        case .keybindings: L("快捷键")
        }
    }

    var subtitle: String {
        switch self {
        case .appearance: L("主题、语言、配色")
        case .terminal: L("Shell 与会话")
        case .ghostty: L("底层终端选项")
        case .behavior: L("工作区默认行为")
        case .companion: L("桌面通知宠物")
        case .keybindings: L("应用命令")
        }
    }

    var systemImage: String {
        switch self {
        case .appearance: "paintbrush"
        case .terminal: "terminal"
        case .ghostty: "slider.horizontal.3"
        case .behavior: "arrow.triangle.2.circlepath"
        case .companion: "pawprint.fill"
        case .keybindings: "keyboard"
        }
    }
}

struct ConductorGhosttyConfigGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    let keys: [String]

    var countTitle: String { L("%ld 项", keys.count) }
}

struct ConductorGhosttyConfigCopy: Equatable {
    let title: String
    let summary: String
}

enum ConductorGhosttyConfigControlKind {
    case boolean
    case choice([(label: String, value: String)])
    case color
    case filePath
    case fontFamily
    case integer(range: ClosedRange<Int>, step: Int)
    case percent(range: ClosedRange<Double>, defaultValue: Double, format: ConductorGhosttyPercentFormat)
    case decimal(range: ClosedRange<Double>, defaultValue: Double, step: Double)
    case text
}

enum ConductorGhosttyPercentFormat {
    case fraction
    case percentString
}

enum ConductorGhosttyConfigCatalog {
    static let knownKeySet = Set(productGroups.flatMap(\.keys))
    private static let localizedCopy: [String: ConductorGhosttyConfigCopy] = [
        "font-family": ConductorGhosttyConfigCopy(title: L("字体"), summary: L("选择终端文字使用的等宽字体")),
        "font-size": ConductorGhosttyConfigCopy(title: L("字号"), summary: L("调整终端文字大小")),
        "font-feature": ConductorGhosttyConfigCopy(title: L("字体特性"), summary: L("开启或关闭字体连字等 OpenType 特性")),
        "font-thicken": ConductorGhosttyConfigCopy(title: L("文字加粗渲染"), summary: L("macOS 原生风格的笔画平滑，文字更扎实清晰")),
        "font-thicken-strength": ConductorGhosttyConfigCopy(title: L("加粗强度"), summary: L("0 最轻、255 最重；仅在加粗渲染开启时生效")),
        "adjust-cell-width": ConductorGhosttyConfigCopy(title: L("字格宽度微调"), summary: L("细调每个字符占用的水平空间")),
        "adjust-cell-height": ConductorGhosttyConfigCopy(title: L("字格高度微调"), summary: L("细调每行文字占用的垂直空间")),
        "adjust-font-baseline": ConductorGhosttyConfigCopy(title: L("文字基线微调"), summary: L("上下移动文字，让字体看起来更居中")),
        "adjust-underline-position": ConductorGhosttyConfigCopy(title: L("下划线位置"), summary: L("调整下划线离文字底部的距离")),
        "adjust-underline-thickness": ConductorGhosttyConfigCopy(title: L("下划线粗细"), summary: L("调整下划线显示厚度")),
        "adjust-cursor-thickness": ConductorGhosttyConfigCopy(title: L("光标粗细"), summary: L("调整竖线或下划线光标的厚度")),
        "adjust-cursor-height": ConductorGhosttyConfigCopy(title: L("光标高度"), summary: L("调整光标在字格中的高度")),

        "cursor-style": ConductorGhosttyConfigCopy(title: L("光标样式"), summary: L("选择块、空心块、竖线或下划线光标")),
        "cursor-style-blink": ConductorGhosttyConfigCopy(title: L("光标闪烁"), summary: L("控制光标是否闪烁")),
        "cursor-color": ConductorGhosttyConfigCopy(title: L("光标颜色"), summary: L("指定光标使用的颜色")),
        "cursor-opacity": ConductorGhosttyConfigCopy(title: L("光标透明度"), summary: L("降低后光标更轻，100% 最醒目")),
        "cursor-text": ConductorGhosttyConfigCopy(title: L("光标内文字颜色"), summary: L("光标覆盖文字时使用的文字颜色")),
        "cursor-click-to-move": ConductorGhosttyConfigCopy(title: L("点击移动光标"), summary: L("允许鼠标点击把光标移动到目标位置")),

        "alpha-blending": ConductorGhosttyConfigCopy(title: L("文字混合色彩空间"), summary: L("线性校正可消除彩色文字边缘的暗边毛刺")),
        "background-opacity": ConductorGhosttyConfigCopy(title: L("背景不透明度"), summary: L("降低后可以透出窗口材质，100% 最清晰")),
        "background-blur": ConductorGhosttyConfigCopy(title: L("背景模糊"), summary: L("透明背景下柔化后方内容")),
        "background-image": ConductorGhosttyConfigCopy(title: L("背景图片"), summary: L("选择一张图片作为终端背景")),
        "background-image-opacity": ConductorGhosttyConfigCopy(title: L("背景图片透明度"), summary: L("控制背景图片显示强度")),
        "background-image-fit": ConductorGhosttyConfigCopy(title: L("背景图片填充"), summary: L("控制背景图片如何适配窗口")),
        "minimum-contrast": ConductorGhosttyConfigCopy(title: L("最低对比度"), summary: L("提高文字与背景之间的可读性")),
        "selection-foreground": ConductorGhosttyConfigCopy(title: L("选区文字颜色"), summary: L("被选中文字的前景色")),
        "selection-background": ConductorGhosttyConfigCopy(title: L("选区背景颜色"), summary: L("文本选区的背景色")),
        "search-foreground": ConductorGhosttyConfigCopy(title: L("搜索文字颜色"), summary: L("搜索命中文本的前景色")),
        "search-background": ConductorGhosttyConfigCopy(title: L("搜索背景颜色"), summary: L("搜索命中文本的背景色")),
        "search-selected-foreground": ConductorGhosttyConfigCopy(title: L("当前搜索文字颜色"), summary: L("当前搜索命中的文字颜色")),
        "search-selected-background": ConductorGhosttyConfigCopy(title: L("当前搜索背景颜色"), summary: L("当前搜索命中的背景颜色")),

        "selection-clear-on-typing": ConductorGhosttyConfigCopy(title: L("输入时清除选区"), summary: L("开始输入后自动取消当前选择")),
        "selection-clear-on-copy": ConductorGhosttyConfigCopy(title: L("复制后清除选区"), summary: L("复制完成后自动取消当前选择")),
        "selection-word-chars": ConductorGhosttyConfigCopy(title: L("单词选择字符"), summary: L("定义双击选择单词时包含哪些字符")),
        "copy-on-select": ConductorGhosttyConfigCopy(title: L("选中即复制"), summary: L("选中文本后自动复制到剪贴板")),
        "mouse-hide-while-typing": ConductorGhosttyConfigCopy(title: L("输入时隐藏鼠标"), summary: L("打字时暂时隐藏鼠标指针")),
        "mouse-reporting": ConductorGhosttyConfigCopy(title: L("应用接收鼠标事件"), summary: L("允许终端程序接收鼠标点击和滚动")),
        "mouse-scroll-multiplier": ConductorGhosttyConfigCopy(title: L("滚轮速度"), summary: L("放大或降低鼠标滚动速度")),
        "link-url": ConductorGhosttyConfigCopy(title: L("识别链接"), summary: L("自动识别终端里的网址")),
        "link-previews": ConductorGhosttyConfigCopy(title: L("链接预览"), summary: L("悬停链接时显示预览信息")),

        "clipboard-read": ConductorGhosttyConfigCopy(title: L("允许读取剪贴板"), summary: L("允许终端程序读取剪贴板内容")),
        "clipboard-write": ConductorGhosttyConfigCopy(title: L("允许写入剪贴板"), summary: L("允许终端程序写入剪贴板")),
        "clipboard-trim-trailing-spaces": ConductorGhosttyConfigCopy(title: L("复制时去掉行尾空格"), summary: L("复制文本时自动清理每行末尾空格")),
        "clipboard-paste-protection": ConductorGhosttyConfigCopy(title: L("粘贴保护"), summary: L("粘贴可疑多行内容时进行保护")),
        "clipboard-paste-bracketed-safe": ConductorGhosttyConfigCopy(title: L("安全括号粘贴"), summary: L("使用更安全的括号粘贴模式")),

        "shell-integration": ConductorGhosttyConfigCopy(title: L("Shell 集成"), summary: L("增强目录、命令状态等 Shell 交互能力")),
        "initial-command": ConductorGhosttyConfigCopy(title: L("启动命令"), summary: L("打开终端后自动执行的命令")),
        "working-directory": ConductorGhosttyConfigCopy(title: L("默认工作目录"), summary: L("新终端启动时进入的目录")),
        "scrollback-limit": ConductorGhosttyConfigCopy(title: L("历史回滚行数"), summary: L("控制终端保留多少行历史输出")),

        "key-remap": ConductorGhosttyConfigCopy(title: L("终端键位映射"), summary: L("改写发送给终端程序的按键")),
        "macos-option-as-alt": ConductorGhosttyConfigCopy(title: L("Option 作为 Alt"), summary: L("指定哪些 Option 键按 Alt 发送"))
    ]

    static let booleanKeys: Set<String> = [
        "cursor-style-blink", "cursor-click-to-move", "selection-clear-on-typing",
        "selection-clear-on-copy", "copy-on-select", "mouse-hide-while-typing",
        "mouse-reporting", "link-url", "link-previews", "clipboard-read",
        "clipboard-write", "clipboard-trim-trailing-spaces", "clipboard-paste-protection",
        "clipboard-paste-bracketed-safe", "shell-integration", "font-thicken"
    ]

    static let choiceOptions: [String: [(label: String, value: String)]] = [
        "cursor-style": [(L("块"), "block"), (L("空心块"), "block_hollow"), (L("竖线"), "bar"), (L("下划线"), "underline")],
        "background-image-fit": [(L("包含"), "contain"), (L("覆盖"), "cover"), (L("拉伸"), "stretch"), (L("不缩放"), "none")],
        "macos-option-as-alt": [(L("左"), "left"), (L("右"), "right"), (L("两侧"), "true"), (L("关闭"), "false")],
        "alpha-blending": [(L("线性校正"), "linear-corrected"), (L("原生"), "native"), (L("线性"), "linear")]
    ]

    static func copy(for key: String) -> ConductorGhosttyConfigCopy {
        localizedCopy[key] ?? ConductorGhosttyConfigCopy(title: L("高级选项"), summary: L("底层终端配置"))
    }

    static func controlKind(for key: String) -> ConductorGhosttyConfigControlKind {
        if let options = choiceOptions[key] { return .choice(options) }
        if booleanKeys.contains(key) { return .boolean }
        if key == "font-family" { return .fontFamily }
        if key == "background-image" || key == "working-directory" { return .filePath }
        if key.hasSuffix("-color") ||
            key.hasSuffix("-foreground") ||
            key.hasSuffix("-background") ||
            key == "cursor-text" {
            return .color
        }
        if key == "font-size" { return .integer(range: 8...36, step: 1) }
        if key == "font-thicken-strength" { return .integer(range: 0...255, step: 16) }
        if key == "scrollback-limit" { return .integer(range: 0...1_000_000, step: 1000) }
        if key == "minimum-contrast" { return .integer(range: 1...21, step: 1) }
        if key.hasPrefix("adjust-") {
            return .percent(range: -40...40, defaultValue: 0, format: .percentString)
        }
        if key == "background-opacity" ||
            key == "background-image-opacity" ||
            key == "cursor-opacity" {
            return .percent(range: 0...1, defaultValue: 1, format: .fraction)
        }
        if key == "mouse-scroll-multiplier" {
            return .decimal(range: 0.1...5, defaultValue: 1, step: 0.1)
        }
        return .text
    }

    static let productGroups: [ConductorGhosttyConfigGroup] = [
        ConductorGhosttyConfigGroup(
            id: "typography",
            title: L("字体与字格"),
            subtitle: L("字体、字号、行高、字格和下划线微调"),
            systemImage: "textformat.size",
            keys: [
                "font-family", "font-size", "font-feature",
                "font-thicken", "font-thicken-strength",
                "adjust-cell-width", "adjust-cell-height",
                "adjust-font-baseline", "adjust-underline-position",
                "adjust-underline-thickness", "adjust-cursor-thickness",
                "adjust-cursor-height"
            ]
        ),
        ConductorGhosttyConfigGroup(
            id: "cursor",
            title: L("光标"),
            subtitle: L("形状、颜色、闪烁、透明度和点击移动"),
            systemImage: "cursorarrow",
            keys: [
                "cursor-style", "cursor-style-blink", "cursor-color",
                "cursor-opacity", "cursor-text", "cursor-click-to-move"
            ]
        ),
        ConductorGhosttyConfigGroup(
            id: "background",
            title: L("背景与颜色"),
            subtitle: L("背景、透明度、选区、搜索高亮和对比度"),
            systemImage: "paintpalette",
            keys: [
                "alpha-blending", "background-opacity", "background-blur", "background-image",
                "background-image-opacity", "background-image-fit",
                "minimum-contrast", "selection-foreground", "selection-background",
                "search-foreground", "search-background", "search-selected-foreground",
                "search-selected-background"
            ]
        ),
        ConductorGhosttyConfigGroup(
            id: "selection_mouse",
            title: L("选择、鼠标与链接"),
            subtitle: L("选区清理、复制选择、滚轮速度和链接"),
            systemImage: "cursorarrow.click",
            keys: [
                "selection-clear-on-typing", "selection-clear-on-copy",
                "selection-word-chars", "copy-on-select", "mouse-hide-while-typing",
                "mouse-reporting", "mouse-scroll-multiplier", "link-url", "link-previews"
            ]
        ),
        ConductorGhosttyConfigGroup(
            id: "clipboard",
            title: L("剪贴板与粘贴"),
            subtitle: L("剪贴板读写、尾随空格和粘贴保护"),
            systemImage: "doc.on.clipboard",
            keys: [
                "clipboard-read", "clipboard-write", "clipboard-trim-trailing-spaces",
                "clipboard-paste-protection", "clipboard-paste-bracketed-safe"
            ]
        ),
        ConductorGhosttyConfigGroup(
            id: "shell",
            title: L("Shell 与启动"),
            subtitle: L("启动命令、默认目录、Shell 集成和历史容量"),
            systemImage: "terminal",
            keys: [
                "shell-integration", "initial-command", "working-directory", "scrollback-limit"
            ]
        ),
        ConductorGhosttyConfigGroup(
            id: "keyboard",
            title: L("键盘"),
            subtitle: L("终端输入层键位，不含应用命令快捷键"),
            systemImage: "keyboard",
            keys: [
                "key-remap", "macos-option-as-alt"
            ]
        )
    ]
}
