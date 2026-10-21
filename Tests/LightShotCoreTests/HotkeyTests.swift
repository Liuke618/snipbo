import Testing
@testable import LightShotCore

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
}
