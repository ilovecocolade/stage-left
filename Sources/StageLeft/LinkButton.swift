import AppKit
import ApplicationServices

/// One window the link picker offers.
struct LinkChoice {
    let id: CGWindowID
    let pid: pid_t
    let label: String
    let linked: Bool
}

/// The small link button that pokes out of the top-left corner of the window
/// you are working in on a staged screen. Clicking it opens a list of the
/// other windows on that screen, on stage or in the strip; tick as many as you
/// like to link them. The list stays open until you click elsewhere.
///
/// Only the focused window gets one, and only its own moves and resizes are
/// watched, so the button costs nothing for every other window.
final class LinkButtonController {
    /// The windows the button's window can link with.
    var choices: ((CGWindowID) -> [LinkChoice])?
    /// Links or unlinks the first window with the second (the button's).
    var onToggle: ((CGWindowID, CGWindowID) -> Void)?
    /// Takes the button's window out of its group.
    var onUnlink: ((CGWindowID) -> Void)?

    static let size: CGFloat = 20
    /// How far the button sits over the window's corner; the rest pokes out.
    private static let overlap: CGFloat = 6

    private let panel: NSPanel
    private let button = LinkButtonView()
    private let picker = LinkPicker()
    private var target: (id: CGWindowID, element: AXUIElement)?
    private var frame: CGRect = .zero
    private var observer: AXObserver?
    /// Runs while the window is being dragged or resized, reading its frame
    /// from the window server every frame so the button keeps pace.
    private var follower: Timer?
    private var lastChange = Date.distantPast

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.size, height: Self.size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        // Above the menu bar, so the button can still poke out of a window
        // pressed against the top of the screen.
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        // Like the strip: on its own desktop only, never over a full-screen app.
        panel.collectionBehavior = [.ignoresCycle]
        button.frame = NSRect(x: 0, y: 0, width: Self.size, height: Self.size)
        button.autoresizingMask = [.width, .height]
        button.action = { [weak self] in self?.togglePicker() }
        panel.contentView = button

