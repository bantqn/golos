import Foundation
import SwiftUI
import Combine
import AVFoundation

enum Route: String, CaseIterable, Identifiable, Hashable {
    case record, library, dictation, archive, stats, models, system, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .record: return "Запись"
        case .library: return "Библиотека"
        case .dictation: return "Диктовка"
        case .archive: return "Транскрипции"
        case .stats: return "Статистика"
        case .models: return "Модели"
        case .system: return "Нагрузка"
        case .settings: return "Настройки"
        }
    }

    var symbol: String {
        switch self {
        case .record: return "waveform.circle.fill"
        case .library: return "rectangle.stack.fill"
        case .dictation: return "waveform.badge.mic"
        case .archive: return "doc.text.fill"
        case .stats: return "chart.bar.fill"
        case .models: return "cube.transparent.fill"
        case .system: return "gauge.with.dots.needle.67percent"
        case .settings: return "gearshape.fill"
        }
    }
}

/// Корневой объект приложения: держит все сервисы и связывает их между собой.
@MainActor
final class AppEnvironment: ObservableObject {

    /// HUD диктовки живёт в отдельном окне вне иерархии SwiftUI —
    /// ему нужна прямая ссылка на настройки для темы.
    static var sharedSettings = Settings()

    let settings: Settings
    let library: LibraryStore
    let models: ModelStore
    let transcription: TranscriptionService
    let recorder: RecordingController
    let monitor: SystemMonitor
    let dictation: DictationController
    let calls: CallDetector

    @Published var route: Route = .record
    @Published var selectedRecording: UUID?
    @Published var showOnboarding = false
    /// Первая загрузка Metal-ядер занимает секунды — показываем это честно.
    @Published var warmup: WarmupState = .idle
    @Published var banner: Banner?

    enum WarmupState: Equatable {
        case idle, running, ready, unavailable
    }

