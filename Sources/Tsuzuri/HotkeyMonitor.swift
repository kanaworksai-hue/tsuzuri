import AppKit

/// Watches a single modifier key globally.
///
/// - Hold the key (longer than `tapThreshold`) → push-to-talk: `onStart` on press, `onStop` on release.
/// - Tap the key → toggle: first tap `onStart`, next tap `onStop`.
/// - Any other key pressed while the trigger is held (e.g. ⌥+letter for a special
///   character) cancels, so normal shortcuts keep working.
/// - Esc cancels a running recording.
///
/// Global monitors only fire once the app is trusted for Accessibility.
final class HotkeyMonitor {
    var onStart: () -> Void = {}
    var onStop: () -> Void = {}
    var onCancel: () -> Void = {}

    var trigger: TriggerKey
    private let tapThreshold: TimeInterval = 0.3
    private var monitors: [Any] = []
    private var pressedAt: Date?
    private var toggledOn = false
    private var active = false

    init(trigger: TriggerKey) {
        self.trigger = trigger
    }

    func start() {
        stop()
        let flags = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] in self?.handleFlags($0) }
        let keys = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] in self?.handleKey($0) }
        let localFlags = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] in
            self?.handleFlags($0); return $0
        }
        let localKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] in
            self?.handleKey($0); return $0
        }
        monitors = [flags, keys, localFlags, localKeys].compactMap { $0 }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    /// Called by the app when a recording ends for another reason (error, cancel).
    func reset() {
        active = false
        toggledOn = false
        pressedAt = nil
    }

    private func isDown(_ event: NSEvent) -> Bool {
        switch trigger {
        case .rightOption: event.modifierFlags.contains(.option)
        case .rightCommand: event.modifierFlags.contains(.command)
        case .fn: event.modifierFlags.contains(.function)
        }
    }

    private func handleFlags(_ event: NSEvent) {
        guard event.keyCode == trigger.keyCode else { return }
        if isDown(event) {
            pressedAt = Date()
            if toggledOn {
                // Second tap of a toggle: stop on press so it feels immediate.
                toggledOn = false
                active = false
                pressedAt = nil
                onStop()
            } else if !active {
                active = true
                onStart()
            }
        } else {
            guard let pressedAt, active else { return }
            self.pressedAt = nil
            if Date().timeIntervalSince(pressedAt) < tapThreshold {
                toggledOn = true // short tap: keep recording until the next tap
            } else {
                active = false
                onStop()
            }
        }
    }

    private func handleKey(_ event: NSEvent) {
        guard active else { return }
        if event.keyCode == 53 || pressedAt != nil {
            // Esc, or a chord like ⌥+key while the trigger is held.
            reset()
            onCancel()
        }
    }
}
