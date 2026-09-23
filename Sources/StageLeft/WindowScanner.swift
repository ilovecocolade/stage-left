import AppKit
import ApplicationServices

/// Finds the windows on screen that are safe to move around.
enum WindowScanner {
    private static let ownPID = ProcessInfo.processInfo.processIdentifier

    /// Every ordinary, visible, movable window belonging to a normal app.
    static func visibleWindows() -> [ManagedWindow] {
        var result: [ManagedWindow] = []

        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != ownPID
            && !app.isTerminated && !app.isHidden {
            let name = app.localizedName ?? "Unknown"

            for element in Accessibility.windows(ofPID: app.processIdentifier) {
                // Only real document windows. Sheets, popovers and panels either
                // cannot be moved or should never leave their parent.
                guard Accessibility.subrole(element) == kAXStandardWindowSubrole as String,
                      !Accessibility.isMinimized(element),
                      let id = Accessibility.windowID(element),
                      let frame = Accessibility.frame(element),
                      frame.width > 80, frame.height > 80
                else { continue }

                result.append(ManagedWindow(id: id,
                                            pid: app.processIdentifier,
                                            element: element,
                                            appName: name,
                                            title: Accessibility.title(element) ?? name,
                                            axFrame: frame))
            }
        }
        return result
    }

    /// On-screen windows ranked front to back, so 0 is the frontmost.
    ///
    /// The window server keeps this list in stacking order, which is the
    /// closest thing to "most recently used" without tracking history
    /// ourselves — and it is already correct the moment Stage Left starts.
    static func frontToBackOrder() -> [CGWindowID: Int] {
        let listed = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                kCGNullWindowID) as? [[String: Any]] ?? []
        var order: [CGWindowID: Int] = [:]
        for (index, entry) in listed.enumerated() {
            guard let number = entry[kCGWindowNumber as String] as? CGWindowID else { continue }
            if order[number] == nil { order[number] = index }
        }
        return order
    }

    /// Displays that still have an ordinary window visibly on screen.
    ///
    /// Revealing the desktop sweeps every window aside without closing or
    /// moving it, so Accessibility still reports the old frames. The window
    /// server's own on-screen list is what actually notices, and an empty
    /// display is the cue to take the strip away too.
    static func displaysShowingWindows(among displays: [Display]) -> Set<String> {
        let listed = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                kCGNullWindowID) as? [[String: Any]] ?? []
        var result = Set<String>()

        for entry in listed {
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  (entry[kCGWindowOwnerPID as String] as? pid_t) != ownPID,
                  let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let width = bounds["Width"], let height = bounds["Height"],
                  width > 80, height > 80
            else { continue }

            let frame = CGRect(x: x, y: y, width: width, height: height)
            if let display = Geometry.display(containing: frame, among: displays) {
                result.insert(display.id)
            }
        }
        return result
    }

    /// Window IDs on the Space showing right now.
    ///
    /// Windows on another desktop are absent from this list even though they
    /// are neither minimised nor hidden, which is how the strip knows its stage
    /// is not the desktop in front of you.
    static func onScreenWindowIDs() -> Set<CGWindowID> {
        let listed = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(listed.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
    }

    /// Displays whose visible Space is given over to a full-screen window.
    ///
    /// Restricted to windows on the Space in front of you, so a full-screen app
    /// sitting on some other desktop does not suppress the strip here.
    static func displaysWithFullScreenWindow(among displays: [Display]) -> Set<String> {
        let onScreen = onScreenWindowIDs()
        var result = Set<String>()

        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != ownPID
            && !app.isTerminated && !app.isHidden {
            for element in Accessibility.windows(ofPID: app.processIdentifier) {
                guard let id = Accessibility.windowID(element),
                      onScreen.contains(id),
                      Accessibility.isFullScreen(element),
                      let frame = Accessibility.frame(element),
                      let display = Geometry.display(containing: frame, among: displays)
                else { continue }
                result.insert(display.id)
            }
        }
        return result
    }

    /// The window the user is actually working in.
    static func focusedWindow() -> ManagedWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ownPID,
              app.activationPolicy == .regular
        else { return nil }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let raw = Accessibility.copyValue(appElement, kAXFocusedWindowAttribute),
              CFGetTypeID(raw) == AXUIElementGetTypeID()
        else { return nil }
        let element = raw as! AXUIElement

        guard let id = Accessibility.windowID(element),
              let frame = Accessibility.frame(element)
        else { return nil }

        return ManagedWindow(id: id,
                             pid: app.processIdentifier,
                             element: element,
                             appName: app.localizedName ?? "Unknown",
                             title: Accessibility.title(element) ?? "",
                             axFrame: frame)
    }
}
