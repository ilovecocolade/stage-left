import AppKit
import ApplicationServices

/// Watches every running app for window activity.
///
/// Polling for focus changes is both slow and wasteful, so instead we attach an
/// Accessibility observer to each ordinary app. Every event is funnelled into
/// one coalesced callback — the engine recomputes from scratch, so it does not
/// matter which particular thing happened.
final class AXObserverCenter {
    static let shared = AXObserverCenter()

    private var observers: [pid_t: AXObserver] = [:]
    private var pending: DispatchWorkItem?

    /// Called on the main queue, at most once per coalescing window.
    var onChange: (() -> Void)?

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
                     NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            center.addObserver(self, selector: #selector(workspaceChanged), name: name, object: nil)
        }
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
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<AXObserverCenter>.fromOpaque(refcon).takeUnretainedValue().signal()
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
