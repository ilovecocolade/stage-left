import AppKit
import Carbon.HIToolbox

/// System-wide hotkeys via Carbon.
///
/// Carbon's `RegisterEventHotKey` is deprecated but still the only way to grab
/// a shortcut without asking for Accessibility permission, which this app has
/// no other reason to want.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef?] = []
    private var nextID: UInt32 = 1
    private var handlerInstalled = false

    private init() {}

    func register(keyCode: Int, action: @escaping () -> Void) {
        installHandlerIfNeeded()

        let id = nextID
        nextID += 1

        let hotKeyID = EventHotKeyID(signature: OSType(0x53544748), id: id) // 'STGH'
        var ref: EventHotKeyRef?
        let modifiers = UInt32(optionKey | cmdKey)

        let status = RegisterEventHotKey(UInt32(keyCode), modifiers, hotKeyID,
                                         GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr else {
            NSLog("Stagehand: could not register hotkey \(keyCode) (OSStatus \(status))")
            return
        }

        actions[id] = action
        refs.append(ref)
    }

    func unregisterAll() {
        for ref in refs where ref != nil { UnregisterEventHotKey(ref!) }
        refs.removeAll()
        actions.removeAll()
        nextID = 1
    }

    fileprivate func fire(_ id: UInt32) {
        actions[id]?()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))

        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr else { return status }
            HotKeyCenter.shared.fire(id.id)
            return noErr
        }, 1, &spec, nil, nil)
    }
}
