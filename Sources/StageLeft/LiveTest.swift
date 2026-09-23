#if DEBUG
// Debug builds only: see "Diagnostics" in the README for why.

import AppKit

/// Stages a real display for a moment, then puts everything back.
///
/// The dry run proves the geometry; this proves windows actually leave the
/// stage and, more importantly, that they come home again.
enum LiveTest {
    static func run(engine: StageEngine, preferences: Preferences) {
        let displays = Display.connected
        let windows = WindowScanner.visibleWindows()
        let previouslyActive = NSWorkspace.shared.frontmostApplication

        // Pick the display with the most windows: the one where staging has
        // something to prove.
        let counts = displays.map { display in
            (display, windows.filter { Geometry.display(containing: $0.axFrame, among: displays)?.id == display.id })
        }
        guard let (target, targetWindows) = counts.max(by: { $0.1.count < $1.1.count }),
              targetWindows.count > 1,
              let lead = targetWindows.first
        else { write("live test: need a display with 2+ windows, skipping\n"); return }

        write("live test: staging \(target.name) — \(targetWindows.map(\.appName).joined(separator: ", "))\n")

        // The engine only stages the display holding focus, so put focus there.
        NSRunningApplication(processIdentifier: lead.pid)?.activate()
        preferences.setState(true, for: target)

        after(1.0) {
            engine.evaluate()
            after(1.5) {
                write("  tucked \(engine.tuckedCount): \(engine.tuckedWindows(on: target).map(\.appName).joined(separator: ", "))\n")
                report("staged")

                preferences.setState(false, for: target)
                engine.evaluate()
                engine.restoreAll()

                after(1.5) {
                    report("restored")
                    write("  still tucked (must be 0): \(engine.tuckedCount)\n")
                    previouslyActive?.activate()
                    write("live test: done, focus returned to \(previouslyActive?.localizedName ?? "?")\n")
                }
            }
        }
    }

    private static func report(_ label: String) {
        let names = WindowScanner.visibleWindows().map(\.appName).sorted().joined(separator: ", ")
        write("  [\(label)] visible: \(names)\n")
        write("  [\(label)] strip panels on screen: \(ownWindowsOnScreen())\n")
    }

    /// The strip is a real panel, so it shows up in the window list. Anything
    /// other than 0 while staged means the user can actually see it.
    private static func ownWindowsOnScreen() -> Int {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.filter { ($0[kCGWindowOwnerName as String] as? String) == "Stage Left" }.count
    }

    private static func after(_ seconds: Double, _ block: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: block)
    }

    private static func write(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }
}
#endif
