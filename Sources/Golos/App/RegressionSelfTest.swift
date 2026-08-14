import AppKit
import SwiftUI

/// Минимальные регрессионные проверки без зависимости от XCTest.
///
/// Command Line Tools умеют собирать приложение, но некоторые установки не
/// содержат XCTest. `GOLOS_SELF_TEST=1 Golos` выполняет проверки внутри того же
/// бинарника и завершается до появления интерфейса.
@MainActor
enum RegressionSelfTest {
    static func runIfRequested() -> Bool {
        guard ProcessInfo.processInfo.environment["GOLOS_SELF_TEST"] == "1" else {
            return false
        }

        var failures: [String] = []
        check(Settings().appearance == .dark,
              "новые настройки должны использовать тёмную тему", into: &failures)
        check(WindowMetrics.initial == CGSize(width: 980, height: 680),
              "изменился стартовый размер окна", into: &failures)
        check(WindowMetrics.minimum == CGSize(width: 860, height: 580),
              "изменился минимальный размер окна", into: &failures)

        do {
            let settings = Settings()
            settings.appearance = .system
            let data = try JSONEncoder().encode(settings)
            let decoded = try JSONDecoder().decode(Settings.self, from: data)
            check(decoded.appearance == .system,
                  "тема не пережила JSON round-trip", into: &failures)
            check(decoded.appearance.colorScheme == nil,
                  "системная тема должна передавать выбор macOS", into: &failures)
        } catch {
            failures.append("не удалось проверить JSON настроек: \(error)")
        }

        let hosting = TransparentHostingView(rootView: Color.clear)
        check(hosting.isOpaque == false, "NSHostingView сообщает, что непрозрачен", into: &failures)
        check(hosting.layer?.isOpaque == false, "layer HUD сообщает, что непрозрачен", into: &failures)
        check(hosting.layer?.backgroundColor == NSColor.clear.cgColor,
              "у layer HUD не прозрачный фон", into: &failures)

        if failures.isEmpty {
            print("✓ Self-test: тема, размеры окна и прозрачность HUD")
            fflush(stdout)
            _exit(0)
        }

        for failure in failures { FileHandle.standardError.write(Data("✗ \(failure)\n".utf8)) }
        _exit(1)
    }

    private static func check(_ condition: @autoclosure () -> Bool,
                              _ message: String, into failures: inout [String]) {
        if !condition() { failures.append(message) }
    }
}
