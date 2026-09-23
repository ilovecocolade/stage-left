import AppKit

/// Reads and changes the Dock's "Automatically hide and show the Dock" setting.
///
/// macOS 27 gives another app no live way to change this. The private CoreDock
/// calls are gone, System Events accepts `set autohide of dock preferences` but
/// changes nothing, a synthesised ⌥⌘D has no effect, and the Dock does not
/// reload the preference on its own. It does read it on startup, so the setting
/// is written and the Dock restarted. The Dock blinks for about a second;
/// everything in it, minimised windows included, comes back.
enum DockAutohide {
    private static let domain = "com.apple.dock" as CFString

    static var isEnabled: Bool {
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue("autohide" as CFString, domain) as? Bool ?? false
    }

    static func set(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        CFPreferencesSetAppValue("autohide" as CFString, enabled as CFBoolean, domain)
        CFPreferencesAppSynchronize(domain)
        // launchd starts the Dock again immediately, reading the new setting.
        for dock in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock") {
            kill(dock.processIdentifier, SIGTERM)
        }
    }
}

/// Hides the Dock while staging is on, and hands it back exactly as it was.
///
/// The user's own setting is saved the moment Stage Left takes the Dock over and
/// put back when staging stops. It is kept on disk, so a crash while the Dock
/// is hidden is undone at the next launch.
final class DockController {
    private static let savedKey = "dockAutohideBeforeStageLeft"
    private let defaults = UserDefaults.standard

    /// Safe to call on every state change: it only acts on a transition.
    func apply(active: Bool) {
        let saved = defaults.object(forKey: Self.savedKey) as? Bool
        if active {
            guard saved == nil else { return }   // already hidden by us
            defaults.set(DockAutohide.isEnabled, forKey: Self.savedKey)
            defaults.synchronize()
            DockAutohide.set(true)
        } else if let saved {
            defaults.removeObject(forKey: Self.savedKey)
            defaults.synchronize()
            DockAutohide.set(saved)
        }
    }
}
