#if DEBUG
// Debug builds only: see "Diagnostics" in the README for why.

import AppKit

/// Recreates the failure where a hidden app is left with nothing to bring it
/// back: hide it, record it, then die without cleaning up.
///
/// This is the bug that made apps vanish, so it is worth being able to
/// reproduce on demand rather than by accident.
enum StrandTest {
    /// Pass "Recorded,Unrecorded". The first is hidden and written to the
    /// ledger, standing in for a window Stage Left tucked. The second is hidden
    /// and deliberately not recorded, standing in for one the user hid with
    /// Cmd-H — Stage Left must leave that one alone.
    static func run(appNamed names: String) {
        let wanted = names.split(separator: ",").map(String.init)
        var recorded: [String] = []

        for (index, name) in wanted.enumerated() {
            guard let app = NSWorkspace.shared.runningApplications
                .first(where: { $0.localizedName == name }),
                  let bundleID = app.bundleIdentifier
            else { write("strand test: \(name) is not running\n"); continue }

            app.hide()
            if index == 0 { recorded.append(bundleID) }
            write("strand test: hid \(name)\(index == 0 ? " (recorded)" : " (NOT recorded)")\n")
        }

        UserDefaults.standard.set(recorded, forKey: "hiddenAppLedger")
        UserDefaults.standard.synchronize()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            write("strand test: exiting without restoring, as a crash would\n")
            exit(0)
        }
    }

    private static func write(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }
}
#endif
