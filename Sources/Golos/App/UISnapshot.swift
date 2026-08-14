import SwiftUI
import AppKit

/// Отрисовка экранов приложения в PNG — диагностика вёрстки.
///
/// `GOLOS_UI_SNAPSHOT=/папка` рисует основные экраны и завершает приложение.
/// Нужно, чтобы проверять вёрстку, не имея доступа к записи экрана: снимок
/// показывает грубые поломки — наложения, обрезанное содержимое, разъехавшиеся
/// колонки, — даже если материалы и размытия отрисуются не совсем как вживую.
@MainActor
enum UISnapshot {

    static func runIfRequested(env: AppEnvironment) -> Bool {
        guard let path = ProcessInfo.processInfo.environment["GOLOS_UI_SNAPSHOT"] else { return false }
        // Диагностические PNG не должны становиться неявным экспортом
        // пользовательских названий и расшифровок.
        guard env.library.recordings.isEmpty else {
            FileHandle.standardError.write(Data(
                "UI snapshots требуют пустую тестовую библиотеку; пользовательские данные не экспортированы.\n".utf8
            ))
            Log.flush()
            _exit(2)
        }
        render(into: URL(fileURLWithPath: path, isDirectory: true), env: env)
        return true
    }

    private static func render(into directory: URL, env: AppEnvironment) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let sampleIDs = addSamplesIfEmpty(env: env)

        for route in Route.allCases {
            env.route = route
            env.selectedRecording = nil
            write(env: env, name: route.rawValue, into: directory)
        }

        // Отдельно — открытая запись: у неё своя вёрстка.
        if let first = env.library.recordings.first {
            env.route = .library
            env.selectedRecording = first.id
            write(env: env, name: "library-detail", into: directory)
        }

        // Предложение завершить запись: главный экран этот способ отрисовки не
        // берёт целиком, поэтому карточку рисуем отдельно.
        writeSheet(env: env, name: "card-finish", into: directory) {
            FinishProposalCard(appName: "Zoom", elapsed: 2730, accent: env.settings.accent,
                               onMute: {}, onKeep: {}, onFinish: {})
                .padding(18)
                .frame(width: 900)
        }

        // Диалоги отдельно: на экранах их не видно, а проверять вёрстку нужно.
        if let sample = env.library.recordings.first {
            writeSheet(env: env, name: "sheet-speakers", into: directory) {
                ImportSpeakersSheet(recordings: [sample], onDone: { _, _ in }, onSkip: {})
            }
            // С заданным числом видно поля имён — их вёрстку иначе не проверить.
            writeSheet(env: env, name: "sheet-speakers-named", into: directory) {
                SpeakerSetupView(
                    expected: .constant(3),
                    names: .constant(["Аня", "Борис", ""])
                )
                .padding(22)
                .frame(width: 430)
            }
        }

        cleanUp(sampleIDs, env: env)
        print("Снимки экранов: \(directory.path)")
        // Минуя деструкторы: ggml падает в них при живом Metal-контексте.
        Log.flush()
        _exit(0)
    }

    /// Экран без NavigationSplitView: ImageRenderer его не умеет и отдаёт
    /// вместо картинки заглушку «не поддерживается».
    @ViewBuilder
    private static func screen(for route: Route) -> some View {
        switch route {
        case .record: RecordView()
        case .library: LibraryView()
        case .dictation: DictationView()
        case .archive: ArchiveView()
        case .stats: StatsView()
        case .models: ModelsView()
        case .system: SystemView()
        case .settings: SettingsView()
        }
    }

    private static func write(env: AppEnvironment, name: String, into directory: URL) {
        let content = ZStack {
            AuroraBackground(accent: env.settings.accent, animated: false)
            screen(for: env.route)
        }
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
            .frame(width: 1180, height: 780)

        guard let png = render(content, size: NSSize(width: 1180, height: 780),
                               appearance: env.settings.appearance) else {
            FileHandle.standardError.write(Data("Не удалось отрисовать \(name)\n".utf8))
            return
        }
        try? png.write(to: directory.appendingPathComponent("\(name).png"))
    }

    /// То же самое для листов: у них своя ширина и нет фона приложения.
    private static func writeSheet<Content: View>(
        env: AppEnvironment, name: String, into directory: URL,
        @ViewBuilder content: () -> Content
    ) {
        let view = content()
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
            .background(Color(nsColor: .windowBackgroundColor))

        let hosting = NSHostingView(rootView: view.fixedSize())
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        guard let png = render(view, size: size, appearance: env.settings.appearance) else {
            FileHandle.standardError.write(Data("Не удалось отрисовать \(name)\n".utf8))
            return
        }
        try? png.write(to: directory.appendingPathComponent("\(name).png"))
    }

    /// `ImageRenderer` на macOS заменяет некоторые AppKit-контролы знаком
    /// запрета. Кэширование настоящего `NSHostingView` проходит через тот же
    /// AppKit-путь, что пользовательское окно, и поэтому годится для QA.
    private static func render<Content: View>(_ content: Content, size: NSSize,
                                              appearance: Settings.AppearanceMode) -> Data? {
        guard size.width > 0, size.height > 0 else { return nil }
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(origin: .zero, size: size)
        switch appearance {
        case .dark: hosting.appearance = NSAppearance(named: .darkAqua)
        case .light: hosting.appearance = NSAppearance(named: .aqua)
        case .system: hosting.appearance = NSApp.effectiveAppearance
        }

        // AppKit-контролы и ScrollView полноценно раскладываются только внутри
        // окна. Это окно остаётся невидимым и существует лишь на время кадра.
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()

        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            return nil
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        window.contentView = nil
        return bitmap.representation(using: .png, properties: [:])
    }

    /// Пустой список ничего не расскажет о вёрстке — подкладываем примеры
    /// и убираем их за собой, чтобы не портить настоящую библиотеку.
    private static func addSamplesIfEmpty(env: AppEnvironment) -> [UUID] {
        guard env.library.recordings.isEmpty else { return [] }

        let samples: [(String, TimeInterval, Recording.Source, String?, String?)] = [
            ("Встреча · Zoom · Сегодня, 11:20", 3720, .meeting, "Zoom",
             "Давайте начнём с итогов недели. По первому пункту всё идёт по плану, "
             + "релиз готов к пятнице. По второму есть риск: подрядчик просит отсрочку."),
            ("Запись · Вчера, 18:04", 214, .microphone, nil,
             "Напоминание себе: заказать пропуск, подготовить смету и отправить её до конца дня."),
            ("Импорт · интервью.m4a", 1880, .imported, nil, nil)
        ]

        var ids: [UUID] = []
        for (index, sample) in samples.enumerated() {
            let id = UUID()
            ids.append(id)
            var recording = Recording(
                id: id,
                title: sample.0,
                createdAt: Date(timeIntervalSince1970: 1_770_000_000 - Double(index) * 86_400),
                duration: sample.1,
                source: sample.2,
                appHint: sample.3,
                tracks: [],
                transcriptStatus: sample.4 == nil ? .none : .done(segmentCount: 42, wordCount: 1280),
                language: "ru",
                modelID: "ggml-parakeet-tdt-0.6b-v3-q8_0"
            )
            recording.preview = sample.4
            recording.starred = index == 0
            env.library.add(recording)
        }
        return ids
    }

    private static func cleanUp(_ ids: [UUID], env: AppEnvironment) {
        for id in ids {
            if let recording = env.library.recordings.first(where: { $0.id == id }) {
                env.library.delete(recording)
            }
        }
    }
}
