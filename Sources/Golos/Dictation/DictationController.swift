import Foundation
import AppKit
import Combine

/// Одна выполненная диктовка — хранится, чтобы текст можно было
/// скопировать повторно, если вставка ушла не туда.
struct DictationEntry: Identifiable, Codable, Hashable {
    var id = UUID()
    var text: String
    var createdAt: Date
    var targetApp: String?
    var seconds: TimeInterval
    var recognitionSeconds: TimeInterval
}

/// Диктовка в любое приложение: зажали сочетание, сказали, отпустили — текст на месте.
@MainActor
final class DictationController: ObservableObject {

    enum Phase: Equatable {
        case idle
        case listening
        case recognizing
        /// Текст распознан, идёт обработка языковой моделью.
        case processing
        case inserted(String)
        case copiedOnly(String)     // текст распознан, но вставить было некуда
        case failed(String)

        var isActive: Bool { self != .idle }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var level: Float = 0
    @Published private(set) var waveform: [Float] = Array(repeating: 0, count: 40)
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var history: [DictationEntry] = []
    @Published private(set) var hotKeyRegistered = false
    /// Клавиши отпущены сразу — значит режим «зафиксировано», ждём второго нажатия.
    @Published private(set) var isLatched = false

    /// Куда попадёт текст — показывается в HUD.
    @Published private(set) var targetApp: String?
    /// Текст, распознанный по ходу речи. Черновик: финальный проход обычно
    /// расставляет знаки и исправляет окончания.
    @Published private(set) var partialText: String = ""
    /// Раскрыты ли настройки в плашке.
    @Published var hudSettingsExpanded = false
    /// Держать плашку на экране вне диктовки — чтобы её можно было переставить
    /// и настроить, не начиная говорить.
    @Published private(set) var hudPinned = false
    /// Последняя ошибка постобработки — показывается на экране диктовки.
    @Published var lastProcessingError: String?

    private let mic = MicRecorder()
    private var buffer: [Float] = []
    private var hotKey: HotKey?
    /// Escape перехватывается только на время диктовки: глобально его занимать
    /// нельзя, это клавиша всей системы.
    private var escapeHotKey: HotKey?
    private var escapeGlobalMonitor: Any?
    private var escapeLocalMonitor: Any?

    /// Номер текущей диктовки. Нужен потому, что следующую можно начать, не
    /// дожидаясь, пока досчитается предыдущая: результат старой сессии обязан
    /// вставить свой текст, но не имеет права трогать состояние новой.
    private var sessionID = 0
    private var previewTask: Task<Void, Never>?
    private var previewCancellation = CancellationFlag()
    /// Дольше этого предпросмотр не считаем: перераспознавать минуту речи
    /// каждые полторы секунды — это занять процессор целиком без всякой пользы.
    private let previewLimitSeconds: TimeInterval = 25
    /// Сессии, отменённые Escape уже после запуска распознавания: их результат
    /// выбрасывается целиком.
    private var cancelledSessions: Set<Int> = []
    private var startedAt: Date?
    private var pressedAt: Date?
    private var timer: Timer?
    private var hud: DictationHUD?

    /// Больше двух минут одной репликой — это уже не диктовка, а встреча.
    private let maximumSeconds: TimeInterval = 120

    private unowned let settings: Settings
    private unowned let models: ModelStore

    private var historyFile: URL { Container.root.appendingPathComponent("dictation.json") }

    private var cancellables: Set<AnyCancellable> = []

    init(settings: Settings, models: ModelStore) {
        self.settings = settings
        self.models = models
        loadHistory()

        // Пока настройки раскрыты, панели нужно разрешить становиться активной:
        // иначе выпадающие меню внутри неё не открываются.
        $hudSettingsExpanded
            .sink { [weak self] expanded in
                self?.hud?.setAcceptsKey(expanded)
            }
            .store(in: &cancellables)
    }

    // MARK: - Плашка вне диктовки

    /// Показывает плашку с раскрытыми настройками, чтобы её можно было
    /// переставить и настроить.
    func showHUDForSetup() {
        hudPinned = true
        showHUD()
        hudSettingsExpanded = true
    }

