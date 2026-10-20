import Carbon

/// Global ⌃⌥P shortcut via Carbon (works without any extra permission).
final class HotKey {
    var action: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    func register() {
        unregister()
        if handlerRef == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                     eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
                guard let userData else { return OSStatus(noErr) }
                let me = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
                me.action?()
                return OSStatus(noErr)
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        }
        let id = EventHotKeyID(signature: OSType(0x464C_5054), id: 1) // "FLPT"
        RegisterEventHotKey(UInt32(kVK_ANSI_P), UInt32(controlKey | optionKey), id,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }
}
