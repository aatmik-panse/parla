import AppKit
import AVFoundation
import ParlaCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let store = SettingsStore()
    let hotkey = HotkeyMonitor()
    let recorder = AudioRecorder()
    let hud = HUD()
    var transcriber: WhisperTranscriber?
    var processTask: Task<Void, Never>?
    var isRecording = false
    // Live streaming: whether the focused field accepts typed text, and what
    // we've already streamed into it (grapheme-accurate, so backspace counts match).
    var liveTyping = false
    var focus = Inserter.FocusTarget.none
    var typed = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        setStatus("🎤")
        buildMenu()
        requestPermissions()
        loadModel()

        recorder.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.hud.push(level: level) }
        }

        hotkey.onEdge = { [weak self] edge in
            guard let self else { return }
            NSLog("Parla: fn %@", edge == .down ? "down" : "up")
            switch edge {
            case .down:
                self.isRecording = true
                // typed is NOT reset here: a still-queued finish from the previous
                // dictation must see it to erase that dictation's live text.
                do { try self.recorder.start(); self.setStatus("🔴"); self.hud.show(.listening) }
                catch {
                    self.setStatus("⚠️"); self.hud.show(.error("Mic failed"))
                    NSLog("Parla mic start failed: \(error)")
                    return
                }
                // Only stream into a confirmed text field; elsewhere keystrokes
                // could fire shortcuts. Unconfirmed focus still gets the final
                // text pasted; no focus at all is clipboard-only (see finish).
                self.focus = Inserter.focusTarget()
                self.liveTyping = self.focus == .editable
                if self.liveTyping, let transcriber = self.transcriber {
                    // Chain onto the previous finish so partial passes never run
                    // concurrently with the final pass (whisper ctx isn't reentrant).
                    self.processTask = Task { [prev = self.processTask] in
                        await prev?.value
                        await self.stream(transcriber: transcriber)
                    }
                }
            case .up:
                self.isRecording = false
                let samples = self.recorder.stop()
                // Capture this dictation's mode now: a quick next fn-press
                // rewrites self.liveTyping/focus before finish runs.
                let live = self.liveTyping
                let focus = self.focus
                self.setStatus("…")
                self.hud.show(.cleaning)
                // Chain onto the previous work (any in-flight streaming pass):
                // whisper ctx is not reentrant, and insertions must land in
                // dictation order.
                self.processTask = Task { [prev = self.processTask] in
                    await prev?.value
                    await self.finish(samples: samples, live: live, focus: focus)
                }
            }
        }
        hotkey.start()
    }

    func finish(samples: [Float], live: Bool, focus: Inserter.FocusTarget) async {
        let hud = self.hud // bind so main-queue hops don't capture non-Sendable self
        defer {
            DispatchQueue.main.async {
                // Don't stamp over an active recording, and keep ⚠️ visible
                // while there's no model.
                guard !self.isRecording else { return }
                self.setStatus(self.transcriber == nil ? "⚠️" : "🎤")
            }
        }
        guard let transcriber else {
            NSLog("Parla: no whisper model loaded — run scripts/download-model.sh")
            DispatchQueue.main.async { hud.show(.error("No whisper model")) }
            return
        }
        let settings = store.load()
        let pipeline = Pipeline(
            transcribe: { samples, prompt in transcriber.transcribe(samples, initialPrompt: prompt) },
            cleanup: { transcript, ctx in
                // A factory throw (misconfig / no key) lands in Pipeline's raw-transcript fallback.
                try await makeCleanupClient(settings: settings, env: ProcessInfo.processInfo.environment)
                    .clean(transcript: transcript, context: ctx)
            },
            settings: { settings },
            frontAppName: { NSWorkspace.shared.frontmostApplication?.localizedName })
        let result = await pipeline.process(samples: samples)
        await MainActor.run {
            let typedCount = self.typed.count // graphemes streamed live so far
            NSLog("Parla finish: result=%@ live=%d focus=%d typed=%d",
                  result ?? "<nil>", live ? 1 : 0, focus == .none ? 0 : 1, typedCount)
            if let text = result {
                switch (live, focus) {
                case (true, _) where typedCount == 0 || Inserter.canEraseTyped(self.typed):
                    // Replace the live-typed text wholesale with the cleaned final.
                    Inserter.typeBackspaces(typedCount)
                    Inserter.insert(text)
                    hud.show(.done)
                case (true, _):
                    // Can't prove the field still ends with our streamed text —
                    // leave it in place and offer the cleaned version instead.
                    Inserter.copy(text)
                    hud.show(.copied)
                case (false, .unknown), (false, .editable):
                    Inserter.insert(text) // focus we couldn't stream into: paste at cursor
                    hud.show(.done)
                case (false, .none):
                    Inserter.copy(text) // nothing focused: clipboard only, never paste
                    hud.show(.copied)
                }
            } else {
                // Empty transcript: undo anything we streamed — only if verified ours.
                if typedCount > 0 && Inserter.canEraseTyped(self.typed) {
                    Inserter.typeBackspaces(typedCount)
                }
                hud.hide()
            }
            self.typed = ""
        }
    }

    /// Live streaming pass loop: while fn is held, re-transcribe the whole buffer
    /// and reconcile it with what's already typed via erase+append. Runs on the
    /// processTask chain (serialized with the final pass).
    // ponytail: full-buffer re-transcription each pass is O(n²) over the
    // utterance — fine for short dictations; window the buffer if it bites.
    func stream(transcriber: WhisperTranscriber) async {
        let dict = store.load().dictionary
        let prompt = dict.isEmpty ? nil : dict.joined(separator: ", ")
        var lastCount = 0
        // ponytail: isRecording is written on main, read here — benign stop-flag race.
        while self.isRecording {
            let snap = self.recorder.snapshot()
            guard snap.count - lastCount >= 8000 else { // <0.5s new audio, wait
                try? await Task.sleep(nanoseconds: 300_000_000)
                continue
            }
            lastCount = snap.count
            let text = transcriber.transcribe(snap, initialPrompt: prompt)
            await MainActor.run {
                let d = LiveTyper.diff(typed: self.typed, new: text)
                if d.erase > 0 && !Inserter.canEraseTyped(self.typed) {
                    // Field is opaque or its tail no longer matches what we typed
                    // (dropped keystroke, autocorrect, user moved the cursor).
                    // Never risk deleting text that isn't ours: skip this revision.
                    NSLog("Parla stream: revision skipped, tail unverified (erase %d)", d.erase)
                    return
                }
                NSLog("Parla stream: %.1fs audio -> \"%@\" (erase %d, append \"%@\")",
                      Double(snap.count) / 16_000, text, d.erase, d.append)
                Inserter.typeBackspaces(d.erase)
                Inserter.typeUnicode(d.append)
                self.typed = text
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    func loadModel() {
        let path = store.load().whisperModelPath ?? WhisperTranscriber.defaultModelPath()
        transcriber = try? WhisperTranscriber(modelPath: path)
        if transcriber == nil { setStatus("⚠️") }
    }

    func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            if !ok { NSLog("Parla: microphone permission denied") }
        }
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            NSLog("Parla: grant Accessibility permission in System Settings")
        }
    }

    func setStatus(_ s: String) { statusItem.button?.title = s }

    func buildMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Hold fn 🌐 to dictate", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open Settings File", action: #selector(openSettings), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(NSMenuItem(title: "Quit Parla", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc func openSettings() {
        try? store.save(store.load()) // ensure the file exists with defaults
        NSWorkspace.shared.open(store.url)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