    func hideHUDSetup() {
        hudPinned = false
        hudSettingsExpanded = false
        if phase == .idle { hideHUD() }
    }

    func resetHUDPosition() {
        hud?.resetPosition()
    }

    // MARK: - Горячая клавиша

    func activate() {
        guard settings.dictationEnabled else { deactivate(); return }
        registerHotKey()
    }

    func deactivate() {
        hotKey = nil
        hotKeyRegistered = false
    }

    func reloadHotKey() {
        hotKey = nil
        hotKeyRegistered = false
        guard settings.dictationEnabled else { return }
        registerHotKey()
    }

    private func registerHotKey() {
        hotKey = HotKey(
            combo: settings.dictationHotKey,
            onPressed: { [weak self] in Task { @MainActor in self?.handlePress() } },
            onReleased: { [weak self] in Task { @MainActor in self?.handleRelease() } }
        )
        hotKeyRegistered = hotKey != nil
        if !hotKeyRegistered {
            Log.warn("Сочетание \(settings.dictationHotKey.displayString) занято другим приложением")
        }
    }

    private func handlePress() {
        switch settings.dictationMode {
        case .toggle:
            if phase == .listening { finish() } else { begin() }
        case .pushToTalk:
            if isLatched && phase == .listening {
                // Второе нажатие в зафиксированном режиме завершает диктовку.
                isLatched = false
                finish()
                return
            }
            pressedAt = Date()
            begin()
        }
    }

    private func handleRelease() {
        guard settings.dictationMode == .pushToTalk, phase == .listening else { return }
        let held = pressedAt.map { Date().timeIntervalSince($0) } ?? 0
        pressedAt = nil
        // Короткий тап удобно трактовать как «включить и говорить без зажима».
        if held < 0.4 {
            isLatched = true
            return
        }
        finish()
    }

    // MARK: - Цикл диктовки

    func begin() {
        // Единственное состояние, из которого начинать нельзя, — уже идущая
        // запись. Из показа результата и даже из «распознаю» стартуем сразу:
        // ждать, пока сойдёт плашка, — потерянные секунды. Распознавание
        // предыдущей фразы при этом продолжается в фоне и вставит свой текст,
        // когда закончит.
        guard phase != .listening else { return }

        guard let modelID = resolveModelID(), let spec = ModelCatalog.spec(id: modelID) else {
            present(.failed("Не скачана ни одна модель. Откройте «Модели» и загрузите Small · Q5."))
            return
        }
        guard TextInjector.isTrusted else {
            present(.failed("Нужен доступ в «Универсальный доступ», иначе текст некуда вставить."))
            TextInjector.requestTrust()
            return
        }

        targetApp = TextInjector.frontmostAppName()
        buffer.removeAll(keepingCapacity: true)
        buffer.reserveCapacity(Int(AudioFormat.sampleRate * 15))

        mic.onSamples = { [weak self] samples in
            Task { @MainActor in self?.collect(samples) }
        }
        mic.onLevel = { [weak self] value in
            Task { @MainActor in self?.pushLevel(value) }
        }

        do {
            let device = settings.inputDeviceID == 0 ? nil : settings.inputDeviceID
            try mic.start(deviceID: device, avoidBluetooth: settings.avoidBluetoothMic)
        } catch {
            present(.failed(error.localizedDescription))
            return
        }

        sessionID += 1
        startedAt = Date()
        elapsed = 0
        partialText = ""
        phase = .listening
        // Настройки в плашке закрываем: раскрытая панель может забрать фокус,
        // и текст уйдёт в неё вместо целевого приложения.
        hudSettingsExpanded = false
        registerEscape()
        startPreview(spec: spec)
        showHUD()
        startTimer()
        if settings.dictationSound { NSSound(named: "Pop")?.play() }

        // Модель греется параллельно с речью — к моменту отпускания она уже в памяти.
        Engines.engine(for: spec, role: .dictation)
            .preload(settings.dictationOptions(modelURL: models.fileURL(for: spec)))
    }

