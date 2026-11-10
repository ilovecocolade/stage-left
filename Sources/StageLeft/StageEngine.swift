import AppKit
import ApplicationServices

/// Stage Left's own Stage Manager.
///
/// On a display the user has marked as managed, only the focused window — and,
/// by default, its app's other windows there — stays on screen. Everything else
/// on that display is taken off stage and listed in a strip at the edge.
/// Displays that are not managed are never touched, which is the entire point.
final class StageEngine {
    private let prefs: Preferences
    private var tucked: [CGWindowID: TuckedWindow] = [:]
    private var evaluating = false
    /// The window each display was last working in, so a display can be staged
    /// without waiting for the user to click something on it.
    private var lastLead: [String: CGWindowID] = [:]
    /// The same windows' Accessibility elements, to recognise one closing.
    private var leadElements: [String: AXUIElement] = [:]

    private(set) var isRunning = false

    /// Windows the user has linked to go on and off stage together.
    let links = WindowLinks()

    /// The focused window, when it is the window a managed display is staged
    /// around: where the link button goes.
    private(set) var focusedStage: (window: ManagedWindow, display: Display)?

    /// The windows on stage on each managed display, as of the last pass.
    private var stageWindows: [String: [ManagedWindow]] = [:]

    /// Screens whose Space in front is a full-screen app, as last checked.
    /// Only managed screens are looked up in it, though an unmanaged one can
    /// appear when an app has windows on both. The strip's twice-a-second
    /// refresh reads this instead of asking every app again, because full
    /// screen comes and goes with the Space: every pass rewrites it, and while
    /// anything is tucked, so do Space changes and the strip's own rechecks.
    private(set) var fullScreenDisplays: Set<String> = []

    /// Managed screens whose staged window has left — closed, minimised, its
    /// app hidden or quit, or gone full screen — with nothing else on stage.
    /// The strip stays on such a desktop as the way back to the tucked
    /// windows, but does not follow you onto some other, empty desktop.
    private(set) var emptiedStages: Set<String> = []

    /// Fires after any change the strip or menu should reflect.
    var onStateChange: (() -> Void)?

    init(preferences: Preferences) {
        self.prefs = preferences
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning, Accessibility.isTrusted else { return }
        isRunning = true
        recoverFromPreviousRun()
        reconcileHiddenApps()
        AXObserverCenter.shared.onChange = { [weak self] in self?.evaluate() }
        AXObserverCenter.shared.isStagedWindow = { [weak self] element in
            self?.isStaged(element) ?? false
        }
        AXObserverCenter.shared.start()
        evaluate()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        AXObserverCenter.shared.stop()
        restoreAll()
    }

    // MARK: - Queries

    /// By app name, except that linked windows sit together, in the place of
    /// the first of them.
    func tuckedWindows(on display: Display) -> [TuckedWindow] {
        let here = tucked.values.filter { $0.homeDisplayID == display.id }
        var anchor: [CGWindowID: String] = [:]
        for window in here {
            guard let key = links.groupKey(of: window.id) else { continue }
            if let name = anchor[key], name.localizedCaseInsensitiveCompare(window.appName) != .orderedDescending { continue }
            anchor[key] = window.appName
        }
        func sortKey(_ window: TuckedWindow) -> (String, CGWindowID, String) {
            let key = links.groupKey(of: window.id)
            return (key.flatMap { anchor[$0] } ?? window.appName, key ?? 0, window.appName)
        }
        return here.sorted {
            let (a, b) = (sortKey($0), sortKey($1))
            if a.0 != b.0 { return a.0.localizedCaseInsensitiveCompare(b.0) == .orderedAscending }
            if a.1 != b.1 { return a.1 < b.1 }
            return a.2.localizedCaseInsensitiveCompare(b.2) == .orderedAscending
        }
    }

