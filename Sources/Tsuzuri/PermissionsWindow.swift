import AppKit
import AVFoundation
import SwiftUI

/// First-run guide: the speech model and the two permissions Tsuzuri needs. Without
/// Accessibility the app never sees the shortcut key, so pressing it can't give feedback:
/// this window (opened at launch and from the menu) is where the user finds out.
@MainActor
final class PermissionsWindow {
    private var window: NSWindow?
    private let model: Model

    init(downloads: ModelDownloads) {
        model = Model(downloads: downloads)
    }

    final class Model: ObservableObject {
        @Published var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        @Published var accessibility = Paster.isTrusted
        @Published var speechModel = Settings.model
        @Published var speechModelInstalled = Settings.model.isInstalled
        let downloads: ModelDownloads
        var allGranted: Bool { microphone == .authorized && accessibility && speechModelInstalled }

        init(downloads: ModelDownloads) {
            self.downloads = downloads
        }

        func refresh() {
            let mic = AVCaptureDevice.authorizationStatus(for: .audio)
            if mic != microphone { microphone = mic }
            let trusted = Paster.isTrusted
            if trusted != accessibility { accessibility = trusted }
            if Settings.model != speechModel { speechModel = Settings.model }
            let installed = Settings.model.isInstalled
            if installed != speechModelInstalled { speechModelInstalled = installed }
        }
    }

    static var needed: Bool {
        !Paster.isTrusted || AVCaptureDevice.authorizationStatus(for: .audio) != .authorized
            || !Settings.model.isInstalled
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        model.refresh()
        if window == nil {
            let view = PermissionsView(model: model, close: { [weak self] in self?.window?.close() })
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = String(localized: "Set Up Tsuzuri")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.level = .floating
            self.window = window
            position()  // only the first time: keep wherever the user moved it
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Top right, under the menu bar icon: system permission prompts appear in the
    /// middle of the screen and would cover a centred window.
    private func position() {
        guard let window, let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: frame.maxX - size.width - 16, y: frame.maxY - size.height - 8))
    }

    /// Called by the app's permission poll (and after a download) so the rows turn green while the window is open.
    func refresh() {
        guard isVisible else { return }
        model.refresh()
    }
}

private struct PermissionsView: View {
    @ObservedObject var model: PermissionsWindow.Model
    @ObservedObject var downloads: ModelDownloads
    let close: () -> Void

    init(model: PermissionsWindow.Model, close: @escaping () -> Void) {
        self.model = model
        self.downloads = model.downloads
        self.close = close
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tsuzuri needs a speech model and two permissions. Your voice never leaves this Mac.")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            speechModelRow

            row(granted: model.microphone == .authorized,
                symbol: "mic",
                title: String(localized: "Microphone"),
                detail: String(localized: "To hear you while you dictate: while you hold the shortcut key, or from one tap to the next."),
                button: microphoneButton)

            row(granted: model.accessibility,
                symbol: "accessibility",
                title: String(localized: "Accessibility"),
                detail: String(localized: "To notice the shortcut key and paste the text where your cursor is."),
                button: Button(String(localized: "Open System Settings…")) {
                    Paster.promptForAccessibility()
                    openSettings("Privacy_Accessibility")
                })

            if !model.accessibility {
                Text("Turn on Tsuzuri in the list. If it is already on, select it, remove it with −, then add Tsuzuri again with +.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            HStack {
                if model.allGranted {
                    Label(String(localized: "All set. Hold \(Settings.trigger.title) to talk."), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(model.allGranted ? String(localized: "Done") : String(localized: "Later"), action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    /// Download button, progress with Cancel, or the error with Try Again.
    private var speechModelRow: some View {
        // The model being downloaded (e.g. a second one, started from the menu), else the chosen one.
        let speech = downloads.model ?? model.speechModel
        let installed = speech == model.speechModel ? model.speechModelInstalled : speech.isInstalled
        let failure = downloads.failure(for: speech)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "waveform")
                .font(.title2)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Speech Model").font(.body.weight(.semibold))
                Text("\(speech.displayName) turns your voice into text on this Mac. It is downloaded once from Hugging Face (huggingface.co); recognition itself never uses the internet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if downloads.isDownloading(speech) {
                    downloadProgress
                } else if let failure {
                    Text(failure)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if installed {
                Label(String(localized: "Downloaded"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .fixedSize()
            } else if downloads.isDownloading(speech) {
                Button(String(localized: "Cancel")) { downloads.cancel() }
                    .fixedSize()
            } else {
                Button(failure == nil
                       ? String(localized: "Download (\(ModelDownloads.size(speech.downloadSize)))")
                       : String(localized: "Try Again")) {
                    downloads.start(speech)
                }
                .disabled(downloads.isDownloading)  // another model is downloading
                .fixedSize()
            }
        }
    }

    @ViewBuilder private var downloadProgress: some View {
        switch downloads.state {
        case .downloading(let done, let total):
            ProgressView(value: Double(done), total: Double(max(total, 1)))
                .padding(.top, 4)
            Text("\(ModelDownloads.size(done)) of \(ModelDownloads.size(total)) (\(downloads.percentText))")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        case .verifying:
            ProgressView(value: 1)
                .padding(.top, 4)
            Text("Checking the download…")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .idle, .failed:
            EmptyView()
        }
    }

    private var microphoneButton: Button<Text> {
        if model.microphone == .notDetermined {
            return Button(String(localized: "Allow…")) {
                Task {
                    _ = await AudioRecorder.requestPermission()
                    await MainActor.run { model.refresh() }
                }
            }
        }
        return Button(String(localized: "Open System Settings…")) { openSettings("Privacy_Microphone") }
    }

    private func row(granted: Bool, symbol: String, title: String, detail: String, button: Button<Text>) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if granted {
                Label(String(localized: "Allowed"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .fixedSize()
            } else {
                button.fixedSize()
            }
        }
    }

    private func openSettings(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}
