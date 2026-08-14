import SwiftUI
import AppKit

@main
struct GolosApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var env: AppEnvironment

    init() {
        // Self-test должен завершиться до создания AppEnvironment: тот сразу
        // подключает системные уведомления, которым нужен полноценный .app.
        if RegressionSelfTest.runIfRequested() { fatalError("self-test must exit") }
        _env = StateObject(wrappedValue: AppEnvironment())
    }

    var body: some Scene {
        WindowGroup("голос") {
            RootView()
                .environmentObject(env)
                .environmentObject(env.settings)
                .environmentObject(env.library)
                .environmentObject(env.models)
                .environmentObject(env.transcription)
                .environmentObject(env.recorder)
                .environmentObject(env.monitor)
                .environmentObject(env.dictation)
                .environmentObject(env.calls)
                .preferredColorScheme(env.settings.appearance.colorScheme)
                .frame(minWidth: WindowMetrics.minimum.width,
                       minHeight: WindowMetrics.minimum.height)
                .onAppear {
                    delegate.env = env
                    env.start()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: WindowMetrics.initial.width,
                     height: WindowMetrics.initial.height)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Начать запись") { env.toggleRecording() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Импортировать аудио…") { env.route = .record; delegate.requestImport() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(after: .appInfo) {
                Button("Показать папку с данными") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: Container.root.path)
                }
            }
        }

        MenuBarExtra("голос", systemImage: menuBarSymbol, isInserted: Binding(
            get: { env.settings.showMenuBarIcon },
            set: { newValue in
                guard env.settings.showMenuBarIcon != newValue else { return }
                env.settings.showMenuBarIcon = newValue
            }
        )) {
            MenuBarPanel()
                .environmentObject(env)
                .environmentObject(env.settings)
                .environmentObject(env.library)
                .environmentObject(env.models)
                .environmentObject(env.transcription)
                .environmentObject(env.recorder)
                .environmentObject(env.monitor)
                .environmentObject(env.dictation)
                .environmentObject(env.calls)
                .preferredColorScheme(env.settings.appearance.colorScheme)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarSymbol: String {
        if env.recorder.isBusy { return "waveform.circle.fill" }
        if env.dictation.phase.isActive { return "mic.circle.fill" }
        return "waveform"
    }
}

/// Размеры собраны в одном месте: интерфейс, self-test и документация должны
/// говорить об одном и том же стартовом окне.
enum WindowMetrics {
    static let initial = CGSize(width: 980, height: 680)
    static let minimum = CGSize(width: 860, height: 580)
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    weak var env: AppEnvironment?
    var importRequest: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    /// Завершаемся, не давая запуститься статическим деструкторам C++.
    ///
    /// Иначе `exit()` доходит до деструктора ggml-вектора Metal-устройств,
    /// тот вызывает `ggml_metal_rsets_free`, а он бьёт `ggml_abort`, потому что
    /// собственный рабочий поток ggml к этому моменту ещё жив. Результат —
    /// отчёт о падении при каждом обычном выходе из приложения. Ошибка внутри
    /// ggml, и снаружи её чинить нечем, кроме как не выполнять эту стадию
    /// завершения вовсе.
    ///
    /// Терять при этом нечего: настройки, библиотека и расшифровки пишутся
    /// на диск сразу по изменению, а не при выходе.
    func applicationWillTerminate(_ notification: Notification) {
        env?.settings.save()
        Log.info("Выход")
        Log.flush()
        _exit(0)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Со значком в строке меню приложение продолжает работать без окна:
        // диктовка должна быть под рукой всегда. Если значок выключен, окно —
        // единственный вход в программу, и закрывать его без выхода нельзя:
        // иначе «голос» останется висеть невидимым процессом.
        !(env?.settings.showMenuBarIcon ?? true)
    }

    /// Не даём выйти, потеряв незавершённую запись.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let env, env.recorder.isBusy else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "Идёт запись"
        alert.informativeText = "Сохранить её перед выходом?"
        alert.addButton(withTitle: "Сохранить и выйти")
        alert.addButton(withTitle: "Отмена")
        alert.addButton(withTitle: "Удалить и выйти")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { @MainActor in
                await env.recorder.stop()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        case .alertThirdButtonReturn:
            Task { @MainActor in
                await env.recorder.discard()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        default:
            return .terminateCancel
        }
    }

    func requestImport() {
        importRequest?()
    }
}
