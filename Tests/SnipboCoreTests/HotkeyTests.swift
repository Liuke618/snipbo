import Foundation
import Testing
@testable import SnipboCore

@Suite("HotkeyTests")
struct HotkeyTests {
    @Test func testDefaultDisplayString() {
        let hotkey = Hotkey(keyCode: 26, modifiers: [.command, .shift])
        #expect(hotkey.displayString == "⇧⌘7")
    }

    @Test func testModifierOrder() {
        let hotkey = Hotkey(keyCode: 1, modifiers: [.command, .shift, .option, .control])
        #expect(hotkey.displayString == "⌃⌥⇧⌘S")
    }

    @Test func testUnknownKeyFallsBackToCode() {
        let hotkey = Hotkey(keyCode: 200, modifiers: [])
        #expect(hotkey.displayString == "Key200")
    }

    @Test func testKeyGlyphMapsCommonKeys() {
        // Single-character glyphs are what NSMenuItem.keyEquivalent needs.
        #expect(Hotkey.keyGlyph(for: 26) == "7")
        #expect(Hotkey.keyGlyph(for: 0) == "a")
        #expect(Hotkey.keyGlyph(for: 27) == "-")
        // Keys without a one-character representation yield nil.
        #expect(Hotkey.keyGlyph(for: 49) == nil)   // "Space"
        #expect(Hotkey.keyGlyph(for: 999) == nil)
    }

    @Test func testSettingsShortcutIsCommandCommaOnly() {
        #expect(SettingsShortcut.matches(keyCode: 43, modifiers: [.command]))
        #expect(!SettingsShortcut.matches(keyCode: 43, modifiers: [.command, .shift]))
        #expect(!SettingsShortcut.matches(keyCode: 43, modifiers: []))
        #expect(!SettingsShortcut.matches(keyCode: 44, modifiers: [.command]))
    }

    @Test func testQuitShortcutIsCommandQOnly() {
        #expect(QuitShortcut.matches(keyCode: 12, modifiers: [.command]))
        #expect(!QuitShortcut.matches(keyCode: 12, modifiers: [.command, .shift]))
        #expect(!QuitShortcut.matches(keyCode: 12, modifiers: []))
        #expect(!QuitShortcut.matches(keyCode: 13, modifiers: [.command]))
    }

    @Test func testCloseWindowShortcutIsCommandWOnly() {
        #expect(CloseWindowShortcut.matches(keyCode: 13, modifiers: [.command]))
        #expect(!CloseWindowShortcut.matches(keyCode: 13, modifiers: [.command, .shift]))
        #expect(!CloseWindowShortcut.matches(keyCode: 13, modifiers: [.command, .option]))
        #expect(!CloseWindowShortcut.matches(keyCode: 13, modifiers: []))
        #expect(!CloseWindowShortcut.matches(keyCode: 12, modifiers: [.command]))
    }

    @Test func testGlobalShortcutRequiresCommandOptionOrControl() {
        #expect(Hotkey(keyCode: 0, modifiers: [.command]).isGlobalShortcut)
        #expect(Hotkey(keyCode: 0, modifiers: [.option]).isGlobalShortcut)
        #expect(Hotkey(keyCode: 0, modifiers: [.control]).isGlobalShortcut)
        #expect(!Hotkey(keyCode: 0, modifiers: [.shift]).isGlobalShortcut)
        #expect(!Hotkey(keyCode: 0, modifiers: []).isGlobalShortcut)
    }

    @Test func testNormalizationDropsShiftOnlyModeHotkeys() {
        var settings = AppSettings.default
        settings.modeHotkeys["window"] = Hotkey(keyCode: 13, modifiers: [.shift])
        settings.modeHotkeys["screen"] = Hotkey(keyCode: 12, modifiers: [.command])
        let normalized = settings.normalized()
        #expect(normalized.modeHotkeys["window"] == nil)
        #expect(normalized.modeHotkeys["screen"] == Hotkey(keyCode: 12, modifiers: [.command]))
    }

    @Test func testNormalizationReplacesInvalidBaseHotkey() {
        var settings = AppSettings.default
        settings.hotkey = Hotkey(keyCode: 0, modifiers: [.shift])
        #expect(settings.normalized().hotkey == AppSettings.default.hotkey)
    }

    @Test func testModeHotkeysFallbackToRegionHotkey() {
        var settings = AppSettings.default
        let region = settings.hotkey
        #expect(settings.hotkey(for: "region") == region)
        #expect(settings.hotkey(for: "window") == nil)
        settings.modeHotkeys["window"] = Hotkey(keyCode: 13, modifiers: [.command, .shift])
        #expect(settings.hotkey(for: "window") != region)
        #expect(settings.hotkey(for: "scrolling") == nil)
    }

    @Test func testModeHotkeysRoundTripAndLegacyDecode() throws {
        var settings = AppSettings.default
        settings.modeHotkeys["window"] = Hotkey(keyCode: 13, modifiers: [.command, .shift])
        settings.modeHotkeys["scrolling"] = Hotkey(keyCode: 15, modifiers: [.command, .shift])
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.hotkey(for: "window") == settings.hotkey(for: "window"))
        #expect(decoded.hotkey(for: "scrolling") == settings.hotkey(for: "scrolling"))

        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object.removeValue(forKey: "modeHotkeys")
        let legacy = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(legacy.modeHotkeys.isEmpty)
        #expect(legacy.hotkey(for: "region") == legacy.hotkey)
    }

    @Test func testModeHotkeyNormalizationDropsUnknownModesAndDuplicateChords() {
        var settings = AppSettings.default
        let regionChord = settings.hotkey
        settings.modeHotkeys = [
            "region": Hotkey(keyCode: 7, modifiers: [.command, .shift]),
            "bogus": Hotkey(keyCode: 12, modifiers: []),
            // Same chord as region: duplicate, dropped.
            "window": Hotkey(keyCode: 7, modifiers: [.command, .shift]),
            "screen": Hotkey(keyCode: 12, modifiers: [.command]),
        ]
        let normalized = settings.normalized()
        #expect(normalized.modeHotkeys["region"]?.keyCode == 7)
        #expect(normalized.modeHotkeys["screen"]?.keyCode == 12)
        #expect(normalized.modeHotkeys["window"] == nil)
        #expect(normalized.modeHotkeys["bogus"] == nil)
        // The fallback chord still resolves for modes without an entry.
        #expect(normalized.hotkey(for: "region")?.keyCode == 7)
        #expect(regionChord.keyCode == 26)
    }
}
