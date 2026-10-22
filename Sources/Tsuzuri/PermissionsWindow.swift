import AppKit
import AVFoundation
import SwiftUI

/// First-run guide for the two permissions Tsuzuri needs. Without Accessibility the app
/// never sees the shortcut key, so pressing it can't give feedback: this window (opened at
/// launch and from the menu) is where the user finds out.
@MainActor
final class PermissionsWindow {
    private var window: NSWindow?
    private let model = Model()

    final class Model: ObservableObject {
        @Published var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        @Published var accessibility = Paster.isTrusted
        var allGranted: Bool { microphone == .authorized && accessibility }

        func refresh() {
            let mic = AVCaptureDevice.authorizationStatus(for: .audio)
            if mic != microphone { microphone = mic }
            let trusted = Paster.isTrusted
            if trusted != accessibility { accessibility = trusted }
        }
    }

    static var needed: Bool {
        !Paster.isTrusted || AVCaptureDevice.authorizationStatus(for: .audio) != .authorized
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

    /// Called by the app's permission poll so the rows turn green while the window is open.
    func refresh() {
        guard isVisible else { return }
        model.refresh()
    }
}

private struct PermissionsView: View {
    @ObservedObject var model: PermissionsWindow.Model
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tsuzuri needs two permissions. Everything stays on this Mac.")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            row(granted: model.microphone == .authorized,
                symbol: "mic",
                title: String(localized: "Microphone"),
                detail: String(localized: "To hear you while you hold the shortcut key."),
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
                }
                Spacer()
                Button(model.allGranted ? String(localized: "Done") : String(localized: "Later"), action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
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
