import AppKit
@preconcurrency import GhosttyKit

// 键盘输入翻译层：NSEvent.ModifierFlags ⇄ libghostty mods 互转，以及把 NSEvent
// 翻成 ghostty_input_key_s。逻辑移植自 Ghostty 官方 macOS app（MIT License,
// © 2024 Mitchell Hashimoto & Ghostty contributors）：
//   macos/Sources/Ghostty/Ghostty.Input.swift
//   macos/Sources/Ghostty/NSEvent+Extension.swift
// 这些是终端按键编码里踩坑最多、最该照搬的部分（consumed_mods / 无修饰码点 /
// 死键与 Option-as-Alt 的 translation mods），自己重写极易出错。

enum GhosttyInput {
    /// NSEvent 修饰键 → libghostty mods。含 capsLock 与左右分侧（部分键绑定要区分左右 Option 等）。
    static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue

        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }

        // 分侧信息：ghostty 结构里无法表达"左右同时按下"，但我们也用不到。
        let raw = flags.rawValue
        if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }

        return ghostty_input_mods_e(mods)
    }

    /// libghostty mods → NSEvent 修饰键。用于把 ghostty_surface_key_translation_mods 的
    /// 结果回译成 NSEvent.ModifierFlags 以重建按键事件。只关心四个基本修饰键。
    static func eventModifierFlags(_ mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags = NSEvent.ModifierFlags(rawValue: 0)
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
        return flags
    }
}

extension NSEvent {
    /// 把本按键事件翻成 ghostty_input_key_s（不含 text / composing —— 这两个生命周期
    /// 不安全，由调用方按需补上）。translationMods 应传"实际用于字符翻译的修饰键"
    /// （来自 ghostty_surface_key_translation_mods），没有则退回原始 modifierFlags。
    func ghosttyKeyEvent(
        _ action: ghostty_input_action_e,
        translationMods: NSEvent.ModifierFlags? = nil
    ) -> ghostty_input_key_s {
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        keyEvent.keycode = UInt32(keyCode)
        keyEvent.text = nil
        keyEvent.composing = false
        keyEvent.mods = GhosttyInput.ghosttyMods(modifierFlags)

        // macOS 没有直接接口告诉我们"出字消费了哪些修饰键"。沿用 Ghostty 多年验证的
        // 启发式：control / command 永不参与文字翻译，其余都算被消费。缺这个字段时
        // libghostty 的 KeyEncoder 会算错转义序列（Option-as-Alt 等组合首当其冲）。
        keyEvent.consumed_mods = GhosttyInput.ghosttyMods(
            (translationMods ?? modifierFlags).subtracting([.control, .command]))

        // 无修饰码点：必须用 characters(byApplyingModifiers: []) 而非
        // charactersIgnoringModifiers —— 后者在按住 Ctrl 时行为会变（Ghostty 注释专门点名）。
        keyEvent.unshifted_codepoint = 0
        if type == .keyDown || type == .keyUp,
           let chars = characters(byApplyingModifiers: []),
           let scalar = chars.unicodeScalars.first {
            keyEvent.unshifted_codepoint = scalar.value
        }

        return keyEvent
    }

    /// 要作为 text 发给 ghostty 的字符串：剔除控制字符（ghostty 的 KeyEncoder 自己编码，
    /// 否则 ctrl+enter 之类会出错）与功能键 PUA（0xF700–0xF8FF）。
    var ghosttyCharacters: String? {
        guard let characters else { return nil }

        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            // 单个控制字符：返回去掉 control 后的字符，控制编码交给 ghostty。
            if scalar.value < 0x20 {
                return self.characters(byApplyingModifiers: modifierFlags.subtracting(.control))
            }
            // PUA 区单字符是功能键（方向键等），不下发。
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF { return nil }
        }

        return characters
    }
}
