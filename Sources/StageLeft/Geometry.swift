import AppKit

/// Translates between AppKit screen coordinates (origin bottom-left of the
/// primary display, y up) and Accessibility coordinates (origin top-left,
/// y down). Getting this wrong sends windows to the wrong monitor, so it lives
/// in one place.
enum Geometry {
    /// Height of the primary display — the pivot for the y flip.
    private static var primaryHeight: CGFloat {
        (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first)?.frame.height ?? 0
    }

    static func axRect(fromScreen rect: CGRect) -> CGRect {
        CGRect(x: rect.origin.x,
               y: primaryHeight - rect.maxY,
               width: rect.width,
               height: rect.height)
    }

    static func screenRect(fromAX rect: CGRect) -> CGRect {
        CGRect(x: rect.origin.x,
               y: primaryHeight - rect.maxY,
               width: rect.width,
               height: rect.height)
    }

    /// The display a window sits on: whichever screen holds most of it.
    static func display(containing axFrame: CGRect, among displays: [Display]) -> Display? {
        var best: (display: Display, overlap: CGFloat)?
        for display in displays {
            guard let screen = display.screen else { continue }
            let bounds = axRect(fromScreen: screen.frame)
            let intersection = bounds.intersection(axFrame)
            guard !intersection.isNull else { continue }
            let area = intersection.width * intersection.height
            if area > (best?.overlap ?? 0) { best = (display, area) }
        }
        return best?.display
    }
}