    /// Everything on the display the window is staged on, other than the
    /// window itself: what it can be linked with.
    func linkCandidates(for window: CGWindowID) -> [(id: CGWindowID, pid: pid_t, appName: String, title: String)] {
        guard let stage = focusedStage, stage.window.id == window else { return [] }
        let visible = (stageWindows[stage.display.id] ?? []).map { (id: $0.id, pid: $0.pid, appName: $0.appName, title: $0.title) }
        let away = tuckedWindows(on: stage.display).map { (id: $0.id, pid: $0.pid, appName: $0.appName, title: $0.title) }
        return (visible + away).filter { $0.id != window }
    }

    /// Links or unlinks, then restages so the change shows at once: a window
    /// linked from the strip comes onto the stage, one unlinked leaves it.
    func toggleLink(_ other: CGWindowID, with window: CGWindowID) {
        links.toggle(other, with: window)
        restage(around: window)
    }

    /// Takes the window out of its group. It stays on stage; the rest of the
    /// group leaves for the strip.
    func unlink(_ window: CGWindowID) {
        links.remove(window)
        restage(around: window)
    }

    /// Restages with `window` as its display's lead, even if focus has moved
    /// for a moment, so a link change always applies around the window whose
    /// button was used.
    private func restage(around window: CGWindowID) {
        if let stage = focusedStage, stage.window.id == window {
            lastLead[stage.display.id] = window
        }
        evaluate()
    }

    /// A strip tile clicked: the window comes back with everything linked to it.
    func bringBack(_ id: CGWindowID) {
        for member in links.group(of: id) where member != id { restore(member, activate: false) }
        restore(id, activate: true)
    }

    var tuckedCount: Int { tucked.count }

    /// The window this display is currently staged around, if any.
    func leadWindow(on display: Display) -> CGWindowID? {
        lastLead[display.id]
    }

    // MARK: - The main loop

