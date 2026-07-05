import AppKit
import AVFoundation
import ParlaCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let store = SettingsStore()
    let hotkey = HotkeyMonitor()
    let recorder = AudioRecorder()
    var transcriber: WhisperTranscriber?
    var processTask: Task<Void, Never>?
    var isRecording = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setStatus("🎤")
        buildMenu()
        requestPermissions()
        loadModel()

        hotkey.onEdge = { [weak self] edge in
            guard let self else { return }
            switch edge {
            case .down:
                self.isRecording = true
                do { try self.recorder.start(); self.setStatus("🔴") }
                catch { self.setStatus("⚠️"); NSLog("Parla mic start failed: \(error)") }
            case .up:
                self.isRecording = false
                let samples = self.recorder.stop()
                self.setStatus("…")
                // Chain onto the previous finish: whisper ctx is not reentrant,
                // and insertions must land in dictation order.
                self.processTask = Task { [prev = self.processTask] in
                    await prev?.value
                    await self.finish(samples: samples)
                }
            }
        }
        hotkey.start()
    }

    func finish(samples: [Float]) async {
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
        if let text = await pipeline.process(samples: samples) {
            DispatchQueue.main.async { Inserter.insert(text) }
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
