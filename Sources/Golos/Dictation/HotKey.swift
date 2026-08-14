import Foundation
import Carbon.HIToolbox
import AppKit

/// Глобальное сочетание клавиш через Carbon Hot Keys.
///
/// Намеренно не CGEventTap: тот потребовал бы разрешения «Мониторинг ввода»
/// и видел бы каждое нажатие в системе. Carbon-хоткей получает событие
/// только для своей комбинации и не требует никаких доступов вообще.
final class HotKey {

    typealias Handler = () -> Void

    private var reference: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let id: UInt32
    private let onPressed: Handler
    private let onReleased: Handler

    /// Реестр держит слабые ссылки: иначе объект никогда не освободился бы,
    /// deinit не сработал бы и старое сочетание осталось бы занятым навсегда.
    private final class WeakRef {
        weak var value: HotKey?
        init(_ value: HotKey) { self.value = value }
    }

    private static var registry: [UInt32: WeakRef] = [:]
    private static var nextID: UInt32 = 1
    private static let signature: OSType = 0x474C5348   // 'GLSH'

    /// - Returns: `nil`, если комбинацию уже занял кто-то другой в системе.
    init?(combo: HotKeyCombo, onPressed: @escaping Handler, onReleased: @escaping Handler) {
        self.onPressed = onPressed
        self.onReleased = onReleased
        self.id = Self.nextID
        Self.nextID += 1

        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]

        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, _ -> OSStatus in
                guard let event else { return noErr }
                var hotKeyID = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                  EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
                guard let hotKey = HotKey.registry[hotKeyID.id]?.value else { return noErr }

                switch GetEventKind(event) {
                case UInt32(kEventHotKeyPressed): hotKey.onPressed()
                case UInt32(kEventHotKeyReleased): hotKey.onReleased()
                default: break
                }
                return noErr
            },
            2, &eventTypes, nil, &handlerRef
        )
        guard status == noErr else { return nil }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let registerStatus = RegisterEventHotKey(
            combo.keyCode, combo.modifiers, hotKeyID,
            GetEventDispatcherTarget(), 0, &reference
        )
        guard registerStatus == noErr, reference != nil else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            Log.warn("Не удалось занять сочетание \(combo.displayString) (код \(registerStatus))")
            return nil
        }
        Self.registry[id] = WeakRef(self)
        Log.info("Глобальное сочетание \(combo.displayString) зарегистрировано")
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        HotKey.registry[id] = nil
    }
}

/// Небольшая помощь окну «нажмите сочетание» в настройках:
/// переводит событие AppKit в формат Carbon.
enum HotKeyRecorder {

    static func combo(from event: NSEvent) -> HotKeyCombo? {
        var modifiers: UInt32 = 0
        let flags = event.modifierFlags
        if flags.contains(.command) { modifiers |= UInt32(HotKeyCombo.cmdKeyMask) }
        if flags.contains(.option) { modifiers |= UInt32(HotKeyCombo.optionKeyMask) }
        if flags.contains(.control) { modifiers |= UInt32(HotKeyCombo.controlKeyMask) }
        if flags.contains(.shift) { modifiers |= UInt32(HotKeyCombo.shiftKeyMask) }

        // Без модификаторов хоткей перехватывал бы обычный набор текста.
        guard modifiers != 0 else { return nil }
        return HotKeyCombo(keyCode: UInt32(event.keyCode), modifiers: modifiers)
    }
}
