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
}
