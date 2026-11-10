import AppKit
import ApplicationServices

/// Watches every running app for window activity.
///
/// Polling for focus changes is both slow and wasteful, so instead we attach an
/// Accessibility observer to each ordinary app. Events are funnelled into one
/// coalesced callback — the engine recomputes from scratch, so it does not
/// matter which particular thing happened. The exception is an element being
/// destroyed, which counts only when it was a window on stage or tucked away.
final class AXObserverCenter {
    static let shared = AXObserverCenter()

    private var observers: [pid_t: AXObserver] = [:]
    private var pending: DispatchWorkItem?

    /// Called on the main queue, at most once per coalescing window.
    var onChange: (() -> Void)?

    /// Whether an element that has just been destroyed was a window on stage
    /// or tucked away.
    var isStagedWindow: ((AXUIElement) -> Bool)?

    private static let watched = [
        kAXFocusedWindowChangedNotification,
        kAXMainWindowChangedNotification,
        kAXWindowCreatedNotification,
        kAXUIElementDestroyedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
        kAXApplicationActivatedNotification,
    ]

    private init() {}

    func start() {
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(self, selector: #selector(workspaceChanged), name: name, object: nil)
        }
        center.addObserver(self, selector: #selector(appActivated(_:)),
                           name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    func stop() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        for pid in Array(observers.keys) { detach(pid) }
        pending?.cancel()
    }

    @objc private func workspaceChanged() {
        refresh()
        signal()
    }

    /// Every app switch lands here, so attach just the app that came forward
    /// — one that turned regular after launching — rather than re-checking
    /// every process on the Mac, which costs a LaunchServices round trip each.
    @objc private func appActivated(_ note: Notification) {
        if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
           observers[app.processIdentifier] == nil,
           app.activationPolicy == .regular, !app.isTerminated {
            attach(app.processIdentifier)
        }
        signal()
    }

    /// Attach to any of these apps not yet watched. Cheap: no process walk.
    func watch(_ apps: [NSRunningApplication]) {
        for app in apps where observers[app.processIdentifier] == nil { attach(app.processIdentifier) }
    }

    /// Attach to apps we have not seen, drop the ones that have quit.
    func refresh() {
        let live = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated }
            .map(\.processIdentifier)
        let liveSet = Set(live)

        for pid in Array(observers.keys) where !liveSet.contains(pid) { detach(pid) }
        for pid in live where observers[pid] == nil { attach(pid) }
    }

    private func attach(_ pid: pid_t) {
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }

        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let center = Unmanaged<AXObserverCenter>.fromOpaque(refcon).takeUnretainedValue()
            // Watched on the whole app, 'destroyed' fires for every menu, list
            // row and tooltip the app tears down, and most passes used to start
            // here. Only a staged window closing matters: a tucked one's tile
            // must go, and a stage whose window closed needs a new one.
            if (notification as String) == kAXUIElementDestroyedNotification,
               center.isStagedWindow?(element) != true { return }
            center.signal()
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }

        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for notification in Self.watched {
            AXObserverAddNotification(observer, appElement, notification as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    private func detach(_ pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    /// Window events arrive in bursts — one user action can fire five
    /// notifications — so settle briefly before doing any real work.
    private func signal() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange?() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }
}
