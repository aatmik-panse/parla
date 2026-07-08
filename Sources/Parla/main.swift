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
    // Model download-in-progress state (feature 4): non-nil task means the menu
    // shows a disabled "Downloading…" item instead of the download action.
    var downloadTask: URLSessionDownloadTask?
    var downloadObservation: NSKeyValueObservation?

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
                // Snapshot the frontmost app ONCE here: terminal newline-flattening
                // must use the same target for the raw finalize and the async swap.
                let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                self.setStatus("…")
                self.hud.show(.transcribing)
                // Chain onto the previous work (any in-flight streaming pass):
                // whisper ctx is not reentrant, and insertions must land in
                // dictation order.
                self.processTask = Task { [prev = self.processTask] in
                    await prev?.value
                    await self.finish(samples: samples, live: live, focus: focus, gen: gen, bundleID: bundleID)
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
        setStatus(idleIcon)
    }

    func finish(samples: [Float], live: Bool, focus: Inserter.FocusTarget, gen: Int, bundleID: String?) async {
        let hud = self.hud // bind so main-queue hops don't capture non-Sendable self
        defer {
            DispatchQueue.main.async {
                // Don't stamp over an active recording, and keep ⚠️ visible
                // while there's no model / settings are broken / permissions missing.
                guard !self.isRecording else { return }
                self.setStatus(self.idleIcon)
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
            let tail = Array(samples[cut...])
            // Min-audio guard on the TAIL only: a long dictation trailing off into
            // silence still finalizes its confirmed prefix — we just skip the tail
            // whisper pass (which would hallucinate) and use the confirmed text raw.
            if TextRules.audioWorthTranscribing(sampleCount: tail.count, rms: AudioRecorder.rms(tail)) {
                let tailText = transcriber.transcribe(
                    tail,
                    initialPrompt: StreamWindow.tailPrompt(dictionary: settings.dictionary,
                                                           confirmed: win.confirmedText))
                let joined = StreamWindow.join(win.confirmedText, tailText)
                raw = joined.isEmpty ? nil : joined
            } else {
                raw = win.confirmedText.isEmpty ? nil : win.confirmedText
            }
        } else if TextRules.audioWorthTranscribing(sampleCount: samples.count, rms: AudioRecorder.rms(samples)) {
            raw = pipeline.transcript(samples: samples)
        } else {
            // Too short or silent — whisper hallucinates here. Treat as empty.
            NSLog("Parla finish: audio below min-audio floor, skipping whisper")
            raw = nil
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

        // Terminal newline guard: flatten before ANY insertion so a multi-line
        // transcript can't run each line as a command. insertText is what actually
        // lands in the field — the async swap below must diff against IT, not raw.
        let insertText = TextRules.isTerminal(bundleID: bundleID) ? TextRules.flattenForTerminal(raw) : raw

        // Instant finalize: land the raw transcript NOW; the LLM polish swaps in
        // behind it without blocking the user.
        let landing: Landing = await MainActor.run {
            let typedCount = self.typed.count // graphemes streamed live so far
            defer { self.typed = "" }
            NSLog("Parla finish: raw=%@ live=%d focus=%d typed=%d",
                  insertText, live ? 1 : 0, focus == .none ? 0 : 1, typedCount)
            switch (live, focus) {
            case (_, .secure):
                // Password field: on-device transcript to the clipboard only.
                // Never paste (it isn't a normal field) and never cloud-polish
                // (it's plausibly a password) — the guard below skips clean().
                NSLog("Parla finish path: secure field, clipboard only")
                Inserter.copy(insertText)
                hud.show(.copied)
                return .clipboard
            case (true, _) where typedCount == 0 || Inserter.canEraseTyped(self.typed):
                // Replace the live-typed text wholesale with the raw final.
                NSLog("Parla finish path: ax-verified replace")
                Inserter.typeBackspaces(typedCount)
                Inserter.insert(insertText)
                hud.show(.polishing)
                return .field
            case (true, _) where Inserter.selectBackAndVerify(self.typed):
                // Opaque field: our streamed text is now the live selection —
                // pasting replaces exactly it.
                NSLog("Parla finish path: select-verified replace")
                Inserter.insert(insertText)
                hud.show(.polishing)
                return .field
            case (true, _):
                // Can't prove the field still ends with our streamed text —
                // leave it in place and offer the transcript instead.
                NSLog("Parla finish path: unverified, clipboard only")
                Inserter.copy(insertText)
                hud.show(.polishing)
                return .clipboard
            case (false, .unknown), (false, .editable):
                NSLog("Parla finish path: focused paste")
                Inserter.insert(insertText) // focus we couldn't stream into: paste at cursor
                hud.show(.polishing)
                return .field
            case (false, .none):
                NSLog("Parla finish path: no focus, clipboard only")
                Inserter.copy(insertText) // nothing focused: clipboard only, never paste
                hud.show(.polishing)
                return .clipboard
            }
        }
        Sound.finish() // raw transcript landed — the user-visible finalize moment

        // Secure field: never send the transcript to the cloud cleanup LLM. The
        // raw on-device text is already in the clipboard with the .copied HUD.
        guard focus != .secure else { return }

        // Async polish: cleanup, then swap raw → cleaned with the same
        // verification machinery. Still on the processTask chain, so a queued
        // next dictation starts only after this resolves (insertion order holds).
        let cleanResult = await pipeline.clean(transcript: raw)
        // Same terminal guard on the cleaned text — it replaces insertText in the
        // field, so it must be flattened too, and the plan must diff flattened vs
        // flattened (insertText) or the erase/verify counts won't match the field.
        let cleaned = TextRules.isTerminal(bundleID: bundleID) ? TextRules.flattenForTerminal(cleanResult.text) : cleanResult.text
        await MainActor.run {
            let plan = LiveTyper.swapPlan(raw: insertText, cleaned: cleaned)
            guard gen == self.generation else {
                // A newer dictation owns the field and HUD — no keystrokes, no
                // HUD. Cleaned text still lands in the clipboard if it's still
                // our raw sitting there.
                NSLog("Parla swap: stale generation, clipboard fallback")
                if plan != nil, NSPasteboard.general.string(forType: .string) == insertText {
                    Inserter.copy(cleaned)
                }
                return
            }
            switch landing {
            case .clipboard:
                // Nothing of ours in a field — just refresh the clipboard
                // raw → cleaned, unless the user copied something meanwhile.
                if NSPasteboard.general.string(forType: .string) == insertText {
                    if plan != nil { Inserter.copy(cleaned) }
                    hud.show(cleanResult.failed ? .rawFallback : .copied)
                } else {
                    hud.hide() // clipboard is the user's now — never clobber
                }
            case .field:
                guard let plan else { // polish was a no-op: either cleanup failed, or the LLM agreed raw was fine
                    hud.show(cleanResult.failed ? .rawFallback : .done)
                    return
                }
                if Inserter.canEraseTyped(insertText) {
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
        setStatus(idleIcon)
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

    var micGranted: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    var axGranted: Bool { AXIsProcessTrusted() }

    /// Idle menu-bar glyph: ⚠️ if anything needs the user's attention (no model,
    /// broken settings.json, missing permission), else the plain mic icon.
    /// store.lastError reflects the most recent load() — refreshed at launch
    /// and on every dictation (finish() reloads settings each time).
    var idleIcon: String {
        (transcriber != nil && store.lastError == nil && micGranted && axGranted) ? "🎤" : "⚠️"
    }

    func setStatus(_ s: String) { statusItem.button?.title = s }

    func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    @objc func openSettings() {
        // Only seed defaults when there's no file yet — never overwrite a
        // broken settings.json the user is about to fix (that's their typo'd
        // API key / dictionary, don't discard it).
        if !FileManager.default.fileExists(atPath: store.url.path) {
            try? store.save(store.load())
        }
        NSWorkspace.shared.open(store.url)
    }

    @objc func openPrivacyPane(_ sender: NSMenuItem) {
        guard let pane = sender.representedObject as? String,
              let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// Kicks off the base.en download; menuNeedsUpdate hides this action while
    /// downloadTask is non-nil so a second click can't start a duplicate.
    @objc func downloadModel() {
        guard downloadTask == nil,
              let url = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin")
        else { return }
        setStatus("⬇️ 0%")
        let task = URLSession.shared.downloadTask(with: url) { [weak self] tmp, _, error in
            // The tmp file is deleted the moment this handler returns — move it
            // to its destination NOW, before hopping to main for the UI.
            let moveError: Error? = error ?? tmp.flatMap { Self.installModel(from: $0) }
            DispatchQueue.main.async { self?.finishDownload(error: moveError ?? (tmp == nil ? CleanupError(description: "no file") : nil)) }
        }
        // KVO on the task's own Progress — least code for a live percentage,
        // no delegate class needed.
        downloadObservation = task.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            DispatchQueue.main.async { self?.setStatus("⬇️ \(Int(progress.fractionCompleted * 100))%") }
        }
        downloadTask = task
        task.resume()
    }

    /// Move the downloaded model into place. Runs on the URLSession callback
    /// queue (must complete before the completion handler returns). nil = ok.
    private static func installModel(from tmp: URL) -> Error? {
        do {
            let dest = URL(fileURLWithPath: WhisperTranscriber.defaultModelPath())
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.moveItem(at: tmp, to: dest)
            return nil
        } catch { return error }
    }

    private func finishDownload(error: Error?) {
        downloadObservation = nil
        downloadTask = nil
        if let error {
            NSLog("Parla model download failed: \(error)")
            hud.show(.error("Model download failed"))
            setStatus(idleIcon)
            return
        }
        loadModel() // clears the ⚠️ when it succeeds (setStatus(idleIcon) inside)
    }
}

extension AppDelegate: NSMenuDelegate {
    /// Rebuilt from scratch right before the menu shows, so permission/model/
    /// settings status is always current — cheaper than tracking diffs.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(NSMenuItem(title: "Hold fn 🌐 to dictate", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())

        if transcriber == nil {
            if downloadTask != nil {
                let item = NSMenuItem(title: "Downloading base.en…", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            } else {
                let item = NSMenuItem(title: "Download model (base.en, ~148 MB)",
                                       action: #selector(downloadModel), keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        if let error = store.lastError {
            let item = NSMenuItem(title: "⚠️ settings.json invalid — click to open",
                                   action: #selector(openSettings), keyEquivalent: "")
            item.target = self
            item.toolTip = error
            menu.addItem(item)
            menu.addItem(.separator())
        }

        menu.addItem(permissionItem(name: "Microphone", granted: micGranted, pane: "Privacy_Microphone"))
        menu.addItem(permissionItem(name: "Accessibility", granted: axGranted, pane: "Privacy_Accessibility"))
        menu.addItem(.separator())

        let open = NSMenuItem(title: "Open Settings File", action: #selector(openSettings), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(NSMenuItem(title: "Quit Parla", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        setStatus(idleIcon) // menu open is a free moment to reconcile the icon too
    }

    private func permissionItem(name: String, granted: Bool, pane: String) -> NSMenuItem {
        guard !granted else {
            return NSMenuItem(title: "\(name): ✓ granted", action: nil, keyEquivalent: "")
        }
        let item = NSMenuItem(title: "⚠️ \(name): not granted — click to open settings",
                               action: #selector(openPrivacyPane(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = pane
        return item
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
