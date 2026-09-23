import AppKit

/// A dry run: reports what the engine would stage, without moving anything.
///
/// Window scanning, display assignment and the coordinate flip are the parts
/// most likely to be subtly wrong, and getting them wrong means throwing
/// somebody's windows onto the wrong monitor. This checks them harmlessly.
enum SelfTest {
    static func run() {
        var out = "Stagehand dry run\n"

        guard Accessibility.isTrusted else {
            write(out + "  Accessibility NOT granted — nothing to report.\n")
            return
        }

        let displays = Display.connected
        let windows = WindowScanner.visibleWindows()
        let focused = WindowScanner.focusedWindow()
        let focusedDisplay = focused.flatMap { Geometry.display(containing: $0.axFrame, among: displays) }

        out += "  focused: \(focused.map { "\($0.appName) — \($0.title)" } ?? "none")"
        out += "  on \(focusedDisplay?.name ?? "unknown")\n"

        for display in displays {
            let screen = display.screen?.frame ?? .zero
            let ax = Geometry.axRect(fromScreen: screen)
            out += "\n  \(display.name)\n"
            out += "     AppKit frame \(fmt(screen))  ->  AX frame \(fmt(ax))\n"

            let onDisplay = windows.filter {
                Geometry.display(containing: $0.axFrame, among: displays)?.id == display.id
            }
            out += "     \(onDisplay.count) window(s)\n"

            for window in onDisplay {
                let wouldStay = window.id == focused?.id
                    || (focused.map { $0.pid == window.pid } ?? false)
                let mark = focusedDisplay?.id == display.id ? (wouldStay ? "stays " : "tucks ") : "     "
                out += "       \(mark)\(window.appName) — \(window.title)  \(fmt(window.axFrame))\n"
            }
        }

        write(out)
    }

    private static func fmt(_ rect: CGRect) -> String {
        "(\(Int(rect.minX)),\(Int(rect.minY))) \(Int(rect.width))x\(Int(rect.height))"
    }

    private static func write(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }
}
