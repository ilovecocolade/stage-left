import Foundation

/// Per-screen desired state, stored against the stable display UUID so a
/// monitor keeps its setting across unplugging, sleep and reboots.
final class Preferences {
    private enum Key {
        static let states = "screenStates"
        static let names = "screenNames"
        static let active = "activeScreenID"
        static let grouping = "groupsByApp"
        static let schema = "schemaVersion"
        static let menuBar = "showsMenuBarIcon"
        static let hidesDock = "hidesDockWhileStaging"
    }

    private let defaults = UserDefaults.standard

    init() {
        // Version 1 stored "apply Apple's switch from this screen". Version 2
        // means "Stagehand moves windows on this screen", which is a much
        // bigger promise — so old settings are cleared rather than reinterpreted.
        if defaults.integer(forKey: Key.schema) < 2 {
            defaults.removeObject(forKey: Key.states)
            defaults.removeObject(forKey: Key.active)
            defaults.set(2, forKey: Key.schema)
        }
    }

    private var states: [String: Bool] {
        get { defaults.dictionary(forKey: Key.states) as? [String: Bool] ?? [:] }
        set { defaults.set(newValue, forKey: Key.states) }
    }

    private var names: [String: String] {
        get { defaults.dictionary(forKey: Key.names) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: Key.names) }
    }

    /// Keep an app's other windows on stage alongside the focused one, which
    /// matches what Apple's Stage Manager does by default.
    var groupsByApp: Bool {
        get {
            if defaults.object(forKey: Key.grouping) == nil { return true }
            return defaults.bool(forKey: Key.grouping)
        }
        set { defaults.set(newValue, forKey: Key.grouping) }
    }

    /// Whether the menu bar icon is shown. With it hidden the app is driven
    /// entirely from Control Centre; opening Stagehand brings settings back.
    var showsMenuBarIcon: Bool {
        get {
            if defaults.object(forKey: Key.menuBar) == nil { return true }
            return defaults.bool(forKey: Key.menuBar)
        }
        set { defaults.set(newValue, forKey: Key.menuBar) }
    }

    /// Whether the Dock is set to auto-hide while staging is on. Off by default:
    /// it changes a system setting, and restarting the Dock makes it blink.
    var hidesDockWhileStaging: Bool {
        get { defaults.bool(forKey: Key.hidesDock) }
        set { defaults.set(newValue, forKey: Key.hidesDock) }
    }

    /// The screen whose setting the global switch currently reflects.
    var activeScreenID: String? {
        get { defaults.string(forKey: Key.active) }
        set { defaults.set(newValue, forKey: Key.active) }
    }

    /// Whether Stagehand manages this screen. A screen seen for the first time
    /// is left alone — plugging in a monitor must never start rearranging
    /// windows on it unasked.
    func state(for display: Display) -> Bool {
        if let known = states[display.id] { return known }
        states[display.id] = false
        names[display.id] = display.name
        return false
    }

    func setState(_ enabled: Bool, for display: Display) {
        states[display.id] = enabled
        names[display.id] = display.name
    }

    func name(for id: String) -> String? { names[id] }

    func forget(_ id: String) {
        states[id] = nil
        names[id] = nil
        if activeScreenID == id { activeScreenID = nil }
    }

    /// Screens we hold a setting for that are not plugged in right now.
    func remembered(excluding connected: [Display]) -> [(id: String, name: String, enabled: Bool)] {
        let live = Set(connected.map(\.id))
        return states
            .filter { !live.contains($0.key) }
            .map { (id: $0.key, name: names[$0.key] ?? "Unknown screen", enabled: $0.value) }
            .sorted { $0.name < $1.name }
    }
}
