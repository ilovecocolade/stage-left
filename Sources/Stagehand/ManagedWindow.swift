import AppKit
import ApplicationServices

/// A window Stagehand is willing to take off stage.
struct ManagedWindow {
    let id: CGWindowID
    let pid: pid_t
    let element: AXUIElement
    let appName: String
    let title: String
    var axFrame: CGRect

    /// Falls back to the bundle's icon on disk: a running application reports
    /// no icon for a moment while it is being hidden.
    var appIcon: NSImage? {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        if let icon = app.icon { return icon }
        return app.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
    }
}

/// How a window was taken off the screen.
///
/// Two mechanisms were ruled out: moving a window off-screen is clamped by
/// macOS so it stays partly visible, and the window server refuses
/// cross-process moves. Setting window alpha to zero does work, but an
/// invisible window still swallows clicks and would be unrecoverable if
/// Stagehand died. Both of these leave the window in the Dock.
enum TuckMethod: String {
    /// The whole app was hidden — instant, with no animation at all. Only safe
    /// when every one of that app's windows is on this display.
    case appHidden
    /// A single window was minimised. Costs the Dock animation, so it is the
    /// fallback for apps with windows spread across displays.
    case minimized
}

/// A window Stagehand has taken off stage, and what it needs to bring it back.
struct TuckedWindow {
    let id: CGWindowID
    let pid: pid_t
    let element: AXUIElement
    let appName: String
    let title: String
    let bundleID: String?
    let homeDisplayID: String
    let method: TuckMethod
    /// When it was taken off stage. Hiding and minimising are both
    /// asynchronous, so the system still reports the window as visible for a
    /// moment afterwards; without this the engine would decide it had come back
    /// and immediately tuck it again, in a loop.
    let tuckedAt: Date

    /// Falls back to the bundle's icon on disk: a running application reports
    /// no icon for a moment while it is being hidden, and the strip would then
    /// draw an empty tile.
    var appIcon: NSImage? {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        if let icon = app.icon { return icon }
        return app.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
    }
}
