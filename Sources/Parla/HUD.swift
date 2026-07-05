import AppKit

/// Floating pill shown while dictating. All methods are main-thread only.
// ponytail: @unchecked Sendable — main-thread-only by contract, lets async
// callers hand it to DispatchQueue.main without non-Sendable capture warnings.
final class HUD: @unchecked Sendable {
    enum State {
        case listening
        case cleaning
        case done
        case copied
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
        switch state {
        case .listening:
            dot.isHidden = false
            waveform.isHidden = false
            waveform.clear()
            label.stringValue = "Listening…"
            position()
            panel.orderFrontRegardless()
        case .cleaning:
            dot.isHidden = true
            waveform.isHidden = true
            label.stringValue = "Cleaning…"
            panel.orderFrontRegardless()
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

    private func position() {
        guard let screen = NSScreen.main else { return }
        let f = panel.frame
        let x = screen.frame.midX - f.width / 2
        let y = screen.frame.minY + 80
        panel.setFrameOrigin(NSPoint(x: x, y: y))
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
