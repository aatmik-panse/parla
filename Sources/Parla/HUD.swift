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
    private let pill = DraggablePill(frame: HUD.activePillFrame)
    private let label = NSTextField(labelWithString: "")
    private let dot = NSView()
    private let waveform = WaveformView()
    private let mic = NSImageView()
    private var hideItem: DispatchWorkItem?
    // Currently collapsed to the mini idle capsule (vs. the full active pill).
    private var isIdle = false
    // ponytail: a user drag pins the pill to one spot across screens/sessions.
    // Delete the "hudOrigin" pref (or a future Hub control) to restore auto-centering.
    private var draggedOrigin: NSPoint?
    private static let originKey = "hudOrigin"

    private static let activePillFrame = NSRect(x: 12, y: 12, width: 260, height: 44)
    private static let idlePillFrame = NSRect(x: 110, y: 18, width: 64, height: 32)

    /// Keep the pill floating as a mini idle capsule whenever not dictating.
    var showAlways = false {
        didSet {
            guard showAlways != oldValue else { return }
            if showAlways {
                if !panel.isVisible { showIdle() }
            } else if isIdle {
                panel.orderOut(nil)
            }
        }
    }

    init() {
        // Panel is larger than the pill so the lavender glow has room to render.
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 284, height: 68),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // the pill's own glow is the only shadow
        // Borderless + clear background: macOS routes clicks straight through
        // fully transparent window pixels, so only the opaque pill (alpha 0.97)
        // catches them — the panel accepts events without stealing clicks nearby.
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Flow-bar look (docs/plan.md §Flow Bar): near-black capsule with a thin
        // purple ring and soft lavender glow. Static colors in both appearances.
        let container = NSView(frame: panel.contentView!.bounds)
        container.autoresizingMask = [.width, .height]
        pill.autoresizingMask = [.width, .height]
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor(srgbRed: 0.102, green: 0.102, blue: 0.102, alpha: 0.97).cgColor // vast-950
        pill.layer?.cornerRadius = 22
        pill.layer?.borderWidth = 1
        pill.layer?.borderColor = NSColor(srgbRed: 0.635, green: 0.431, blue: 0.757, alpha: 0.6).cgColor // brand-700
        pill.layer?.shadowColor = NSColor(srgbRed: 0.941, green: 0.843, blue: 1.0, alpha: 1).cgColor // brand-500 glow
        pill.layer?.shadowOpacity = 0.45
        pill.layer?.shadowRadius = 9
        pill.layer?.shadowOffset = .zero
        container.addSubview(pill)
        panel.contentView = container

        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor(srgbRed: 0.933, green: 0.416, blue: 0.416, alpha: 1).cgColor // coral (destructive-500)
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

        // Idle-only mic glyph, centered in the full pill. Flexible margins keep
        // it centered as the pill animates down to the mini capsule.
        mic.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Parla")
        mic.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        mic.contentTintColor = .white
        mic.imageScaling = .scaleProportionallyUpOrDown
        mic.frame = NSRect(x: 122, y: 14, width: 16, height: 16)
        mic.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        mic.isHidden = true
        pill.addSubview(mic)

        // Restore a pinned drag position, if the user set one, and persist new ones.
        if let o = UserDefaults.standard.array(forKey: Self.originKey) as? [Double], o.count == 2 {
            draggedOrigin = NSPoint(x: o[0], y: o[1])
        }
        pill.onDragEnd = { [weak self] origin in
            guard let self else { return }
            self.draggedOrigin = origin
            UserDefaults.standard.set([Double(origin.x), Double(origin.y)], forKey: Self.originKey)
        }
    }

    /// Show the idle capsule (position on the active screen if the panel was off).
    private func showIdle() {
        hideItem?.cancel()
        hideItem = nil
        collapse(animated: false, to: Self.activeScreen())
        panel.orderFrontRegardless()
    }

    /// Collapse to the mini idle capsule — mic only, dot/waveform/label hidden.
    /// Moves the panel to the idle auto-position (or a passed target screen),
    /// animating the panel origin alongside the pill morph.
    private func collapse(animated: Bool, to screen: NSScreen? = nil) {
        isIdle = true
        dot.isHidden = true
        waveform.isHidden = true
        label.isHidden = true
        mic.isHidden = false
        let target = (screen ?? currentScreen()).map { autoOrigin(idle: true, on: $0) }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                pill.animator().frame = HUD.idlePillFrame
                if let target { panel.animator().setFrame(NSRect(origin: target, size: panel.frame.size), display: true) }
            }
        } else {
            pill.frame = HUD.idlePillFrame
            if let target { panel.setFrameOrigin(target) }
        }
        pill.layer?.cornerRadius = 16
    }

    /// Expand to the full active pill. Animates (pill + panel origin) only when
    /// coming from idle. `screen` moves to a specific screen (dictation start);
    /// nil keeps the panel on its current screen.
    private func expand(to screen: NSScreen? = nil) {
        let wasIdle = isIdle
        isIdle = false
        mic.isHidden = true
        label.isHidden = false
        let target = (screen ?? currentScreen()).map { autoOrigin(idle: false, on: $0) }
        if wasIdle {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                pill.animator().frame = HUD.activePillFrame
                if let target { panel.animator().setFrame(NSRect(origin: target, size: panel.frame.size), display: true) }
            }
        } else {
            pill.frame = HUD.activePillFrame
            if let target { panel.setFrameOrigin(target) }
        }
        pill.layer?.cornerRadius = 22
    }

    /// Settle after a dictation: collapse to idle when always-on, else order out.
    private func settle() {
        hideItem?.cancel()
        hideItem = nil
        if showAlways { collapse(animated: true) } else { panel.orderOut(nil) }
    }

    func show(_ state: State) {
        hideItem?.cancel()
        hideItem = nil
        // .listening moves to the screen the user is dictating into; every other
        // state stays on the panel's current screen.
        if case .listening = state { expand(to: Self.activeScreen()) } else { expand() }
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

    func hide() { settle() }

    private func scheduleHide() {
        let item = DispatchWorkItem { [weak self] in self?.settle() }
        hideItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: item)
    }

    /// Auto-position for a mode on `screen`: active sits 80pt above the screen
    /// bottom; idle hugs just above the Dock (visibleFrame). A pinned drag
    /// origin overrides both, so both modes share the dragged spot verbatim.
    private func autoOrigin(idle: Bool, on screen: NSScreen) -> NSPoint {
        if let draggedOrigin { return draggedOrigin }
        let x = screen.frame.midX - panel.frame.width / 2
        let y = idle ? screen.visibleFrame.minY + 2 : screen.frame.minY + 80
        return NSPoint(x: x, y: y)
    }

    /// Screen the panel currently occupies (by its center), else the active
    /// screen — used during morphs so the pill doesn't jump screens.
    private func currentScreen() -> NSScreen? {
        let c = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        return NSScreen.screens.first { $0.frame.contains(c) } ?? Self.activeScreen()
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

/// The pill view, draggable by the user. Manual drag (not performDrag /
/// isMovableByWindowBackground) so we get a clean end-of-drag hook and never
/// confuse a programmatic panel move with a user drag. Subviews (label, dot,
/// waveform, mic) don't handle mouseDown, so it bubbles up to here.
final class DraggablePill: NSView {
    /// Called after a real drag (not a plain click) with the window's final origin.
    var onDragEnd: ((NSPoint) -> Void)?
    private var dragOffset: NSPoint?  // mouse → window-origin gap at mouseDown
    private var didDrag = false       // plain clicks must not pin the pill

    override func mouseDown(with event: NSEvent) {
        guard let win = window else { return }
        didDrag = false
        let m = NSEvent.mouseLocation
        dragOffset = NSPoint(x: m.x - win.frame.origin.x, y: m.y - win.frame.origin.y)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let win = window, let off = dragOffset else { return }
        didDrag = true
        let m = NSEvent.mouseLocation
        win.setFrameOrigin(NSPoint(x: m.x - off.x, y: m.y - off.y))
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragOffset = nil; didDrag = false }
        guard didDrag, let win = window else { return }
        onDragEnd?(win.frame.origin)
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
