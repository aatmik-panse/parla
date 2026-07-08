import Foundation

/// Diff engine for live streaming dictation: turns "what's already typed" plus
/// "the latest transcript" into the keystrokes that reconcile them — a run of
/// backspaces to erase the diverging tail, then the text to append.
public enum LiveTyper {
    /// Longest common prefix by grapheme cluster (a backspace deletes one
    /// grapheme in AppKit text views, and one emoji/combining sequence is one
    /// grapheme). `erase` = graphemes in typed's remainder; `append` = new's
    /// remainder.
    public static func diff(typed: String, new: String) -> (erase: Int, append: String) {
        let t = Array(typed)
        let n = Array(new)
        var i = 0
        while i < t.count, i < n.count, t[i] == n[i] { i += 1 }
        return (erase: t.count - i, append: String(n[i...]))
    }

    /// Plan the raw→cleaned swap after an instant finalize: `eraseTail` is the
    /// suffix of `raw` to verify and erase (never empty, so select-back
    /// verification of an AX-opaque field has something to check), `replacement`
    /// is what to type in its place. nil ⇒ equal after trimming, no keystrokes.
    public static func swapPlan(raw: String, cleaned: String) -> (eraseTail: String, replacement: String)? {
        let ws = CharacterSet.whitespacesAndNewlines
        let c = cleaned.trimmingCharacters(in: ws)
        // Empty cleaned (e.g. sanitizer ate a quotes-only response) must never
        // become "erase everything, type nothing" — keep the raw text.
        guard !c.isEmpty, raw.trimmingCharacters(in: ws) != c else { return nil }
        let d = diff(typed: raw, new: cleaned)
        let erase = Swift.max(d.erase, 1) // extend a pure append so the verified tail is non-empty
        let tail = String(raw.suffix(erase))
        return (eraseTail: tail, replacement: String(tail.dropLast(d.erase)) + d.append)
    }
}
