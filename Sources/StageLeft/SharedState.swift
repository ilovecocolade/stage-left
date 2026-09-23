import Foundation

/// The handful of things the app and its Control Centre extension both need.
///
/// They are separate processes, so this is deliberately the smallest possible
/// surface: one boolean, one notification, and the names they agree on. The
/// per-screen settings stay private to the app.
enum SharedState {
    /// An app group, because the Control Centre extension is sandboxed and
    /// cannot otherwise see the app's preferences. Its name must start with the
    /// signing team, so build.sh works it out from the certificate and records
    /// it in each bundle's Info.plist rather than it being fixed in the source.
    static let suiteName: String =
        Bundle.main.object(forInfoDictionaryKey: "StageLeftAppGroup") as? String ?? "io.github.ilovecocolade.stageleft.shared"
    static let controlKind = "io.github.ilovecocolade.stageleft.staging"
    static let changed = Notification.Name("io.github.ilovecocolade.stageleft.stateChanged")
    static let showSettings = Notification.Name("io.github.ilovecocolade.stageleft.showSettings")

    private static let activeKey = "stagingActive"

    /// The master switch. Off means every screen is left alone, whatever it is
    /// individually set to. Defaults to on so the app works out of the box.
    ///
    /// Read through CFPreferences rather than UserDefaults: the two processes
    /// write this independently, and only an explicit synchronise reliably
    /// picks up a change made by the other one.
    static var isStaging: Bool {
        get {
            CFPreferencesAppSynchronize(suiteName as CFString)
            return CFPreferencesCopyAppValue(activeKey as CFString, suiteName as CFString) as? Bool ?? true
        }
        set {
            CFPreferencesSetAppValue(activeKey as CFString, newValue as CFBoolean, suiteName as CFString)
            CFPreferencesAppSynchronize(suiteName as CFString)
        }
    }

    /// Asks the running menu bar app to bring up its settings window.
    static func requestSettings() {
        DistributedNotificationCenter.default().postNotificationName(
            showSettings, object: nil, userInfo: nil, deliverImmediately: true)
    }

    /// Tells the other process the switch moved.
    static func announceChange() {
        DistributedNotificationCenter.default().postNotificationName(
            changed, object: nil, userInfo: nil, deliverImmediately: true)
    }
}
