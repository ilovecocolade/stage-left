import Foundation

/// The one switch macOS actually exposes.
///
/// Stage Manager has no per-display state anywhere in macOS 27. The
/// WindowManager binary only ever talks about `setStageManagerGloballyEnabled`,
/// and the preference domain holds a single `GloballyEnabled` boolean. Writing
/// it takes effect in well under a second with no process restart, which is
/// what makes this app viable at all.
enum StageManager {
    private static let domain = "com.apple.WindowManager" as CFString
    private static let key = "GloballyEnabled" as CFString

    static var isEnabled: Bool {
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue(key, domain) as? Bool ?? false
    }

    /// Writes the switch and returns whether WindowManager accepted it.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        CFPreferencesSetAppValue(key, enabled as CFBoolean, domain)
        guard CFPreferencesAppSynchronize(domain) else { return false }
        return isEnabled == enabled
    }

    @discardableResult
    static func toggle() -> Bool {
        setEnabled(!isEnabled)
    }
}
