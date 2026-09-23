import AppKit
import ApplicationServices

/// Thin, failure-tolerant wrappers over the Accessibility API.
///
/// Every call here can fail for ordinary reasons — the app quit mid-scan, the
/// window closed, the app refuses to be moved — so nothing throws. Callers
/// treat a nil as "skip this window".
enum Accessibility {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Prompts once, showing the system's own explanation sheet.
    @discardableResult
    static func requestPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Attributes

    static func copyValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    static func windows(ofPID pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        return copyValue(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
    }

    static func title(_ window: AXUIElement) -> String? {
        copyValue(window, kAXTitleAttribute) as? String
    }

    static func subrole(_ window: AXUIElement) -> String? {
        copyValue(window, kAXSubroleAttribute) as? String
    }

    /// Whether the window is in macOS full screen, on its own Space.
    ///
    /// Asking the window directly beats measuring it: on a notched display a
    /// full-screen window does not cover the menu bar area, so it is not the
    /// same size as the screen and geometry comparisons miss it.
    static func isFullScreen(_ window: AXUIElement) -> Bool {
        (copyValue(window, "AXFullScreen") as? Bool) ?? false
    }

    static func isMinimized(_ window: AXUIElement) -> Bool {
        (copyValue(window, kAXMinimizedAttribute) as? Bool) ?? false
    }

    /// Window frame in Accessibility coordinates: origin top-left of the
    /// primary display, y increasing downward.
    static func frame(_ window: AXUIElement) -> CGRect? {
        guard let posRef = copyValue(window, kAXPositionAttribute),
              let sizeRef = copyValue(window, kAXSizeAttribute)
        else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    @discardableResult
    static func setPosition(_ window: AXUIElement, _ point: CGPoint) -> Bool {
        var mutable = point
        guard let value = AXValueCreate(.cgPoint, &mutable) else { return false }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success
    }

    /// Brings a window to the front without activating anything else.
    @discardableResult
    static func raise(_ window: AXUIElement) -> Bool {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
    }

    /// A stable-enough identity for a window across scans.
    ///
    /// `_AXUIElementGetWindow` is the private call every window manager uses to
    /// get the real window number; without it we fall back to the element's own
    /// hash, which is stable while the window lives.
    static func windowID(_ window: AXUIElement) -> CGWindowID? {
        var id = CGWindowID(0)
        if _AXUIElementGetWindow(window, &id) == .success, id != 0 { return id }
        return nil
    }
}

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ identifier: UnsafeMutablePointer<CGWindowID>) -> AXError