    func finish() {
        guard phase == .listening else { return }
        stopTimer()
        mic.stop()
        releaseEscape()
        stopPreview()
        isLatched = false

        let samples = buffer
        buffer.removeAll(keepingCapacity: false)
        let spokenSeconds = Double(samples.count) / AudioFormat.sampleRate

        guard spokenSeconds > 0.3, let modelID = resolveModelID(),
              let spec = ModelCatalog.spec(id: modelID) else {
            present(.failed("Слишком коротко — ничего не услышал."))
            return
        }

        phase = .recognizing
        if settings.dictationSound { NSSound(named: "Tink")?.play() }

        let options = settings.dictationOptions(modelURL: models.fileURL(for: spec))
        let engine = Engines.engine(for: spec, role: .dictation)
        let mode = settings.insertionMode
        let keepInClipboard = settings.keepTextInClipboard
        let trimPeriod = settings.trimTrailingPeriod
        let app = targetApp
        let started = Date()
        let session = sessionID

        Task.detached(priority: .userInitiated) {
            do {
                let segments = try engine.transcribe(samples: samples, options: options)
                let raw = segments.map(\.text).joined(separator: " ")
                let text = Self.clean(raw, trimTrailingPeriod: trimPeriod)
                let took = Date().timeIntervalSince(started)

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.deliver(
                        text: text, session: session, mode: mode,
                        keepInClipboard: keepInClipboard, app: app,
                        spokenSeconds: spokenSeconds, recognitionSeconds: took
                    )
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.finishWithFailure(error.localizedDescription, session: session)
                }
            }
        }
    }

    /// Доставляет результат распознавания.
    ///
    /// Разделение на «вставить» и «показать» существенно: пока считалась эта
    /// фраза, пользователь мог начать следующую. Тогда текст всё равно нужно
    /// вставить, но плашку переключать нельзя — она занята новой записью.
    private func deliver(text: String, session: Int, mode: InsertionMode,
                         keepInClipboard: Bool, app: String?,
                         spokenSeconds: TimeInterval,
                         recognitionSeconds: TimeInterval) {
        if cancelledSessions.remove(session) != nil {
            Log.info("Результат отменённой диктовки отброшен")
            return
        }
        guard !text.isEmpty else {
            finishWithFailure("Речь не распознана. Попробуйте говорить ближе к микрофону.", session: session)
            return
        }

        // Обработка языковой моделью — единственный шаг, который может занять
        // секунды и уйти в сеть, поэтому у него своя фаза. Проваливается он
        // безопасно: при любой ошибке вставляется исходный распознанный текст.
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if PostProcessor.prompt(for: bundleID, settings: settings) != nil {
            if session == sessionID {
                phase = .processing
                showHUD()
            }
            let settings = self.settings
            Task { @MainActor [weak self] in
                var finalText = text
                do {
                    finalText = try await PostProcessor.process(text, bundleID: bundleID, settings: settings)
                } catch {
                    Log.warn("Постобработка не удалась, вставляю как есть: \(error.localizedDescription)")
                    self?.lastProcessingError = error.localizedDescription
                }
                self?.finishDelivery(text: finalText, session: session, mode: mode,
                                     keepInClipboard: keepInClipboard, app: app,
                                     spokenSeconds: spokenSeconds,
                                     recognitionSeconds: recognitionSeconds)
            }
            return
        }

        finishDelivery(text: text, session: session, mode: mode,
                       keepInClipboard: keepInClipboard, app: app,
                       spokenSeconds: spokenSeconds, recognitionSeconds: recognitionSeconds)
    }

    /// Вставка и показ результата — общий финал для обоих путей.
    private func finishDelivery(text: String, session: Int, mode: InsertionMode,
                                keepInClipboard: Bool, app: String?,
                                spokenSeconds: TimeInterval,
                                recognitionSeconds: TimeInterval) {
        // Пока шла обработка, диктовку могли отменить.
        if cancelledSessions.remove(session) != nil {
            Log.info("Результат отменённой диктовки отброшен")
            return
        }

        let inserted = TextInjector.insert(text, mode: mode, keepInClipboard: keepInClipboard)
        record(DictationEntry(
            text: text, createdAt: Date(), targetApp: app,
            seconds: spokenSeconds, recognitionSeconds: recognitionSeconds
        ))

        // Вставить не удалось — текст обязан остаться хотя бы в буфере.
        if !inserted { TextInjector.copyToClipboard(text) }
        // Плашку трогаем только если эта диктовка всё ещё последняя.
        guard session == sessionID else { return }
        partialText = ""
        present(inserted ? .inserted(text) : .copiedOnly(text))
    }