    func evaluate() {
        guard isRunning, Accessibility.isTrusted, !evaluating else { return }
        evaluating = true
        defer { evaluating = false }

        pruneWindowsBroughtBackElsewhere()

        let displays = Display.connected
        let managed = managed(among: displays)

        // Anything belonging to a display we no longer manage comes straight
        // back. Snapshot first — restoring mutates what we are reading.
        let managedIDs = Set(managed.map(\.id))
        for window in Array(tucked.values) where !managedIDs.contains(window.homeDisplayID) {
            restore(window.id, activate: false)
        }

        focusedStage = nil
        links.prune()

        guard !managed.isEmpty else {
            fullScreenDisplays = []
            emptiedStages = []
            stageWindows = [:]
            persist()
            reconcileHiddenApps()
            onStateChange?()
            return
        }

        // Cmd-Tab can land on a window we took off stage. Bring it back first,
        // or the user activates an app and sees nothing. Restoring never moves
        // focus, so this stays the focused window for the rest of the pass.
        let focused = WindowScanner.focusedWindow()
        if let focused, tucked[focused.id] != nil {
            restore(focused.id, activate: false)
        }

        // Ask only the apps with a window on a staged screen. Their windows on
        // other screens still count below, for choosing between hiding and
        // minimising.
        let snapshot = WindowScanner.snapshot()
        let apps = snapshot.apps(on: managed)
        // An app that turned regular after launching is only caught here.
        AXObserverCenter.shared.watch(apps)
        // Only windows on the Space in front take part. Accessibility can name
        // one that is not: the focused window may be full screen on another
        // Space, and staging around that would empty this desktop.
        let visible = WindowScanner.visibleWindows(of: apps)
            .filter { tucked[$0.id] == nil && snapshot.onScreenIDs.contains($0.id) }
        let onStage = focused.flatMap { snapshot.onScreenIDs.contains($0.id) ? $0 : nil }
        let focusedDisplay = onStage.flatMap { Geometry.display(containing: $0.axFrame, among: displays) }

        let order = snapshot.frontToBackOrder
        let fullScreen = WindowScanner.displaysWithFullScreenWindow(of: apps, among: displays, in: snapshot)
        fullScreenDisplays = fullScreen

        for display in managed {
            // Swiping to a full-screen app puts it on its own Space and makes
            // it frontmost on this display. It is not a stage, so leave the
            // display's remembered lead alone and change nothing.
            guard !fullScreen.contains(display.id) else { continue }

            let onDisplay = visible.filter {
                Geometry.display(containing: $0.axFrame, among: displays)?.id == display.id
            }

            // Stage around whatever this display was last used for, rather than
            // waiting for it to be clicked. Turning staging on should take
            // effect straight away on every managed screen, not just the one
            // holding focus.
            let lead: ManagedWindow?
            if let onStage, focusedDisplay?.id == display.id {
                lead = onStage
            } else if let remembered = lastLead[display.id],
                      let match = onDisplay.first(where: { $0.id == remembered }) {
                lead = match
            } else {
                lead = onDisplay.min { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
            }

            guard let lead else {
                if Self.hasLeft(leadElements[display.id]) {
                    emptiedStages.insert(display.id)
                } else {
                    emptiedStages.remove(display.id)
                }
                continue
            }
            emptiedStages.remove(display.id)
            lastLead[display.id] = lead.id
            leadElements[display.id] = lead.element
            if lead.id == onStage?.id { focusedStage = (lead, display) }

            var keep: Set<CGWindowID> = [lead.id]
            if prefs.groupsByApp {
                keep.formUnion(onDisplay.filter { $0.pid == lead.pid }.map(\.id))
                keep.formUnion(tuckedWindows(on: display).filter { $0.pid == lead.pid }.map(\.id))
            }
            keep.formUnion(links.group(of: lead.id))
            stageWindows[display.id] = onDisplay.filter { keep.contains($0.id) }

            for window in tuckedWindows(on: display) where keep.contains(window.id) {
                restore(window.id, activate: false)
            }
            takeOffStage(on: display, keeping: keep, candidates: onDisplay, allVisible: visible)
        }

        persist()
        reconcileHiddenApps()
        onStateChange?()
    }

    /// Re-reads which managed screens show a full-screen app, for the strip.
    func refreshFullScreen(using snapshot: WindowScanner.Snapshot = WindowScanner.snapshot()) {
        guard isRunning, Accessibility.isTrusted else { return }
        let displays = Display.connected
        let managed = managed(among: displays)
        fullScreenDisplays = managed.isEmpty ? [] : WindowScanner.displaysWithFullScreenWindow(
            of: snapshot.apps(on: managed), among: displays, in: snapshot)
    }

    /// Whether an element is a window Stage Left is staging around or has
    /// tucked away, so that its closing calls for a fresh pass.
    private func isStaged(_ element: AXUIElement) -> Bool {
        tucked.values.contains { CFEqual($0.element, element) }
            || leadElements.values.contains { CFEqual($0, element) }
    }

    /// The master switch wins over the per-screen settings: off means every
    /// screen is left alone, and anything already off stage comes back.
    private func managed(among displays: [Display]) -> [Display] {
        SharedState.isStaging ? displays.filter { prefs.state(for: $0) } : []
    }

    /// Forgets windows that are back on screen without us restoring them.
    ///
    /// The Dock, Mission Control, Cmd-Tab and taking a window full screen all
    /// un-minimise or unhide behind our back. Left alone those windows stay
    /// listed in the strip for something already visible.
    private func pruneWindowsBroughtBackElsewhere() {
        // Snapshot first — removing while iterating a dictionary is undefined.
        for (id, window) in Array(tucked) {
            // Give the hide or minimise time to actually take effect — unless
            // the window or its app has gone, when there is nothing to wait for.
            guard Date().timeIntervalSince(window.tuckedAt) > 1.5 || !Self.stillExists(window)
            else { continue }

            let stillOffStage: Bool
            switch window.method {
            case .minimized:
                stillOffStage = Accessibility.isMinimized(window.element)
            case .appHidden:
                stillOffStage = NSRunningApplication(processIdentifier: window.pid)?.isHidden ?? false
            }
            if !stillOffStage { tucked.removeValue(forKey: id) }
        }
    }

    private static func hasLeft(_ element: AXUIElement?) -> Bool {
        guard let element else { return false }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              let app = NSRunningApplication(processIdentifier: pid),
              !app.isTerminated, !app.isHidden
        else { return true }
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .invalidUIElement {
            return true
        }
        return Accessibility.isMinimized(element) || Accessibility.isFullScreen(element)
    }

    private static func stillExists(_ window: TuckedWindow) -> Bool {
        guard NSRunningApplication(processIdentifier: window.pid) != nil else { return false }
        var role: CFTypeRef?
        return AXUIElementCopyAttributeValue(window.element, kAXRoleAttribute as CFString, &role)
            != .invalidUIElement
    }

    // MARK: - Taking windows off stage

    private func takeOffStage(on display: Display,
                              keeping keep: Set<CGWindowID>,
                              candidates: [ManagedWindow],
                              allVisible: [ManagedWindow]) {
        for (pid, windowsHere) in Dictionary(grouping: candidates, by: \.pid) {
            let leaving = windowsHere.filter { !keep.contains($0.id) }
            guard !leaving.isEmpty else { continue }

            let idsHere = Set(windowsHere.map(\.id))
            let keepsSomethingHere = windowsHere.contains { keep.contains($0.id) }
            let hasWindowsElsewhere = allVisible.contains { $0.pid == pid && !idsHere.contains($0.id) }

            // Hiding is instant and animation-free, but it takes every window
            // with it — so only when the app is entirely on this display and is
            // keeping nothing on stage.
            if !keepsSomethingHere, !hasWindowsElsewhere,
               let app = NSRunningApplication(processIdentifier: pid) {
                // The return value of hide() is not dependable; the state change is.
                app.hide()
                for window in windowsHere { record(window, on: display, method: .appHidden) }
            } else {
                for window in leaving where minimize(window) {
                    record(window, on: display, method: .minimized)
                }
            }
        }
    }

    private func minimize(_ window: ManagedWindow) -> Bool {
        AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString,
                                     kCFBooleanTrue) == .success
    }

