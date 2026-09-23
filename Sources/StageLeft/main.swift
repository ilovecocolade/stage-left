import AppKit

// A command means "do this and exit", not "open the menu bar app".
if CommandLineInterface.handle(Array(CommandLine.arguments.dropFirst())) {
    exit(0)
}

// Opening Stage Left while it is already running should show its settings, not
// start a rival copy. Hand over to the running one and bow out.
guard SingleInstance.claim() else {
    SharedState.requestSettings()
    exit(0)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
