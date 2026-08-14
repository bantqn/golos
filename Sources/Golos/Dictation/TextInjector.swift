import Foundation
import AppKit
import ApplicationServices

/// Вставляет распознанный текст в то приложение, которое сейчас активно.
enum TextInjector {

    // MARK: - Разрешение

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Показывает системный запрос доступа к универсальному доступу.
    @discardableResult
    static func requestTrust() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Вставка

    /// - Parameter keepInClipboard: оставить текст в буфере обмена вместо того,
    ///   чтобы вернуть прежнее содержимое. Это страховка: убедиться, что чужое
    ///   приложение действительно приняло ⌘V, технически невозможно, а
    ///   продиктованную фразу заново не произнесёшь.
    @discardableResult
    static func insert(_ text: String, mode: InsertionMode, keepInClipboard: Bool) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard isTrusted else {
            Log.warn("Вставка невозможна: нет доступа к универсальному доступу")
            if keepInClipboard { copyToClipboard(trimmed) }
            return false
        }

        switch mode {
        case .paste:
            return pasteViaClipboard(trimmed, keepInClipboard: keepInClipboard)
        case .type:
            let typed = typeCharacters(trimmed)
            // При посимвольном вводе буфер не участвует, поэтому кладём текст
            // туда отдельно — если попросили.
            if keepInClipboard { copyToClipboard(trimmed) }
            return typed
        }
    }

    static func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Быстрый путь: подменяем буфер обмена, шлём ⌘V, возвращаем буфер обратно.
    private static func pasteViaClipboard(_ text: String, keepInClipboard: Bool) -> Bool {
        let pasteboard = NSPasteboard.general

        // Сохраняем прежнее содержимое всех типов, чтобы вернуть его без потерь.
        let saved = pasteboard.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data] in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { copy[type] = data }
            }
            return copy
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard sendCommandV() else {
            if !keepInClipboard { restore(saved, to: pasteboard) }
            return false
        }

        // Приложению нужно время прочитать буфер до того, как мы его вернём.
        if !keepInClipboard {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                restore(saved, to: pasteboard)
            }
        }
        return true
    }

    private static func restore(_ saved: [[NSPasteboard.PasteboardType: Data]]?, to pasteboard: NSPasteboard) {
        guard let saved, !saved.isEmpty else { return }
        pasteboard.clearContents()
        let items = saved.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
    }

    private static func sendCommandV() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        // Не даём системе подмешать зажатые пользователем модификаторы.
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents], state: .eventSuppressionStateSuppressionInterval)

        let vKeyCode: CGKeyCode = 9   // «V» на любой раскладке — код физической клавиши
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else { return false }

        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }

    /// Медленный путь: «печатаем» текст как последовательность символов.
    /// Буфер обмена при этом не трогается вообще.
    private static func typeCharacters(_ text: String) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }

        // CGEvent принимает не больше 20 UTF-16 единиц за раз.
        let units = Array(text.utf16)
        for chunk in stride(from: 0, to: units.count, by: 16).map({ Array(units[$0..<min($0 + 16, units.count)]) }) {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { return false }

            chunk.withUnsafeBufferPointer { buffer in
                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
            down.post(tap: .cgAnnotatedSessionEventTap)
            up.post(tap: .cgAnnotatedSessionEventTap)
            usleep(1500)
        }
        return true
    }

    /// Имя приложения, в которое попадёт текст, — показывается в HUD.
    static func frontmostAppName() -> String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }
}
