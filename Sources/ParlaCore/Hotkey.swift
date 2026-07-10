import AppKit

/// Global dictation hotkeys. fn/Globe (keyCode 63) held is push-to-talk;
/// fn+Space latches hands-free (press again to stop); Esc cancels a dictation
/// or dismisses the HUD toast; ⌃⌘V pastes the last transcript.
///
/// A CGEventTap (same Accessibility permission) replaced the old NSEvent
/// global monitors: fn+Space / Esc / ⌃⌘V must be swallowed, not leak a space
/// or an Esc into the front app. Other cancelling keys still pass through.
public final class HotkeyMonitor {
    public enum Edge: Equatable {
        /// Recording starts. command is true when shift was held at fn-down:
        /// that dictation is a transform-selection instruction, not plain
        /// dictation. The mode is latched here, so shift may be released
        /// while speaking.
        case down(command: Bool)
        /// Recording ends → transcribe. short is true when the session lasted
        /// under `shortTapThreshold` (an accidental Globe tap, not dictation).
        case up(short: Bool)
        /// Dictation aborted: Esc, or any real key while fn was held.
        case cancel
        /// fn+Space latched hands-free: recording continues past fn release.
        case handsFree
        /// ⌃⌘V while idle: paste the last transcript.
        case pasteLast
        /// ⌃⌘S while idle: open the scratchpad.
        case openScratchpad
        /// Esc while idle: dismiss the HUD toast.
        case dismiss
    }
    public var onEdge: ((Edge) -> Void)?
    /// Sessions shorter than this are treated as accidental (see Edge.up).
    public var shortTapThreshold: TimeInterval = 0.2

    private enum Session { case idle, push, handsFree }
    private var session = Session.idle
    private var downAt: TimeInterval = 0
    private var tap: CFMachPort?

    public init() {}

    // MARK: - Pure state machine (exercised by tests; `time` injected so tests never sleep)

    /// flagsChanged: fn press starts push-to-talk, fn release finishes it.
    /// During hands-free, any fn press stops and transcribes — the guaranteed
    /// exit: it can't depend on the Space keyDown carrying the fn flag, and
    /// the fn release after latching must not finish early (session ≠ .push).
    public func handle(keyCode: UInt16, fnActive: Bool, shiftActive: Bool = false, at time: TimeInterval) {
        // Shift arrives via flagsChanged with keyCode 56/60 (not 63), so this
        // guard drops it — holding/releasing shift can never double-fire .down.
        guard keyCode == 63 else { return }
        if fnActive, session == .idle {
            session = .push
            downAt = time
            onEdge?(.down(command: shiftActive))
        } else if fnActive, session == .handsFree {
            session = .idle
            onEdge?(.up(short: time - downAt < shortTapThreshold))
        } else if !fnActive, session == .push {
            session = .idle
            onEdge?(.up(short: time - downAt < shortTapThreshold))
        }
    }

    /// keyDown. Returns true when the event must be swallowed (never reach the
    /// front app). fnActive comes from the key event's own flags.
    public func keyDown(keyCode: UInt16, fnActive: Bool = false, cmd: Bool = false, ctrl: Bool = false,
                        at time: TimeInterval) -> Bool {
        if keyCode == 49, fnActive { // fn+Space: hands-free latch / stop
            switch session {
            case .push: // convert the held push-to-talk: recording survives fn release
                session = .handsFree
                onEdge?(.handsFree)
            case .handsFree: // fn held since the latch, so the fn-down stop above never fired
                session = .idle
                onEdge?(.up(short: time - downAt < shortTapThreshold))
            case .idle: // fn-down just stopped the session — swallow the chord's Space, no restart
                break
            }
            return true
        }
        if keyCode == 53, session != .idle { // Esc: cancel the dictation
            session = .idle
            onEdge?(.cancel)
            return true
        }
        if session == .push { // any other key while fn is held cancels (and passes through)
            session = .idle
            onEdge?(.cancel)
            return false
        }
        if session == .handsFree { return false } // typing while hands-free is fine
        if keyCode == 9, cmd, ctrl { // ⌃⌘V: paste last transcript
            onEdge?(.pasteLast)
            return true
        }
        if keyCode == 1, cmd, ctrl { // ⌃⌘S: open the scratchpad
            onEdge?(.openScratchpad)
            return true
        }
        if keyCode == 53 { onEdge?(.dismiss) } // Esc while idle: dismiss HUD toast, pass through
        return false
    }

    // MARK: - Event tap

    public func start() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                Unmanaged<HotkeyMonitor>.fromOpaque(refcon!).takeUnretainedValue()
                    .process(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            // No Accessibility permission yet (fresh install): keep retrying so
            // a grant starts working without an app restart.
            NSLog("Parla: keyboard event tap unavailable (Accessibility not granted?), retrying in 3s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.start() }
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    private func process(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) } // macOS disables slow taps; revive
            return pass
        case .flagsChanged:
            handle(keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
                   fnActive: event.flags.contains(.maskSecondaryFn),
                   shiftActive: event.flags.contains(.maskShift),
                   at: Double(event.timestamp) / 1_000_000_000)
            return pass
        case .keyDown:
            // Skip Parla's OWN synthetic keystrokes (typing/erasing while
            // streaming carries our marker — without this the tap would
            // self-cancel), and key autorepeat (a held space must not
            // latch-then-stop hands-free on its repeats).
            guard event.getIntegerValueField(.eventSourceUserData) != Inserter.syntheticMarker,
                  event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return pass }
            let swallow = keyDown(keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
                                  fnActive: event.flags.contains(.maskSecondaryFn),
                                  cmd: event.flags.contains(.maskCommand),
                                  ctrl: event.flags.contains(.maskControl),
                                  at: Double(event.timestamp) / 1_000_000_000)
            return swallow ? nil : pass
        default:
            return pass
        }
    }

    deinit {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap) // also invalidates the run-loop source
        }
    }
}
