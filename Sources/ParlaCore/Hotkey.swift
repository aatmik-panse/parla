import AppKit

/// Push-to-talk on fn/Globe (keyCode 63).
/// ponytail: NSEvent global monitor instead of a CGEventTap — same Accessibility
/// permission, far less code. Switch to a tap if we ever need to swallow the key
/// (a global monitor can't: the cancelling Esc/arrow still reaches the front app).
public final class HotkeyMonitor {
    /// `.down(command:)` — command is true when shift was held at fn-down: that
    /// dictation is a transform-selection instruction, not plain dictation. The
    /// mode is latched here, so shift may be released while speaking.
    /// `.up(short:)` — short is true when fn was held under `shortTapThreshold`
    /// (an accidental Globe tap for emoji/input-switching, not dictation).
    /// `.cancel` — a real key was pressed while fn was held (fn+arrow, Esc).
    public enum Edge: Equatable { case down(command: Bool), up(short: Bool), cancel }
    public var onEdge: ((Edge) -> Void)?
    /// Taps shorter than this are treated as accidental (see Edge.up).
    public var shortTapThreshold: TimeInterval = 0.2
    private var isDown = false
    private var downAt: TimeInterval = 0
    private var flagsMonitor: Any?
    private var keyMonitor: Any?

    public init() {}

    /// Pure state machine — exercised by tests. `time` is the event timestamp
    /// (injected so tests never sleep).
    public func handle(keyCode: UInt16, fnActive: Bool, shiftActive: Bool = false, at time: TimeInterval) {
        // Shift arrives via flagsChanged with keyCode 56/60 (not 63), so this
        // guard drops it — holding/releasing shift can never double-fire .down or
        // reach .cancel (that's the keyDown monitor, which flagsChanged isn't).
        guard keyCode == 63 else { return }
        if fnActive && !isDown {
            isDown = true
            downAt = time
            onEdge?(.down(command: shiftActive))
        } else if !fnActive && isDown {
            isDown = false
            onEdge?(.up(short: time - downAt < shortTapThreshold))
        }
    }

    /// A non-fn key was pressed while fn is held → cancel the dictation. Clears
    /// the held state so the eventual fn release is a no-op (no trailing `.up`).
    public func otherKeyDown() {
        guard isDown else { return }
        isDown = false
        onEdge?(.cancel)
    }

    public func start() {
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            self?.handle(keyCode: e.keyCode, fnActive: e.modifierFlags.contains(.function),
                         shiftActive: e.modifierFlags.contains(.shift), at: e.timestamp)
        }
        // Any real keypress while dictating cancels. Skip Parla's OWN synthetic
        // keystrokes (typing/erasing while streaming) — they carry our marker in
        // eventSourceUserData; without this check the monitor would self-cancel.
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if let cg = e.cgEvent,
               cg.getIntegerValueField(.eventSourceUserData) == Inserter.syntheticMarker { return }
            self?.otherKeyDown()
        }
    }

    deinit {
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }
}
