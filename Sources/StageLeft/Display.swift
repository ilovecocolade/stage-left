import AppKit
import CoreGraphics

/// A connected screen, keyed by something that survives a reconnect.
///
/// `CGDirectDisplayID` is recycled by the window server, so it is useless as a
/// preference key. The ColorSync UUID is stable for a given physical panel.
struct Display: Identifiable, Hashable {
    let id: String
    let displayID: CGDirectDisplayID
    let name: String
    let isBuiltin: Bool

    init?(screen: NSScreen) {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return nil }

        self.displayID = number
        self.isBuiltin = CGDisplayIsBuiltin(number) != 0
        self.name = screen.localizedName

        if let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue(),
           let string = CFUUIDCreateString(nil, uuid) as String? {
            self.id = string
        } else {
            // Fall back to the panel's own identity rather than the volatile ID.
            self.id = "\(CGDisplayVendorNumber(number))-\(CGDisplayModelNumber(number))-\(CGDisplaySerialNumber(number))"
        }
    }

    static var connected: [Display] {
        NSScreen.screens.compactMap(Display.init(screen:))
    }

    /// The live screen for this display, or nil once it is unplugged.
    var screen: NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        }
    }

    /// Visible bounds in Accessibility coordinates, excluding menu bar and Dock.
    var axVisibleFrame: CGRect? {
        screen.map { Geometry.axRect(fromScreen: $0.visibleFrame) }
    }
}
