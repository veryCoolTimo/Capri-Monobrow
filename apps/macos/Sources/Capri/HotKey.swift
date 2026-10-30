import Carbon.HIToolbox

/// Глобальный шорткат через Carbon `RegisterEventHotKey`: работает без разрешений Accessibility/Input Monitoring.
/// nil — сочетание занято другим приложением (или система отказала).
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    /// ⌃⌥Space — вызвать Capri.
    static let assistant = (keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey), label: "⌃⌥Space")

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, user in
            guard let user else { return noErr }
            let hotKey = Unmanaged<HotKey>.fromOpaque(user).takeUnretainedValue()
            // Carbon зовёт обработчик на главном потоке — сразу, без async (объект мог бы успеть освободиться).
            hotKey.action()
            return noErr
        }, 1, &spec, me, &handler)
        let id = EventHotKeyID(signature: OSType(0x4350_5249), id: 1)   // 'CPRI'
        guard installed == noErr,
              RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr else {
            if let h = handler { RemoveEventHandler(h) }
            handler = nil
            return nil
        }
    }

    deinit {
        if let r = ref { UnregisterEventHotKey(r) }
        if let h = handler { RemoveEventHandler(h) }
    }
}