    private func finishWithFailure(_ message: String, session: Int) {
        if cancelledSessions.remove(session) != nil { return }
        guard session == sessionID else { return }
        present(.failed(message))
    }

    /// Отмена по Escape: запись прекращается, распознавание не запускается,
    /// в активное приложение ничего не вставляется.
    func cancel(source: String = "вручную") {
        guard phase != .idle else { return }
        stopTimer()
        mic.stop()
        releaseEscape()
        stopPreview()
        partialText = ""
        buffer.removeAll(keepingCapacity: false)
        isLatched = false
        // Если распознавание уже ушло в работу, его результат нужно выбросить:
        // Escape означает «ничего не вставлять».
        cancelledSessions.insert(sessionID)
        if cancelledSessions.count > 32 { cancelledSessions.removeFirst() }
        sessionID += 1
        if settings.dictationSound { NSSound(named: "Bottle")?.play() }
        phase = .idle
        hideHUD()
        Log.info("Диктовка отменена (\(source))")
    }

    /// Escape ловится двумя способами сразу, и это не перестраховка ради красоты.
    ///
    /// Carbon-хоткей без модификаторов регистрируется успешно, но события по нему
    /// система приложению не доставляет — проверено на практике. Поэтому основной
    /// путь — монитор событий NSEvent: он требует доверия в «Универсальном
    /// доступе», а оно у диктовки и так есть, иначе текст было бы некуда вставлять.
    /// Локальный монитор нужен отдельно: когда активно наше собственное окно,
    /// глобальный не срабатывает.
    // MARK: - Предпросмотр по ходу речи

