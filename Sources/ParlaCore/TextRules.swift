import Foundation

/// Pure safety rules for what/where dictated text may land. AppKit wiring
/// (focus, frontmost app, insertion) lives in Sources/Parla; this is the
/// decision logic so it stays unit-testable.
public enum TextRules {
    /// Bundle IDs where a bare newline SUBMITS a command — pasting multi-line
    /// text would execute every line. We flatten before inserting into these.
    public static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp",
        "com.github.wez.wezterm", "net.kovidgoyal.kitty", "com.mitchellh.ghostty",
        "org.alacritty", "co.zeit.hyper",
    ]

    public static func isTerminal(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return terminalBundleIDs.contains(bundleID)
    }

    /// Collapse every whitespace run that contains a newline into a single space,
    /// then trim — so nothing typed into a terminal spans lines (each of which
    /// would run as its own command). Whitespace runs without a newline (e.g.
    /// aligned spaces) are left alone.
    public static func flattenForTerminal(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s*\\n\\s*", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whisper hallucinates ("Thank you.", "you") on sub-half-second or silent
    /// buffers. Gate transcription on a floor of duration AND loudness.
    /// Defaults: 6400 samples ≈0.4s @16kHz; RMS 1e-4 is orders of magnitude below
    /// real speech, so this only rejects near-digital-silence.
    // ponytail: fixed thresholds, no VAD — bump if quiet speech gets dropped.
    public static func audioWorthTranscribing(sampleCount: Int, rms: Float,
                                              minSamples: Int = 6400,
                                              minRMS: Float = 1e-4) -> Bool {
        sampleCount >= minSamples && rms >= minRMS
    }
}
