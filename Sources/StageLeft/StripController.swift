import AppKit

/// The column of tucked windows along the edge of a managed display.
///
/// One floating panel per managed screen. The panels are non-activating, so
/// clicking one never steals focus from the window you are working in — the
/// engine decides what gets focus, not the strip.
final class StripController {
    private var panels: [String: StripPanel] = [:]

    /// Called with the window the user picked out of the strip.
    var onSelect: ((CGWindowID) -> Void)?

    func update(_ contents: [(display: Display, windows: [TuckedWindow])]) {
        var seen = Set<String>()

        for (display, windows) in contents {
            guard let screen = display.screen, !windows.isEmpty else { continue }
            seen.insert(display.id)

            if let panel = panels[display.id] {
                panel.apply(windows: windows, screen: screen)
            } else {
                let panel = StripPanel { [weak self] id in self?.onSelect?(id) }
                panels[display.id] = panel
                panel.apply(windows: windows, screen: screen)
                panel.appear()
            }
        }

        // Snapshot first — removing while iterating a dictionary is undefined.
        for id in Array(panels.keys) where !seen.contains(id) {
            panels.removeValue(forKey: id)?.dismiss()
        }
    }

    func hideAll() {
        for id in Array(panels.keys) { panels.removeValue(forKey: id)?.dismiss() }
    }

    /// Describes every tile on screen: an invisible one is a bug, and it cannot
    /// be seen from outside the process.
    func report() -> String {
        guard !panels.isEmpty else { return "  no strip on screen" }
        return panels.map { "  display \($0.key.prefix(8)): \($0.value.report())" }
            .sorted().joined(separator: "\n")
    }
}

// MARK: - Panel

private final class StripPanel {
    enum Metrics {
        // The tile is the hover target and sits 3pt proud of the icon; padding
        // is the gap from the tile to the container edge. Together they are the
        // visible margin around each icon, so keep them small.
        static let tile: CGFloat = 50
        static let icon: CGFloat = 44
        static let spacing: CGFloat = 3
        static let padding: CGFloat = 3
        static let corner: CGFloat = 14
        static var width: CGFloat { tile + padding * 2 }

        static let fade = 0.16
        static let reflow = 0.20
        /// Applied to the blurred backing only, never the icons — fading the
        /// whole panel would wash out the app icons along with it.
        static let backingOpacity: CGFloat = 0.78
    }

    private let panel: NSPanel
    private let background: NSVisualEffectView
    /// Icons live above the blurred backing rather than inside it, so the
    /// backing can be made translucent on its own.
    private let items = NSView()
    private let onSelect: (CGWindowID) -> Void
    private var shownIDs: [CGWindowID] = []

    init(onSelect: @escaping (CGWindowID) -> Void) {
        self.onSelect = onSelect

        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Metrics.width, height: Metrics.width),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.alphaValue = 0
        // None of .stationary, .canJoinAllSpaces or .fullScreenAuxiliary.
        // .stationary pins the panel in place while Exposé or a desktop reveal
        // sweeps the real windows away; the other two carry it onto every
        // Space, including a full-screen app's own, which is how it ended up
        // floating over unrelated maximised windows. Without them the strip
        // stays on the desktop it was put on, next to the windows it lists.
        panel.collectionBehavior = [.ignoresCycle]