    /// Периодически перераспознаёт накопленный буфер, чтобы показать черновик.
    ///
    /// Настоящего потокового распознавания у whisper нет: модель работает по
    /// окну целиком. Поэтому черновик получается повторным проходом по всему
    /// буферу — честно говоря, расточительно, но это единственный способ
    /// показать текст до окончания фразы. Отсюда и ограничение по длине,
    /// и возможность выключить в настройках.
    private func startPreview(spec: ModelSpec) {
        guard settings.livePreview else { return }
        stopPreview()

        let options = settings.dictationOptions(modelURL: models.fileURL(for: spec))
        let engine = Engines.engine(for: spec, role: .dictation)
        let flag = CancellationFlag()
        previewCancellation = flag
        let session = sessionID

        previewTask = Task { @MainActor [weak self] in
            // Первую догадку раньше секунды речи строить бессмысленно.
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            while !Task.isCancelled, let self, self.phase == .listening, self.sessionID == session {
                let snapshot = self.buffer
                let seconds = Double(snapshot.count) / AudioFormat.sampleRate
                guard seconds > 0.7 else {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    continue
                }
                guard seconds <= self.previewLimitSeconds else {
                    Log.info("Предпросмотр остановлен: речь дольше \(Int(self.previewLimitSeconds)) с")
                    return
                }

                let started = Date()
                let text = await Task.detached(priority: .utility) { () -> String? in
                    guard let segments = try? engine.transcribe(
                        samples: snapshot, options: options, timeOffset: 0,
                        onProgress: nil, onSegment: nil, isCancelled: { flag.isSet }
                    ) else { return nil }
                    return segments.map(\.text).joined(separator: " ")
                }.value

                guard !Task.isCancelled, self.phase == .listening, self.sessionID == session else { return }
                if let text {
                    let cleaned = Self.clean(text, trimTrailingPeriod: false)
                    if !cleaned.isEmpty { self.partialText = cleaned }
                }

                // Пауза соразмерна тому, сколько занял сам проход: на длинной
                // фразе догадки обновляются реже, зато машина не задыхается.
                let took = Date().timeIntervalSince(started)
                let pause = max(0.9, min(3.0, took * 1.3))
                try? await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000))
            }
        }
    }

    private func stopPreview() {
        previewCancellation.set()
        previewTask?.cancel()
        previewTask = nil
    }

    private func registerEscape() {
        if escapeHotKey == nil {
            escapeHotKey = HotKey(
                combo: HotKeyCombo(keyCode: 53, modifiers: 0),
                onPressed: { [weak self] in Task { @MainActor in self?.cancel(source: "хоткей") } },
                onReleased: {}
            )
        }
        if escapeGlobalMonitor == nil {
            escapeGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53 else { return }
                Task { @MainActor in self?.cancel(source: "глобальный монитор") }
            }
        }
        if escapeLocalMonitor == nil {
            escapeLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53 else { return event }
                Task { @MainActor in self?.cancel(source: "локальный монитор") }
                return nil
            }
        }
        if escapeGlobalMonitor == nil && escapeHotKey == nil {
            Log.warn("Escape перехватить не удалось: нет ни хоткея, ни монитора событий")
        }
    }

    private func releaseEscape() {
        escapeHotKey = nil
        if let monitor = escapeGlobalMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = escapeLocalMonitor { NSEvent.removeMonitor(monitor) }
        escapeGlobalMonitor = nil
        escapeLocalMonitor = nil
    }

    // MARK: - Внутреннее

    private func collect(_ samples: [Float]) {
        buffer.append(contentsOf: samples)
        if Double(buffer.count) / AudioFormat.sampleRate > maximumSeconds {
            Log.info("Диктовка достигла лимита в \(Int(maximumSeconds)) с — завершаю")
            finish()
        }
    }

    private func pushLevel(_ value: Float) {
        level = value
        waveform.removeFirst()
        waveform.append(value)
    }

    private func present(_ next: Phase) {
        phase = next
        showHUD()
        if settings.dictationSound {
            switch next {
            case .inserted, .copiedOnly: NSSound(named: "Morse")?.play()
            case .failed: NSSound(named: "Funk")?.play()
            default: break
            }
        }
        let delay: TimeInterval
        switch next {
        case .failed: delay = 3.0
        case .copiedOnly: delay = 2.6
        default: delay = 0.9
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.phase == next else { return }
            self.phase = .idle
            self.hideHUD()
        }
    }

    private func startTimer() {
        stopTimer()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func showHUD() {
        if hud == nil {
            hud = DictationHUD(controller: self, settings: settings, models: models)
        }
        hud?.show()
        hud?.setAcceptsKey(hudSettingsExpanded)
    }

    private func hideHUD() {
        // Закреплённую плашку не убираем: пользователь оставил её нарочно.
        guard !hudPinned else { return }
        hud?.hide()
    }

    private func resolveModelID() -> String? {
        if models.isInstalled(settings.dictationModelID) { return settings.dictationModelID }
        // Для диктовки важнее скорость, поэтому берём самую лёгкую из установленных.
        return models.installedSpeechModels
            .sorted { $0.sizeBytes < $1.sizeBytes }
            .first?.id
    }

    /// Убирает артефакты whisper: пометки вроде «[музыка]», двойные пробелы,
    /// финальную точку — если так удобнее пользователю.
    nonisolated static func clean(_ text: String, trimTrailingPeriod: Bool) -> String {
        var result = text
        for pattern in ["\\[[^\\]]*\\]", "\\([^\\)]*\\)", "\\*[^\\*]*\\*"] {
            result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        result = result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimTrailingPeriod, result.hasSuffix(".") { result.removeLast() }
        return result
    }

    // MARK: - История

    private func record(_ entry: DictationEntry) {
        history.insert(entry, at: 0)
        if history.count > 100 { history.removeLast(history.count - 100) }
        saveHistory()
    }

    func clearHistory() {
        history = []
        try? FileManager.default.removeItem(at: historyFile)
    }

    func copy(_ entry: DictationEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
    }

    private func loadHistory() {
        guard let data = try? Data(contentsOf: historyFile),
              let decoded = try? JSONDecoder.golos.decode([DictationEntry].self, from: data)
        else { return }
        history = decoded
    }

    private func saveHistory() {
        guard let data = try? JSONEncoder.golos.encode(history) else { return }
        try? data.write(to: historyFile, options: .atomic)
    }
}
