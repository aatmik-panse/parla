import AppKit

public enum Inserter {
    /// Clipboard + synthetic ⌘V. The text intentionally STAYS in the clipboard —
    /// that is the escape hatch when an app rejects the paste.
    /// ponytail: no clipboard save/restore (racy per architecture.md); add only if users complain.
    public static func insert(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        // Give the pasteboard a beat before the keystroke lands.
        usleep(50_000)
        postCmdV()
    }

    static func postCmdV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Fallback: type the text as Unicode keystrokes (layout-independent).
    /// Chunked because CGEventKeyboardSetUnicodeString caps around 20 UTF-16 units.
    public static func typeUnicode(_ text: String) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            let chunk = Array(units[i ..< min(i + 20, units.count)])
            if let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
               let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            }
            i += 20
            usleep(5_000)
        }
    }
}
