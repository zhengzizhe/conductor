@testable import ConductorApp
import GhosttyKit
import XCTest

@MainActor
final class GhosttyInputTests: XCTestCase {
    private func keyDownEvent(
        characters: String,
        flags: NSEvent.ModifierFlags,
        keyCode: UInt16 = 0
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode)!
    }

    private func contains(_ mods: ghostty_input_mods_e, _ flag: ghostty_input_mods_e) -> Bool {
        mods.rawValue & flag.rawValue != 0
    }

    // MARK: - mods 转换

    func testGhosttyModsMapsEachBasicFlag() {
        XCTAssertTrue(contains(GhosttyInput.ghosttyMods(.shift), GHOSTTY_MODS_SHIFT))
        XCTAssertTrue(contains(GhosttyInput.ghosttyMods(.control), GHOSTTY_MODS_CTRL))
        XCTAssertTrue(contains(GhosttyInput.ghosttyMods(.option), GHOSTTY_MODS_ALT))
        XCTAssertTrue(contains(GhosttyInput.ghosttyMods(.command), GHOSTTY_MODS_SUPER))
        XCTAssertTrue(contains(GhosttyInput.ghosttyMods(.capsLock), GHOSTTY_MODS_CAPS))
    }

    func testGhosttyModsEmptyIsNone() {
        XCTAssertEqual(GhosttyInput.ghosttyMods([]).rawValue, GHOSTTY_MODS_NONE.rawValue)
    }

    func testEventModifierFlagsRoundTripsBasicFlags() {
        let flags: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
        let back = GhosttyInput.eventModifierFlags(GhosttyInput.ghosttyMods(flags))
        XCTAssertEqual(back, flags)
    }

    // MARK: - ghosttyKeyEvent

    func testConsumedModsExcludeControlAndCommand() {
        let event = keyDownEvent(characters: "a", flags: [.shift, .control, .option, .command])
        let key = event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)

        // mods 保留全部修饰键……
        XCTAssertTrue(contains(key.mods, GHOSTTY_MODS_SHIFT))
        XCTAssertTrue(contains(key.mods, GHOSTTY_MODS_CTRL))
        XCTAssertTrue(contains(key.mods, GHOSTTY_MODS_ALT))
        XCTAssertTrue(contains(key.mods, GHOSTTY_MODS_SUPER))

        // ……但 consumed_mods（参与出字的修饰键）剔除 control / command。
        XCTAssertTrue(contains(key.consumed_mods, GHOSTTY_MODS_SHIFT))
        XCTAssertTrue(contains(key.consumed_mods, GHOSTTY_MODS_ALT))
        XCTAssertFalse(contains(key.consumed_mods, GHOSTTY_MODS_CTRL))
        XCTAssertFalse(contains(key.consumed_mods, GHOSTTY_MODS_SUPER))
    }

    func testTranslationModsOverrideConsumedMods() {
        // 出字事件去掉了 option（如 Option-as-Alt）：consumed_mods 应据 translationMods 算，不含 ALT。
        let event = keyDownEvent(characters: "a", flags: [.shift, .option])
        let key = event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS, translationMods: [.shift])
        XCTAssertTrue(contains(key.consumed_mods, GHOSTTY_MODS_SHIFT))
        XCTAssertFalse(contains(key.consumed_mods, GHOSTTY_MODS_ALT))
    }

    func testKeyEventCarriesAction() {
        let event = keyDownEvent(characters: "a", flags: [])
        XCTAssertEqual(event.ghosttyKeyEvent(GHOSTTY_ACTION_RELEASE).action, GHOSTTY_ACTION_RELEASE)
    }

    // MARK: - ghosttyCharacters

    func testGhosttyCharactersPassesThroughPrintable() {
        XCTAssertEqual(keyDownEvent(characters: "a", flags: []).ghosttyCharacters, "a")
    }

    func testGhosttyCharactersDropsFunctionKeyPUA() {
        // 0xF700 (上方向键) 落在功能键 PUA 区，不应作为文本下发。
        XCTAssertNil(keyDownEvent(characters: "\u{F700}", flags: []).ghosttyCharacters)
    }
}
