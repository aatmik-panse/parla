import AppKit

/// Push-to-talk on Right Option (keyCode 61).
/// ponytail: NSEvent global monitor instead of a CGEventTap — same Accessibility
/// permission, far less code. Switch to a tap if we ever need to swallow the key.
public final class HotkeyMonitor {
    public enum Edge: Equatable { case down, up }
    public var onEdge: ((Edge) -> Void)?
    private var isDown = false
    private var monitor: Any?

    public init() {}

    /// Pure state machine — exercised by tests.
    public func handle(keyCode: UInt16, optionActive: Bool) {
        guard keyCode == 61 else { return }
        if optionActive && !isDown {
            isDown = true
            onEdge?(.down)
        } else if !optionActive && isDown {
            isDown = false
            onEdge?(.up)
        }
    }

    public func start() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            // 0x40 = NX_DEVICERALTKEYMASK (right-Alt device bit): `.option` is true while
            // EITHER Option is held, which would miss the Right Option release.
            self?.handle(keyCode: e.keyCode, optionActive: e.modifierFlags.rawValue & 0x40 != 0)
        }
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
