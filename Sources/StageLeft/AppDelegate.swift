import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = MenuController()
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSignalHandlers()
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutDown()
    }

    /// Opening Stage Left shows settings — the only way back to them once the
    /// menu bar icon is hidden.
    ///
    /// This fires when the app is opened from Finder, Spotlight or the Dock,
    /// whether or not it was already running. Starting at login does not send
    /// it, so Stage Left comes up silently every morning.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller.showSettings()
        return true
    }

    /// Parked windows live off-screen, so being killed without putting them back
    /// would strand the user's windows. `applicationWillTerminate` does not run
    /// for a plain `kill`, so catch the signals too.
    private func installSignalHandlers() {
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                self?.controller.shutDown()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
