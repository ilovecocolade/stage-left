#if DEBUG
// Debug builds only: see "Diagnostics" in the README for why.

import AppKit
import ApplicationServices

/// Reports and un-minimises windows.
///
/// A safety hatch for windows left minimised by a crash or a bad run. Pass
/// "list" to see what is minimised without changing anything, "all" to restore
/// every one, or a comma-separated list of Accessibility window IDs.
enum Rescue {
    static func run(argument: String) {
        guard Accessibility.isTrusted else { return }

        let restoreAll = argument == "all"
        let listOnly = argument == "list"
        let wanted = Set(argument.split(separator: ",").compactMap { CGWindowID($0) })
        var found = 0, restored = 0

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            for element in Accessibility.windows(ofPID: app.processIdentifier) {
                guard Accessibility.isMinimized(element) else { continue }
                found += 1
                let id = Accessibility.windowID(element).map(String.init) ?? "?"
                let title = Accessibility.title(element) ?? "(untitled)"
                write("  minimised: \(app.localizedName ?? "?") #\(id) — \(title)\n")

                guard !listOnly else { continue }
                guard restoreAll || Accessibility.windowID(element).map(wanted.contains) == true else { continue }
                AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                restored += 1
            }
        }
        write("rescue: \(found) minimised, \(restored) restored\n")
    }

    private static func write(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }
}
#endif
