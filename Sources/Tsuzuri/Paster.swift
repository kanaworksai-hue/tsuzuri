import AppKit
import Carbon.HIToolbox

/// Inserts text into the focused app by putting it on the pasteboard and
/// sending ⌘V, then restoring the previous pasteboard contents.
///
/// Pasting (instead of synthesising key strokes per character) bypasses
/// Chinese/Japanese input methods, which would otherwise try to compose the text.
enum Paster {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func promptForAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Where the dictated text ended up.
    enum Outcome {
        /// Pasted into a text field; the previous clipboard was restored.
        case pasted
        /// Pasted, but we could not tell whether there is a text field, so the
        /// text was also left on the clipboard.
        case pastedAndCopied
        /// No text field has focus: the text was only copied to the clipboard.
        case copied
    }

    /// Pastes into the focused text field, or leaves the text on the clipboard
    /// when nothing editable has focus so the dictation is not lost.
    static func insert(_ text: String, focus: FocusInfo) -> Outcome {
        switch focus.target {
        case .textInput:
            paste(text)
            return .pasted
        case .unknown:
            paste(text, keepOnClipboard: true)
            return .pastedAndCopied
        case .other:
            copy(text)
            return .copied
        }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func paste(_ text: String, keepOnClipboard: Bool = false) {
        guard !text.isEmpty else { return }
        if keepOnClipboard {
            copy(text)
            sendCommandV()
            return
        }
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Mark as transient so clipboard managers skip it.
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let ourChange = pasteboard.changeCount

        sendCommandV()

        // Give the target app time to read the pasteboard before restoring it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard pasteboard.changeCount == ourChange else { return } // user copied something meanwhile
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    private static func sendCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        // Ignore the physical trigger modifier that may still be held.
        source?.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitSystemDefinedEvents],
                                                           state: .eventSuppressionStateSuppressionInterval)
        let v = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

/// What currently has keyboard focus, read through the Accessibility API.
struct FocusInfo: Sendable {
    enum Target {
        case textInput
        /// Something non-editable (a list, a button, the desktop…).
        case other
        /// No focused element, or a container that may hide an editable
        /// element (web views, groups): treat as possibly editable.
        case unknown
    }

    var target: Target
    var role: String
    var app: String

    private static let textRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole]
    private static let containerRoles: Set<String> = [
        "AXWebArea", kAXGroupRole, kAXScrollAreaRole, kAXWindowRole, kAXApplicationRole, kAXUnknownRole,
    ]

    /// Queries the frontmost app off the main thread. Accessibility calls can
    /// block for seconds when the target app is busy, so give up after `timeout`
    /// and report `.unknown` (paste, and keep the text on the clipboard).
    @MainActor
    static func current(timeout: TimeInterval = 0.5) async -> FocusInfo {
        let front = NSWorkspace.shared.frontmostApplication
        let appName = front?.bundleIdentifier ?? front?.localizedName ?? "-"
        guard let pid = front?.processIdentifier else { return FocusInfo(target: .unknown, role: "-", app: appName) }
        return await withCheckedContinuation { continuation in
            let once = Once()
            DispatchQueue.global(qos: .userInitiated).async {
                let info = query(pid: pid, appName: appName)
                once.run { continuation.resume(returning: info) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.run { continuation.resume(returning: FocusInfo(target: .unknown, role: "timeout", app: appName)) }
            }
        }
    }

    private static func query(pid: pid_t, appName: String) -> FocusInfo {
        // Applies to every element this process talks to (the default is 6 s per call).
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.2)
        let app = AXUIElementCreateApplication(pid)
        guard let element = element(app, kAXFocusedUIElementAttribute) else {
            return FocusInfo(target: .unknown, role: "none", app: appName)
        }
        let role = attribute(element, kAXRoleAttribute) as? String ?? "-"
        let target: Target
        if textRoles.contains(role)
            || isSettable(element, kAXSelectedTextRangeAttribute)
            || (isSettable(element, kAXValueAttribute) && attribute(element, kAXValueAttribute) is String) {
            target = .textInput
        } else if containerRoles.contains(role) {
            target = .unknown
        } else {
            target = .other
        }
        return FocusInfo(target: target, role: role, app: appName)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success && settable.boolValue
    }
}

/// Runs its body at most once, from any thread.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}
