import AppKit
import SwiftUI

/// Small floating capsule near the bottom of the screen that shows the
/// dictation state. It never takes focus, so the target app keeps the cursor.
@MainActor
final class Overlay {
    enum Phase: Equatable {
        case listening
        case transcribing
        case message(String)
        /// Text left on the clipboard for the user to paste.
        case copied(String)
    }

    final class Model: ObservableObject {
        @Published var phase: Phase = .listening
        @Published var level: Float = 0
    }

    private let model = Model()
    private var hideWork: DispatchWorkItem?
    private lazy var panel: NSPanel = {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 44),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: OverlayView(model: model))
        return panel
    }()

    func show(_ phase: Phase) {
        hideWork?.cancel()
        model.phase = phase
        if phase == .listening { model.level = 0 }
        position()
        panel.orderFrontRegardless()
    }

    func setLevel(_ level: Float) {
        model.level = model.level * 0.6 + level * 0.4
    }

    func hide(after delay: TimeInterval = 0) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func position() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 72))
    }
}

private struct OverlayView: View {
    @ObservedObject var model: Overlay.Model

    var body: some View {
        HStack(spacing: 10) {
            switch model.phase {
            case .listening:
                Image(systemName: "mic.fill").foregroundStyle(.red)
                LevelBars(level: model.level)
                Text("Listening…").foregroundStyle(.secondary)
            case .transcribing:
                ProgressView().controlSize(.small)
                Text("Transcribing…").foregroundStyle(.secondary)
            case .message(let text):
                Image(systemName: "text.bubble").foregroundStyle(.secondary)
                Text(text).lineLimit(1).truncationMode(.tail)
            case .copied(let text):
                Image(systemName: "doc.on.clipboard").foregroundStyle(.secondary)
                Text(text).lineLimit(1).truncationMode(.tail)
            }
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 16)
        .frame(width: 240, height: 44)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
    }
}

private struct LevelBars: View {
    var level: Float
    private let weights: [Float] = [0.5, 0.8, 1, 0.7, 0.45]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(weights.indices, id: \.self) { i in
                Capsule()
                    .fill(.primary.opacity(0.8))
                    .frame(width: 3, height: CGFloat(4 + 16 * min(1, level * weights[i])))
            }
        }
        .frame(height: 20)
        .animation(.easeOut(duration: 0.08), value: level)
    }
}
