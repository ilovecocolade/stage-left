#if DEBUG
// Debug builds only: see "Diagnostics" in the README for why.

import AppKit

/// Checks that a popup in a linked window's app keeps the group on stage.
///
/// Needs two copies of a helper app named PopTest running: one with a window
/// titled "PopTest Main" that opens an alert a few seconds after launch, and
/// one titled "PopTest Partner". Moves both onto the first staged screen,
/// links them, then reports the stage before and while the alert has focus.
enum PopupTest {
    static func run(engine: StageEngine) {
        func write(_ text: String) { FileHandle.standardError.write(Data(text.utf8)) }
        func after(_ seconds: Double, _ work: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        }
        func window(titled title: String) -> (app: NSRunningApplication, element: AXUIElement, id: CGWindowID)? {
            for app in NSWorkspace.shared.runningApplications where app.localizedName == "PopTest" {
                for element in Accessibility.windows(ofPID: app.processIdentifier)
                where Accessibility.title(element) == title {
                    if let id = Accessibility.windowID(element) { return (app, element, id) }
                }
            }
            return nil
        }

        after(1.5) {
            guard let display = Display.connected.first(where: { engine.leadWindow(on: $0) != nil }),
                  let frame = display.axVisibleFrame,
                  let main = window(titled: "PopTest Main"),
                  let partner = window(titled: "PopTest Partner")
            else {
                write("popup test: needs a staged screen and both PopTest windows (staged screen: \(Display.connected.contains { engine.leadWindow(on: $0) != nil }), main: \(window(titled: "PopTest Main") != nil), partner: \(window(titled: "PopTest Partner") != nil))\n")
                NSWorkspace.shared.runningApplications.filter { $0.localizedName == "PopTest" }.forEach { $0.forceTerminate() }
                exit(1)
            }

            _ = Accessibility.setPosition(main.element, CGPoint(x: frame.minX + 40, y: frame.minY + 40))
            _ = Accessibility.setPosition(partner.element, CGPoint(x: frame.minX + 480, y: frame.minY + 40))
            engine.links.toggle(partner.id, with: main.id)
            main.app.activate()
            _ = Accessibility.raise(main.element)

            func report(_ label: String) {
                engine.evaluate()
                let gone = Set(engine.tuckedWindows(on: display).map(\.id))
                let lead = engine.leadWindow(on: display)
                let button = engine.focusedStage.map { $0.window.id == main.id ? "on main" : "on \($0.window.id)" } ?? "hidden"
                write("  \(label): lead=\(lead == main.id ? "main" : String(lead ?? 0)), main tucked=\(gone.contains(main.id)), partner tucked=\(gone.contains(partner.id)), link button \(button)\n")
            }
            func finish(_ code: Int32) {
                engine.links.remove(main.id)
                main.app.forceTerminate()
                partner.app.forceTerminate()
                exit(code)
            }

            after(1.5) {
                report("main focused")
                var waited = 0.0
                func poll() {
                    let focused = WindowScanner.focusedWindow()
                    guard let popup = focused, popup.pid == main.app.processIdentifier, popup.id != main.id else {
                        waited += 0.25
                        if waited > 12 { write("popup test: the alert never took focus\n"); finish(1) }
                        after(0.25, poll)
                        return
                    }
                    // Put the alert on the staged screen, wherever AppKit opened it.
                    let moved = Accessibility.setPosition(popup.element, CGPoint(x: frame.minX + 200, y: frame.minY + 200))
                    let landed = Accessibility.frame(popup.element).flatMap { Geometry.display(containing: $0, among: Display.connected) }
                    write("  popup: subrole \(Accessibility.subrole(popup.element) ?? "none"), moved=\(moved), on \(landed?.name ?? "nothing"), staged screen \(display.name)\n")
                    after(1.0) {
                        report("popup focused")
                        finish(0)
                    }
                }
                poll()
            }
        }
    }
}
#endif
