#if DEBUG
// Debug builds only: see "Diagnostics" in the README for why.

import AppKit
import ApplicationServices

/// Reports which windows macOS considers full screen.
///
/// Whether the strip appears on another Space hangs entirely on this one
/// signal, and it cannot be judged from a normal desktop — so it is worth being
/// able to ask directly.
enum FullScreenSurvey {
    /// Lists every window the system reports as full screen, across all
    /// Spaces, so the signal can be checked without staging anything.
    static func run() {
        guard Accessibility.isTrusted else { write("no accessibility\n"); return }
        let displays = Display.connected
        let onScreen = WindowScanner.onScreenWindowIDs()
        var found = 0

        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && !app.isTerminated {
            for element in Accessibility.windows(ofPID: app.processIdentifier) {
                guard Accessibility.isFullScreen(element) else { continue }
                found += 1
                let id = Accessibility.windowID(element)
                let here = id.map { onScreen.contains($0) } ?? false
                let display = Accessibility.frame(element)
                    .flatMap { Geometry.display(containing: $0, among: displays) }
                write("  FULL SCREEN: \(app.localizedName ?? "?") — onThisSpace=\(here) display=\(display?.name ?? "unknown")\n")
            }
        }
        write("full-screen windows found: \(found)\n")
        write("engine sees these displays as full screen: \(report(displays))\n")
    }

    private static func report(_ displays: [Display]) -> String {
        let full = WindowScanner.displaysWithFullScreenWindow(among: displays)
        return full.isEmpty ? "no full-screen display"
            : displays.filter { full.contains($0.id) }.map(\.name).joined(separator: ", ")
    }

    private static func after(_ seconds: Double, _ block: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: block)
    }

    private static func write(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }
}
#endif