        picker.ownWindows = { [weak self] in [self?.panel].compactMap { $0 } }
        picker.onToggle = { [weak self] other in
            guard let self, let target = self.target else { return }
            self.onToggle?(other, target.id)
            self.refreshPicker()
        }
        picker.onUnlink = { [weak self] in
            guard let self, let target = self.target else { return }
            self.onUnlink?(target.id)
            self.refreshPicker()
        }
    }

    /// Puts the button on `window`, or keeps it there if it already is.
    func show(on window: ManagedWindow, linked: Bool) {
        if target?.id != window.id {
            stopFollowing()
            picker.close()
            target = (window.id, window.element)
            frame = window.axFrame
            watch(window)
        }
        button.isLinked = linked
        place()
        // A panel belongs to the Space it was ordered in on; bring it to this one.
        if !panel.isVisible || !panel.isOnActiveSpace {
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        stopFollowing()
        picker.close()
        guard target != nil || panel.isVisible else { return }
        panel.orderOut(nil)
        target = nil
        stopWatching()
    }

    /// Straddles the window's top-left corner, kept on the window's screen.
    private func place() {
        let window = Geometry.screenRect(fromAX: frame)
        var origin = NSPoint(x: window.minX - Self.size + Self.overlap,
                             y: window.maxY - Self.overlap)
        let screen = NSScreen.screens.max {
            $0.frame.intersection(window).area < $1.frame.intersection(window).area
        }
        if let bounds = screen?.frame {
            origin.x = min(max(origin.x, bounds.minX), bounds.maxX - Self.size)
            origin.y = min(max(origin.y, bounds.minY), bounds.maxY - Self.size)
        }
        origin = NSPoint(x: origin.x.rounded(), y: origin.y.rounded())
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        if picker.isOpen { picker.place(below: panel.frame) }
    }

    private func togglePicker() {
        if picker.isOpen { picker.close(); return }
        refreshPicker()
        picker.open(below: panel.frame)
    }

    private func refreshPicker() {
        guard let target else { return }
        let options = choices?(target.id) ?? []
        picker.update(choices: options, isLinked: options.contains { $0.linked })
        if picker.isOpen { picker.place(below: panel.frame) }
    }

    // MARK: Following the window

    private func watch(_ window: ManagedWindow) {
        stopWatching()
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<LinkButtonController>.fromOpaque(refcon).takeUnretainedValue().targetMoved()
        }
        guard AXObserverCreate(window.pid, callback, &created) == .success, let created else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXMovedNotification, kAXResizedNotification] {
            AXObserverAddNotification(created, window.element, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
    }

    private func stopWatching() {
        guard let observer else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        self.observer = nil
    }

    /// Accessibility reports moves late and in bursts, which made the button
    /// stutter behind the window. Its first report starts a per-frame poll of
    /// the window server, which knows the frame as it is drawn; the poll stops
    /// once the window has been still for a moment.
    private func targetMoved() {
        lastChange = Date()
        follow()
        guard follower == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.follow() }
        RunLoop.main.add(timer, forMode: .common)
        follower = timer
    }

    private func follow() {
        guard let target else { stopFollowing(); return }
        if let bounds = Self.windowServerFrame(of: target.id), bounds != frame {
            frame = bounds
            lastChange = Date()
            place()
        } else if Date().timeIntervalSince(lastChange) > 0.5 {
            stopFollowing()
            // Settle on Accessibility's own reading once the window is still.
            if let settled = Accessibility.frame(target.element), settled != frame {
                frame = settled
                place()
            }
        }
    }

    private func stopFollowing() {
        follower?.invalidate()
        follower = nil
    }

    /// The window's frame in Accessibility's top-left coordinates, which the
    /// window server shares.
    private static func windowServerFrame(of id: CGWindowID) -> CGRect? {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary
        else { return nil }
        return CGRect(dictionaryRepresentation: bounds as CFDictionary)
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

// MARK: - The button

/// A round link glyph, faint until the pointer is over it, solid once the
/// window is linked to others.
private final class LinkButtonView: NSView {
    var action: (() -> Void)?
    var isLinked = false { didSet { if isLinked != oldValue { updateLook() } } }
    private let glyph = NSImageView()
    private var isHovered = false { didSet { updateLook() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = LinkButtonController.size / 2
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.black.withAlphaComponent(0.15).cgColor
        glyph.image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        toolTip = "Link windows"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Link windows")
        updateLook()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) { action?() }

    override func accessibilityPerformPress() -> Bool {
        action?()
        return true
    }

    private func updateLook() {
        let strong = isHovered || isLinked
        layer?.backgroundColor = (isLinked ? NSColor.controlAccentColor : NSColor.windowBackgroundColor)
            .withAlphaComponent(strong ? 0.95 : 0.8).cgColor
        glyph.contentTintColor = isLinked ? .white : (strong ? .labelColor : .secondaryLabelColor)
        alphaValue = strong ? 1 : 0.85
    }
}

// MARK: - The picker

/// The list the button opens. A click on a row links or unlinks that window
/// and leaves the list open, so a whole group can be built in one go.
private final class LinkPicker {
    var onToggle: ((CGWindowID) -> Void)?
    var onUnlink: (() -> Void)?
    /// Windows whose clicks should not close the list: the button's own.
    var ownWindows: () -> [NSWindow] = { [] }

    private enum Metrics {
        static let width: CGFloat = 300
        static let row: CGFloat = 28
        static let header: CGFloat = 26
        static let padding: CGFloat = 6
        static let gap: CGFloat = 4
    }

    private let panel: NSPanel
    private let stack = NSView()
    private var monitors: [Any] = []

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Metrics.width, height: 100),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.collectionBehavior = [.ignoresCycle]

        let background = NSVisualEffectView()
        background.material = .menu
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        background.autoresizingMask = [.width, .height]
        stack.autoresizingMask = [.width, .height]
        let content = NSView()
        content.addSubview(background)
        content.addSubview(stack)
        panel.contentView = content
    }

    var isOpen: Bool { panel.isVisible }

    func update(choices: [LinkChoice], isLinked: Bool) {
        stack.subviews.forEach { $0.removeFromSuperview() }
        var rows: [NSView] = []

        let header = NSTextField(labelWithString: choices.isEmpty
            ? "No other windows on this screen"
            : "Link windows with this one")
        header.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        header.textColor = .secondaryLabelColor
        rows.append(header)

        for choice in choices {
            rows.append(LinkPickerRow(choice: choice) { [weak self] in
                // After the click has finished: the row is rebuilt underneath it.
                DispatchQueue.main.async { self?.onToggle?(choice.id) }
            })
        }
        if isLinked {
            rows.append(LinkPickerSeparator())
            rows.append(LinkPickerRow(unlinkAction: { [weak self] in
                DispatchQueue.main.async { self?.onUnlink?() }
            }))
        }

        let height = rows.reduce(Metrics.padding * 2) { total, row in
            total + rowHeight(row)
        }
        panel.setContentSize(NSSize(width: Metrics.width, height: height))
        stack.frame = NSRect(x: 0, y: 0, width: Metrics.width, height: height)
        var y = height - Metrics.padding
        for row in rows {
            let h = rowHeight(row)
            y -= h
            if row is NSTextField {
                row.frame = NSRect(x: Metrics.padding + 8, y: y + 5, width: Metrics.width - Metrics.padding * 2 - 16, height: 16)
            } else {
                row.frame = NSRect(x: Metrics.padding, y: y, width: Metrics.width - Metrics.padding * 2, height: h)
            }
            stack.addSubview(row)
        }
    }

    private func rowHeight(_ row: NSView) -> CGFloat {
        switch row {
        case is NSTextField: return Metrics.header
        case is LinkPickerSeparator: return Metrics.gap * 2 + 1
        default: return Metrics.row
        }
    }

    func open(below anchor: NSRect) {
        place(below: anchor)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        // Any click outside the list, in another app or elsewhere in Stage
        // Left, closes it, the way a menu would.
        let outside: [NSEvent.EventTypeMask] = [.leftMouseDown, .rightMouseDown]
        for mask in outside {
            if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
                self?.close()
            }) { monitors.append(global) }
            if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
                guard let self else { return event }
                if event.window !== self.panel, !self.ownWindows().contains(where: { $0 === event.window }) {
                    self.close()
                }
                return event
            }) { monitors.append(local) }
        }
    }

    /// Hangs from the button, kept inside the screen it is on.
    func place(below anchor: NSRect) {
        let size = panel.frame.size
        var origin = NSPoint(x: anchor.minX, y: anchor.minY - 4 - size.height)
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        if let bounds = screen?.visibleFrame {
            origin.x = min(max(origin.x, bounds.minX + 4), bounds.maxX - size.width - 4)
            origin.y = max(origin.y, bounds.minY + 4)
        }
        panel.setFrameOrigin(NSPoint(x: origin.x.rounded(), y: origin.y.rounded()))
    }

    func close() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }
}

