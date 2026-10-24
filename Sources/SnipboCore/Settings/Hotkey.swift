import Foundation

public struct HotkeyModifiers: OptionSet, Codable, Equatable, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let command = HotkeyModifiers(rawValue: 1 << 8)
    public static let shift = HotkeyModifiers(rawValue: 1 << 9)
    public static let option = HotkeyModifiers(rawValue: 1 << 11)
    public static let control = HotkeyModifiers(rawValue: 1 << 12)
}

public struct Hotkey: Codable, Equatable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: HotkeyModifiers

    public init(keyCode: UInt32, modifiers: HotkeyModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public var displayString: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result + Self.keyName(for: keyCode)
    }

    private static let keyNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
        44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space", 50: "`",
    ]

    /// Single-character glyph suitable for `NSMenuItem.keyEquivalent`, or nil
    /// when the key has no one-character representation.
    public static func keyGlyph(for keyCode: UInt32) -> String? {
        guard let name = keyNames[keyCode], name.count == 1 else { return nil }
        return name.lowercased()
    }

    private static func keyName(for keyCode: UInt32) -> String {
        keyNames[keyCode] ?? "Key\(keyCode)"
    }
}

/// The non-global shortcut for opening Settings while Snipbo is frontmost.
/// Kept out of the Carbon hotkey table so it cannot steal ⌘, from other apps.
public enum SettingsShortcut {
    public static let hotkey = Hotkey(keyCode: 43, modifiers: [.command])

    public static func matches(keyCode: UInt32, modifiers: HotkeyModifiers) -> Bool {
        Hotkey(keyCode: keyCode, modifiers: modifiers) == hotkey
    }
}

/// The standard quit chord, also handled locally: the app is an accessory
/// with no main menu, so ⌘Q would otherwise do nothing in its windows.
public enum QuitShortcut {
    public static let hotkey = Hotkey(keyCode: 12, modifiers: [.command])

    public static func matches(keyCode: UInt32, modifiers: HotkeyModifiers) -> Bool {
        Hotkey(keyCode: keyCode, modifiers: modifiers) == hotkey
    }
}
