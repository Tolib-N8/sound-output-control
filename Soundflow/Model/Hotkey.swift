import Carbon.HIToolbox
import Foundation

/// A global keyboard shortcut (virtual key code + modifiers).
struct Hotkey: Codable, Hashable, Sendable {
    struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        let rawValue: Int
        static let control = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let shift = Modifiers(rawValue: 1 << 2)
        static let command = Modifiers(rawValue: 1 << 3)

        var carbon: UInt32 {
            var flags: UInt32 = 0
            if contains(.control) { flags |= UInt32(controlKey) }
            if contains(.option) { flags |= UInt32(optionKey) }
            if contains(.shift) { flags |= UInt32(shiftKey) }
            if contains(.command) { flags |= UInt32(cmdKey) }
            return flags
        }

        /// Symbols in the macOS canonical order: ⌃ ⌥ ⇧ ⌘.
        var symbols: [String] {
            var result: [String] = []
            if contains(.control) { result.append("⌃") }
            if contains(.option) { result.append("⌥") }
            if contains(.shift) { result.append("⇧") }
            if contains(.command) { result.append("⌘") }
            return result
        }
    }

    struct Key: Codable, Hashable, Sendable {
        let code: UInt16

        static let s = Key(code: UInt16(kVK_ANSI_S))
        static let m = Key(code: UInt16(kVK_ANSI_M))
        static let o = Key(code: UInt16(kVK_ANSI_O))
        static let one = Key(code: UInt16(kVK_ANSI_1))
        static let two = Key(code: UInt16(kVK_ANSI_2))
        static let three = Key(code: UInt16(kVK_ANSI_3))
        static let four = Key(code: UInt16(kVK_ANSI_4))
        static let up = Key(code: UInt16(kVK_UpArrow))
        static let down = Key(code: UInt16(kVK_DownArrow))
        static let left = Key(code: UInt16(kVK_LeftArrow))
        static let right = Key(code: UInt16(kVK_RightArrow))

        var label: String {
            if let special = Self.special[Int(code)] { return special }
            if let letter = Self.ansi[Int(code)] { return letter }
            return "#\(code)"
        }

        private static let special: [Int: String] = [
            kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_LeftArrow: "←", kVK_RightArrow: "→",
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋", kVK_Delete: "⌫",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]

        private static let ansi: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
            kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
            kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z", kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
            kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
            kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
        ]
    }

    var key: Key
    var modifiers: Modifiers

    /// Key caps as shown in the UI, e.g. ["⌥", "⌘", "S"].
    var caps: [String] { modifiers.symbols + [key.label] }
    var display: String { caps.joined(separator: " ") }
}
