@testable import ConductorApp
import ConductorCore
import XCTest

final class GhosttyConfigCatalogTests: XCTestCase {
    func testCatalogGroupsExposeHighValueGhosttyKeys() {
        let keys = Set(ConductorGhosttyConfigCatalog.productGroups.flatMap(\.keys))

        XCTAssertTrue(keys.contains("font-size"))
        XCTAssertTrue(keys.contains("cursor-style"))
        XCTAssertTrue(keys.contains("background-opacity"))
        XCTAssertTrue(keys.contains("copy-on-select"))
        XCTAssertTrue(keys.contains("clipboard-paste-protection"))
        XCTAssertTrue(keys.contains("scrollback-limit"))
    }

    func testCatalogMapsKeysToSemanticControls() {
        if case .fontFamily = ConductorGhosttyConfigCatalog.controlKind(for: "font-family") {} else {
            XCTFail("font-family should use a font picker")
        }
        if case .integer = ConductorGhosttyConfigCatalog.controlKind(for: "font-size") {} else {
            XCTFail("font-size should use numeric controls")
        }
        if case .percent = ConductorGhosttyConfigCatalog.controlKind(for: "background-opacity") {} else {
            XCTFail("background-opacity should use a percentage slider")
        }
        if case .color = ConductorGhosttyConfigCatalog.controlKind(for: "cursor-color") {} else {
            XCTFail("cursor-color should use a color picker")
        }
        if case .filePath = ConductorGhosttyConfigCatalog.controlKind(for: "background-image") {} else {
            XCTFail("background-image should use a file picker")
        }
        if case .choice = ConductorGhosttyConfigCatalog.controlKind(for: "cursor-style") {} else {
            XCTFail("cursor-style should use a choice control")
        }
        if case .boolean = ConductorGhosttyConfigCatalog.controlKind(for: "copy-on-select") {} else {
            XCTFail("copy-on-select should use a boolean control")
        }
        if case .text = ConductorGhosttyConfigCatalog.controlKind(for: "key-remap") {} else {
            XCTFail("key-remap should stay a free-text control")
        }
    }

    func testBackgroundImageFitUsesGhosttyAcceptedValues() {
        guard case let .choice(options) = ConductorGhosttyConfigCatalog.controlKind(for: "background-image-fit") else {
            return XCTFail("background-image-fit should use a choice control")
        }

        XCTAssertEqual(Set(options.map(\.value)), ["contain", "cover", "stretch", "none"])
    }

    func testAllCatalogKeysHaveLocalizedUserFacingCopy() {
        for key in ConductorGhosttyConfigCatalog.productGroups.flatMap(\.keys) {
            let copy = ConductorGhosttyConfigCatalog.copy(for: key)

            XCTAssertFalse(copy.title.isEmpty, "\(key) should have a localized title")
            XCTAssertFalse(copy.summary.isEmpty, "\(key) should have a localized summary")
            XCTAssertFalse(copy.title.contains("-"), "\(key) title should not expose the raw Ghostty key")
            XCTAssertNotEqual(copy.title, key, "\(key) title should not equal the raw Ghostty key")
        }
    }

    @MainActor
    func testGhosttyConfigTextAppliesOverrides() {
        var config = AppConfig.default
        config.ghosttyOverrides = [
            "cursor-style": "block",
            "background-opacity": "0.88",
            "copy-on-select": "true"
        ]

        let text = GhosttyRuntime.ghosttyConfigText(from: config)

        XCTAssertTrue(text.contains("cursor-style = block"))
        XCTAssertTrue(text.contains("background-opacity = 0.88"))
        XCTAssertTrue(text.contains("copy-on-select = true"))
        XCTAssertFalse(text.contains("cursor-style = bar"))
    }

    /// 没装 Ghostty.app 的机器上 xterm-ghostty terminfo 缺失会导致全灰无色，
    /// 必须默认 xterm-256color（用户可用 overrides 改回）。
    @MainActor
    func testGhosttyConfigTextDefaultsToPortableTerm() {
        let text = GhosttyRuntime.ghosttyConfigText(from: .default)
        XCTAssertTrue(text.contains("term = xterm-256color"))
    }

    @MainActor
    func testGhosttyConfigTextIncludesAnsiPalette() {
        let text = GhosttyRuntime.ghosttyConfigText(from: .default)
        let paletteLines = text
            .split(separator: "\n")
            .filter { $0.hasPrefix("palette = ") }

        XCTAssertEqual(paletteLines.count, 16)
        XCTAssertTrue(text.contains("palette = 1=#ff6b6b"))
        XCTAssertTrue(text.contains("palette = 4=#8aa9ff"))
    }

    @MainActor
    func testGhosttyConfigTextUsesLightAnsiPalette() {
        var config = AppConfig.default
        config.appearance.theme = "light"

        let text = GhosttyRuntime.ghosttyConfigText(from: config)

        XCTAssertTrue(text.contains("foreground = 26272c"))
        XCTAssertTrue(text.contains("palette = 1=#d1242f"))
        XCTAssertTrue(text.contains("palette = 4=#0969da"))
    }

    @MainActor
    func testGhosttyConfigTextUsesCustomAnsiPaletteWhenProvided() {
        var config = AppConfig.default
        config.appearance.theme = "custom"
        config.appearance.colors = Colors(ansi: [
            "#111111", "#222222", "#333333", "#444444",
            "#555555", "#666666", "#777777", "#888888",
            "#999999", "#aaaaaa", "#bbbbbb", "#cccccc",
            "#dddddd", "#eeeeee", "#f0f0f0", "#fafafa",
        ])

        let text = GhosttyRuntime.ghosttyConfigText(from: config)

        XCTAssertTrue(text.contains("palette = 0=#111111"))
        XCTAssertTrue(text.contains("palette = 15=#fafafa"))
    }

    @MainActor
    func testGhosttyConfigTextAppliesBackgroundImageOverrides() {
        var config = AppConfig.default
        config.ghosttyOverrides = [
            "background-image": "/Users/example/Pictures/wallpaper.png",
            "background-image-opacity": "1.00",
            "background-image-fit": "none"
        ]

        let text = GhosttyRuntime.ghosttyConfigText(from: config)

        XCTAssertTrue(text.contains("background-image = /Users/example/Pictures/wallpaper.png"))
        XCTAssertTrue(text.contains("background-image-opacity = 1.00"))
        XCTAssertTrue(text.contains("background-image-fit = none"))
    }
}