    struct Banner: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var kind: Kind
        enum Kind { case info, warning, error, success }
    }

    /// Предложение остановить запись: разговор закончился, а мы всё пишем.
    struct FinishProposal: Identifiable, Equatable {
        let id = UUID()
        var appName: String
        var bundleID: String?
    }

    @Published var finishProposal: FinishProposal?

    private var cancellables: Set<AnyCancellable> = []

    init() {
        Container.bootstrap()

        let settings = Settings.load()
        AppEnvironment.sharedSettings = settings
        self.settings = settings

        let library = LibraryStore()
        library.settings = settings
        let models = ModelStore()
        self.library = library
        self.models = models
        self.transcription = TranscriptionService(settings: settings, library: library, models: models)
        self.recorder = RecordingController(settings: settings, library: library)
        self.monitor = SystemMonitor()
        self.dictation = DictationController(settings: settings, models: models)
        self.calls = CallDetector()

        wire()
    }

    private func wire() {
        // Готовая запись сразу уходит в очередь расшифровки.
        recorder.onFinished = { [weak self] recording in
            guard let self else { return }
            if self.settings.autoTranscribeAfterRecording {
                self.transcription.enqueue(recording)
            }
            self.selectedRecording = recording.id
        }

        // Найден звонок — решение принимается по правилу для этой программы.
        calls.onCallStarted = { [weak self] detection in
            guard let self, !self.recorder.isBusy else { return }
            let rule = self.settings.rule(forBundleID: detection.bundleID)

            if rule.autoRecord {
                Task {
                    await self.recorder.start(source: .meeting, appHint: detection.appName,
                                              appBundleID: detection.bundleID)
                }
                self.banner = Banner(
                    text: "Запись разговора в \(detection.appName) началась автоматически",
                    kind: .success
                )
                return
            }
            if rule.notify {
                // Окно может быть закрыто или перекрыто — тогда баннер внутри
                // приложения никто не увидит, и нужно системное уведомление.
                Notifier.shared.notifyCallDetected(
                    appName: detection.appName, bundleID: detection.bundleID)
            }
        }

        // Разговор закончился — программа отпустила микрофон.
        calls.onCallEnded = { [weak self] detection in
            guard let self, self.recorder.isBusy, self.settings.callEndAction != .ignore else { return }

            // Ждём: при переключении устройства или включении демонстрации экрана
            // программы отпускают микрофон на секунду-две, и предлагать завершить
            // запись в такой момент было бы неверно.
            let delay = max(2, self.settings.callEndDelaySeconds)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                guard let self else { return }
                if let bundleID = detection.bundleID,
                   self.calls.active.contains(where: { $0.bundleID == bundleID }) {
                    Log.info("\(detection.appName) снова занял микрофон — запись продолжается")
                    return
                }
                self.handleCallEnd(detection)
            }
        }

        // Отрезок дневной записи готов — расшифровываем его, не дожидаясь вечера.
        recorder.onSegmentReady = { [weak self] recordingID, tracks in
            guard let self, self.settings.continuousTranscribeIncrementally else { return }
            let title = self.library.recording(id: recordingID)?.title ?? "Дневная запись"
            self.transcription.enqueueSegments(
                recordingID: recordingID, tracks: tracks, title: title)
        }

        // Замеченные программы пополняют таблицу правил в настройках.
        calls.onAppSeen = { [weak self] bundleID, name in
            self?.settings.noteSeenApp(bundleID: bundleID, name: name)
        }

        // Пока микрофон занят нами самими, детектор молчит: иначе он
        // докладывает о «разговоре», который мы же и затеяли диктовкой.
        recorder.$state
            .combineLatest(dictation.$phase)
            .sink { [weak self] state, phase in
                self?.calls.isSuppressed = state != .idle || phase != .idle
                if state == .idle { self?.finishProposal = nil }
            }
            .store(in: &cancellables)

        // Кнопка «Записать» в уведомлении.
        Notifier.shared.onRecordRequested = { [weak self] bundleID in
            guard let self, !self.recorder.isBusy else { return }
            let name = bundleID.flatMap { id in
                KnownCallApps.all.first { $0.bundleID == id }?.name
            }
            self.calls.dismissCurrent()
            Task {
                await self.recorder.start(source: .meeting, appHint: name, appBundleID: bundleID)
            }
        }

        // Кнопка «Завершить запись» в уведомлении об окончании разговора.
        Notifier.shared.onFinishRequested = { [weak self] in
            guard let self, self.recorder.isBusy else { return }
            self.finishProposal = nil
            Task { await self.recorder.stop() }
        }

        // Кнопка «Не уведомлять об этой программе» — прямо из уведомления.
        Notifier.shared.onMuteAppRequested = { [weak self] bundleID in
            guard let self else { return }
            self.muteNotifications(forBundleID: bundleID)
        }

        // Смена сочетания клавиш применяется без перезапуска.
        settings.$dictationHotKey
            .dropFirst()
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.dictation.reloadHotKey() }
            .store(in: &cancellables)

        settings.$dictationEnabled
            .dropFirst()
            .sink { [weak self] enabled in
                enabled == true ? self?.dictation.activate() : self?.dictation.deactivate()
            }
            .store(in: &cancellables)

        settings.$detectCalls
            .sink { [weak self] enabled in
                enabled == true ? self?.calls.start() : self?.calls.stop()
            }
            .store(in: &cancellables)

        // Порог простоя применяется к обоим движкам сразу.
        settings.$modelIdleUnloadSeconds
            .sink { seconds in
                Engines.setIdleUnloadSeconds(TimeInterval(max(0, seconds)))
            }
            .store(in: &cancellables)

        // Пересылать сюда objectWillChange настроек нельзя: тело App читает
        // настройки, а его повторное вычисление снова пишет в них через
        // MenuBarExtra(isInserted:) — получается бесконечная перерисовка,
        // которая занимает главный поток целиком и жрёт память.
        // Каждый экран подписывается на нужные ему объекты сам, через
        // @EnvironmentObject.

        // Система жалуется на память — отдаём всё, что можем, немедленно.
        MemoryGuard.startMonitoring { [weak self] critical in
            self?.relieveMemoryPressure(critical: critical)
        }

        // Пока окном не пользуются, держать в памяти гигабайты незачем.
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in self?.scheduleIdleUnload() }
            .store(in: &cancellables)
    }

    // MARK: - Память

    /// Освобождает всё, что можно освободить без потери данных.
    func relieveMemoryPressure(critical: Bool) {
        // Идущую расшифровку не рвём: её модель занята делом, а выгрузка
        // из-под работающего whisper_full всё равно дождётся конца расчёта.
        Engines.unloadIdle(
            keepBulk: transcription.isRunning,
            keepDictation: dictation.phase != .idle
        )
        library.trimCaches()
        MemoryGuard.releaseFreedPages()

        if critical {
            banner = Banner(
                text: "Системе не хватает памяти — освободил всё, что мог. "
                    + "Если это повторяется, возьмите модель поменьше.",
                kind: .warning
            )
        }
        Log.warn("Освобождение памяти по давлению системы, процесс занимает \(Fmt.bytes(MemoryGuard.footprintBytes))")
    }

    /// Через полминуты после потери фокуса выгружаем модели, если ничего не идёт.
    private func scheduleIdleUnload() {
        guard settings.unloadWhenInactive else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard let self, !NSApp.isActive,
                  !self.transcription.isRunning,
                  !self.recorder.isBusy,
                  self.dictation.phase == .idle
            else { return }
            Engines.unloadAll()
            self.library.trimCaches()
            MemoryGuard.releaseFreedPages()
        }
    }

    /// Выгрузка по кнопке из настроек.
    func unloadModelsNow() {
        Engines.unloadAll()
        library.trimCaches()
        MemoryGuard.releaseFreedPages()
        banner = Banner(text: "Модели выгружены из памяти", kind: .success)
    }

    func start() {
        // Диагностический режим: отрисовать плашку диктовки и выйти.
        if HUDSnapshot.runIfRequested() { return }
        if UISnapshot.runIfRequested(env: self) { return }
        Notifier.shared.configure()
        monitor.start()
        Engines.setIdleUnloadSeconds(TimeInterval(max(0, settings.modelIdleUnloadSeconds)))
        if settings.dictationEnabled { dictation.activate() }
        if settings.detectCalls { calls.start() }
        showOnboarding = !models.hasAnyModel
        if models.hasAnyModel { warmUpEngine() }
        startMemoryDiagnostics()
        runLLMDiagnosticIfRequested()
        runDiarizationDiagnosticIfRequested()
        runMicHoldIfRequested()
        runMicTestIfRequested()
        runRecordTestIfRequested()
        runCallWatchIfRequested()
    }

    /// `GOLOS_LLM_TEST="текст"` прогоняет строку через настроенную обработку
    /// и пишет результат в журнал. Нужно, чтобы проверять связь с моделью
    /// без нажатий в интерфейсе.
    private func runLLMDiagnosticIfRequested() {
        guard let sample = ProcessInfo.processInfo.environment["GOLOS_LLM_TEST"] else { return }
        // GOLOS_LLM_PRESET — прогнать через конкретную заготовку, а не через
        // текущие настройки. Нужно, чтобы проверять заготовки по одной.
        let presetIDs = (ProcessInfo.processInfo.environment["GOLOS_LLM_PRESET"] ?? "")
            .split(separator: ",").map(String.init)

        Task { @MainActor in
            Log.info("[LLM] провайдер: \(settings.llmProvider.title), модель: \(settings.llmModel)")
            Log.info("[LLM] вход: \(sample)")
            do {
                if presetIDs.isEmpty {
                    // GOLOS_LLM_BUNDLE — проверить, какое правило сработает для
                    // конкретной программы, включая вариант «без обработки».
                    let bundleID = ProcessInfo.processInfo.environment["GOLOS_LLM_BUNDLE"]
                    let rule = PostProcessor.prompt(for: bundleID, settings: settings)
                    Log.info("[LLM] программа: \(bundleID ?? "—"), правило: \(rule == nil ? "без обработки" : "есть")")
                    let result = try await PostProcessor.process(sample, bundleID: bundleID, settings: settings)
                    Log.info("[LLM] выход: \(result)")
                } else {
                    for id in presetIDs {
                        guard let preset = PostProcessor.preset(id: id) else {
                            Log.warn("[LLM] нет заготовки \(id)"); continue
                        }
                        let started = Date()
                        let result = try await PostProcessor.run(
                            sample, instruction: preset.prompt, settings: settings)
                        let took = String(format: "%.1f", Date().timeIntervalSince(started))
                        Log.info("[LLM] «\(preset.title)» (\(took) с): \(result)")
                    }
                }
            } catch {
                Log.error("[LLM] ошибка: \(error.localizedDescription)")
            }
            Log.flush()
            _exit(0)
        }
    }

    /// Диагностика записи: `GOLOS_REC_TEST=6` пишет шесть секунд обычной записи
    /// и докладывает, что получилось в файле. Нужна после смены способа захвата:
    /// журнал скажет «запись начата» и при полной тишине в дорожке.
    private func runRecordTestIfRequested() {
        guard let raw = ProcessInfo.processInfo.environment["GOLOS_REC_TEST"],
              let seconds = Double(raw) else { return }

        Task { @MainActor in
            // Микрофон в настройках может быть выключен, а проверять надо именно
            // его. Возвращаем как было — чужие настройки диагностика не меняет.
            let previousMic = settings.recordMicrophone
            settings.recordMicrophone = true

            // Запоминаем, что было до нас: удалять можно только свою запись.
            // Иначе диагностика снесла бы чужую, начатую в это же время.
            let before = Set(library.recordings.map(\.id))
            await recorder.start(source: .microphone)
            guard recorder.isBusy else {
                Log.error("[запись] не началась: \(recorder.lastError ?? "причина неизвестна")")
                settings.recordMicrophone = previousMic
                settings.save()
                Log.flush()
                _exit(1)
            }
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            await recorder.stop()
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            settings.recordMicrophone = previousMic
            settings.save()

            guard let recording = library.recordings.first(where: { !before.contains($0.id) }) else {
                Log.error("[запись] в библиотеке ничего не появилось")
                Log.flush()
                _exit(1)
            }
            Log.info("[запись] «\(recording.title)», \(Fmt.duration(recording.duration)), "
                     + "микрофон: \(recording.micDeviceName ?? "?")")
            for track in recording.orderedTracks {
                let url = recording.url(for: track)
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                let samples = (try? AudioLoader.samples(from: url, start: 0, duration: 3)) ?? []
                var peak: Float = 0
                var sum: Float = 0
                for value in samples {
                    peak = max(peak, abs(value))
                    sum += value * value
                }
                let rms = samples.isEmpty ? 0 : (sum / Float(samples.count)).squareRoot()
                Log.info("[запись] дорожка \(track.kind.title): \(size) байт, "
                         + "семплов \(samples.count), пик \(String(format: "%.3f", peak)), "
                         + "громкость \(String(format: "%.4f", rms))")
            }
            library.delete(recording)
            Log.info("[запись] проверочная запись удалена")
            Log.flush()
            _exit(0)
        }
    }

    /// Диагностика Bluetooth-наушников: `GOLOS_MIC_TEST=6` включает микрофон
    /// тем же путём, что и диктовка, и следит за частотой устройства вывода.
    /// Проверять на слух бессмысленно: падение с 44 100 до 16 000 Гц — это и есть
    /// переход гарнитуры в режим разговора, и видно его только в числах.
    /// `GOLOS_MIC_BT=1` заставляет взять микрофон гарнитуры — для сравнения.
    private func runMicTestIfRequested() {
        guard let raw = ProcessInfo.processInfo.environment["GOLOS_MIC_TEST"],
              let seconds = Double(raw) else { return }
        let avoid = ProcessInfo.processInfo.environment["GOLOS_MIC_BT"] == nil

        let mic = MicRecorder()
        var samples = 0
        var peak: Float = 0
        mic.onSamples = { chunk in
            samples += chunk.count
            for value in chunk { peak = max(peak, abs(value)) }
        }

        Task { @MainActor in
            for device in AudioInputDevice.available() {
                Log.info("[наушники] вход: «\(device.name)»"
                         + (device.isBluetooth ? ", Bluetooth" : "")
                         + (device.isBuiltIn ? ", встроенный" : "")
                         + (device.isDefault ? ", по умолчанию" : ""))
            }
            Log.info("[наушники] выход «\(AudioOutputInfo.defaultName())»: "
                     + "\(AudioOutputInfo.defaultSampleRate()) Гц — до включения микрофона; "
                     + "подмена Bluetooth: \(avoid ? "включена" : "выключена")")

            do {
                let configured = settings.inputDeviceID == 0 ? nil : settings.inputDeviceID
                try mic.start(deviceID: configured, avoidBluetooth: avoid)
            } catch {
                Log.error("[наушники] микрофон не запустился: \(error.localizedDescription)")
                Log.flush()
                _exit(1)
            }

            let steps = max(1, Int(seconds))
            for step in 1...steps {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                Log.info("[наушники] +\(step) с: выход \(AudioOutputInfo.defaultSampleRate()) Гц, "
                         + "семплов \(samples), пик \(String(format: "%.3f", peak))")
            }

            mic.stop()
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            Log.info("[наушники] после остановки: выход \(AudioOutputInfo.defaultSampleRate()) Гц; "
                     + "писали с «\(mic.deviceName ?? "?")»")
            Log.flush()
            _exit(0)
        }
    }

    /// Диагностика: `GOLOS_MIC_HOLD=20` занимает микрофон на 20 секунд и выходит.
    /// Нужен как «чужая программа» для проверки детектора разговоров: второй
    /// экземпляр приложения видит этот процесс как постороннего и должен
    /// заметить и начало, и освобождение микрофона.
    private func runMicHoldIfRequested() {
        guard let raw = ProcessInfo.processInfo.environment["GOLOS_MIC_HOLD"],
              let seconds = Double(raw) else { return }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 4096,
                        format: input.inputFormat(forBus: 0)) { _, _ in }
        do {
            try engine.start()
        } catch {
            Log.error("[держу микрофон] не удалось: \(error.localizedDescription)")
            Log.flush()
            _exit(1)
        }
        Log.info("[держу микрофон] занял на \(Int(seconds)) с, pid \(getpid())")

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            engine.stop()
            input.removeTap(onBus: 0)
            Log.info("[держу микрофон] отпустил")
            Log.flush()
            // Даём CoreAudio обновить состояние, прежде чем исчезнуть.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            _exit(0)
        }
    }

    /// Диагностика детектора разговоров: `GOLOS_CALL_WATCH=45` включает детектор
    /// на 45 секунд, пишет в журнал, кто занимает микрофон, и проверяет всю
    /// цепочку — начало разговора, запись, освобождение микрофона, предложение
    /// завершить. `GOLOS_CALL_RECORD=1` заодно начинает запись, чтобы убедиться,
    /// что собственный микрофон больше не мешает видеть чужой.
    private func runCallWatchIfRequested() {
        guard let raw = ProcessInfo.processInfo.environment["GOLOS_CALL_WATCH"],
              let seconds = Double(raw) else { return }
        let alsoRecord = ProcessInfo.processInfo.environment["GOLOS_CALL_RECORD"] != nil

        // Настройки трогаем на время прогона и возвращаем перед выходом: они
        // сохраняются сами, и диагностика не должна менять то, что выбрал человек.
        let previous = (detect: settings.detectCalls,
                        action: settings.callEndAction,
                        delay: settings.callEndDelaySeconds)
        settings.detectCalls = true
        settings.callEndDelaySeconds =
            Int(ProcessInfo.processInfo.environment["GOLOS_CALL_DELAY"] ?? "") ?? 3
        if let mode = ProcessInfo.processInfo.environment["GOLOS_CALL_END"],
           let action = CallEndAction(rawValue: mode) {
            settings.callEndAction = action
        }
        Log.info("[звонки] наблюдаю \(Int(seconds)) с; точный способ: "
                 + "\(AudioProcessMonitor.isAvailable ? "есть" : "нет"); "
                 + "реакция на конец: \(settings.callEndAction.title)")

        let started = Date()
        calls.start()

        var sawStart = false
        var sawEnd = false
        var sawProposal = false

        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            Task { @MainActor [weak self] in
                guard let self else { timer.invalidate(); return }
                let elapsed = Date().timeIntervalSince(started)

                let names = self.calls.active.map { "\($0.name) [\($0.bundleID)]" }
                if let detection = self.calls.current, !sawStart {
                    sawStart = true
                    Log.info("[звонки] +\(Int(elapsed)) с: начало — \(detection.appName)")
                    if alsoRecord {
                        Log.info("[звонки] начинаю запись, чтобы занять микрофон и собой")
                        await self.recorder.start(source: .meeting, appHint: detection.appName,
                                                  appBundleID: detection.bundleID)
                    }
                }
                if sawStart, self.calls.active.isEmpty, !sawEnd {
                    sawEnd = true
                    Log.info("[звонки] +\(Int(elapsed)) с: микрофон свободен, "
                             + "пишем сами: \(self.recorder.isBusy ? "да" : "нет")")
                }
                if let proposal = self.finishProposal, !sawProposal {
                    sawProposal = true
                    Log.info("[звонки] +\(Int(elapsed)) с: предложено завершить — \(proposal.appName)")

                    // GOLOS_CALL_MUTE=1 — проверка кнопки «не уведомлять
                    // об этой программе»: это тот же код, что и в уведомлении.
                    if ProcessInfo.processInfo.environment["GOLOS_CALL_MUTE"] != nil,
                       let bundleID = proposal.bundleID {
                        let before = self.settings.rule(forBundleID: bundleID)
                        self.muteNotifications(forBundleID: bundleID)
                        let after = self.settings.rule(forBundleID: bundleID)
                        Log.info("[звонки] правило для \(bundleID): уведомлять "
                                 + "\(before.notify) → \(after.notify), "
                                 + "писать сразу \(before.autoRecord) → \(after.autoRecord); "
                                 + "в таблице настроек: "
                                 + "\(self.settings.ruleCandidates.contains { $0.bundleID == bundleID } ? "есть" : "нет")")
                        self.settings.clearRule(forBundleID: bundleID)
                    }
                }
                if !names.isEmpty {
                    Log.info("[звонки] +\(Int(elapsed)) с: микрофон у \(names.joined(separator: ", "))")
                }

                guard elapsed >= seconds else { return }
                timer.invalidate()
                if self.recorder.isBusy { await self.recorder.stop() }
                Log.info("[звонки] итог: начало \(sawStart ? "да" : "нет"), "
                         + "конец \(sawEnd ? "да" : "нет"), "
                         + "предложение \(sawProposal ? "да" : "нет")")

                // Убираем за собой: запись, сделанную ради проверки, и настройки.
                for recording in self.library.recordings
                where recording.title.hasPrefix("Встреча · Голос")
                   || recording.title.hasPrefix("Встреча · голос") {
                    self.library.delete(recording)
                    Log.info("[звонки] удалил проверочную запись «\(recording.title)»")
                }
                self.settings.detectCalls = previous.detect
                self.settings.callEndAction = previous.action
                self.settings.callEndDelaySeconds = previous.delay
                self.settings.save()
                Log.flush()
                _exit(0)
            }
        }
    }

    /// Диагностический прогон разделения по голосам:
    /// `GOLOS_DIAR=/путь/к/файлу` (плюс необязательные `GOLOS_DIAR_SPEAKERS=2`
    /// и `GOLOS_DIAR_ASR=1`) печатает шкалу «кто когда говорит», а с `ASR` —
    /// ещё и готовые реплики с ролями. Проверять разделение на слух и по
    /// скриншотам бессмысленно: нужны границы отрезков в секундах.
    private func runDiarizationDiagnosticIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["GOLOS_DIAR"] else { return }
        let expected = ProcessInfo.processInfo.environment["GOLOS_DIAR_SPEAKERS"].flatMap(Int.init)
        let withASR = ProcessInfo.processInfo.environment["GOLOS_DIAR_ASR"] != nil
        let url = URL(fileURLWithPath: path)

        Task { @MainActor in
            let options = Diarizer.Options(
                maxSpeakers: settings.maxSpeakers,
                threshold: 0.15,
                minPitchSeparation: settings.diarizationThreshold
            )
            let started = Date()
            let turns = await Task.detached(priority: .userInitiated) {
                Diarizer.speakerTurns(audioURL: url, expectedSpeakers: expected, options: options)
            }.value
            Log.info("[голоса] \(url.lastPathComponent): отрезков \(turns.count), "
                     + "голосов \(Set(turns.map(\.voice)).count), "
                     + "задано \(expected.map(String.init) ?? "авто"), "
                     + "за \(String(format: "%.1f", Date().timeIntervalSince(started))) с")
            for turn in turns {
                Log.info(String(format: "[голоса] %6.2f–%6.2f  голос %d",
                                turn.start, turn.end, turn.voice))
            }

            guard withASR else {
                Log.flush()
                _exit(0)
            }

            guard var recording = await recorder.importFile(at: url, autoQueue: false) else {
                Log.error("[голоса] не удалось импортировать \(path)")
                Log.flush()
                _exit(1)
            }
            recording.expectedSpeakers = expected
            // GOLOS_DIAR_NAMES=Аня,Борис — проверка, что подписи доходят до текста.
            recording.speakerNames = (ProcessInfo.processInfo.environment["GOLOS_DIAR_NAMES"] ?? "")
                .split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            library.update(recording)
            transcription.enqueue(recording)
            while !transcription.isRunning { try? await Task.sleep(nanoseconds: 200_000_000) }
            while transcription.isRunning { try? await Task.sleep(nanoseconds: 500_000_000) }

            if let transcript = library.transcript(for: recording.id) {
                let voices = Set(transcript.segments.compactMap { segment -> Int? in
                    if case .voice(let index) = segment.speaker { return index } else { return nil }
                })
                Log.info("[голоса] реплик \(transcript.segments.count), "
                         + "ролей \(voices.count), слов \(transcript.wordCount)")
                for segment in transcript.segments.prefix(40) {
                    Log.info(String(format: "[голоса] %6.2f  %@ — %@", segment.start,
                                    recording.speakerTitle(for: segment.speaker),
                                    String(segment.text.prefix(70))))
                }
            } else {
                Log.error("[голоса] расшифровка не появилась: \(recording.transcriptStatus)")
            }
            // Убираем за собой: диагностика не должна оставлять мусор
            // в настоящей библиотеке пользователя.
            if let fresh = library.recording(id: recording.id) { library.delete(fresh) }
            Log.flush()
            _exit(0)
        }
    }

    /// Диагностический прогон: `GOLOS_BENCH=/путь/к/файлу` импортирует файл,
    /// расшифровывает его и раз в секунду пишет в журнал занятую память.
    /// Нужен, чтобы проверять расход памяти на длинных записях, а не догадываться о нём.
    private func startMemoryDiagnostics() {
        guard let path = ProcessInfo.processInfo.environment["GOLOS_BENCH"] else { return }
        Log.info("[замер] диагностический прогон: \(path)")

        var peak: Int64 = 0
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            let current = MemoryGuard.footprintBytes
            peak = max(peak, current)
            Task { @MainActor [weak self] in
                guard let self else { timer.invalidate(); return }
                let stage = self.transcription.current?.stage ?? "простой"
                let progress = Int((self.transcription.current?.progress ?? 0) * 100)
                Log.info("[замер] сейчас \(Fmt.bytes(current)), пик \(Fmt.bytes(peak)) — \(stage) \(progress)%")
            }
        }

        // GOLOS_BENCH_RUNS повторяет расшифровку несколько раз подряд:
        // так видно, растёт ли расход памяти от прогона к прогону.
        let runs = Int(ProcessInfo.processInfo.environment["GOLOS_BENCH_RUNS"] ?? "1") ?? 1

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let recording = await recorder.importFile(at: URL(fileURLWithPath: path)) else {
                Log.error("[замер] не удалось импортировать \(path)")
                return
            }
            for run in 1...max(1, runs) {
                Log.info("[замер] прогон \(run) из \(runs), пик до старта \(Fmt.bytes(peak))")
                transcription.enqueue(recording)
                // Ждём завершения: сначала старта, затем окончания.
                while !transcription.isRunning { try? await Task.sleep(nanoseconds: 200_000_000) }
                while transcription.isRunning { try? await Task.sleep(nanoseconds: 500_000_000) }
            }
            Log.info("[замер] все прогоны завершены, пик \(Fmt.bytes(peak))")
        }
    }

    /// Прогревает движок: первая компиляция Metal-ядер занимает секунд десять,
    /// и лучше пережить её в фоне сразу после запуска, чем во время диктовки.
    func warmUpEngine() {
        guard settings.useGPU, warmup == .idle || warmup == .unavailable else { return }
        guard let modelID = models.installedSpeechModels
            .sorted(by: { $0.sizeBytes < $1.sizeBytes }).first?.id,
              let spec = ModelCatalog.spec(id: modelID) else { return }

        warmup = .running
        let options = settings.dictationOptions(modelURL: models.fileURL(for: spec))
        let engine = Engines.engine(for: spec, role: .dictation)

        Task.detached(priority: .utility) {
            // Полсекунды тишины: важен не результат, а инициализация GPU-бэкенда.
            let silence = [Float](repeating: 0, count: Int(AudioFormat.sampleRate / 2))
            let ok = (try? engine.transcribe(samples: silence, options: options)) != nil
            await MainActor.run { [weak self] in
                self?.warmup = ok ? .ready : .unavailable
                if !ok { Log.warn("Прогрев движка не удался — проверьте модель") }
            }
        }
    }

    // MARK: - Действия верхнего уровня

    func toggleRecording() {
        Task {
            if recorder.isBusy {
                await recorder.stop()
            } else {
                let hint = calls.current?.appName
                await recorder.start(source: hint == nil ? .microphone : .meeting, appHint: hint)
            }
        }
    }

    func startRecordingCall(_ detection: CallDetector.Detection) {
        calls.dismissCurrent()
        Task {
            await recorder.start(source: .meeting, appHint: detection.appName,
                                 appBundleID: detection.bundleID)
        }
    }

    /// Больше не уведомлять об этой программе. Автозапись при этом не трогаем:
    /// «не отвлекай» и «не пиши» — разные желания.
    func muteNotifications(forBundleID bundleID: String) {
        var rule = settings.rule(forBundleID: bundleID)
        rule.notify = false
        settings.setRule(rule, forBundleID: bundleID)
        let name = settings.seenCallApps[bundleID]
            ?? KnownCallApps.all.first { $0.bundleID == bundleID }?.name
            ?? bundleID
        banner = Banner(text: "Уведомления о «\(name)» отключены", kind: .info)
        Log.info("Уведомления отключены для \(bundleID)")
    }

    /// Запись, которую предлагаем завершить, — только начатая ради разговора.
    /// Дневную и обычную запись с микрофона трогать нельзя: их начинали не из-за
    /// звонка, и чужой микрофон к ним отношения не имеет.
    private func handleCallEnd(_ detection: CallDetector.Detection) {
        Log.info("Разговор в «\(detection.appName)» закончился; наша запись: "
                 + "\(recorder.isBusy ? "идёт" : "нет"), тип \(recorder.source.title), "
                 + "реакция \(settings.callEndAction.title)")
        guard recorder.isBusy, recorder.source == .meeting else { return }
        // Запись могла начаться из-за другой программы.
        if let started = recorder.appBundleID, let ended = detection.bundleID,
           started != ended { return }

        switch settings.callEndAction {
        case .ignore:
            return
        case .finish:
            Log.info("Завершаю запись: \(detection.appName) освободил микрофон")
            banner = Banner(text: "\(detection.appName) освободил микрофон — запись завершена",
                            kind: .success)
            Task { await recorder.stop() }
        case .ask:
            finishProposal = FinishProposal(appName: detection.appName,
                                            bundleID: detection.bundleID)
            if settings.rule(forBundleID: detection.bundleID).notify {
                Notifier.shared.notifyCallEnded(
                    appName: detection.appName, bundleID: detection.bundleID,
                    elapsed: recorder.elapsed)
            }
        }
    }

    func show(_ route: Route) {
        self.route = route
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
        }
    }

    func open(recording: Recording) {
        selectedRecording = recording.id
        route = .library
    }

    /// Удаляет всё содержимое контейнера. Возврата нет.
    func eraseAllData() {
        library.deleteAll()
        dictation.clearHistory()
        for spec in ModelCatalog.all { models.delete(spec) }
        Container.cleanTemporary()
        Log.clear()
        banner = Banner(text: "Все данные удалены", kind: .success)
    }

    var containerSize: Int64 { Container.size(of: Container.root) }
}
