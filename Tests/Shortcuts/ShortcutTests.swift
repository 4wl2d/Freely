import AppKit
import Foundation
import Testing
@testable import Freely

struct ShortcutTests {
    @Test func everyRequiredActionHasDistinctValidDefault() {
        let defaults = ShortcutBinding.defaults
        #expect(defaults.count == 10)
        #expect(Set(defaults.map(\.action)) == Set(HotkeyAction.allCases))
        #expect(Set(defaults.compactMap(\.chord)).count == 10)
        #expect(defaults.allSatisfy { $0.chord?.isValid == true })
        #expect(HotkeyController.validate(defaults).values.allSatisfy { $0 == .registered })
    }

    @Test func duplicateActionsAndChordsAreConflictsWithoutBlindRegistration() {
        let chord = ShortcutChord(key: .k, modifiers: [.command, .control])
        let duplicateChord = HotkeyController.validate([.init(action: .answerNow, chord: chord), .init(action: .clearAnswer, chord: chord)])
        #expect(duplicateChord[.answerNow] == .duplicate)
        #expect(duplicateChord[.clearAnswer] == .duplicate)
        let duplicateAction = HotkeyController.validate([.init(action: .answerNow, chord: chord), .init(action: .answerNow, chord: nil)])
        #expect(duplicateAction[.answerNow] == .duplicate)
        #expect(duplicateAction[.toggleOverlay] == .disabled)
    }

    @Test func modifierOnlyAndUnsupportedKeysAreRejected() {
        #expect(!ShortcutChord(key: .a, modifiers: [.option, .shift]).isValid)
        #expect(!ShortcutChord(keyCode: 55, modifiers: .command).isValid)
        #expect(!ShortcutChord(keyCode: 128, modifiers: .control).isValid)
        #expect(!ShortcutChord(key: .a, modifiers: .init(rawValue: 255)).isValid)
        #expect(ShortcutChord(key: .f12, modifiers: [.control, .option, .command]).isValid)
        #expect(ShortcutChord(key: .one, modifiers: [.control, .option, .command]).label == "⌃⌥⌘1")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["FREELY_HOTKEY_TEST"] == "1"))
    @MainActor func nativeRegistrationConflictReconfigureAndCleanup() {
        _ = NSApplication.shared
        let first = HotkeyController { _ in }
        let second = HotkeyController { _ in }
        let chord = ShortcutChord(key: .f12, modifiers: [.control, .option, .command, .shift])
        let binding = ShortcutBinding(action: .answerNow, chord: chord)
        #expect(first.configure([binding])[.answerNow] == .registered)
        if case .failed = second.configure([binding])[.answerNow] { } else { Issue.record("Exclusive native registration should report conflict") }
        first.unregisterAll()
        #expect(second.configure([binding])[.answerNow] == .registered)
        #expect(second.configure([.init(action: .answerNow, chord: nil)])[.answerNow] == .disabled)
        #expect(first.configure([binding])[.answerNow] == .registered)
        first.unregisterAll(); first.unregisterAll(); second.unregisterAll()
    }
}
