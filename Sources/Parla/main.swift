import AppKit
import AVFoundation
import ParlaCore
import ServiceManagement

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
    let history = HistoryStore()
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
    // Cleanup context is latched at fn-down and read at fn-up like liveTyping/focus.
    var bundleID: String?
    var appName: String?
    var clipboardSnapshot: String?
    var settings = Settings()
    // Command mode (⇧+fn): transform the selection captured at fn-down instead of
    // dictating. Latched at fn-down, read at fn-up like liveTyping/focus.
    var commandMode = false
    var commandSelection = ""
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
            case .down(let command):
                if command {
                    // Command mode: capture the selection NOW; refuse early (no
                    // recording) when there's nothing safe to transform.
                    let focus = Inserter.focusTarget()
                    guard focus != .secure else {
                        self.hud.show(.error("No transforms in password fields")); return
                    }
                    guard let selection = Inserter.selectedText() else {
                        self.hud.show(.error("Select text first")); return
                    }
                    self.generation += 1 // invalidates any pending cleaned-swap
                    self.commandMode = true
                    self.commandSelection = selection
                    self.focus = focus
                    self.liveTyping = false // never stream a transform
                    do { try self.recorder.start() }
                    catch {
                        self.setStatus("⚠️"); self.hud.show(.error("Mic failed"))
                        NSLog("Parla mic start failed: \(error)"); return
                    }
                    self.isRecording = true
                    self.setStatus("🔴"); self.hud.show(.listening(command: true)); Sound.start()
                    return
                }
                self.commandMode = false
                self.clipboardSnapshot = NSPasteboard.general.string(forType: .string)
                let frontApp = NSWorkspace.shared.frontmostApplication
                self.bundleID = frontApp?.bundleIdentifier
                self.appName = frontApp?.localizedName
                let settings = self.store.load()
                self.settings = settings
                if let url = cleanupWarmURL(
                    settings: settings, env: ProcessInfo.processInfo.environment) {
                    var request = URLRequest(url: url)
                    request.httpMethod = "HEAD"
                    request.timeoutInterval = 5
                    URLSession.shared.dataTask(with: request).resume()
                }
                self.generation += 1 // invalidates any pending cleaned-swap
                self.isRecording = true
                // typed is NOT reset here: a still-queued finish from the previous
                // dictation must see it to erase that dictation's live text.
                do { try self.recorder.start(); self.setStatus("🔴"); self.hud.show(.listening(command: false)); Sound.start() }
                catch {
                    self.setStatus("⚠️"); self.hud.show(.error("Mic failed"))
                    NSLog("Parla mic start failed: \(error)")
                    return
                }
                // Focused field gets the final paste at fn-up; no focus is
                // clipboard-only (see finish).
                self.focus = Inserter.focusTarget()
                // Live in-field typing is hard-disabled: keystrokes posted while
                // the user physically holds fn merge with the modifier (fn+A
                // opens the Dock, ⇧← becomes select-to-Home), and Chromium never
                // answers the ⌘C verify probe — revisions stall on the first
                // wrong hypothesis and the finalize demotes to clipboard-only.
                // Shadow streaming below keeps the speed win; the transcript
                // lands as ONE paste at fn-up, after the modifier is released.
                // Re-enable only with a verified fix for the fn-merge + probe.
                self.liveTyping = false
                // Shadow streaming: run the pass loop on EVERY dictation, not just
                // live-typing ones, so finish() only ever pays for the unconfirmed
                // tail. Actual typing inside the loop is gated on liveTyping.
                if let transcriber = self.transcriber {
                    // Chain onto the previous finish so partial passes never run
                    // concurrently with the final pass (whisper ctx isn't reentrant).
                    self.processTask = Task { [prev = self.processTask] in
                        await prev?.value
                        await self.stream(transcriber: transcriber)
                    }
                }
            case .up(let short):
                // A command down that refused (bad focus/selection) never started
                // recording; the paired fn-up has nothing to finish.
                guard self.isRecording else { return }
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
                if self.commandMode {
                    // Transform path: instruction → LLM → replace selection. Runs
                    // on the processTask chain (whisper ctx not reentrant).
                    let selection = self.commandSelection
                    let gen = self.generation
                    let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                    self.setStatus("…"); self.hud.show(.transcribing)
                    self.processTask = Task { [prev = self.processTask] in
                        await prev?.value
                        await self.transform(samples: samples, selection: selection, gen: gen, bundleID: bundleID)
                    }
                    return
                }
                // Capture this dictation's context now: a quick next fn-press
                // rewrites the latched state before finish runs.
                let live = self.liveTyping
                let focus = self.focus
                let gen = self.generation
                let bundleID = self.bundleID
                let appName = self.appName
                let clipboardSnapshot = self.clipboardSnapshot
                let settings = self.settings
                self.setStatus("…")
                self.hud.show(.transcribing)
                // Chain onto the previous work (any in-flight streaming pass):
                // whisper ctx is not reentrant, and insertions must land in
                // dictation order.
                self.processTask = Task { [prev = self.processTask] in
                    await prev?.value
                    await self.finish(samples: samples, live: live, focus: focus, gen: gen, bundleID: bundleID,
                                      appName: appName, clipboardSnapshot: clipboardSnapshot, settings: settings)
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

    func finish(samples: [Float], live: Bool, focus: Inserter.FocusTarget, gen: Int,
                bundleID: String?, appName: String?, clipboardSnapshot: String?, settings: Settings) async {
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
        let pipeline = Pipeline(
            transcribe: { samples, prompt in transcriber.transcribe(samples, initialPrompt: prompt) },
            cleanup: { transcript, ctx in
                // A factory throw (misconfig / no key) lands in Pipeline's raw-transcript fallback.
                try await makeCleanupClient(settings: settings, env: ProcessInfo.processInfo.environment)
                    .clean(transcript: transcript, context: ctx)
            },
            settings: { settings },
            frontAppName: { appName })

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

        let cleanTask: Task<(text: String, failed: Bool), Never>?
        if focus != .secure {
            cleanTask = Task { await pipeline.clean(transcript: raw) }
        } else {
            cleanTask = nil
        }

        // Instant finalize: land the raw transcript NOW; the LLM polish swaps in
        // behind it without blocking the user.
        let landing: Landing = await MainActor.run {
            let typedCount = self.typed.count // graphemes streamed live so far
            defer { self.typed = "" }
            // Never log the transcript for a secure field — it's plausibly a
            // password, and unified logging is readable in Console.
            NSLog("Parla finish: raw=%@ live=%d focus=%d typed=%d",
                  focus == .secure ? "<secure>" : insertText, live ? 1 : 0, focus == .none ? 0 : 1, typedCount)
            switch (live, focus) {
            case (_, .secure):
                // Password field: on-device transcript to the clipboard only.
                // Never paste (it isn't a normal field) and never cloud-polish
                // (it's plausibly a password) — the guard below skips clean().
                NSLog("Parla finish path: secure field, clipboard only")
                Inserter.copy(insertText)
                hud.show(.copied)
                return .clipboard
            case (true, _):
                // Diff-based finalize: fix only the diverging tail of the
                // live-typed text instead of erasing and retyping all of it —
                // the streamed text usually already equals the final text.
                let d = LiveTyper.diff(typed: self.typed, new: insertText)
                if typedCount == 0 {
                    // Nothing streamed (short utterance): single paste, and
                    // insert() already leaves insertText in the clipboard.
                    NSLog("Parla finish path: nothing typed, focused paste")
                    Inserter.insert(insertText)
                } else if Inserter.canEraseTyped(self.typed) {
                    NSLog("Parla finish path: ax-verified diff finalize (erase %d)", d.erase)
                    Inserter.typeBackspaces(d.erase)
                    Inserter.typeUnicode(d.append)
                    Inserter.copy(insertText) // escape-hatch invariant: raw transcript stays in the clipboard
                } else if d.erase == 0, d.append.isEmpty {
                    // Streamed text already IS the final text — no keystrokes.
                    NSLog("Parla finish path: streamed text already final")
                    Inserter.copy(insertText)
                } else if Inserter.selectBackAndVerify(String(self.typed.suffix(d.erase))) {
                    // Opaque field: the diverging suffix is now the live
                    // selection — typing replaces exactly it (as in stream()).
                    NSLog("Parla finish path: select-verified diff finalize (erase %d)", d.erase)
                    if d.append.isEmpty {
                        Inserter.typeBackspaces(1) // pure shrink: delete the verified selection
                    } else {
                        Inserter.typeUnicode(d.append) // replaces the verified live selection
                    }
                    Inserter.copy(insertText)
                } else {
                    // Can't prove the field still ends with our streamed text —
                    // leave it in place and offer the transcript instead.
                    NSLog("Parla finish path: unverified, clipboard only")
                    Inserter.copy(insertText)
                    hud.show(.polishing)
                    return .clipboard
                }
                hud.show(.polishing)
                return .field
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
        guard focus != .secure, let cleanTask else { return }

        // Async polish: cleanup, then swap raw → cleaned with the same
        // verification machinery. Still on the processTask chain, so a queued
        // next dictation starts only after this resolves (insertion order holds).
        let cleanResult = await cleanTask.value
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
                    if !cleanResult.failed, settings.restoreClipboard { Inserter.restore(clipboardSnapshot) }
                    hud.show(cleanResult.failed ? .rawFallback : .done)
                    return
                }
                if Inserter.canEraseTyped(insertText) {
                    NSLog("Parla swap path: ax-verified tail swap (erase %d)", plan.eraseTail.count)
                    Inserter.typeBackspaces(plan.eraseTail.count)
                    Inserter.typeUnicode(plan.replacement)
                    Inserter.copy(cleaned) // escape-hatch invariant: full final text in the clipboard
                    // Opt-in: the point of restoreClipboard is to replace that
                    // escape-hatch copy with whatever the user had before, now
                    // that the swap is verified to have landed in-field.
                    if settings.restoreClipboard { Inserter.restore(clipboardSnapshot) }
                    hud.show(.done)
                } else {
                    // AX can't prove the field still ends with our paste. No
                    // select-back copy-probe fallback here: it parks a probe
                    // marker in the clipboard for up to 600ms per dictation
                    // (immortalized by clipboard managers), flicker-selects the
                    // user's text, and Chromium never answers the ⌘C anyway.
                    // Leave the raw text alone; cleaned to the clipboard.
                    NSLog("Parla swap path: unverified, cleaned to clipboard")
                    Inserter.copy(cleaned)
                    hud.show(.cleanedCopied)
                }
            }
        }

        // Record once per dictation (secure fields returned above; raw is
        // non-nil past the guard). cleaned is dropped when cleanup failed or
        // matched raw. Append on main to serialize with menu reads/Clear.
        if settings.historyEnabled {
            let cleanedForHistory = (!cleanResult.failed && cleanResult.text != raw) ? cleanResult.text : nil
            let entry = HistoryEntry(raw: raw, cleaned: cleanedForHistory, appName: appName)
            DispatchQueue.main.async { self.history.append(entry) }
        }
    }

    /// Command mode: transcribe the spoken instruction on-device, transform the
    /// selection captured at fn-down via the cleanup LLM, and replace the live
    /// selection (paste) if it's still intact — else park the result in the
    /// clipboard. Runs on the processTask chain like finish().
    func transform(samples: [Float], selection: String, gen: Int, bundleID: String?) async {
        let hud = self.hud
        defer {
            DispatchQueue.main.async {
                guard !self.isRecording else { return }
                self.setStatus(self.idleIcon)
            }
        }
        guard let transcriber else {
            NSLog("Parla transform: no whisper model loaded")
            DispatchQueue.main.async { hud.show(.error("No whisper model")) }
            return
        }
        let settings = store.load()
        // Same min-audio floor as dictation: too short/silent = no instruction.
        guard TextRules.audioWorthTranscribing(sampleCount: samples.count, rms: AudioRecorder.rms(samples)) else {
            NSLog("Parla transform: audio below min-audio floor")
            DispatchQueue.main.async { hud.show(.error("No command heard")) }
            return
        }
        let prompt = settings.dictionary.isEmpty ? nil : settings.dictionary.joined(separator: ", ")
        let instruction = transcriber.transcribe(samples, initialPrompt: prompt)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else {
            NSLog("Parla transform: empty instruction")
            DispatchQueue.main.async { hud.show(.error("No command heard")) }
            return
        }

        // Transform via the cleanup client DIRECTLY (not Pipeline.clean): its
        // raw-transcript fallback would return the spoken instruction on failure,
        // which must never be pasted over the user's selection. A failure here is
        // a hard failure — nothing inserted, nothing copied.
        let ctx = CleanupContext(dictionary: settings.dictionary, snippets: [:], appName: nil, selection: selection)
        let transformed: String
        do {
            let out = try await makeCleanupClient(settings: settings, env: ProcessInfo.processInfo.environment)
                .clean(transcript: instruction, context: ctx)
            transformed = CleanupSanitizer.sanitize(out)
        } catch {
            NSLog("Parla transform failed: \(error)")
            DispatchQueue.main.async { hud.show(.error("Transform failed")) }
            return
        }
        guard !transformed.isEmpty else {
            NSLog("Parla transform: empty result")
            DispatchQueue.main.async { hud.show(.error("Transform failed")) }
            return
        }
        // Terminal newline guard: a multi-line result pasted into a terminal would
        // run each line — same insertion-safety invariant as dictation.
        let result = TextRules.isTerminal(bundleID: bundleID) ? TextRules.flattenForTerminal(transformed) : transformed

        await MainActor.run {
            guard gen == self.generation else {
                // A newer dictation owns the field/HUD — no keystrokes. Park the
                // result in the clipboard so it isn't lost.
                NSLog("Parla transform: stale generation, clipboard fallback")
                Inserter.copy(result)
                return
            }
            // Only replace if the selection is provably still ours; otherwise the
            // user clicked away — clipboard it rather than paste over new context.
            if Inserter.selectedText() == selection {
                NSLog("Parla transform: selection intact, replacing")
                Inserter.insert(result) // paste replaces the live selection
                Sound.finish()
                hud.show(.done)
            } else {
                NSLog("Parla transform: selection changed, clipboard fallback")
                Inserter.copy(result)
                hud.show(.cleanedCopied)
            }
        }
        // ponytail: no history recording for transforms (v1) — the instruction
        // isn't a dictation, and the source text is the user's, not ours.
    }

    /// ~300ms between streaming passes, sliced so fn-up (isRecording flipping
    /// false) unblocks the queued finish() within ~50ms instead of sitting out
    /// the full sleep as dead time.
    private func pauseBetweenPasses() async {
        for _ in 0..<6 {
            guard isRecording else { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Streaming pass loop: while fn is held, re-transcribe the unconfirmed
    /// tail of the buffer. Runs for EVERY dictation (shadow streaming) so the
    /// confirmed-prefix window is always built and finish() stays O(tail);
    /// the erase+append typing is additionally gated on liveTyping. Runs on
    /// the processTask chain (serialized with the final pass). Once the tail
    /// exceeds ~15s a confirmed prefix is frozen at a quiet spot (see
    /// StreamWindow) so each pass stays O(tail), not O(n²).
    ///
    /// Passes abort cooperatively at fn-up (shouldAbort) and return "" — every
    /// transcribe here is followed by an isRecording recheck that BREAKS before
    /// the result is used, so an aborted "" is never committed as a hypothesis
    /// or a confirmed head. The handoff below still runs after a break: it only
    /// carries state from completed passes.
    func stream(transcriber: WhisperTranscriber) async {
        let dict = store.load().dictionary
        var confirmed = "" // frozen transcript of snap[0..<cut]
        var cut = 0
        var lastCount = 0
        // ponytail: isRecording is written on main, read here — benign stop-flag race.
        while self.isRecording {
            let snap = self.recorder.snapshot()
            guard snap.count - lastCount >= 8000 else { // <0.5s new audio, wait
                await pauseBetweenPasses()
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
                    initialPrompt: StreamWindow.tailPrompt(dictionary: dict, confirmed: confirmed),
                    shouldAbort: { !self.isRecording })
                // Aborted head pass returns "": committing the cut would silently
                // drop the head's text from confirmed. Only commit a completed pass.
                guard self.isRecording else { break }
                confirmed = StreamWindow.join(confirmed, head)
                cut += rel
                tail = Array(tail[rel...])
                NSLog("Parla stream: cut at %.1fs, confirmed %d chars",
                      Double(cut) / 16_000, confirmed.count)
            }
            let tailText = transcriber.transcribe(
                tail,
                initialPrompt: StreamWindow.tailPrompt(dictionary: dict, confirmed: confirmed),
                shouldAbort: { !self.isRecording })
            // Aborted pass returns "": never treat it as a new hypothesis —
            // live typing would erase everything the user sees. finish() takes over.
            guard self.isRecording else { break }
            let text = StreamWindow.join(confirmed, tailText)
            await MainActor.run {
                // Shadow mode: window-building only, never touch the field.
                guard self.liveTyping else { return }
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
            await pauseBetweenPasses()
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
        if let transcriber {
            // First whisper inference pays Metal shader/graph setup (hundreds of ms) —
            // warm it now on throwaway silence so the user's first real dictation
            // isn't the one paying it. Queued on processTask like every other
            // transcribe call: the whisper ctx isn't reentrant, and loadModel() can
            // also fire post-download while the app is already live.
            processTask = Task { [prev = processTask] in
                await prev?.value
                // Preemptible: a dictation started before warmup finishes takes
                // priority — it eats the cold start instead of queueing behind it.
                _ = transcriber.transcribe([Float](repeating: 0, count: 16_000), initialPrompt: nil,
                                           shouldAbort: { self.isRecording })
                NSLog("Parla: whisper warmup done")
            }
        }
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

    /// Paste-an-API-key box: writes anthropicApiKey to settings.json, which
    /// every dictation re-reads — no in-memory refresh needed.
    @objc func setAPIKey() {
        var settings = store.load()
        if store.lastError != nil {
            // Saving over a broken settings.json would clobber the user's file
            // with defaults — send them to fix it instead (same rule as openSettings).
            NSWorkspace.shared.open(store.url)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Anthropic API Key"
        alert.informativeText = "Used to clean up transcripts. Stored in settings.json (remove it there to clear)."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = settings.anthropicApiKey == nil ? "sk-ant-…" : "•••••••• (key currently set)"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true) // LSUIElement app: modal needs focus
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return } // empty Save = no change, not key removal
        settings.anthropicApiKey = key
        do { try store.save(settings) } catch { hud.show(.error("Couldn't save settings")) }
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

        addHistoryItems(to: menu)

        menu.addItem(permissionItem(name: "Microphone", granted: micGranted, pane: "Privacy_Microphone"))
        menu.addItem(permissionItem(name: "Accessibility", granted: axGranted, pane: "Privacy_Accessibility"))
        menu.addItem(.separator())

        let launch = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launch.target = self
        launch.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(launch)
        menu.addItem(.separator())

        let apiKey = NSMenuItem(title: "Set API Key…", action: #selector(setAPIKey), keyEquivalent: "")
        apiKey.target = self
        menu.addItem(apiKey)
        let open = NSMenuItem(title: "Open Settings File", action: #selector(openSettings), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(NSMenuItem(title: "Quit Parla", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        setStatus(idleIcon) // menu open is a free moment to reconcile the icon too
    }

    /// "Paste Last Dictation" + a "Recent" submenu (up to 8, newest first) with
    /// a "Clear History" action. Nil action ⇒ auto-disabled when empty.
    private func addHistoryItems(to menu: NSMenu) {
        let entries = history.entries
        let pasteLast = NSMenuItem(title: "Paste Last Dictation",
                                    action: entries.isEmpty ? nil : #selector(pasteLastDictation),
                                    keyEquivalent: "")
        pasteLast.target = self
        menu.addItem(pasteLast)

        let recent = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        if entries.isEmpty {
            let none = NSMenuItem(title: "No dictations yet", action: nil, keyEquivalent: "")
            none.isEnabled = false
            sub.addItem(none)
        } else {
            for entry in entries.prefix(8) {
                let item = NSMenuItem(title: Self.menuTitle(entry.best),
                                       action: #selector(pasteRecent(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.best
                item.toolTip = entry.appName
                sub.addItem(item)
            }
            sub.addItem(.separator())
            let clear = NSMenuItem(title: "Clear History", action: #selector(clearHistory), keyEquivalent: "")
            clear.target = self
            sub.addItem(clear)
        }
        recent.submenu = sub
        menu.addItem(recent)
        menu.addItem(.separator())
    }

    /// First non-empty line of `text`, capped ~40 chars with an ellipsis.
    static func menuTitle(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.count > 40 ? String(line.prefix(40)) + "…" : line
    }

    @objc func pasteLastDictation() {
        guard let best = history.entries.first?.best else { return }
        insertFromMenu(best)
    }

    @objc func pasteRecent(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        insertFromMenu(text)
    }

    @objc func clearHistory() { history.clear() }

    /// SMAppService registration only works from the installed .app bundle
    /// (Info.plist + code signature). ponytail: running via `swift run` still
    /// shows the toggle, it'll just log-and-HUD the thrown error instead of
    /// crashing — fine for dev, real usage is always the bundled app.
    @objc func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Parla: launch-at-login toggle failed: \(error)")
            hud.show(.error("Launch at Login failed"))
        }
    }

    /// Menu actions fire once the menu has dismissed, but focus handoff back to
    /// the previous app can lag the click — a paste landing too early hits
    /// nothing. Delay a beat. insert() sets the clipboard first regardless, so
    /// worst case the text is still there to paste by hand.
    private func insertFromMenu(_ text: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { Inserter.insert(text) }
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
