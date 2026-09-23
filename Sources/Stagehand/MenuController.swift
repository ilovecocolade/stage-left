import AppKit
import Carbon.HIToolbox
import ServiceManagement
import WidgetKit

final class MenuController: NSObject, NSMenuDelegate {
    private let prefs = Preferences()
    private lazy var engine = StageEngine(preferences: prefs)
    private let strip = StripController()
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private var displays: [Display] = []
    private var revealTimer: Timer?
    private let settings = SettingsWindowController()
    private let dock = DockController()

    private static let hotKeyDigits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
                                       kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]

    func start() {
        menu.delegate = self
        menu.autoenablesItems = false
        updateMenuBarPresence()

        engine.onStateChange = { [weak self] in
            self?.refreshStrips()
            self?.refreshIcon()
            self?.updateDock()
        }
        strip.onSelect = { [weak self] id in self?.bringBack(id) }

        registerHotKeys()
        reloadDisplays()
        logDiagnosticsIfRequested()
        if ProcessInfo.processInfo.environment["STAGEHAND_SELFTEST"] != nil { SelfTest.run() }

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // The Control Centre button lives in another process and flips the same
        // switch, so react when it does.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(sharedStateChanged),
            name: SharedState.changed, object: nil)

        // A second launch hands over to this one rather than running alongside.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(showSettings),
            name: SharedState.showSettings, object: nil)

        // Swiping between Spaces must take the strip away immediately, not at
        // the next poll half a second later.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(spaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)

        defer { updateDock() }

        if Accessibility.isTrusted {
            engine.start()
            if ProcessInfo.processInfo.environment["STAGEHAND_LIVETEST"] != nil {
                LiveTest.run(engine: engine, preferences: prefs)
            }
            if let argument = ProcessInfo.processInfo.environment["STAGEHAND_RESCUE"] {
                Rescue.run(argument: argument)
            }
            if ProcessInfo.processInfo.environment["STAGEHAND_FSTEST"] != nil {
                FullScreenSurvey.run()
            }
            if let target = ProcessInfo.processInfo.environment["STAGEHAND_STRANDTEST"] {
                StrandTest.run(appNamed: target)
            }
            if ProcessInfo.processInfo.environment["STAGEHAND_STRIPDUMP"] != nil {
                Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    FileHandle.standardError.write(Data("strip:\n\(self.strip.report())\n".utf8))
                }
            }
        } else {
            // Ask on first launch; the engine starts by itself once granted.
            Accessibility.requestPermission()
            waitForPermission()
        }
        refreshIcon()
    }

    func shutDown() {
        dock.apply(active: false)
        engine.stop()
        strip.hideAll()
        HotKeyCenter.shared.unregisterAll()
    }

    /// Accessibility is granted outside the app, so watch for it rather than
    /// making the user relaunch.
    private func waitForPermission() {
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard Accessibility.isTrusted else { return }
            timer.invalidate()
            self.engine.start()
            self.refreshIcon()
        }
    }

    // MARK: - Settings

    /// Creates or removes the menu bar item to match the preference. The item
    /// must be created after NSApplication is running, or the menu bar
    /// silently drops it.
    private func updateMenuBarPresence() {
        if prefs.showsMenuBarIcon {
            guard statusItem == nil else { refreshIcon(); return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.isVisible = true
            item.menu = menu
            item.button?.toolTip = "Stagehand — Stage Manager per screen"
            statusItem = item
            refreshIcon()
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    @objc func showSettings() {
        settings.show(SettingsWindowController.Actions(
            preferences: prefs,
            displays: { Display.connected },
            changed: { [weak self] in
                guard let self else { return }
                self.reloadDisplays()
                self.updateMenuBarPresence()
                if !self.engine.isRunning, Accessibility.isTrusted { self.engine.start() }
                self.engine.evaluate()
                self.refreshIcon()
                self.publishControlState()
            },
            restoreAll: { [weak self] in self?.restoreEverything() },
            tuckedCount: { [weak self] in self?.engine.tuckedCount ?? 0 }))
    }

    // MARK: - State

    private func reloadDisplays() {
        displays = Display.connected
    }

    @objc private func spaceChanged() {
        refreshStrips()
    }

    @objc private func screensChanged() {
        reloadDisplays()
        engine.evaluate()
        refreshIcon()
    }

    private var managedDisplays: [Display] {
        SharedState.isStaging ? displays.filter { prefs.state(for: $0) } : []
    }

    @objc private func sharedStateChanged() {
        if ProcessInfo.processInfo.environment["STAGEHAND_DEBUG"] != nil {
            FileHandle.standardError.write(Data(
                "control changed staging to \(SharedState.isStaging ? "on" : "off")\n".utf8))
        }
        engine.evaluate()
        refreshIcon()
    }

    @objc private func toggleStaging() {
        SharedState.isStaging.toggle()
        engine.evaluate()
        refreshIcon()
        publishControlState()
    }

    /// Keeps the Control Centre button in step when the change came from here.
    /// Control Centre buttons only exist on macOS 26 and later; everything else
    /// in the app works without them.
    private func publishControlState() {
        SharedState.announceChange()
        if #available(macOS 26.0, *) {
            ControlCenter.shared.reloadControls(ofKind: SharedState.controlKind)
        }
    }

    private func refreshStrips() {
        let displays = managedDisplays
        let showing = WindowScanner.displaysShowingWindows(among: displays)
        let onScreen = WindowScanner.onScreenWindowIDs()
        let fullScreen = WindowScanner.displaysWithFullScreenWindow(among: displays)

        // Show a strip only where its own stage is: the display must still have
        // windows on it, and the window it is staged around must be on the
        // desktop in front of you rather than another Space.
        strip.update(displays
            .filter { display in
                guard showing.contains(display.id), !fullScreen.contains(display.id) else { return false }
                guard let lead = engine.leadWindow(on: display) else { return false }
                return onScreen.contains(lead)
            }
            .map { (display: $0, windows: engine.tuckedWindows(on: $0)) })
        watchForDesktopReveal(active: !displays.isEmpty && engine.tuckedCount > 0)
    }

    /// Revealing the desktop raises no notification of its own, so poll — but
    /// only while a strip is actually on screen, which keeps it near-free.
    private func watchForDesktopReveal(active: Bool) {
        if active, revealTimer == nil {
            revealTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.refreshStrips()
            }
        } else if !active {
            revealTimer?.invalidate()
            revealTimer = nil
        }
    }

    /// The Dock hides only while staging is genuinely doing something.
    private func updateDock() {
        dock.apply(active: prefs.hidesDockWhileStaging && engine.isRunning && !managedDisplays.isEmpty)
    }

    private func refreshIcon() {
        let active = engine.isRunning && !managedDisplays.isEmpty
        let symbol = active ? "rectangle.stack.fill" : "rectangle.stack"
        let image = NSImage(systemSymbolName: symbol,
                            accessibilityDescription: active ? "Staging windows" : "Idle")
        image?.isTemplate = true
        statusItem?.button?.image = image
    }

    // MARK: - Actions

    private func bringBack(_ id: CGWindowID) {
        engine.restore(id, activate: true)
        // Activation is asynchronous, so let focus settle before restaging.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.engine.evaluate() }
    }

    @objc private func screenClicked(_ sender: NSMenuItem) {
        guard sender.tag < displays.count else { return }
        let display = displays[sender.tag]
        prefs.setState(!prefs.state(for: display), for: display)

        if !engine.isRunning, Accessibility.isTrusted { engine.start() }
        engine.evaluate()
        refreshIcon()
        publishControlState()
    }

    @objc private func toggleGrouping() {
        prefs.groupsByApp.toggle()
        engine.evaluate()
    }

    @objc private func restoreEverything() {
        engine.restoreAll()
        refreshStrips()
    }

    @objc private func grantAccessibility() {
        Accessibility.requestPermission()
        Accessibility.openSettings()
        waitForPermission()
    }

    @objc private func disableAppleStageManager() {
        StageManager.setEnabled(false)
        engine.evaluate()
    }

    // MARK: - Hotkeys

    private func registerHotKeys() {
        HotKeyCenter.shared.register(keyCode: kVK_ANSI_S) { [weak self] in
            self?.restoreEverything()
        }
        for (index, key) in Self.hotKeyDigits.enumerated() {
            HotKeyCenter.shared.register(keyCode: key) { [weak self] in
                guard let self else { return }
                self.reloadDisplays()
                guard index < self.displays.count else { return }
                let item = NSMenuItem()
                item.tag = index
                self.screenClicked(item)
            }
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        reloadDisplays()
        rebuild(menu)
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()

        if !Accessibility.isTrusted {
            menu.addItem(warning("Stagehand needs Accessibility permission",
                                 action: #selector(grantAccessibility)))
            menu.addItem(.separator())
        }

        if StageManager.isEnabled {
            menu.addItem(warning("Apple's Stage Manager is on and will fight this — turn it off",
                                 action: #selector(disableAppleStageManager)))
            menu.addItem(.separator())
        }

        let master = NSMenuItem(title: SharedState.isStaging ? "Staging Is On" : "Staging Is Off",
                                action: #selector(toggleStaging), keyEquivalent: "")
        master.state = SharedState.isStaging ? .on : .off
        master.target = self
        master.toolTip = "Turns staging on or off for the screens ticked below"
        menu.addItem(master)
        menu.addItem(.separator())

        menu.addItem(header("Stage these screens"))
        for (index, display) in displays.enumerated() {
            let managed = prefs.state(for: display)
            let tuckedCount = managed ? engine.tuckedWindows(on: display).count : 0
            var title = display.name
            if managed, tuckedCount > 0 { title += "  (\(tuckedCount) tucked)" }

            let item = NSMenuItem(title: title,
                                  action: #selector(screenClicked(_:)),
                                  keyEquivalent: index < 9 ? String(index + 1) : "")
            item.keyEquivalentModifierMask = [.option, .command]
            item.state = managed ? .on : .off
            item.target = self
            item.tag = index
            item.toolTip = display.isBuiltin ? "Built-in display" : "External display"
            menu.addItem(item)
        }

        let offline = prefs.remembered(excluding: displays)
        if !offline.isEmpty {
            menu.addItem(.separator())
            menu.addItem(header("Not connected"))
            for screen in offline {
                let item = NSMenuItem(title: screen.name, action: #selector(forgetScreen(_:)), keyEquivalent: "")
                item.state = screen.enabled ? .on : .off
                item.target = self
                item.representedObject = screen.id
                item.toolTip = "Setting remembered for when this screen returns. Click to forget it."
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let grouping = NSMenuItem(title: "Keep an App's Windows Together",
                                  action: #selector(toggleGrouping), keyEquivalent: "")
        grouping.state = prefs.groupsByApp ? .on : .off
        grouping.target = self
        menu.addItem(grouping)

        let restore = NSMenuItem(title: "Bring Back All Windows",
                                 action: #selector(restoreEverything), keyEquivalent: "s")
        restore.keyEquivalentModifierMask = [.option, .command]
        restore.target = self
        restore.isEnabled = engine.tuckedCount > 0
        menu.addItem(restore)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.target = self
        menu.addItem(login)

        let quit = NSMenuItem(title: "Quit Stagehand", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        return item
    }

    private func warning(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        return item
    }

    @objc private func forgetScreen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        prefs.forget(id)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert(error: error)
            alert.messageText = "Could not change the login item"
            alert.runModal()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func fullScreenReport() -> String {
        let all = Display.connected
        let full = WindowScanner.displaysWithFullScreenWindow(among: all)
        return full.isEmpty ? "none" : all.filter { full.contains($0.id) }.map(\.name).joined(separator: ", ")
    }

    /// Run with STAGEHAND_DEBUG=1 to confirm the app came up healthy.
    private func logDiagnosticsIfRequested() {
        guard ProcessInfo.processInfo.environment["STAGEHAND_DEBUG"] != nil else { return }
        let report = """
            Stagehand diagnostics
              statusItem: \(statusItem == nil ? "MISSING" : "created")
              button width: \(statusItem?.button?.frame.width.description ?? "n/a")
              accessibility: \(Accessibility.isTrusted ? "granted" : "NOT GRANTED")
              apple stage manager: \(StageManager.isEnabled ? "ON (conflicts)" : "off")
              staging master switch: \(SharedState.isStaging ? "on" : "off")
              full-screen displays: \(fullScreenReport())
              screens: \(displays.map { "\($0.name)=\(prefs.state(for: $0) ? "managed" : "free")" }.joined(separator: ", "))

            """
        FileHandle.standardError.write(Data(report.utf8))
    }
}
