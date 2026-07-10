import AppKit

/// Free-form scratch pad — a safe landing place for dictations: focus it, hold
/// fn, and the transcript types in like any other field. One persistent text
/// area, saved to Application Support/Parla/scratchpad.txt (debounced on edit,
/// flushed on close/quit). Closing hides the window (isReleasedWhenClosed =
/// false); the app stays menu-bar-only.
final class ScratchpadController: NSObject, NSWindowDelegate, NSTextViewDelegate {
    private var window: NSWindow?
    private let scroll = NSTextView.scrollableTextView()
    private var textView: NSTextView { scroll.documentView as! NSTextView }
    private var saveItem: DispatchWorkItem?

    static let fileURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Parla/scratchpad.txt")

    func show() {
        if window == nil { window = makeWindow() }
        NSApp.activate(ignoringOtherApps: true) // LSUIElement app: needs explicit focus
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(textView)
    }

    private func makeWindow() -> NSWindow {
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.allowsUndo = true
        textView.delegate = self
        textView.string = (try? String(contentsOf: Self.fileURL, encoding: .utf8)) ?? ""

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Scratchpad"
        w.minSize = NSSize(width: 280, height: 180)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentView = scroll
        w.setFrameAutosaveName("ParlaScratchpad")
        if !w.setFrameUsingName("ParlaScratchpad") { w.center() }
        return w
    }

    func textDidChange(_ notification: Notification) {
        saveItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.save() }
        saveItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    func windowWillClose(_ notification: Notification) { save() }

    /// Flush pending edits to disk. Safe to call anytime (quit hook): a never-
    /// shown scratchpad has nothing to write.
    func save() {
        saveItem?.cancel()
        saveItem = nil
        guard window != nil else { return }
        try? FileManager.default.createDirectory(
            at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? textView.string.write(to: Self.fileURL, atomically: true, encoding: .utf8)
    }
}
