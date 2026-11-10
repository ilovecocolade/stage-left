#if DEBUG
// Debug builds only: see "Diagnostics" in the README for why.

import AppKit

/// Unlinks the lead of the first staged screen from its group and checks the
/// rest of the group leaves for the strip, then links them again and checks
/// they come back. Leaves the group as it found it.
enum LinkTest {
    static func run(engine: StageEngine) {
        func write(_ text: String) { FileHandle.standardError.write(Data(text.utf8)) }
        func after(_ seconds: Double, _ work: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        }
        after(1.5) {
            guard let display = Display.connected.first(where: { engine.leadWindow(on: $0) != nil }),
                  let lead = engine.leadWindow(on: display)
            else { write("link test: no staged screen\n"); exit(1) }
            func tucked() -> Set<CGWindowID> { Set(engine.tuckedWindows(on: display).map(\.id)) }
            guard let other = engine.tuckedWindows(on: display).first(where: { $0.id != lead })
            else { write("link test: nothing in the strip to link with\n"); exit(1) }
            write("link test: lead \(lead), linking \(other.appName) \(other.id)\n")

            engine.toggleLink(other.id, with: lead)
            after(1.5) {
                engine.evaluate()
                write("  after link: linked=\(engine.links.isLinked(other.id)), other tucked=\(tucked().contains(other.id))\n")
                engine.unlink(lead)
                after(1.5) {
                    engine.evaluate()
                    let gone = tucked()
                    write("  after unlink: linked=\(engine.links.isLinked(lead)), lead tucked=\(gone.contains(lead)), other tucked=\(gone.contains(other.id)), lead still lead=\(engine.leadWindow(on: display) == lead)\n")
                    exit(0)
                }
            }
        }
    }
}
#endif