    private func record(_ window: ManagedWindow, on display: Display, method: TuckMethod) {
        tucked[window.id] = TuckedWindow(
            id: window.id,
            pid: window.pid,
            element: window.element,
            appName: window.appName,
            title: window.title,
            bundleID: NSRunningApplication(processIdentifier: window.pid)?.bundleIdentifier,
            homeDisplayID: display.id,
            method: method,
            tuckedAt: Date())
    }

    // MARK: - Bringing windows back

    @discardableResult
    func restore(_ id: CGWindowID, activate: Bool) -> Bool {
        guard let window = tucked[id] else { return false }
        let app = NSRunningApplication(processIdentifier: window.pid)

        switch window.method {
        case .appHidden:
            app?.unhide()
            confirmUnhidden(pid: window.pid)
            // Unhiding brings back every window that app owns, so none of them
            // is off stage any more. Snapshot the keys first — removing while
            // iterating a dictionary is undefined behaviour.
            for key in Array(tucked.keys) where tucked[key]?.pid == window.pid
                && tucked[key]?.method == .appHidden {
                tucked.removeValue(forKey: key)
            }
        case .minimized:
            AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            tucked.removeValue(forKey: id)
        }

        if activate {
            Accessibility.raise(window.element)
            app?.activate()
        }
        persist()
        return true
    }