        background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.alphaValue = Metrics.backingOpacity
        background.layer?.cornerRadius = Metrics.corner
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        let content = NSView()
        content.autoresizesSubviews = true
        background.autoresizingMask = [.width, .height]
        items.autoresizingMask = [.width, .height]
        content.addSubview(background)
        content.addSubview(items)
        panel.contentView = content
        panel.hasShadow = false
    }

    // MARK: Contents

    func apply(windows: [TuckedWindow], screen: NSScreen) {
        let height = CGFloat(windows.count) * Metrics.tile
            + CGFloat(max(0, windows.count - 1)) * Metrics.spacing
            + Metrics.padding * 2
        let visible = screen.visibleFrame
        let frame = NSRect(x: visible.minX + Metrics.padding,
                           y: visible.midY - height / 2,
                           width: Metrics.width,
                           height: height)

        let ids = windows.map(\.id)
        let contentsChanged = ids != shownIDs
        shownIDs = ids

        // Reflow and restack together so the panel never jumps ahead of the
        // icons it contains.
        // Size the backing and the icon overlay to the panel's new size up
        // front; both fill it, and the icons are laid out in its coordinates.
        let bounds = NSRect(origin: .zero, size: frame.size)
        background.frame = bounds
        items.frame = bounds

        NSAnimationContext.runAnimationGroup { context in
            context.duration = panel.alphaValue == 0 ? 0 : Metrics.reflow
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(frame, display: true)
            if contentsChanged { layout(windows: windows, height: height) }
        }
    }

    private func layout(windows: [TuckedWindow], height: CGFloat) {
        let wanted = Set(windows.map(\.id))
        let present = items.subviews.compactMap { $0 as? StripItemView }

        for view in present where !wanted.contains(view.windowID) && !view.isLeaving {
            view.isLeaving = true
            view.animator().alphaValue = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + Metrics.fade) { [weak view] in
                // Only if it is still on its way out: it may have been asked
                // back in the meantime.
                guard let view, view.isLeaving else { return }
                view.removeFromSuperview()
            }
        }

        // A view that is mid fade-out must never be reused. Reviving one leaves
        // it at zero alpha — invisible, but still clickable, because AppKit hit
        // tests transparent views — and its scheduled removal still fires.
        let reusable = Dictionary(present.filter { !$0.isLeaving }.map { ($0.windowID, $0) },
                                  uniquingKeysWith: { first, _ in first })

        // Top to bottom reads more naturally than AppKit's bottom-up origin.
        for (index, window) in windows.enumerated() {
            let y = height - Metrics.padding - Metrics.tile - CGFloat(index) * (Metrics.tile + Metrics.spacing)
            let origin = NSPoint(x: Metrics.padding, y: y)

            if let view = reusable[window.id] {
                view.refresh(with: window)
                view.animator().setFrameOrigin(origin)
            } else {
                let view = StripItemView(window: window) { [weak self] id in self?.onSelect(id) }
                view.frame = NSRect(origin: origin, size: NSSize(width: Metrics.tile, height: Metrics.tile))
                view.alphaValue = 0
                items.addSubview(view)
                view.animator().alphaValue = 1
            }
        }
    }

    func report() -> String {
        let tiles = items.subviews.compactMap { $0 as? StripItemView }
        guard !tiles.isEmpty else { return "no tiles" }
        // A tile on its way out is meant to be transparent; only a tile that is
        // staying and cannot be seen is a fault.
        let broken = tiles.filter { !$0.isLeaving && ($0.alphaValue < 0.99 || $0.hasNoIcon) }
        let detail = tiles.map { $0.report() }.joined(separator: ", ")
        return "\(tiles.count) tiles, \(broken.count) BROKEN — \(detail)"
    }

    // MARK: Appearance

    func appear() {
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Metrics.fade
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func dismiss() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Metrics.fade
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [panel] in
            panel.orderOut(nil)
        }
        // Belt and braces: a panel whose fade never reports completing, such as
        // one on a Space that is not showing, must still go.
        DispatchQueue.main.asyncAfter(deadline: .now() + Metrics.fade + 0.2) { [panel] in
            panel.orderOut(nil)
        }
    }
}

// MARK: - One icon

private final class StripItemView: NSView {
    let windowID: CGWindowID
    /// Set while the view is fading out and awaiting removal.
    var isLeaving = false
    private let action: (CGWindowID) -> Void
    private let iconView = NSImageView()
    private var isHovered = false { didSet { updateHighlight() } }

    init(window: TuckedWindow, action: @escaping (CGWindowID) -> Void) {
        self.windowID = window.id
        self.action = action
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = .clear

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: StripPanel.Metrics.icon),
            iconView.heightAnchor.constraint(equalToConstant: StripPanel.Metrics.icon),
        ])

        refresh(with: window)
    }

    /// Re-reads the icon and clears any leftover fade. An app's icon can come
    /// back nil for a moment, and a tile that renders as nothing is worse than
    /// a placeholder — it looks like the strip has holes in it.
    func refresh(with window: TuckedWindow) {
        isLeaving = false
        alphaValue = 1
        iconView.image = window.appIcon
            ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: window.appName)
        toolTip = window.title.isEmpty ? window.appName : "\(window.appName) — \(window.title)"
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // The panel is never key, so the tracking area has to stay live anyway.
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self))
    }

    var hasNoIcon: Bool { iconView.image == nil }

    func report() -> String {
        "\(iconView.image == nil ? "NO-ICON" : "icon")@\(String(format: "%.2f", alphaValue))\(isLeaving ? "/leaving" : "")"
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) {
        action(windowID)
    }

    private func updateHighlight() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            layer?.backgroundColor = isHovered
                ? NSColor.labelColor.withAlphaComponent(0.12).cgColor
                : NSColor.clear.cgColor
        }
    }
}
