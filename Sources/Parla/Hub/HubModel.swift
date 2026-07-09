import AppKit
import AVFoundation
import Combine
import ParlaCore
import ServiceManagement

/// UI state for the Hub window, bridging the existing stores. Main-thread only
/// (same contract as HUD) — mutations come from SwiftUI or AppDelegate on main.
final class HubModel: ObservableObject {
    struct WordRow: Identifiable, Equatable {
        let id = UUID()
        var text = ""
    }
    struct SnippetRow: Identifiable, Equatable {
        let id = UUID()
        var trigger = ""
        var expansion = ""
    }

    let store: SettingsStore
    let history: HistoryStore
    // Wired by AppDelegate to its existing actions.
    var onDownloadModel: () -> Void = {}
    var onOpenSettingsFile: () -> Void = {}

    @Published var settings = Settings() { didSet { touch() } }
    @Published var words: [WordRow] = [] { didSet { touch() } }
    @Published var snippets: [SnippetRow] = [] { didSet { touch() } }
    /// settings.json decode error. Editing is disabled while non-nil so the hub
    /// never clobbers a file the user needs to hand-fix (same rule as the menu).
    @Published var loadError: String?
    @Published var saveError: String?
    @Published var modelLoaded = false
    @Published var downloadProgress: Double? // non-nil while downloading
    @Published var historyEntries: [HistoryEntry] = []
    @Published var launchAtLogin = false
    @Published var micGranted = false
    @Published var axGranted = false

    private var loading = false
    private var saveItem: DispatchWorkItem?

    init(store: SettingsStore, history: HistoryStore) {
        self.store = store
        self.history = history
    }

    var modelPath: String {
        settings.whisperModelPath ?? WhisperTranscriber.defaultModelPath()
    }

    /// Re-read everything from disk — called when the window opens/becomes key
    /// so external edits (settings file, new dictations) show up.
    func refresh() {
        loading = true
        defer { loading = false }
        settings = store.load()
        loadError = store.lastError
        words = settings.dictionary.map { WordRow(text: $0) }
        snippets = settings.snippets.sorted { $0.key < $1.key }
            .map { SnippetRow(trigger: $0.key, expansion: $0.value) }
        historyEntries = history.entries
        launchAtLogin = SMAppService.mainApp.status == .enabled
        refreshPermissions()
    }

    func refreshPermissions() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        axGranted = AXIsProcessTrusted()
    }

    func toggleLaunchAtLogin() {
        // Same logic as the menu toggle; fails harmlessly outside a bundled app.
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch { NSLog("Parla: launch-at-login toggle failed: \(error)") }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func clearHistory() {
        history.clear()
        historyEntries = []
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func openPrivacyPane(_ pane: String) {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Debounced whole-file save — same style as the menu's Set API Key path.
    private func touch() {
        guard !loading, loadError == nil else { return }
        saveItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.save() }
        saveItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    private func save() {
        var s = settings
        s.dictionary = words.map { $0.text.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        s.snippets = Dictionary(
            snippets.map { ($0.trigger.trimmingCharacters(in: .whitespaces), $0.expansion) }
                .filter { !$0.0.isEmpty },
            uniquingKeysWith: { _, b in b })
        do {
            try store.save(s)
            saveError = nil
        } catch {
            saveError = "Couldn't save settings: \(error.localizedDescription)"
        }
    }
}
