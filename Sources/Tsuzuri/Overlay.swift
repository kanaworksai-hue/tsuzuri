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
        @Published var size = Overlay.compactSize
    }

    nonisolated static let compactSize = CGSize(width: 240, height: 44)
    /// Messages often say what to do next ("menu → Permissions…"): widen the capsule and
    /// allow a second line instead of cutting them off.
    private static let maxWidth: CGFloat = 480
    private static let chrome: CGFloat = 16 * 2 + 20 + 10 + 6  // padding, icon, spacing, slack
    static let font = NSFont.systemFont(ofSize: 13, weight: .medium)

    private static func size(for phase: Phase) -> CGSize {
        let text: String
        switch phase {
        case .listening, .transcribing: return compactSize
        case .message(let t), .copied(let t): text = t
        }
        let width = ceil((text as NSString).size(withAttributes: [.font: font]).width) + chrome
        if width <= compactSize.width { return compactSize }
        if width <= maxWidth { return CGSize(width: width, height: compactSize.height) }
        return CGSize(width: maxWidth, height: 62)
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
        let host = NSHostingView(rootView: OverlayView(model: model))
        host.sizingOptions = []  // show() sets the size; don't let SwiftUI resize the panel
        panel.contentView = host
        return panel
    }()

    func show(_ phase: Phase) {
        hideWork?.cancel()
        model.phase = phase
        if phase == .listening { model.level = 0 }
        let size = Self.size(for: phase)
        model.size = size
        panel.setContentSize(size)
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
                Text(text).lineLimit(2).truncationMode(.tail)
            case .copied(let text):
                Image(systemName: "doc.on.clipboard").foregroundStyle(.secondary)
                Text(text).lineLimit(2).truncationMode(.tail)
            }
        }
        .font(Font(Overlay.font))
        .padding(.horizontal, 16)
        .frame(width: model.size.width, height: model.size.height,
               alignment: model.size.height > Overlay.compactSize.height ? .leading : .center)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.15)))
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
