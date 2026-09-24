import Foundation
import notify

/// How the app, its command line and its Control Centre button talk.
///
/// The command line is the app's own binary, so the two share the app's
/// preferences and signal each other with distributed notifications.
///
/// The button is a separate, sandboxed process that cannot read those
/// preferences. It reaches the running app over Darwin notifications instead:
/// the app publishes whether it is staging as a notification's state, and the
/// button posts a request to change it. An app group could share the
/// preferences directly, but only for apps signed by a paid developer team;
/// this works however the app is signed, including the anonymous downloads.
enum SharedState {
    private static let prefix = "io.github.ilovecocolade.stageleft"
    static let controlKind = "\(prefix).staging"

    /// The master switch changed; the running app should act on it.
    static let changed = Notification.Name("\(prefix).stateChanged")
    /// A second launch asking the running app to show its settings.
    static let showSettings = Notification.Name("\(prefix).showSettings")

    private static let activeKey = "stagingActive" as CFString

    /// The master switch. Off means every screen is left alone, whatever it is
    /// individually set to. Read through CFPreferences with an explicit
    /// synchronise so the app always sees the command line's writes.
    static var isStaging: Bool {
        get {
            CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
            return CFPreferencesCopyAppValue(activeKey, kCFPreferencesCurrentApplication) as? Bool ?? true
        }
        set {
            CFPreferencesSetAppValue(activeKey, newValue as CFBoolean, kCFPreferencesCurrentApplication)
            CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        }
    }

    /// Tells the running app the switch moved.
    static func announceChange() { post(changed) }

    /// Asks the running app to bring up its settings window.
    static func requestSettings() { post(showSettings) }

    private static func post(_ name: Notification.Name) {
        DistributedNotificationCenter.default().postNotificationName(
            name, object: nil, userInfo: nil, deliverImmediately: true)
    }

    // MARK: - The Control Centre button

    /// Holds 1 while the running app is staging. notifyd keeps the value only
    /// while the app is registered for it, so it reads 0 once the app quits.
    private static let stateName = "\(prefix).state"
    private static let requestOnName = "\(prefix).request.on"
    private static let requestOffName = "\(prefix).request.off"

    /// The app's registration for `stateName`, held for its lifetime.
    private static let stateToken: Int32 = {
        var token: Int32 = 0
        notify_register_check(stateName, &token)
        return token
    }()

    /// The app: tells the button whether it is staging.
    static func publish(_ on: Bool) {
        notify_set_state(stateToken, on ? 1 : 0)
        notify_post(stateName)
    }

    /// The app: acts on the button's requests, on the main queue.
    static func onRequest(_ handler: @escaping (Bool) -> Void) {
        for (name, on) in [(requestOnName, true), (requestOffName, false)] {
            var token: Int32 = 0 // Never cancelled: the app listens for its lifetime.
            notify_register_dispatch(name, &token, DispatchQueue.main) { _ in handler(on) }
        }
    }

    /// The button: whether the running app says it is staging.
    static var publishedState: Bool {
        var token: Int32 = 0
        guard notify_register_check(stateName, &token) == NOTIFY_STATUS_OK else { return false }
        defer { notify_cancel(token) }
        var state: UInt64 = 0
        notify_get_state(token, &state)
        return state == 1
    }

    /// The button: asks the app to switch staging on or off, then waits up to a
    /// second for it to answer, so Control Centre redraws with the result. If
    /// the app is not running nothing answers, and the button falls back to off.
    static func request(_ on: Bool) async {
        notify_post(on ? requestOnName : requestOffName)
        for _ in 0..<50 {
            if publishedState == on { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
