import Cocoa
import CoreGraphics

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

// Dictate = Left Shift while Control is required: effective Control+Shift.
let dictate = HotkeySpec(
    keyCode: 56, modifiers: [.maskControl], label: "⌃⇧")
let snap = HotkeySpec(
    keyCode: 18, modifiers: [.maskControl, .maskShift], label: "⌃⇧1")
let unrelated = HotkeySpec(
    keyCode: 18, modifiers: [.maskControl, .maskAlternate], label: "⌃⌥1")
let modifierDescendant = HotkeySpec(
    keyCode: 58, modifiers: [.maskControl, .maskShift], label: "⌃⇧⌥")
let duplicatePhysicalSide = HotkeySpec(
    keyCode: 60, modifiers: [.maskControl], label: "⌃⇧")

expect(HotkeyPrecedence.descendant(snap, supersedes: dictate),
       "Control+Shift+1 must supersede modifier-only Control+Shift")
expect(!HotkeyPrecedence.descendant(unrelated, supersedes: dictate),
       "a chord missing Shift must not supersede Control+Shift")
expect(HotkeyPrecedence.descendant(modifierDescendant, supersedes: dictate),
       "an additional modifier must be treated as a longer chord")
expect(!HotkeyPrecedence.descendant(duplicatePhysicalSide, supersedes: dictate),
       "an equivalent modifier-only binding is a conflict, not a descendant")
expect(!HotkeyPrecedence.descendant(dictate, supersedes: snap),
       "a regular-key binding cannot be a modifier-only ancestor")

print("hotkey precedence tests passed")
