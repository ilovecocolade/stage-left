import AppKit
import ServiceManagement
import SwiftUI

/// The small window you get when you open Stagehand.
///
/// It is the only way back once the menu bar icon is hidden, so opening the app
/// again always brings it up.
final class SettingsWindowController {
    private var window: NSWindow?

    /// Everything the window needs to read and write, kept as closures so the
    /// window never holds onto the engine itself.
    struct Actions {
        let preferences: Preferences
        let displays: () -> [Display]
        let changed: () -> Void
        let restoreAll: () -> Void
        let tuckedCount: () -> Int
    }

    func show(_ actions: Actions) {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(actions: actions))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Stagehand"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct SettingsView: View {
    let actions: SettingsWindowController.Actions

    /// Bumped on every write so the bindings below re-read their real source.
    /// The settings all live in UserDefaults rather than in view state.
    @State private var revision = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle(isOn: toggle(get: { SharedState.isStaging },
                                set: { SharedState.isStaging = $0; SharedState.announceChange() })) {
                Text("Staging").font(.headline)
            }
            .toggleStyle(.switch)

            Text("Windows on the screens below are staged one at a time. Every other screen is left alone.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Stage these screens").font(.subheadline).foregroundStyle(.secondary)
                let displays = actions.displays()
                if displays.isEmpty {
                    Text("No screens detected.").font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(displays, id: \.id) { display in
                        Toggle(display.name, isOn: toggle(
                            get: { actions.preferences.state(for: display) },
                            set: { actions.preferences.setState($0, for: display) }))
                    }
                }
            }

            Divider()

            Toggle("Keep an app's windows together", isOn: toggle(
                get: { actions.preferences.groupsByApp },
                set: { actions.preferences.groupsByApp = $0 }))

            Toggle("Hide the Dock while staging", isOn: toggle(
                get: { actions.preferences.hidesDockWhileStaging },
                set: { actions.preferences.hidesDockWhileStaging = $0 }))

            if actions.preferences.hidesDockWhileStaging {
                Text("The Dock blinks briefly as it switches — macOS gives no smoother way to do this.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Show Stagehand in the menu bar", isOn: toggle(
                get: { actions.preferences.showsMenuBarIcon },
                set: { actions.preferences.showsMenuBarIcon = $0 }))

            if !actions.preferences.showsMenuBarIcon {
                Text("Open Stagehand from Applications to get this window back.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Toggle("Open at login", isOn: Binding(
                get: { _ = revision; return SMAppService.mainApp.status == .enabled },
                set: { wanted in
                    try? wanted ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    revision += 1
                }))

            Divider()

            HStack {
                Button("Bring Back All Windows") {
                    actions.restoreAll()
                    revision += 1
                }
                .disabled(actions.tuckedCount() == 0)
                Spacer()
                Button("Quit Stagehand") { NSApp.terminate(nil) }
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func toggle(get: @escaping () -> Bool, set: @escaping (Bool) -> Void) -> Binding<Bool> {
        Binding(
            get: {
                _ = revision   // re-read whenever anything here changes
                return get()
            },
            set: { newValue in
                set(newValue)
                actions.changed()
                revision += 1
            })
    }
}
