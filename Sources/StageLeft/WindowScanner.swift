import AppKit
import ApplicationServices

/// Finds the windows on screen that are safe to move around.
///
/// Every question here is a round trip to another process, and some run twice
/// a second, so each asks as little as it can. The window server answers for
/// every window in one call; Accessibility has to ask each app in turn, on
/// that app's own main thread, so it is kept to the apps with a window on a
/// staged screen.
enum WindowScanner {
    private static let ownPID = ProcessInfo.processInfo.processIdentifier

    /// One copy of the window server's on-screen list, shared by everything a
    /// pass or a strip refresh needs from it.
    struct Snapshot {
        /// Window IDs on the Space showing right now.
        ///
        /// Windows on another desktop are absent from this list even though
        /// they are neither minimised nor hidden, which is how the strip knows
        /// its stage is not the desktop in front of you.
        let onScreenIDs: Set<CGWindowID>

        /// On-screen windows ranked front to back, so 0 is the frontmost.
        ///
        /// The window server keeps this list in stacking order, which is the
        /// closest thing to "most recently used" without tracking history
        /// ourselves — and it is already correct the moment Stage Left starts.
        let frontToBackOrder: [CGWindowID: Int]

        /// Other apps' on-screen windows larger than 80 points each way.
        /// Anything smaller is a palette, a badge or a status item.
        private let windows: [(pid: pid_t, layer: Int, frame: CGRect)]

        fileprivate init() {
            let listed = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] ?? []
            var order: [CGWindowID: Int] = [:]
            var windows: [(pid: pid_t, layer: Int, frame: CGRect)] = []

            for (index, entry) in listed.enumerated() {
                guard let number = entry[kCGWindowNumber as String] as? CGWindowID else { continue }
                if order[number] == nil { order[number] = index }

                guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                      let layer = entry[kCGWindowLayer as String] as? Int,
                      let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
                      let x = bounds["X"], let y = bounds["Y"],
                      let width = bounds["Width"], let height = bounds["Height"],
                      width > 80, height > 80
                else { continue }
                windows.append((pid, layer, CGRect(x: x, y: y, width: width, height: height)))
            }

            onScreenIDs = Set(order.keys)
            frontToBackOrder = order
            self.windows = windows
        }

        /// Displays that still have an ordinary window visibly on screen.
        ///
        /// Revealing the desktop sweeps every window aside without closing or
        /// moving it, so Accessibility still reports the old frames. The window
        /// server's own on-screen list is what actually notices, and an empty
        /// display is the cue to take the strip away too.
        func displaysShowingWindows(among displays: [Display]) -> Set<String> {
            Set(windows.filter { $0.layer == 0 }
                .compactMap { Geometry.display(containing: $0.frame, among: displays)?.id })
        }

        /// The ordinary, visible apps with a window on these displays: the only
        /// ones a pass has anything to ask. An app living entirely on an
        /// unstaged monitor is never hidden, so it would otherwise be asked on
        /// every pass for nothing.
        ///
        /// Looked up by process ID. Walking NSWorkspace's runningApplications
        /// instead costs a LaunchServices round trip for every process on the
        /// Mac, well over a hundred of them, on every pass.
        func apps(on displays: [Display]) -> [NSRunningApplication] {
            Set(windows.filter { Geometry.display(containing: $0.frame, among: displays) != nil }.map(\.pid))
                .compactMap(NSRunningApplication.init(processIdentifier:))
                .filter { $0.activationPolicy == .regular && !$0.isTerminated && !$0.isHidden }
        }
    }

    static func snapshot() -> Snapshot { Snapshot() }

    /// Every ordinary, visible, movable window belonging to these apps.
    static func visibleWindows(of apps: [NSRunningApplication]) -> [ManagedWindow] {
        var result: [ManagedWindow] = []

        for app in apps {
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

    /// Displays whose visible Space is given over to a full-screen window.
    ///
    /// Restricted to windows on the Space in front of you, so a full-screen app
    /// sitting on some other desktop does not suppress the strip here.
    static func displaysWithFullScreenWindow(of apps: [NSRunningApplication],
                                             among displays: [Display],
                                             in snapshot: Snapshot) -> Set<String> {
        Set(fullScreenApps(of: apps, among: displays, in: snapshot).keys)
    }

    /// The same, with the apps whose full-screen window each display shows.
    static func fullScreenApps(of apps: [NSRunningApplication],
                               among displays: [Display],
                               in snapshot: Snapshot) -> [String: Set<pid_t>] {
        var result: [String: Set<pid_t>] = [:]

        for app in apps {
            for element in Accessibility.windows(ofPID: app.processIdentifier) {
                guard let id = Accessibility.windowID(element),
                      snapshot.onScreenIDs.contains(id),
                      Accessibility.isFullScreen(element),
                      let frame = Accessibility.frame(element),
                      let display = Geometry.display(containing: frame, among: displays)
                else { continue }
                result[display.id, default: []].insert(app.processIdentifier)
            }
        }
        return result
    }

    #if DEBUG
    // The diagnostics look at every screen at once.
    static func visibleWindows() -> [ManagedWindow] {
        visibleWindows(of: snapshot().apps(on: Display.connected))
    }

    static func displaysWithFullScreenWindow(among displays: [Display]) -> Set<String> {
        let snapshot = snapshot()
        return displaysWithFullScreenWindow(of: snapshot.apps(on: displays), among: displays, in: snapshot)
    }
    #endif

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