private final class LinkPickerSeparator: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 8, y: bounds.midY, width: bounds.width - 16, height: 1).fill()
    }
}

/// One line of the picker: a tick, the app's icon and the window's name.
private final class LinkPickerRow: NSView {
    private let action: () -> Void
    private var isHovered = false { didSet { needsDisplay = true; updateColors() } }
    private let label: NSTextField
    private let tick = NSImageView()
    private let linked: Bool

    init(choice: LinkChoice, action: @escaping () -> Void) {
        self.action = action
        self.linked = choice.linked
        label = NSTextField(labelWithString: choice.label)
        super.init(frame: .zero)

        tick.image = NSImage(systemSymbolName: choice.linked ? "checkmark.circle.fill" : "circle",
                             accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        let icon = NSImageView()
        icon.image = NSRunningApplication(processIdentifier: choice.pid)?.icon
        icon.imageScaling = .scaleProportionallyUpOrDown
        build(leading: [tick, icon])
        setAccessibilityLabel(choice.label)
        setAccessibilityValue(choice.linked ? "linked" : "not linked")
    }

    init(unlinkAction: @escaping () -> Void) {
        action = unlinkAction
        linked = false
        label = NSTextField(labelWithString: "Unlink this window")
        super.init(frame: .zero)
        tick.image = NSImage(systemSymbolName: "minus.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        build(leading: [tick])
        setAccessibilityLabel("Unlink this window")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build(leading: [NSImageView]) {
        wantsLayer = true
        layer?.cornerRadius = 5
        var x: CGFloat = 8
        for view in leading {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: x),
                view.centerYAnchor.constraint(equalTo: centerYAnchor),
                view.widthAnchor.constraint(equalToConstant: 18),
                view.heightAnchor.constraint(equalToConstant: 18),
            ])
            x += 24
        }
        label.font = .menuFont(ofSize: 0)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: x + 2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        updateColors()
    }

    private func updateColors() {
        layer?.backgroundColor = isHovered ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        label.textColor = isHovered ? .white : .labelColor
        tick.contentTintColor = isHovered ? .white : (linked ? .controlAccentColor : .secondaryLabelColor)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) { action() }

    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }
}
