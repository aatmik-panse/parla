import AppKit
import ParlaCore

/// Floating pill shown while dictating. All methods are main-thread only.
// ponytail: @unchecked Sendable — main-thread-only by contract, lets async
// callers hand it to DispatchQueue.main without non-Sendable capture warnings.
final class HUD: @unchecked Sendable {
    enum State {
        case listening(command: Bool)  // command: transform-selection mode ("Command…")
        case transcribing   // fn-up → raw text landing (fast, on-device)
        case polishing      // raw landed; LLM cleanup in flight — resolves to done/copied/cleanedCopied
        case done
        case copied
        case cleanedCopied  // swap unverifiable; cleaned text parked in the clipboard
        case rawFallback    // cleanup call failed; raw transcript is final, no swap attempted
        case cancelled      // dictation aborted (key pressed while fn held)
        case error(String)
    }

    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let dot = NSView()
    private let waveform = WaveformView()
    private var hideItem: DispatchWorkItem?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 44),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let pill = NSVisualEffectView(frame: panel.contentView!.bounds)
        pill.autoresizingMask = [.width, .height]
        pill.material = .hudWindow
        pill.blendingMode = .behindWindow
        pill.state = .active
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 14
        pill.layer?.masksToBounds = true
        panel.contentView = pill

        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 4
        dot.frame = NSRect(x: 14, y: 18, width: 8, height: 8)
        pill.addSubview(dot)

        waveform.frame = NSRect(x: 30, y: 8, width: 120, height: 28)
        pill.addSubview(waveform)

        label.frame = NSRect(x: 158, y: 12, width: 92, height: 20)
        label.textColor = .white
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        pill.addSubview(label)
    }

    func show(_ state: State) {
        hideItem?.cancel()
        hideItem = nil
        if case .listening = state {
            label.frame = NSRect(x: 158, y: 12, width: 92, height: 20)
        } else {
            // No waveform in these states — let longer labels use the full pill.
            label.frame = NSRect(x: 16, y: 12, width: 228, height: 20)
        }
        switch state {
        case .listening(let command):
            dot.isHidden = false
            waveform.isHidden = false
            waveform.clear()
            label.stringValue = command ? "Command…" : "Listening…"
            position()
            panel.orderFrontRegardless()
        case .transcribing:
            dot.isHidden = true
            waveform.isHidden = true
            label.stringValue = "Transcribing…"
            panel.orderFrontRegardless()
        case .polishing:
            dot.isHidden = true
            waveform.isHidden = true
            label.stringValue = "✓ · polishing…"
            panel.orderFrontRegardless() // no scheduleHide — a terminal state follows
        case .done:
            dot.isHidden = true
            waveform.isHidden = true
            label.stringValue = "✓ Pasted"
            panel.orderFrontRegardless()
            scheduleHide()
        case .copied:
            dot.isHidden = true
            waveform.isHidden = true
            label.stringValue = "✓ In clipboard"
            panel.orderFrontRegardless()
            scheduleHide()
        case .cleanedCopied:
            dot.isHidden = true
            waveform.isHidden = true
            label.stringValue = "✓ cleaned in clipboard"
            panel.orderFrontRegardless()
            scheduleHide()
        case .rawFallback:
            dot.isHidden = true
            waveform.isHidden = true
            label.stringValue = "✓ raw (cleanup failed)"
            panel.orderFrontRegardless()
            scheduleHide()
        case .cancelled:
            dot.isHidden = true
            waveform.isHidden = true
            label.stringValue = "✕ Cancelled"
            panel.orderFrontRegardless()
            scheduleHide()
        case .error(let msg):
            dot.isHidden = true
            waveform.isHidden = true
            label.stringValue = "⚠️ \(msg)"
            panel.orderFrontRegardless()
            scheduleHide()
        }
    }

    func push(level: Float) { waveform.push(level: level) }

    func hide() {
        hideItem?.cancel()
        hideItem = nil
        panel.orderOut(nil)
    }

    private func scheduleHide() {
        let item = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
        hideItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: item)
    }

    /// Positions on the screen the user is actually working on, not always
    /// NSScreen.main — only called from show(.listening), i.e. once per
    /// fn-down, so the pill never jumps mid-dictation.
    private func position() {
        guard let screen = Self.activeScreen() else { return }
        let f = panel.frame
        let x = screen.frame.midX - f.width / 2
        let y = screen.frame.minY + 80
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Screen to show on, in order: the AX-focused element's screen (where the
    /// user is dictating into), else the screen under the mouse, else main.
    private static func activeScreen() -> NSScreen? {
        if let p = Inserter.focusedElementScreenPoint(),
           let s = NSScreen.screens.first(where: { $0.frame.contains(p) }) {
            return s
        }
        let mouse = NSEvent.mouseLocation
        if let s = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            return s
        }
        return NSScreen.main
    }
}

/// Draws the last ~30 pushed levels as centered vertical bars. No timers —
/// motion comes only from real pushed values.
final class WaveformView: NSView {
    private var levels: [Float] = []
    private let capacity = 30

    func push(level: Float) {
        levels.append(level)
        if levels.count > capacity { levels.removeFirst(levels.count - capacity) }
        needsDisplay = true
    }

    func clear() {
        levels.removeAll()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let barW: CGFloat = 3, gap: CGFloat = 1
        let step = barW + gap
        NSColor.white.withAlphaComponent(0.85).setFill()
        for (i, level) in levels.enumerated() {
            let norm = min(1, CGFloat(level) * 8)
            let h = max(2, norm * bounds.height) // floor so silence shows a line
            let x = CGFloat(i) * step
            let rect = NSRect(x: x, y: (bounds.height - h) / 2, width: barW, height: h)
            NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
        }
    }
}
