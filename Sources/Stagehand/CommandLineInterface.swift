import AppKit

/// A tiny command line, so a Shortcut can drive Stagehand.
///
/// This is how the Control Centre button works: Control Centre can host a
/// Shortcut, and a Shortcut can run a shell command. That sidesteps needing a
/// widget extension of our own, which cannot be built without Xcode.
enum CommandLineInterface {
    /// Returns true when the arguments were a command, meaning the process
    /// should exit rather than bring up the menu bar app.
    static func handle(_ arguments: [String]) -> Bool {
        guard let command = arguments.first else { return false }

        switch command {
        case "--on", "--builtin-only":
            stageBuiltInOnly()
        case "--off":
            setStaging(false)
        case "--toggle":
            if SharedState.isStaging { setStaging(false) } else { stageBuiltInOnly() }
        case "--status":
            break
        case "--unhide-all":
            unhideAll()
            return true
        case "--help", "-h":
            usage()
            return true
        default:
            write("Stagehand: unknown option \(command)\n")
            usage()
            exit(2)
        }

        report()
        // Give the distributed notification time to reach the running app
        // before this process goes away.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        return true
    }

    /// The preset: stage the built-in screen, leave every external one alone.
    ///
    /// Written out in full each time rather than remembered, so it lands the
    /// same way at any desk, whatever monitor happens to be plugged in.
    private static func stageBuiltInOnly() {
        let preferences = Preferences()
        for display in Display.connected {
            preferences.setState(display.isBuiltin, for: display)
        }
        setStaging(true)
    }

    /// Unhides every hidden app, whether or not Stagehand hid it.
    ///
    /// The way out if apps have gone missing. Hiding is how Stagehand takes a
    /// whole app off stage, so a lost record used to mean the app stayed hidden
    /// with nothing left to bring it back.
    private static func unhideAll() {
        let hidden = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.isHidden }
        guard !hidden.isEmpty else { write("nothing was hidden\n"); return }

        for app in hidden { app.unhide() }
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))

        // unhide() reports success unreliably, so check and try once more.
        let stubborn = hidden.filter { $0.isHidden }
        for app in stubborn { app.unhide() }
        if !stubborn.isEmpty { RunLoop.current.run(until: Date().addingTimeInterval(1.5)) }

        let names = hidden.map { $0.localizedName ?? "unknown" }
        let stillHidden = hidden.filter { $0.isHidden }.map { $0.localizedName ?? "unknown" }
        write("unhid \(names.count): \(names.joined(separator: ", "))\n")
        if !stillHidden.isEmpty {
            write("STILL HIDDEN: \(stillHidden.joined(separator: ", "))\n")
        }
    }

    private static func setStaging(_ on: Bool) {
        SharedState.isStaging = on
        SharedState.announceChange()
    }

    private static func report() {
        let staged = Display.connected
            .filter { Preferences().state(for: $0) }
            .map(\.name)
        if SharedState.isStaging, !staged.isEmpty {
            write("staging on: \(staged.joined(separator: ", "))\n")
        } else {
            write("staging off\n")
        }
    }

    private static func usage() {
        write("""
            Stagehand

              --on, --builtin-only   Stage the built-in screen only
              --off                  Stop staging everywhere
              --toggle               Switch between the two
              --status               Print the current state
              --unhide-all           Bring back every hidden app

            With no options, Stagehand runs as a menu bar app.

            """)
    }

    private static func write(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }
}
