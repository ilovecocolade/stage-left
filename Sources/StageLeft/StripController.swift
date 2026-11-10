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
    /// Called when the user clicks the settings button under the icons.
    var onSettings: (() -> Void)?
    /// The group a window is linked into, if any. A group shares one tile.
    var groupKey: (CGWindowID) -> CGWindowID? = { _ in nil }

    /// `onScreen` is the window server's on-screen list from just before this
    /// update, used to spot a strip stranded on another Space.
    func update(_ contents: [(display: Display, windows: [TuckedWindow])], onScreen: Set<CGWindowID>) {
        var seen = Set<String>()

        for (display, windows) in contents {
            guard let screen = display.screen, !windows.isEmpty else { continue }
            seen.insert(display.id)

            if let panel = panels[display.id] {
                panel.apply(windows: windows, screen: screen)
                // A panel belongs to the Space it was ordered in on. One ordered
                // in while a swipe was still under way can land on the Space
                // being left, usually a full-screen app's, and sit there unseen.
                if panel.isStranded(onScreen: onScreen) { panel.moveToCurrentSpace() }
            } else {
                let panel = StripPanel(onSelect: { [weak self] id in self?.onSelect?(id) },
                                       groupKey: { [weak self] id in self?.groupKey(id) },
                                       onSettings: { [weak self] in self?.onSettings?() })
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

    /// Whether showing this display's strip means ordering a panel in: there
    /// is none yet, or it was left on a Space no longer in front.
    func needsOrdering(on displayID: String, onScreen: Set<CGWindowID>) -> Bool {
        guard let panel = panels[displayID] else { return true }
        return panel.isStranded(onScreen: onScreen)
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
        /// The settings button's row under the icons, and the gear inside it.
        static let footer = NSSize(width: 26, height: 16)
        static let gear: CGFloat = 10

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
    private let groupKey: (CGWindowID) -> CGWindowID?
    /// The windows on each tile, as last laid out.
    private var shown: [[CGWindowID]] = []

    init(onSelect: @escaping (CGWindowID) -> Void,
         groupKey: @escaping (CGWindowID) -> CGWindowID?,
         onSettings: @escaping () -> Void) {
        self.onSelect = onSelect
        self.groupKey = groupKey

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
        // stays on the desktop it was put on, next to the windows it lists —
        // unless it was put on the wrong one mid-swipe; see moveToCurrentSpace.
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

        // Pinned to the bottom centre, so it stays put as the panel resizes.
        // Added only once the content view has the panel's size: autoresizing
        // keeps its margins in proportion, and grown from zero they go wrong.
        let settings = StripSettingsButton(action: onSettings)
        settings.frame = NSRect(origin: NSPoint(x: content.bounds.midX - Metrics.footer.width / 2,
                                                y: Metrics.padding),
                                size: Metrics.footer)
        settings.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
        content.addSubview(settings)
        panel.hasShadow = false
    }

    // MARK: Contents

    func apply(windows: [TuckedWindow], screen: NSScreen) {
        let tiles = self.tiles(for: windows)
        let height = CGFloat(tiles.count) * Metrics.tile
            + CGFloat(max(0, tiles.count - 1)) * Metrics.spacing
            + Metrics.padding * 2 + Metrics.footer.height
        let visible = screen.visibleFrame
        // Whole points: the window server rounds the frames it is given, so an
        // unrounded target never matches and the strip would re-animate on
        // every refresh.
        let frame = NSRect(x: (visible.minX + Metrics.padding).rounded(.down),
                           y: (visible.midY - height / 2).rounded(.down),
                           width: Metrics.width,
                           height: height)

        let members = tiles.map { $0.map(\.id) }
        let contentsChanged = members != shown
        shown = members

        // Reflow and restack together so the panel never jumps ahead of the
        // icons it contains.
        // Size the backing and the icon overlay to the panel's new size up
        // front; both fill it, and the icons are laid out in its coordinates.
        let bounds = NSRect(origin: .zero, size: frame.size)
        background.frame = bounds
        items.frame = bounds

        // This runs twice a second. Animating to where the panel already is
        // still drives the display for the length of the animation.
        let moves = panel.frame != frame
        guard moves || contentsChanged else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = panel.alphaValue == 0 ? 0 : Metrics.reflow
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            if moves { panel.animator().setFrame(frame, display: true) }
            if contentsChanged { layout(tiles: tiles, height: height) }
        }
    }

    /// One tile per window, except that linked windows share one. The engine
    /// already lists a group's windows next to each other.
    private func tiles(for windows: [TuckedWindow]) -> [[TuckedWindow]] {
        var result: [[TuckedWindow]] = []
        var lastKey: CGWindowID?
        for window in windows {
            let key = groupKey(window.id)
            if let key, key == lastKey, !result.isEmpty {
                result[result.count - 1].append(window)
            } else {
                result.append([window])
            }
            lastKey = key
        }
        return result
    }

    private func layout(tiles: [[TuckedWindow]], height: CGFloat) {
        let wanted = Set(tiles.map { $0[0].id })
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
        for (index, members) in tiles.enumerated() {
            let window = members[0]
            let y = height - Metrics.padding - Metrics.tile - CGFloat(index) * (Metrics.tile + Metrics.spacing)
            let origin = NSPoint(x: Metrics.padding, y: y)

            if let view = reusable[window.id] {
                view.refresh(with: members)
                view.animator().setFrameOrigin(origin)
            } else {
                let view = StripItemView(windows: members) { [weak self] id in
                    self?.onSelect(id)
                }
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

    var windowID: CGWindowID { CGWindowID(panel.windowNumber) }

    /// Off screen because it is on a Space no longer in front. Mission Control
    /// and App Exposé take the strip off screen too, but leave it on its Space,
    /// and re-ordering it then would only churn their layout.
    func isStranded(onScreen: Set<CGWindowID>) -> Bool {
        !onScreen.contains(windowID) && !panel.isOnActiveSpace
    }

    func moveToCurrentSpace() {
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }

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

// MARK: - Clickable spots

/// Anything in the strip that lights up under the pointer.
private class StripHoverView: NSView {
    private var isHovered = false { didSet { updateHighlight() } }

    init(cornerRadius: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = .clear
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

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

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

/// The small gear under the icons, which opens Stage Left's settings.
private final class StripSettingsButton: StripHoverView {
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        super.init(cornerRadius: StripPanel.Metrics.footer.height / 2)

        let gear = NSImageView()
        gear.image = NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: StripPanel.Metrics.gear, weight: .semibold))
        gear.contentTintColor = .secondaryLabelColor
        gear.translatesAutoresizingMaskIntoConstraints = false
        addSubview(gear)
        NSLayoutConstraint.activate([
            gear.centerXAnchor.constraint(equalTo: centerXAnchor),
            gear.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        toolTip = "Stage Left Settings"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Stage Left Settings")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func mouseDown(with event: NSEvent) { action() }

    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }
}

// MARK: - One tile

/// A tucked window's app icon, or for linked windows, their icons fanned out
/// over each other like a hand of cards. Either way one click brings back
/// everything on the tile.
private final class StripItemView: StripHoverView {
    let windowID: CGWindowID
    /// Set while the view is fading out and awaiting removal.
    var isLeaving = false
    private let action: (CGWindowID) -> Void
    private let fan = IconFanView()

    /// The most icons a fan shows; any more sit hidden under the last.
    private static let fanLimit = 4

    init(windows: [TuckedWindow], action: @escaping (CGWindowID) -> Void) {
        self.windowID = windows[0].id
        self.action = action
        super.init(cornerRadius: 12)
        // Sized by hand in setFrameSize: autoresizing grown from a zero-sized
        // tile doubles the fan and pushes every icon off centre.
        addSubview(fan)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        refresh(with: windows)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fan.frame = bounds
    }

    /// Re-reads the icons and clears any leftover fade. An app's icon can come
    /// back nil for a moment, and a tile that renders as nothing is worse than
    /// a placeholder — it looks like the strip has holes in it.
    func refresh(with windows: [TuckedWindow]) {
        isLeaving = false
        alphaValue = 1
        fan.icons = windows.prefix(Self.fanLimit).map {
            $0.appIcon ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: $0.appName)
        }
        let names = windows.map { $0.title.isEmpty ? $0.appName : "\($0.appName) — \($0.title)" }
        toolTip = windows.count > 1 ? "Linked:\n" + names.joined(separator: "\n") : names.first
        setAccessibilityLabel(windows.count > 1 ? "Linked windows: " + names.joined(separator: ", ") : names.first)
    }

    var hasNoIcon: Bool { fan.icons.isEmpty || fan.icons.contains { $0 == nil } }

    func report() -> String {
        "\(hasNoIcon ? "NO-ICON" : "icon")x\(fan.icons.count)@\(String(format: "%.2f", alphaValue))\(isLeaving ? "/leaving" : "")"
    }

    override func mouseDown(with event: NSEvent) {
        action(windowID)
    }
}

/// Draws one icon centred, or several fanned out like a hand of cards, each
/// lying over the one before it. Drawn rather than built from rotated views,
/// which AppKit positions unreliably while the strip animates.
private final class IconFanView: NSView {
    var icons: [NSImage?] = [] { didSet { needsDisplay = true } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        guard icons.count > 1 else {
            let size = StripPanel.Metrics.icon
            icons.first??.draw(in: NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size))
            return
        }
        let size: CGFloat = 30
        let spread: CGFloat = icons.count == 2 ? 6 : 7
        let tilt: CGFloat = icons.count == 2 ? 9 : 12
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)

        for (index, icon) in icons.enumerated() {
            guard let icon else { continue }
            // -1 for the card on the left to 1 for the one on the right.
            let position = CGFloat(index) / CGFloat(icons.count - 1) * 2 - 1
            NSGraphicsContext.saveGraphicsState()
            shadow.set()
            let transform = NSAffineTransform()
            transform.translateX(by: center.x + position * spread, yBy: center.y + 1 - abs(position) * 1.5)
            transform.rotate(byDegrees: -position * tilt)
            transform.concat()
            icon.draw(in: NSRect(x: -size / 2, y: -size / 2, width: size, height: size))
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}
