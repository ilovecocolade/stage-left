// Stand-in app for STAGELEFT_POPUPTEST. Build: swiftc Tools/popup-helper.swift -o /tmp/PopTest
// Run two copies: `/tmp/PopTest partner &` and `/tmp/PopTest panel &` (or `window`).
import AppKit
// PopTest [partner | panel | window]: a main window that opens a popup after 7
// seconds — an NSPanel ("panel", the default) or a full NSWindow ("window").
let args = CommandLine.arguments
let partner = args.contains("partner")
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 400, height: 300),
                      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
window.title = partner ? "PopTest Partner" : "PopTest Main"
window.makeKeyAndOrderFront(nil)
var popup: NSWindow?
if !partner {
    DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
        let rect = NSRect(x: 300, y: 300, width: 300, height: 160)
        popup = args.contains("window")
            ? NSWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            : NSPanel(contentRect: rect, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        popup?.title = "Your token"
        popup?.isReleasedWhenClosed = false
        popup?.makeKeyAndOrderFront(nil)
    }
}
app.run()
