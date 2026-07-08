import AppKit
import AVFoundation
import ParlaCore

/// Subtle system-sound cues. NSSound(named:) uses the bundled ~/Library sounds —
/// no audio framework. ponytail: fire-and-forget; a nil name just no-ops.
enum Sound {
    private static func play(_ name: String) {
        guard let s = NSSound(named: name) else { return }
        s.volume = 0.25
        s.play()
    }
    static func start()  { play("Tink") }   // record-start
    static func finish() { play("Glass") }  // raw transcript landed
    static func cancel() { play("Funk") }   // dictation aborted
}

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
    // Bumped on every fn-down; a pending cleaned-swap compares its captured
    // value on the main actor and never fires keystrokes into a newer session.
    var generation = 0
    // Confirmed-prefix window for long dictations: written by stream(), consumed
    // by the finish() queued right after it — the processTask chain serializes.
    var window: StreamWindow?

    /// Where the instant raw finalize landed — decides how the cleaned swap applies.
    enum Landing: Sendable { case field, clipboard }

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
            NSLog("Parla: fn edge %@", "\(edge)")
            switch edge {
            case .down:
                self.generation += 1 // invalidates any pending cleaned-swap
                self.isRecording = true
                // typed is NOT reset here: a still-queued finish from the previous
                // dictation must see it to erase that dictation's live text.
                do { try self.recorder.start(); self.setStatus("🔴"); self.hud.show(.listening); Sound.start() }
                catch {
                    self.setStatus("⚠️"); self.hud.show(.error("Mic failed"))
                    NSLog("Parla mic start failed: \(error)")
                    return
                }
                // Only stream when final replacement is verifiable. Opaque
                // focused fields still get the final paste; no focus is
                // clipboard-only (see finish).
                self.focus = Inserter.focusTarget()
                self.liveTyping = self.focus == .editable && Inserter.canVerifyFocusedField()
                if self.liveTyping, let transcriber = self.transcriber {
                    // Chain onto the previous finish so partial passes never run
                    // concurrently with the final pass (whisper ctx isn't reentrant).
                    self.processTask = Task { [prev = self.processTask] in
                        await prev?.value
                        await self.stream(transcriber: transcriber)
                    }
                }
            case .up(let short):
                // Short tap = accidental Globe press (emoji/input switch): abort
                // silently, never run whisper. Recording still STARTED on fn-down
                // so we don't clip speech onset; we just discard it here.
                if short {
                    NSLog("Parla: short tap, discarding")
                    self.cancelDictation(silent: true)
                    return
                }
                self.isRecording = false
                let samples = self.recorder.stop()
                // Capture this dictation's mode now: a quick next fn-press
                // rewrites self.liveTyping/focus before finish runs.
                let live = self.liveTyping
                let focus = self.focus
                let gen = self.generation
                self.setStatus("…")
                self.hud.show(.transcribing)
                // Chain onto the previous work (any in-flight streaming pass):
                // whisper ctx is not reentrant, and insertions must land in
                // dictation order.
                self.processTask = Task { [prev = self.processTask] in
                    await prev?.value
                    await self.finish(samples: samples, live: live, focus: focus, gen: gen)
                }
            case .cancel:
                // A real key was pressed while fn was held (fn+arrow, Esc): abort.
                NSLog("Parla: cancelled by keypress")
                self.cancelDictation(silent: false)
            }
        }
        hotkey.start()
    }

    /// Abort the in-flight dictation: stop the stream loop + recorder (discard
    /// audio, never call whisper), then queue the undo of any live-typed text on
    /// the processTask chain so it serializes behind a still-running streaming
    /// pass and reads the final `typed` value. `silent` = accidental short tap
    /// (no sound, HUD just hides); otherwise a real cancel (sound + ✕ HUD).
    func cancelDictation(silent: Bool) {
        isRecording = false          // stops the stream loop
        _ = recorder.stop()          // discard captured audio
        if !silent { Sound.cancel() }
        let hud = self.hud
        processTask = Task { [prev = self.processTask] in
            await prev?.value        // wait out any in-flight streaming pass
            await MainActor.run {
                // Undo live-typed text only if still provably ours (same
                // invariant as finish's empty-transcript path — never blind-delete).
                let typedCount = self.typed.count
                if typedCount > 0 {
                    if Inserter.canEraseTyped(self.typed) {
                        Inserter.typeBackspaces(typedCount)
                    } else if Inserter.selectBackAndVerify(self.typed) {
                        Inserter.typeBackspaces(1) // delete the verified selection
                    }
                }
                self.typed = ""
                self.window = nil    // discard any confirmed-prefix the stream handed off
                if silent { hud.hide() } else { hud.show(.cancelled) }
            }
        }
        setStatus(transcriber == nil ? "⚠️" : "🎤")
    }

    func finish(samples: [Float], live: Bool, focus: Inserter.FocusTarget, gen: Int) async {
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

        // Raw transcript — reuse the stream's confirmed prefix so the final pass
        // is O(tail), not O(whole utterance). self.window is ours to consume:
        // stream() (queued just before us) wrote it, the chain serializes access.
        let raw: String?
        if let win = self.window {
            self.window = nil
            let cut = min(win.cutSample, samples.count)
            let tailText = transcriber.transcribe(
                Array(samples[cut...]),
                initialPrompt: StreamWindow.tailPrompt(dictionary: settings.dictionary,
                                                       confirmed: win.confirmedText))
            let joined = StreamWindow.join(win.confirmedText, tailText)
            raw = joined.isEmpty ? nil : joined
        } else {
            raw = pipeline.transcript(samples: samples)
        }

        guard let raw else {
            await MainActor.run {
                // Empty transcript: undo anything we streamed — only if verified ours.
                let typedCount = self.typed.count
                NSLog("Parla finish: empty transcript, typed=%d", typedCount)
                if typedCount > 0 {
                    if Inserter.canEraseTyped(self.typed) {
                        Inserter.typeBackspaces(typedCount)
                    } else if Inserter.selectBackAndVerify(self.typed) {
                        Inserter.typeBackspaces(1) // delete the verified selection
                    }
                }
                self.typed = ""
                hud.hide()
            }
            return
        }

        // Instant finalize: land the raw transcript NOW; the LLM polish swaps in
        // behind it without blocking the user.
        let landing: Landing = await MainActor.run {
            let typedCount = self.typed.count // graphemes streamed live so far
            defer { self.typed = "" }
            NSLog("Parla finish: raw=%@ live=%d focus=%d typed=%d",
                  raw, live ? 1 : 0, focus == .none ? 0 : 1, typedCount)
            switch (live, focus) {
            case (true, _) where typedCount == 0 || Inserter.canEraseTyped(self.typed):
                // Replace the live-typed text wholesale with the raw final.
                NSLog("Parla finish path: ax-verified replace")
                Inserter.typeBackspaces(typedCount)
                Inserter.insert(raw)
                hud.show(.polishing)
                return .field
            case (true, _) where Inserter.selectBackAndVerify(self.typed):
                // Opaque field: our streamed text is now the live selection —
                // pasting replaces exactly it.
                NSLog("Parla finish path: select-verified replace")
                Inserter.insert(raw)
                hud.show(.polishing)
                return .field
            case (true, _):
                // Can't prove the field still ends with our streamed text —
                // leave it in place and offer the transcript instead.
                NSLog("Parla finish path: unverified, clipboard only")
                Inserter.copy(raw)
                hud.show(.polishing)
                return .clipboard
            case (false, .unknown), (false, .editable):
                NSLog("Parla finish path: focused paste")
                Inserter.insert(raw) // focus we couldn't stream into: paste at cursor
                hud.show(.polishing)
                return .field
            case (false, .none):
                NSLog("Parla finish path: no focus, clipboard only")
                Inserter.copy(raw) // nothing focused: clipboard only, never paste
                hud.show(.polishing)
                return .clipboard
            }
        }
        Sound.finish() // raw transcript landed — the user-visible finalize moment

        // Async polish: cleanup, then swap raw → cleaned with the same
        // verification machinery. Still on the processTask chain, so a queued
        // next dictation starts only after this resolves (insertion order holds).
        let cleaned = await pipeline.clean(transcript: raw)
        await MainActor.run {
            let plan = LiveTyper.swapPlan(raw: raw, cleaned: cleaned)
            guard gen == self.generation else {
                // A newer dictation owns the field and HUD — no keystrokes, no
                // HUD. Cleaned text still lands in the clipboard if it's still
                // our raw sitting there.
                NSLog("Parla swap: stale generation, clipboard fallback")
                if plan != nil, NSPasteboard.general.string(forType: .string) == raw {
                    Inserter.copy(cleaned)
                }
                return
            }
            switch landing {
            case .clipboard:
                // Nothing of ours in a field — just refresh the clipboard
                // raw → cleaned, unless the user copied something meanwhile.
                if NSPasteboard.general.string(forType: .string) == raw {
                    if plan != nil { Inserter.copy(cleaned) }
                    hud.show(.copied)
                } else {
                    hud.hide() // clipboard is the user's now — never clobber
                }
            case .field:
                guard let plan else { hud.show(.done); return } // polish was a no-op
                if Inserter.canEraseTyped(raw) {
                    NSLog("Parla swap path: ax-verified tail swap (erase %d)", plan.eraseTail.count)
                    Inserter.typeBackspaces(plan.eraseTail.count)
                    Inserter.typeUnicode(plan.replacement)
                    Inserter.copy(cleaned) // escape-hatch invariant: full final text in the clipboard
                    hud.show(.done)
                } else if Inserter.selectBackAndVerify(plan.eraseTail) {
                    NSLog("Parla swap path: select-verified tail swap (erase %d)", plan.eraseTail.count)
                    if plan.replacement.isEmpty {
                        Inserter.typeBackspaces(1) // delete the verified selection
                    } else {
                        Inserter.typeUnicode(plan.replacement) // replaces the live selection
                    }
                    Inserter.copy(cleaned)
                    hud.show(.done)
                } else {
                    // User clicked away or typed — leave the raw text alone.
                    NSLog("Parla swap path: unverified, cleaned to clipboard")
                    Inserter.copy(cleaned)
                    hud.show(.cleanedCopied)
                }
            }
        }
    }

    /// Live streaming pass loop: while fn is held, re-transcribe the unconfirmed
    /// tail of the buffer and reconcile it with what's already typed via
    /// erase+append. Runs on the processTask chain (serialized with the final
    /// pass). Once the tail exceeds ~15s a confirmed prefix is frozen at a quiet
    /// spot (see StreamWindow) so each pass stays O(tail), not O(n²).
    func stream(transcriber: WhisperTranscriber) async {
        let dict = store.load().dictionary
        var confirmed = "" // frozen transcript of snap[0..<cut]
        var cut = 0
        var lastCount = 0
        // ponytail: isRecording is written on main, read here — benign stop-flag race.
        while self.isRecording {
            let snap = self.recorder.snapshot()
            guard snap.count - lastCount >= 8000 else { // <0.5s new audio, wait
                try? await Task.sleep(nanoseconds: 300_000_000)
                continue
            }
            lastCount = snap.count
            var tail = Array(snap[cut...])
            if tail.count > StreamWindow.threshold {
                // Freeze the head up to the quietest spot near cutTarget: one
                // final pass over it, then it's never re-transcribed.
                let rel = StreamWindow.quietestCut(samples: tail, near: StreamWindow.cutTarget)
                let head = transcriber.transcribe(
                    Array(tail[..<rel]),
                    initialPrompt: StreamWindow.tailPrompt(dictionary: dict, confirmed: confirmed))
                confirmed = StreamWindow.join(confirmed, head)
                cut += rel
                tail = Array(tail[rel...])
                NSLog("Parla stream: cut at %.1fs, confirmed %d chars",
                      Double(cut) / 16_000, confirmed.count)
            }
            let text = StreamWindow.join(
                confirmed,
                transcriber.transcribe(
                    tail,
                    initialPrompt: StreamWindow.tailPrompt(dictionary: dict, confirmed: confirmed)))
            await MainActor.run {
                let d = LiveTyper.diff(typed: self.typed, new: text)
                NSLog("Parla stream: %.1fs audio -> \"%@\" (erase %d, append \"%@\")",
                      Double(snap.count) / 16_000, text, d.erase, d.append)
                if d.erase == 0 {
                    Inserter.typeUnicode(d.append) // pure append: can't harm foreign text
                } else if Inserter.canEraseTyped(self.typed) {
                    Inserter.typeBackspaces(d.erase)
                    Inserter.typeUnicode(d.append)
                } else if Inserter.selectBackAndVerify(String(self.typed.suffix(d.erase))) {
                    if d.append.isEmpty {
                        Inserter.typeBackspaces(1) // pure shrink: delete the selection
                    } else {
                        Inserter.typeUnicode(d.append) // replaces the verified live selection
                    }
                } else {
                    // Can't prove the tail is ours — never risk foreign text.
                    NSLog("Parla stream: revision skipped, tail unverified (erase %d)", d.erase)
                    return
                }
                self.typed = text
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        // Hand the window to this dictation's finish(), queued right after us on
        // the processTask chain — the chain is the synchronization.
        if !confirmed.isEmpty {
            self.window = StreamWindow(confirmedText: confirmed, cutSample: cut)
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
