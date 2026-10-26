import AppKit
import Carbon.HIToolbox

// Глобальные горячие клавиши. Через Carbon (`RegisterEventHotKey`), а не
// через NSEvent.addGlobalMonitor: монитор требует разрешения «мониторинг
// ввода» — то есть окна системных настроек и доверия ко всему, что человек
// печатает. Регистрация сочетания такого разрешения не требует и видит
// ровно одно сочетание.
//
// Если сочетание уже занято другой программой, регистрация не удаётся —
// тогда подсказка в меню не показывается: обещать клавишу, которая не
// сработает, хуже, чем не иметь её вовсе.
final class GlobalHotkeys {
    static let shared = GlobalHotkeys()

    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef?] = []
    private var names: [String: UInt32] = [:]
    private var handlerInstalled = false

    private init() {}

    func isRegistered(_ name: String) -> Bool { names[name] != nil }

    @discardableResult
    func register(_ name: String, keyCode: UInt32, modifiers: UInt32,
                  action: @escaping () -> Void) -> Bool {
        installHandler()
        let id = UInt32(names.count + 1)
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x6F636272), id: id)   // 'ocbr'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else { return false }
        actions[id] = action
        names[name] = id
        refs.append(ref)
        return true
    }

    fileprivate func fire(_ id: UInt32) { actions[id]?() }

    /// Снять все сочетания. Нужно проверке: занятое сочетание не
    /// регистрируется дважды, и без снятия проверять нечего.
    func unregisterAll() {
        for ref in refs where ref != nil { UnregisterEventHotKey(ref) }
        refs.removeAll(); actions.removeAll(); names.removeAll()
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            // Обработчик — обычная функция C, замкнуть на объект нечего:
            // отсюда singleton.
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let pressed = id.id
            DispatchQueue.main.async { GlobalHotkeys.shared.fire(pressed) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

enum HotkeyCode {
    static let p = UInt32(kVK_ANSI_P)
    static let cmdOption = UInt32(cmdKey | optionKey)
}
