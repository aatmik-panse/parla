import AppKit

public enum Inserter {
    /// Stamped on every CGEvent Parla posts (eventSourceUserData), so the hotkey
    /// keyDown monitor can tell our own synthetic keystrokes from a real user
    /// keypress and not self-cancel a live-streaming dictation. Arbitrary magic.
    public static let syntheticMarker: Int64 = 0x50_41_52_4C_41 // "PARLA"

    /// Post an event after tagging it as ours. All Parla keystrokes go through here.
    static func post(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        event.post(tap: .cghidEventTap)
    }

    /// Clipboard + synthetic ⌘V. The text intentionally STAYS in the clipboard —
    /// that is the escape hatch when an app rejects the paste.
    /// ponytail: no clipboard save/restore (racy per architecture.md); add only if users complain.
    public static func insert(_ text: String) {
        copy(text)
        // Give the pasteboard a beat before the keystroke lands.
        usleep(50_000)
        postCmdV()
    }

    /// Put text on the clipboard without pasting — the no-focus finalize path.
    public static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    static func postCmdV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        post(down)
        post(up)
    }

    /// Split UTF-16 units into chunks of at most `max`, never ending a chunk on an
    /// unpaired high surrogate (which would corrupt emoji/supplementary characters).
    static func chunkUTF16(_ units: [UInt16], max: Int = 20) -> [[UInt16]] {
        var chunks: [[UInt16]] = []
        var i = 0
        while i < units.count {
            var end = Swift.min(i + max, units.count)
            if end < units.count, (0xD800...0xDBFF).contains(units[end - 1]) {
                end -= 1 // keep the surrogate pair together in the next chunk
            }
            chunks.append(Array(units[i ..< end]))
            i = end
        }
        return chunks
    }

    /// Fallback: type the text as Unicode keystrokes (layout-independent).
    /// Chunked because CGEventKeyboardSetUnicodeString caps around 20 UTF-16 units.
    public static func typeUnicode(_ text: String) {
        let src = CGEventSource(stateID: .combinedSessionState)
        for chunk in chunkUTF16(Array(text.utf16)) {
            if let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
               let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                post(down)
                post(up)
            }
            usleep(5_000)
        }
    }

    /// Post `n` Delete (backspace) keystrokes — used by live streaming to erase a
    /// diverging tail before retyping. Same event-posting style as typeUnicode.
    public static func typeBackspaces(_ n: Int) {
        guard n > 0 else { return }
        let src = CGEventSource(stateID: .combinedSessionState)
        let delKey: CGKeyCode = 51 // kVK_Delete
        for _ in 0..<n {
            if let down = CGEvent(keyboardEventSource: src, virtualKey: delKey, keyDown: true),
               let up = CGEvent(keyboardEventSource: src, virtualKey: delKey, keyDown: false) {
                post(down)
                post(up)
            }
            usleep(5_000)
        }
    }

    /// What Parla can do with the current keyboard focus.
    public enum FocusTarget {
        case editable   // confirmed text field: safe to live-type into
        case unknown    // something is focused but AX can't confirm it's a field: paste, don't stream
        case none       // no focused element at all: clipboard only
        case secure     // password field (AXSecureTextField): on-device only, clipboard, never cloud
    }

    /// Best-effort focus classification. Chromium/Electron apps (Chrome, VS Code,
    /// Slack…) expose no AX tree until an assistive client flips their
    /// accessibility flags, so on a non-editable answer we flip them and retry
    /// once. First dictation in such an app may still classify as .unknown
    /// (paste fallback); subsequent ones see the real field.
    public static func focusTarget() -> FocusTarget {
        var result = classifyFocus()
        // Never wake Electron's AX tree for a secure field — the whole point is
        // to touch it as little as possible (never stream, never paste, never cloud).
        if result != .editable, result != .secure, let app = NSWorkspace.shared.frontmostApplication {
            let appEl = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            usleep(50_000) // give the app a beat to build its AX tree
            result = classifyFocus()
        }
        return result
    }

    /// Focused element via the system-wide query, falling back to asking the
    /// frontmost app directly — Electron/Chromium apps often answer only the
    /// app-level query.
    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
           let focused { return (focused as! AXUIElement) }
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        if AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
           let focused { return (focused as! AXUIElement) }
        return nil
    }

    private static func classifyFocus() -> FocusTarget {
        guard let element = focusedElement() else { return .none }
        var roleRef: CFTypeRef?
        let role = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success
            ? roleRef as? String : nil
        // Password field: bail BEFORE any editable heuristic — a secure field is
        // also settable/selectable, so it would otherwise classify as .editable.
        if role == "AXSecureTextField" { return .secure }
        if let role, ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"].contains(role) {
            return .editable
        }
        // A settable value or a selectable text range both mean editable text.
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return .editable
        }
        var sel: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &sel) == .success {
            return .editable
        }
        return .unknown
    }

    /// The focused field's full text and cursor position (UTF-16 offset), when
    /// AX exposes both. nil means "can't see inside the field".
    static func focusedFieldState() -> (text: NSString, cursor: Int)? {
        guard let element = focusedElement() else { return nil }
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let text = valueRef as? String else { return nil }
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range) else { return nil }
        return (text as NSString, range.location)
    }

    /// True when the characters immediately before the cursor are exactly
    /// `typed` — i.e. erasing that many keystrokes removes only our own text.
    /// False when the field is opaque to AX (can't verify ⇒ don't erase).
    public static func canEraseTyped(_ typed: String) -> Bool {
        guard !typed.isEmpty else { return true }
        guard let (text, cursor) = focusedFieldState() else { return false }
        let len = (typed as NSString).length
        guard cursor >= len, cursor <= text.length else { return false }
        return text.substring(with: NSRange(location: cursor - len, length: len)) == typed
    }

    /// True when final replacement can be verified via AX. Fields that merely
    /// look editable but hide text/cursor state should get one final paste, not
    /// live streaming that later falls back to clipboard.
    public static func canVerifyFocusedField() -> Bool {
        focusedFieldState() != nil
    }

    static func postKey(_ key: CGKeyCode, flags: CGEventFlags = []) {
        let src = CGEventSource(stateID: .combinedSessionState)
        if let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true),
           let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false) {
            down.flags = flags
            up.flags = flags
            post(down)
            post(up)
        }
    }

    /// Verification for fields AX can't read: select the last `expected.count`
    /// graphemes with ⇧← and copy them. Match ⇒ returns true with the selection
    /// LEFT ACTIVE, so the very next typed/pasted text atomically replaces
    /// exactly those characters and nothing else. Mismatch (or a field where
    /// selection/copy doesn't work) ⇒ collapses the selection back to the end
    /// and returns false. Clobbers the clipboard by design — Parla already
    /// leaves dictated text there.
    public static func selectBackAndVerify(_ expected: String) -> Bool {
        guard !expected.isEmpty else { return true }
        for _ in 0..<expected.count {
            postKey(123, flags: .maskShift) // ⇧←
            usleep(10_000)
        }
        usleep(80_000)
        let pb = NSPasteboard.general
        var marker = "__PARLA_COPY_PROBE__\(UUID().uuidString)"
        while marker == expected {
            marker = "__PARLA_COPY_PROBE__\(UUID().uuidString)"
        }
        pb.clearContents()
        pb.setString(marker, forType: .string)
        postKey(8, flags: .maskCommand) // ⌘C
        var waited = 0
        while pb.string(forType: .string) == marker, waited < 600_000 {
            usleep(20_000)
            waited += 20_000
        }
        let copied = pb.string(forType: .string)
        if copied == expected {
            return true
        }
        NSLog("Parla select verify failed: %@ expected=%d copied=%d",
              copied == marker ? "copy-timeout" : "mismatch",
              expected.count,
              copied?.count ?? -1)
        postKey(124) // → collapse selection, cursor back to the end
        return false
    }
}