    /// `unhide()` reports success unreliably, and an app left hidden is the
    /// worst outcome this app can produce — so check, retry, and finally
    /// activate, which always forces an app back into view.
    private func confirmUnhidden(pid: pid_t) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard let app = NSRunningApplication(processIdentifier: pid), app.isHidden else { return }
            app.unhide()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard let app = NSRunningApplication(processIdentifier: pid), app.isHidden else { return }
                NSLog("Stage Left: %@ stayed hidden, activating to recover",
                      app.localizedName ?? "an app")
                app.activate()
            }
        }
    }

    func restoreAll() {
        for id in Array(tucked.keys) { restore(id, activate: false) }
        persist()
        reconcileHiddenApps()
        onStateChange?()
    }

    /// Unhides every hidden app, whether or not Stage Left hid it. The manual
    /// way out if apps have gone missing.
    @discardableResult
    func unhideEverything() -> [String] {
        var restored: [String] = []
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.isHidden {
            app.unhide()
            confirmUnhidden(pid: app.processIdentifier)
            restored.append(app.localizedName ?? "unknown")
        }
        hiddenLedger = []
        return restored
    }

    // MARK: - Surviving a crash

    private static let hiddenLedgerKey = "hiddenAppLedger"
    private static let hiddenAppsKey = "tuckedHiddenApps"
    private static let minimizedKey = "tuckedMinimizedWindows"

    /// Nothing is moved off-screen, so a crash cannot lose a window — but it
    /// could leave apps hidden and windows minimised. Both are still reachable
    /// from the Dock, and both lists are written after every change and undone
    /// at the next launch.
    /// Every app Stage Left has hidden, held separately from `tucked`.
    ///
    /// A hidden app that falls out of `tucked` — a stale prune, a lost entry —
    /// becomes invisible to everything: the strip does not list it, the window
    /// scanner skips hidden apps, and nothing ever unhides it. The app is then
    /// gone until the user finds it in the Dock. This ledger is the record that
    /// makes that recoverable.
    private var hiddenLedger: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.hiddenLedgerKey) ?? []) }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: Self.hiddenLedgerKey)
            // Flush now. The point of the ledger is to survive being killed, and
            // a write still sitting in memory would not.
            UserDefaults.standard.synchronize()
        }
    }

    /// Brings back any app we hid but no longer account for, then rewrites the
    /// ledger from what is actually tucked. Runs on every pass, so a lost entry
    /// heals itself within a second instead of stranding the app.
    private func reconcileHiddenApps() {
        let accountedFor = Set(tucked.values.filter { $0.method == .appHidden }.compactMap(\.bundleID))
        var recovered = false

        for bundleID in hiddenLedger.subtracting(accountedFor) {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            where app.isHidden {
                app.unhide()
                confirmUnhidden(pid: app.processIdentifier)
                recovered = true
            }
        }
        hiddenLedger = accountedFor

        // Unhiding raises no notification of its own, so nothing would prompt
        // another look and the recovered windows would sit unstaged. The ledger
        // is empty by now, so this settles rather than repeating.
        if recovered {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.evaluate() }
        }
    }

    private func persist() {
        let hidden = Set(tucked.values.filter { $0.method == .appHidden }.compactMap(\.bundleID))
        let minimized = tucked.values.filter { $0.method == .minimized }.map { Int($0.id) }
        UserDefaults.standard.set(Array(hidden), forKey: Self.hiddenAppsKey)
        UserDefaults.standard.set(minimized, forKey: Self.minimizedKey)
        UserDefaults.standard.synchronize()
    }

    private func recoverFromPreviousRun() {
        let defaults = UserDefaults.standard

        if let bundleIDs = defaults.stringArray(forKey: Self.hiddenAppsKey) {
            for id in bundleIDs {
                for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) { app.unhide() }
            }
        }

        if let ids = defaults.array(forKey: Self.minimizedKey) as? [Int], !ids.isEmpty {
            let wanted = Set(ids.map { CGWindowID($0) })
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
                for element in Accessibility.windows(ofPID: app.processIdentifier) {
                    guard let id = Accessibility.windowID(element), wanted.contains(id) else { continue }
                    AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                }
            }
        }

        defaults.removeObject(forKey: Self.hiddenAppsKey)
        defaults.removeObject(forKey: Self.minimizedKey)
    }
}
