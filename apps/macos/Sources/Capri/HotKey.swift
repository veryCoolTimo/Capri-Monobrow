import Carbon.HIToolbox

/// Глобальный шорткат через Carbon `RegisterEventHotKey`: работает без разрешений Accessibility/Input Monitoring.
/// Нажатие и отпускание (`kEventHotKeyPressed` / `kEventHotKeyReleased`) — для удержания (push-to-talk).
/// nil — сочетание занято другим приложением (или система отказала).
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let onPress: () -> Void
    private let onRelease: () -> Void

    /// ⌃⌥Space — вызвать Capri (коротко) или говорить с ней (держать).
    static let assistant = (keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey), label: "⌃⌥Space")

    init?(keyCode: UInt32, modifiers: UInt32, onPress: @escaping () -> Void, onRelease: @escaping () -> Void = {}) {
        self.onPress = onPress
        self.onRelease = onRelease
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let me = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, user in
            guard let user, let event else { return noErr }
            let hotKey = Unmanaged<HotKey>.fromOpaque(user).takeUnretainedValue()
            // Carbon зовёт обработчик на главном потоке — сразу, без async (объект мог бы успеть освободиться).
            if GetEventKind(event) == UInt32(kEventHotKeyReleased) { hotKey.onRelease() } else { hotKey.onPress() }
            return noErr
        }, 2, &specs, me, &handler)
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
