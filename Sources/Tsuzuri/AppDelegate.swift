import AppKit
import AVFoundation
import TsuzuriCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let transcriber = Transcriber()
    private let recorder = AudioRecorder()
    private let overlay = Overlay()
    private lazy var hotkey = HotkeyMonitor(trigger: Settings.trigger)

    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var modelReady = false
    private var recording = false
    private var recordingStarted = Date()
    private var maxDurationWork: DispatchWorkItem?
    private var trustTimer: Timer?
    /// Recent results, newest first. Kept in memory only so nothing said is lost
    /// when the paste goes nowhere.
    private var history: [String] = []
    private static let historyLimit = 10
    private var status = String(localized: "Starting…") { didSet { statusLine.title = status } }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        hotkey.onStart = { [weak self] in self?.startRecording() }
        hotkey.onStop = { [weak self] in self?.stopRecording() }
        hotkey.onCancel = { [weak self] in self?.cancelRecording() }
        recorder.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.overlay.setLevel(level) }
        }
        recorder.onInterrupted = { [weak self] in
            // The mic changed or went away mid-recording: keep what was captured.
            Log.write("input device changed while recording")
            self?.hotkey.reset()
            self?.stopRecording()
        }
        // Debug hooks (scripts/debug.sh) only when asked for: any process can post these
        // notifications, and dictateFile pastes into the frontmost app.
        if ProcessInfo.processInfo.environment["TSUZURI_DEBUG_HOOKS"] == "1" {
            DistributedNotificationCenter.default().addObserver(
                self, selector: #selector(debugDictateFile(_:)), name: .init("tsuzuri.debug.dictateFile"), object: nil)
            DistributedNotificationCenter.default().addObserver(
                self, selector: #selector(debugOverlay(_:)), name: .init("tsuzuri.debug.overlay"), object: nil)
        }

        Task { _ = await AudioRecorder.requestPermission() }
        waitForAccessibility()
        loadModel(Settings.model)
        if Settings.polish { loadPolisher() }
    }

    // MARK: - Setup

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon(recording: false)
        rebuildMenu()
    }

    private func setIcon(recording: Bool) {
        let name = recording ? "waveform.circle.fill" : "waveform"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Tsuzuri")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        // statusLine is reused across rebuilds; AppKit throws if it is still in the old menu.
        statusLine.menu?.removeItem(statusLine)
        statusLine.title = status
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        let recent = NSMenu()
        if history.isEmpty {
            let empty = NSMenuItem(title: String(localized: "(None yet)"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recent.addItem(empty)
        } else {
            for text in history {
                let title = text.count > 40 ? text.prefix(40) + "…" : text
                let item = item(String(title), #selector(copyHistoryItem(_:)))
                item.representedObject = text
                item.toolTip = text
                recent.addItem(item)
            }
            recent.addItem(.separator())
            recent.addItem(item(String(localized: "Clear"), #selector(clearHistory)))
        }
        addSubmenu(recent, title: String(localized: "Recent (Click to Copy)"), to: menu)
        menu.addItem(.separator())

        let models = NSMenu()
        for model in ASRModel.allCases {
            let item = NSMenuItem(title: model.isInstalled ? model.menuTitle : String(localized: "\(model.menuTitle) (not downloaded)"),
                                  action: #selector(selectModel(_:)), keyEquivalent: "")
            item.representedObject = model.rawValue
            item.state = model == Settings.model ? .on : .off
            item.isEnabled = model.isInstalled
            item.target = self
            models.addItem(item)
        }
        addSubmenu(models, title: String(localized: "Model"), to: menu)

        let languages = NSMenu()
        for language in RecognitionLanguage.allCases {
            let item = NSMenuItem(title: language.title, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.representedObject = language.rawValue
            item.state = language == Settings.language ? .on : .off
            item.target = self
            languages.addItem(item)
        }
        addSubmenu(languages, title: String(localized: "Spoken Language"), to: menu)

        let polishTitle = String(localized: "Polish")
        let polish = item(PolishModel.isInstalled ? polishTitle : String(localized: "\(polishTitle) (not downloaded)"),
                          #selector(togglePolish))
        polish.state = Settings.polish && PolishModel.isInstalled ? .on : .off
        polish.isEnabled = PolishModel.isInstalled
        polish.toolTip = String(localized: "After recognition, a small local model adds punctuation, removes filler words, applies self-corrections and writes numbers as digits. Skipped in terminals.")
        menu.addItem(polish)

        let triggers = NSMenu()
        for trigger in TriggerKey.allCases {
            let item = NSMenuItem(title: trigger.title, action: #selector(selectTrigger(_:)), keyEquivalent: "")
            item.representedObject = trigger.rawValue
            item.state = trigger == Settings.trigger ? .on : .off
            item.target = self
            triggers.addItem(item)
        }
        addSubmenu(triggers, title: String(localized: "Shortcut (Hold to Talk / Tap to Toggle)"), to: menu)

        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Open Accessibility Settings…"), #selector(openAccessibilitySettings)))
        menu.addItem(item(String(localized: "Open Microphone Settings…"), #selector(openMicrophoneSettings)))
        menu.addItem(item(String(localized: "Paste Test (Pastes into the Current Window in 3 s)"), #selector(pasteSelfTest)))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Quit Tsuzuri"), #selector(quit), key: "q"))
        statusItem.menu = menu
    }

    private func addSubmenu(_ submenu: NSMenu, title: String, to menu: NSMenu) {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.submenu = submenu
        menu.addItem(parent)
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    /// Global key monitors only deliver events once the app is trusted, so
    /// (re)install them as soon as the user grants Accessibility.
    private func waitForAccessibility() {
        if Paster.isTrusted {
            hotkey.start()
            refreshStatus()
            return
        }
        Paster.promptForAccessibility()
        status = String(localized: "Accessibility permission needed (System Settings → Privacy & Security)")
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self, Paster.isTrusted else { return }
                timer.invalidate()
                self.hotkey.start()
                self.refreshStatus()
            }
        }
    }

    private func refreshStatus() {
        if !Paster.isTrusted {
            status = String(localized: "Accessibility permission needed (System Settings → Privacy & Security)")
        } else if !modelReady {
            status = String(localized: "Loading model…")
        } else {
            status = String(localized: "Ready · hold \(Settings.trigger.title) to talk")
        }
    }

    private func loadModel(_ model: ASRModel) {
        modelReady = false
        refreshStatus()
        Task {
            do {
                let seconds = try await transcriber.load(model)
                Log.write(String(format: "loaded %@ in %.2fs", model.rawValue, seconds))
                modelReady = true
            } catch {
                Log.write("load failed: \(error)")
                status = String(localized: "Model failed to load: \(model.rawValue)")
                return
            }
            refreshStatus()
        }
    }

    private func loadPolisher() {
        guard PolishModel.isInstalled else { return }
        Task {
            do {
                let seconds = try await transcriber.loadPolisher()
                Log.write(String(format: "loaded %@ in %.2fs", PolishModel.directoryName, seconds))
            } catch {
                Log.write("polish model load failed: \(error)")
            }
        }
    }

    // MARK: - Dictation

    private func startRecording() {
        guard !recording else { return }
        guard modelReady else {
            overlay.show(.message(String(localized: "Model is still loading…")))
            overlay.hide(after: 1.2)
            hotkey.reset()
            return
        }
        do {
            try recorder.start()
        } catch {
            Log.write("recorder failed: \(error)")
            overlay.show(.message((error as? RecorderError)?.message ?? String(localized: "Can't record")))
            overlay.hide(after: 2)
            hotkey.reset()
            return
        }
        recording = true
        recordingStarted = Date()
        setIcon(recording: true)
        overlay.show(.listening)
        let work = DispatchWorkItem { [weak self] in
            self?.hotkey.reset()
            self?.stopRecording()
        }
        maxDurationWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 180, execute: work)
    }

    private func stopRecording() {
        guard recording else { return }
        recording = false
        maxDurationWork?.cancel()
        setIcon(recording: false)
        let samples = recorder.stop()
        guard samples.count > Transcriber.sampleRate / 4 else {
            overlay.hide()
            return
        }
        transcribeAndPaste(samples)
    }

    private func cancelRecording() {
        guard recording else { return }
        recording = false
        maxDurationWork?.cancel()
        setIcon(recording: false)
        _ = recorder.stop()
        overlay.show(.message(String(localized: "Canceled")))
        overlay.hide(after: 0.8)
    }

    private func transcribeAndPaste(_ samples: [Float]) {
        overlay.show(.transcribing)
        let language = Settings.language.modelValue
        let context = Settings.context
        // The app the text is for; decided now, before the user can switch away.
        let targetApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let polish = PolishPolicy.shouldPolish(bundleID: targetApp)
        Task {
            do {
                let result = try await transcriber.transcribe(samples, language: language, context: context)
                Log.write(String(format: "%.2fs in → %.2fs speech, %.3fs, RTF %.3f, %@: %@",
                                 result.inputSeconds, result.audioSeconds, result.elapsed, result.rtf,
                                 result.language ?? "-", Log.redact(result.text)))
                if result.text.isEmpty {
                    overlay.show(.message(String(localized: "No speech heard")))
                    overlay.hide(after: 1)
                    return
                }
                var text = result.text
                if polish {
                    let p = await transcriber.polish(result.text)
                    text = p.text
                    Log.write(String(format: "polish %.0f ms, %d→%d tokens, %@: %@ ⇒ %@",
                                     p.elapsed * 1000, p.promptTokens, p.generatedTokens,
                                     p.rejection.map { "kept raw (\($0))" } ?? "used",
                                     Log.redact(p.raw), Log.redact(p.candidate)))
                } else if Settings.polish {
                    Log.write("polish skipped in \(targetApp ?? "-")")
                }
                addToHistory(text)
                if Paster.isTrusted {
                    let focus = await FocusInfo.current()
                    let outcome = Paster.insert(text, focus: focus)
                    Log.write("focus \(focus.app) \(focus.role) → \(outcome)")
                    switch outcome {
                    case .pasted:
                        overlay.show(.message(text))
                        overlay.hide(after: 1.2)
                    case .pastedAndCopied:
                        overlay.show(.copied(text))
                        overlay.hide(after: 1.5)
                    case .copied:
                        overlay.show(.copied(String(localized: "Copied · ⌘V to paste: \(text)")))
                        overlay.hide(after: 2.5)
                    }
                } else {
                    // Without Accessibility we cannot send ⌘V; leave the text on the clipboard.
                    Paster.copy(text)
                    overlay.show(.copied(String(localized: "Copied (Accessibility not granted)")))
                    overlay.hide(after: 1.5)
                }
            } catch {
                Log.write("transcribe failed: \(error)")
                overlay.show(.message(String(localized: "Recognition failed")))
                overlay.hide(after: 1.5)
            }
        }
    }

    private func addToHistory(_ text: String) {
        history.removeAll { $0 == text }
        history.insert(text, at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
        rebuildMenu()
    }

    // MARK: - Menu actions

    @objc private func copyHistoryItem(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        Paster.copy(text)
        overlay.show(.copied(String(localized: "Copied: \(text)")))
        overlay.hide(after: 1.5)
    }

    @objc private func clearHistory() {
        history.removeAll()
        rebuildMenu()
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let model = ASRModel(rawValue: raw) else { return }
        Settings.model = model
        rebuildMenu()
        loadModel(model)
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let language = RecognitionLanguage(rawValue: raw) else { return }
        Settings.language = language
        rebuildMenu()
    }

    @objc private func togglePolish() {
        Settings.polish.toggle()
        rebuildMenu()
        if Settings.polish {
            loadPolisher()
        } else {
            Task { await transcriber.unloadPolisher() }
        }
    }

    @objc private func selectTrigger(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let trigger = TriggerKey(rawValue: raw) else { return }
        Settings.trigger = trigger
        hotkey.trigger = trigger
        hotkey.reset()
        rebuildMenu()
        refreshStatus()
    }

    @objc private func openAccessibilitySettings() {
        Paster.promptForAccessibility()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openMicrophoneSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    @objc private func pasteSelfTest() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            Paster.paste("綴 " + String(localized: "Tsuzuri paste test") + ": 中文、English、日本語 ✓")
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    /// Debug hook: transcribes a file and pastes the result into the frontmost app,
    /// exercising everything except the microphone. Post with `scripts/debug.sh dictate FILE`.
    @objc private func debugDictateFile(_ note: Notification) {
        guard let path = note.object as? String else { return }
        do {
            let samples = try AudioFile.load16k(URL(fileURLWithPath: path))
            transcribeAndPaste(samples)
        } catch {
            Log.write("debug dictate failed: \(error)")
        }
    }
}

extension AppDelegate {
    /// Debug hook for screenshots: `scripts/debug.sh overlay listening|transcribing|<text>`.
    @objc fileprivate func debugOverlay(_ note: Notification) {
        switch note.object as? String {
        case "listening":
            overlay.show(.listening)
            for i in 0..<30 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.05) {
                    self.overlay.setLevel(Float(0.35 + 0.3 * sin(Double(i) * 0.9)))
                }
            }
        case "transcribing": overlay.show(.transcribing)
        case "hide", nil: overlay.hide()
        case let text?: overlay.show(.message(text))
        }
    }
}

enum Log {
    private static let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Tsuzuri.log")

    /// What was said stays out of the log unless `defaults write com.kanaworks.tsuzuri logText -bool true`.
    static func redact(_ text: String) -> String {
        UserDefaults.standard.bool(forKey: "logText") ? text : "<\(text.count) chars>"
    }

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
