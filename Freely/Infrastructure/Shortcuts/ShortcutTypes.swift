import Foundation

public enum HotkeyAction: String, CaseIterable, Codable, Sendable, Identifiable {
    case startStopSession, toggleOverlay, answerNow, captureAnalyze, expandCollapse, clearAnswer, pinUnpin
    case pauseResumeMicrophone, pauseResumeSystemAudio, endSession
    case focusQuestion, togglePresentationUI
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .startStopSession: "Start / stop session"
        case .toggleOverlay: "Show / hide Freely"
        case .answerNow: "Answer now"
        case .captureAnalyze: "Capture and analyze"
        case .expandCollapse: "Expand / collapse answer"
        case .clearAnswer: "Clear answer"
        case .pinUnpin: "Freeze / unfreeze answer"
        case .pauseResumeMicrophone: "Pause / resume microphone"
        case .pauseResumeSystemAudio: "Pause / resume system audio"
        case .endSession: "End session"
        case .focusQuestion: "Focus question"
        case .togglePresentationUI: "Show / hide Freely in presentation"
        }
    }
}

public struct ShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let command = Self(rawValue: 1)
    public static let control = Self(rawValue: 2)
    public static let option = Self(rawValue: 4)
    public static let shift = Self(rawValue: 8)
    public static let all: Self = [.command, .control, .option, .shift]
    public var label: String {
        (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "") +
        (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
    }
}

/// Physical macOS virtual key codes; display labels follow the familiar US keyboard positions.
/// Native event recording may supply any supported key code; this list provides a convenient settings picker.
public enum ShortcutKey: UInt32, CaseIterable, Codable, Sendable, Identifiable {
    case a = 0, s = 1, d = 2, f = 3, h = 4, g = 5, z = 6, x = 7, c = 8, v = 9, b = 11
    case q = 12, w = 13, e = 14, r = 15, y = 16, t = 17
    case one = 18, two = 19, three = 20, four = 21, six = 22, five = 23, nine = 25, seven = 26, eight = 28, zero = 29
    case o = 31, u = 32, i = 34, p = 35, `return` = 36, l = 37, j = 38, k = 40, n = 45, m = 46, space = 49, escape = 53
    case f1 = 122, f2 = 120, f3 = 99, f4 = 118, f5 = 96, f6 = 97, f7 = 98, f8 = 100, f9 = 101, f10 = 109, f11 = 103, f12 = 111
    public var id: UInt32 { rawValue }
    public var label: String {
        switch self {
        case .one: "1"; case .two: "2"; case .three: "3"; case .four: "4"; case .five: "5"
        case .six: "6"; case .seven: "7"; case .eight: "8"; case .nine: "9"; case .zero: "0"
        case .return: "Return"; case .space: "Space"; case .escape: "Escape"
        default: String(describing: self).uppercased()
        }
    }
}

public struct ShortcutChord: Codable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: ShortcutModifiers
    public init(keyCode: UInt32, modifiers: ShortcutModifiers) { self.keyCode = keyCode; self.modifiers = modifiers }
    public init(key: ShortcutKey, modifiers: ShortcutModifiers) { self.init(keyCode: key.rawValue, modifiers: modifiers) }
    public var label: String { modifiers.label + (ShortcutKey(rawValue: keyCode)?.label ?? "Key \(keyCode)") }
    public var isValid: Bool {
        keyCode <= 127 && ![54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(keyCode) &&
        modifiers.rawValue & ~ShortcutModifiers.all.rawValue == 0 &&
        !modifiers.intersection([.command, .control]).isEmpty
    }
}

public struct ShortcutBinding: Codable, Equatable, Sendable, Identifiable {
    public var action: HotkeyAction
    public var chord: ShortcutChord?
    public var id: HotkeyAction { action }
    public init(action: HotkeyAction, chord: ShortcutChord?) { self.action = action; self.chord = chord }
    public static var defaults: [Self] {
        let keys: [ShortcutKey] = [.one, .two, .three, .four, .five, .six, .seven, .eight, .nine, .zero]
        var bindings: [Self] = zip(HotkeyAction.allCases, keys).map { action, key in
            .init(action: action, chord: .init(key: key, modifiers: [.command, .control, .option]))
        }
        bindings[1].chord = .init(key: .space, modifiers: [.control, .option])
        bindings.append(.init(action: .focusQuestion, chord: .init(key: .return, modifiers: [.control, .option])))
        bindings.append(.init(action: .togglePresentationUI, chord: nil))
        return bindings
    }
}

public enum HotkeyRegistrationStatus: Equatable, Sendable {
    case registered
    case disabled
    case invalidChord
    case duplicate
    case systemReserved
    case failed(status: Int32)
    public var message: String {
        switch self {
        case .registered: "Registered"
        case .disabled: "Disabled; available from the menu"
        case .invalidChord: "Use a key with Command or Control; available from the menu"
        case .duplicate: "Assigned more than once; choose a different shortcut or use the menu"
        case .systemReserved: "Reserved by macOS; choose a different shortcut or use the menu"
        case .failed(let status): "Could not register this shortcut (\(status)); another app or macOS may reserve it. Use the menu or choose another shortcut."
        }
    }
}
