import AppKit
import AVFoundation
import TsuzuriCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let transcriber = Transcriber()
    private let recorder = AudioRecorder()
    private let overlay = Overlay()
    private let permissions = PermissionsWindow()
    private lazy var hotkey = HotkeyMonitor(trigger: Settings.trigger)

    private var statusItem: NSStatusItem!
    private var languagesMenu: NSMenu?
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var modelReady = false
    /// Shown instead of "Loading model…" when the speech model is missing or failed to load.
    private var modelError: String?
    private var modelGeneration = 0
    /// A model is loaded and serving dictations while another one loads.
    private var modelSwitching = false
    private var recording = false
    private var recordingStarted = Date()
    private var maxDurationWork: DispatchWorkItem?
    private var trustTimer: Timer?
    /// Results are pasted one after another, in the order they were spoken.
    private var lastDelivery: Task<Void, Never>?
    private var permissionsTimer: Timer?
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
        // Debug hooks (scripts/debug.sh) exist only in builds made with DEBUG_HOOKS=1 and are
        // registered only when started with TSUZURI_DEBUG_HOOKS=1: any process can post these
        // notifications, and dictateFile pastes into the frontmost app. Never in releases.
        #if TSUZURI_DEBUG_HOOKS
        if ProcessInfo.processInfo.environment["TSUZURI_DEBUG_HOOKS"] == "1" {
            DistributedNotificationCenter.default().addObserver(
                self, selector: #selector(debugDictateFile(_:)), name: .init("tsuzuri.debug.dictateFile"), object: nil)
            DistributedNotificationCenter.default().addObserver(
                self, selector: #selector(debugOverlay(_:)), name: .init("tsuzuri.debug.overlay"), object: nil)
            DistributedNotificationCenter.default().addObserver(
                self, selector: #selector(debugMenu(_:)), name: .init("tsuzuri.debug.menu"), object: nil)
            DistributedNotificationCenter.default().addObserver(
                self, selector: #selector(debugPermissions(_:)), name: .init("tsuzuri.debug.permissions"), object: nil)
        }
        #endif

        // The permissions window asks for the microphone and explains Accessibility; without
        // Accessibility the shortcut key is never seen, so pressing it can't tell the user anything.
        if PermissionsWindow.needed { showPermissions() }
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
        // A warning badge while the shortcut can't work (no Accessibility permission yet).
        let name = recording ? "waveform.circle.fill" : Paster.isTrusted ? "waveform" : "waveform.badge.exclamationmark"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Tsuzuri")
            ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: "Tsuzuri")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        // statusLine is reused across rebuilds; AppKit throws if it is still in the old menu.
        statusLine.menu?.removeItem(statusLine)
        statusLine.title = status
        // While a permission is missing, the status line opens the permissions window.
        let needsPermission = !Paster.isTrusted
        statusLine.isEnabled = needsPermission
        statusLine.action = needsPermission ? #selector(showPermissions) : nil
        statusLine.target = self
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
        languages.addItem(languageItem(.auto))
        languages.addItem(note(String(localized: "Detects the language of each dictation. Tuned for Chinese, English, Japanese and mixing them.")))
        languages.addItem(note(String(localized: "Also recognizes 22 Chinese dialects, such as Sichuanese, Wu and Min Nan.")))
        languages.addItem(.separator())
        RecognitionLanguage.featured.forEach { languages.addItem(languageItem($0)) }
        languages.addItem(.separator())
        RecognitionLanguage.others.forEach { languages.addItem(languageItem($0)) }
        languagesMenu = languages
        let current = Settings.language.language?.nativeName ?? String(localized: "Auto")
        addSubmenu(languages, title: String(localized: "Spoken Language: \(current)"), to: menu)

        let polishTitle = String(localized: "Polish")
        let polish = item(PolishModel.isInstalled ? polishTitle : String(localized: "\(polishTitle) (not downloaded)"),
                          #selector(togglePolish))
        polish.state = Settings.polish && PolishModel.isInstalled ? .on : .off
        polish.isEnabled = PolishModel.isInstalled
        polish.toolTip = String(localized: "After recognition, a small local model adds punctuation, removes filler words, applies self-corrections and writes numbers as digits. Only for \(polishLanguages); other languages are inserted as recognized. Skipped in terminals.")
        menu.addItem(polish)
        menu.addItem(note(String(localized: "Only for \(polishLanguages)")))

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
        menu.addItem(item(String(localized: "Permissions…"), #selector(showPermissions)))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Quit Tsuzuri"), #selector(quit), key: "q"))
        statusItem.menu = menu
    }

    private var polishLanguages: String {
        ListFormatter.localizedString(byJoining: PolishLanguages.supported.compactMap { SpokenLanguage.named($0)?.nativeName })
    }

    private func languageItem(_ language: RecognitionLanguage) -> NSMenuItem {
        let item = NSMenuItem(title: language.title, action: #selector(selectLanguage(_:)), keyEquivalent: "")
        item.representedObject = language.rawValue
        item.state = language == Settings.language ? .on : .off
        item.target = self
        return item
    }

    /// A greyed-out, indented line of explanation.
    private func note(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.indentationLevel = 1
        return item
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
        trustTimer?.invalidate()
        if Paster.isTrusted {
            hotkey.start()
            refreshStatus()
            watchAccessibilityRevoked()
            return
        }
        refreshStatus()
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { return }
                self.permissions.refresh()
                guard Paster.isTrusted else { return }
                timer.invalidate()
                self.hotkey.start()
                self.refreshStatus()
                self.setIcon(recording: false)
                self.rebuildMenu()
                // Keep the window's microphone row live until it is closed.
                self.pollPermissionsWindow()
                self.watchAccessibilityRevoked()
            }
        }
    }

    /// The user can switch Accessibility off (or remove the app) while it runs: the shortcut
    /// then stops working silently, so show the warning again and wait for it to come back.
    private func watchAccessibilityRevoked() {
        trustTimer?.invalidate()
        trustTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self, !Paster.isTrusted else { return }
                timer.invalidate()
                Log.write("accessibility permission was turned off")
                // Esc and the key release can't be seen any more: don't leave a recording running.
                self.cancelRecording()
                self.hotkey.stop()
                self.hotkey.reset()
                self.setIcon(recording: self.recording)
                self.rebuildMenu()
                self.waitForAccessibility()
            }
        }
    }

    private func pollPermissionsWindow() {
        guard permissions.isVisible, !(permissionsTimer?.isValid ?? false) else { return }
        permissionsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self, self.permissions.isVisible else { timer.invalidate(); return }
                self.permissions.refresh()
            }
        }
    }

    private func refreshStatus() {
        if !Paster.isTrusted {
            status = String(localized: "Shortcut needs Accessibility permission · Click to Set Up")
        } else if let modelError {
            status = modelError
        } else if !modelReady || modelSwitching {
            status = String(localized: "Loading model…")
        } else {
            status = String(localized: "Ready · hold \(Settings.trigger.title) to talk")
        }
    }

    /// Loads (or switches to) `model`. While switching, the previous model keeps serving
    /// dictations; only the newest request wins when the user switches quickly.
    private func loadModel(_ model: ASRModel) {
        modelGeneration += 1
        let generation = modelGeneration
        modelError = nil
        modelSwitching = modelReady
        refreshStatus()
        Task {
            do {
                let seconds = try await transcriber.load(model)
                guard generation == modelGeneration else { return }
                Log.write(String(format: "loaded %@ in %.2fs", model.rawValue, seconds))
                modelReady = true
            } catch TranscriberError.superseded {
                return
            } catch {
                guard generation == modelGeneration else { return }
                Log.write("load failed: \(error)")
                let message = model.isInstalled
                    ? String(localized: "Model failed to load: \(model.rawValue)")
                    : String(localized: "\(model.menuTitle) (not downloaded)")
                if modelReady, let current = await transcriber.model {
                    // A switch failed: keep using the model that is still loaded.
                    Settings.model = current
                    rebuildMenu()
                    overlay.show(.message(message))
                    overlay.hide(after: 2.5)
                } else {
                    modelError = message
                }
            }
            modelSwitching = false
            refreshStatus()
        }
    }

    private func loadPolisher() {
        guard PolishModel.isInstalled else { return }
        Task {
            do {
                let seconds = try await transcriber.loadPolisher()
                Log.write(String(format: "loaded %@ in %.2fs", PolishModel.directoryName, seconds))
                // Turned off while it was loading: don't keep it in memory.
                if !Settings.polish { await transcriber.unloadPolisher() }
            } catch {
                Log.write("polish model load failed: \(error)")
            }
        }
    }

    // MARK: - Dictation

    private func startRecording() {
        guard !recording else { return }
        if let modelError, !modelReady {
            // The user may have downloaded the model since: pick it up without a restart.
            if Settings.model.isInstalled {
                rebuildMenu()
                loadModel(Settings.model)
                overlay.show(.message(String(localized: "Model is still loading…")))
            } else {
                overlay.show(.message(modelError))
            }
            overlay.hide(after: 2)
            hotkey.reset()
            return
        }
        guard modelReady else {
            overlay.show(.message(String(localized: "Model is still loading…")))
            overlay.hide(after: 1.2)
            hotkey.reset()
            return
        }
        // Microphone not allowed (or not asked yet): recording would fail or capture
        // silence, so send the user to the permissions window instead.
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            hotkey.reset()
            showPermissions()
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

    /// Shows the outcome of a dictation, unless a new recording has started meanwhile
    /// (its "Listening" capsule must stay up).
    private func showResult(_ state: Overlay.Phase, hideAfter seconds: Double) {
        guard !recording else { return }
        overlay.show(state)
        overlay.hide(after: seconds)
    }

    private func transcribeAndPaste(_ samples: [Float]) {
        overlay.show(.transcribing)
        let language = Settings.language.modelValue
        let context = Settings.context
        // The app the text is for; decided now, before the user can switch away.
        let targetApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let polish = PolishPolicy.shouldPolish(bundleID: targetApp)
        let previous = lastDelivery
        lastDelivery = Task {
            await previous?.value
            do {
                let result = try await transcriber.transcribe(samples, language: language, context: context)
                // Where the text goes, known before Polish and logging: a password field gets the
                // raw text, and it is never shown, kept or logged.
                let focus = Paster.isTrusted && !result.text.isEmpty ? await FocusInfo.current() : nil
                let secure = focus?.secure ?? false
                Log.write(String(format: "%.2fs in → %.2fs speech, %.3fs, RTF %.3f, %@: %@",
                                 result.inputSeconds, result.audioSeconds, result.elapsed, result.rtf,
                                 result.language ?? "-", secure ? "<secure field>" : Log.redact(result.text)))
                if result.text.isEmpty {
                    showResult(.message(String(localized: "No speech heard")), hideAfter: 1)
                    return
                }
                var text = result.text
                let unsupported = PolishLanguages.skipReason(for: result.language)
                if secure {
                    // No Polish: it could rewrite what was spelled out.
                } else if polish, let unsupported {
                    Log.write("polish skipped: \(unsupported)")
                } else if polish {
                    let p = await transcriber.polish(result.text)
                    text = p.text
                    Log.write(String(format: "polish %.0f ms, %d→%d tokens, %@: %@ ⇒ %@",
                                     p.elapsed * 1000, p.promptTokens, p.generatedTokens,
                                     p.rejection.map { "kept raw (\(Log.redactReason($0)))" } ?? "used",
                                     Log.redact(p.raw), Log.redact(p.candidate)))
                } else if Settings.polish {
                    Log.write("polish skipped in \(targetApp ?? "-")")
                }
                if let focus {
                    let outcome = Paster.insert(text, focus: focus)
                    Log.write("focus \(focus.app) \(focus.role)\(secure ? " (secure)" : "") → \(outcome)")
                    if secure, outcome == .pasted {
                        // A password field: don't show the text or keep it in Recent.
                        showResult(.message("••••••"), hideAfter: 1)
                        return
                    }
                    addToHistory(text)
                    switch outcome {
                    case .pasted:
                        showResult(.message(text), hideAfter: 1.2)
                    case .pastedAndCopied:
                        showResult(.copied(text), hideAfter: 1.5)
                    case .copied:
                        showResult(.copied(String(localized: "Copied · ⌘V to paste: \(text)")), hideAfter: 2.5)
                    }
                } else {
                    // Without Accessibility we cannot send ⌘V; leave the text on the clipboard.
                    addToHistory(text)
                    Paster.copy(text)
                    showResult(.copied(String(localized: "Copied (Accessibility not granted)")), hideAfter: 1.5)
                }
            } catch {
                Log.write("transcribe failed: \(error)")
                showResult(.message(String(localized: "Recognition failed")), hideAfter: 1.5)
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
        // Esc only works while the old key is held; don't leave a recording running without it.
        cancelRecording()
        hotkey.trigger = trigger
        hotkey.reset()
        rebuildMenu()
        refreshStatus()
    }

    @objc fileprivate func showPermissions() {
        permissions.show()
        pollPermissionsWindow()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    #if TSUZURI_DEBUG_HOOKS
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
    #endif
}

#if TSUZURI_DEBUG_HOOKS
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

    /// Debug hook for screenshots: `scripts/debug.sh permissions` opens the permissions window.
    @objc fileprivate func debugPermissions(_ note: Notification) {
        showPermissions()
    }

    /// Debug hook for screenshots: `scripts/debug.sh menu main|languages` opens the menu
    /// (or the Spoken Language submenu on its own) and closes it again after 4 s.
    @objc fileprivate func debugMenu(_ note: Notification) {
        guard let button = statusItem.button, let window = button.window else { return }
        let menu: NSMenu? = note.object as? String == "languages" ? languagesMenu?.copy() as? NSMenu : statusItem.menu
        guard let menu else { return }
        nonisolated(unsafe) let tracked = menu  // only touched on the main run loop
        let close = Timer(timeInterval: 4, repeats: false) { _ in tracked.cancelTracking() }
        RunLoop.main.add(close, forMode: .common)
        if note.object as? String == "languages" {
            let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
            menu.popUp(positioning: nil, at: NSPoint(x: frame.minX, y: frame.minY - 4), in: nil)
        } else {
            button.performClick(nil)
        }
    }
}
#endif

enum Log {
    private static let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Tsuzuri.log")

    /// What was said stays out of the log unless `defaults write com.kanaworks.tsuzuri logText -bool true`.
    static func redact(_ text: String) -> String {
        UserDefaults.standard.bool(forKey: "logText") ? text : "<\(text.count) chars>"
    }

    /// Why Polish kept the raw text, without the words or numbers it quotes ("new word: X" → "new word").
    static func redactReason(_ reason: String) -> String {
        guard !UserDefaults.standard.bool(forKey: "logText") else { return reason }
        for prefix in ["new word", "new character", "number"] where reason.hasPrefix(prefix + ":") {
            return prefix
        }
        return reason
    }

    private static let sizeLimit: UInt64 = 5 << 20

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        // Keep one old file (Tsuzuri.log.1) once the log reaches 5 MB.
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? UInt64, size > sizeLimit {
            let old = url.appendingPathExtension("1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        // The throwing FileHandle API: the old write(_:) raises an ObjC exception (crash) on I/O errors.
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
