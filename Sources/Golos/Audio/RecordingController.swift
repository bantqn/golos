import Foundation
import Combine
import AppKit

/// Управляет сессией записи: две независимые дорожки (микрофон и звук системы),
/// уровни для визуализации и сборка готовой записи в библиотеку.
@MainActor
final class RecordingController: ObservableObject {

    enum State: Equatable {
        case idle
        case preparing
        case recording
        case paused
        case finishing
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var systemLevel: Float = 0
    /// Последние 96 значений уровня — для «живой» дорожки на экране.
    @Published private(set) var waveform: [Float] = Array(repeating: 0, count: 96)
    @Published var lastError: String?
    /// Какие источники реально пишутся сейчас.
    @Published private(set) var micActive = false
    @Published private(set) var systemActive = false

    private let mic = MicRecorder()
    private let system = SystemAudioRecorder()
    private var micWriter: WavWriter?
    private var systemWriter: WavWriter?

    private var recordingID: UUID?
    private var startedAt: Date?
    private var pausedDuration: TimeInterval = 0
    private var pauseStartedAt: Date?
    private(set) var source: Recording.Source = .microphone
    private var appHint: String?
    /// Программа, из-за которой началась запись. Нужна, чтобы понять, что
    /// закончился именно этот разговор, а не какой-то посторонний.
    private(set) var appBundleID: String?
    private var micDeviceName: String?

    /// Непрерывная (дневная) запись: пишется отрезками, чтобы каждый файл
    /// оставался вменяемого размера и его можно было расшифровать по ходу дня,
    /// не дожидаясь вечера.
    @Published private(set) var isContinuous = false
    private var segmentIndex = 0
    /// Сколько секунд уже записано в предыдущих отрезках.
    private var accumulatedSeconds: TimeInterval = 0
    private var dayStartedAt: Date?
    private var rolloverTimer: Timer?

    /// Готов очередной отрезок дневной записи — его можно расшифровывать.
    var onSegmentReady: ((UUID, [Recording.Track]) -> Void)?

    private var timer: Timer?
    private var levelThrottle = Date.distantPast
    private var pendingMicLevel: Float = 0
    private var pendingSystemLevel: Float = 0

    private unowned let settings: Settings
    private unowned let library: LibraryStore

    /// Запись завершена — здесь запускается автоматическая расшифровка.
    var onFinished: ((Recording) -> Void)?

    init(settings: Settings, library: LibraryStore) {
        self.settings = settings
        self.library = library

        system.onStreamStopped = { [weak self] error in
            guard let self else { return }
            self.systemActive = false
            self.lastError = "Захват системного звука прервался: \(error.localizedDescription)"
        }
    }

    var isBusy: Bool { state != .idle }

    // MARK: - Управление

    func start(source: Recording.Source = .microphone, appHint: String? = nil,
               appBundleID: String? = nil) async {
        guard state == .idle else { return }
        state = .preparing
        lastError = nil
        self.source = source
        self.appHint = appHint
        self.appBundleID = appBundleID

        let id = UUID()
        recordingID = id
        let directory = Container.recordingDirectory(for: id)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        micDeviceName = Self.currentMicName(settings.inputDeviceID)
        var startedAnything = false

        if settings.recordMicrophone {
            if await MicRecorder.requestPermission() {
                do {
                    let writer = try WavWriter(url: directory.appendingPathComponent("mic.wav"))
                    micWriter = writer
                    mic.onSamples = { [weak writer] samples in writer?.append(samples) }
                    mic.onLevel = { [weak self] level in self?.enqueueLevel(mic: level) }
                    let device = settings.inputDeviceID == 0 ? nil : settings.inputDeviceID
                    try mic.start(deviceID: device, avoidBluetooth: settings.avoidBluetoothMic)
                    // Устройство могли подменить (микрофон гарнитуры на встроенный),
                    // и в легенде должно стоять то, с которого писали на самом деле.
                    micDeviceName = mic.deviceName ?? micDeviceName
                    micActive = true
                    startedAnything = true
                } catch {
                    lastError = error.localizedDescription
                    micWriter?.finalizeFile()
                    micWriter = nil
                }
            } else {
                lastError = "Нет доступа к микрофону. Разрешите его в Системных настройках → Конфиденциальность."
            }
        }

        if settings.recordSystemAudio {
            do {
                let writer = try WavWriter(url: directory.appendingPathComponent("system.wav"))
                systemWriter = writer
                system.onSamples = { [weak writer] samples in writer?.append(samples) }
                system.onLevel = { [weak self] level in self?.enqueueLevel(system: level) }
                try await system.start()
                systemActive = true
                startedAnything = true
            } catch {
                // Отсутствие звука системы не должно ронять запись микрофона.
                let message = error.localizedDescription
                lastError = lastError.map { "\($0)\n\(message)" } ?? message
                systemWriter?.finalizeFile()
                systemWriter = nil
            }
        }

        guard startedAnything else {
            cleanupFailedStart(id: id)
            state = .idle
            if lastError == nil { lastError = "Не выбран ни один источник звука." }
            return
        }

        startedAt = Date()
        pausedDuration = 0
        elapsed = 0
        state = .recording
        startTimer()
        Log.info("Запись начата (микрофон: \(micActive), система: \(systemActive))")
    }

    // MARK: - Непрерывная запись

    func startContinuous() async {
        guard state == .idle else { return }
        state = .preparing
        lastError = nil
        source = .continuous
        appHint = nil
        appBundleID = nil
        isContinuous = true
        micDeviceName = Self.currentMicName(settings.inputDeviceID)
        segmentIndex = 0
        accumulatedSeconds = 0
        dayStartedAt = Date()

        let id = UUID()
        recordingID = id
        let directory = Container.recordingDirectory(for: id)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        guard await openSources(directory: directory) else {
            cleanupFailedStart(id: id)
            isContinuous = false
            state = .idle
            if lastError == nil { lastError = "Не выбран ни один источник звука." }
            return
        }

        // Запись появляется в библиотеке сразу: за ней интересно следить весь день.
        let recording = Recording(
            id: id,
            title: "Весь день · \(Fmt.date(Date()))",
            createdAt: Date(),
            duration: 0,
            source: .continuous,
            appHint: nil,
            tracks: [],
            transcriptStatus: .none,
            language: settings.language == "auto" ? nil : settings.language,
            modelID: nil
        )
        var dayRecording = recording
        dayRecording.micDeviceName = micDeviceName
        library.add(dayRecording)

        startedAt = Date()
        pausedDuration = 0
        elapsed = 0
        state = .recording
        startTimer()
        scheduleRollover()
        Log.info("Дневная запись начата, отрезки по \(settings.continuousSegmentMinutes) мин")
    }

    func stopContinuous() async {
        guard isContinuous else { return }
        rolloverTimer?.invalidate()
        rolloverTimer = nil

        state = .finishing
        stopTimer()
        mic.stop()
        await system.stop()

        closeSegment()

        if let id = recordingID {
            library.setDuration(accumulatedSeconds, for: id)
            if let recording = library.recording(id: id) {
                Log.info("Дневная запись завершена: \(Fmt.duration(accumulatedSeconds)), отрезков \(recording.tracks.count)")
                // Ни одного отрезка со звуком — держать пустую запись незачем.
                if recording.tracks.isEmpty { library.delete(recording) }
            }
        }

        isContinuous = false
        resetState()
    }

    private func scheduleRollover() {
        rolloverTimer?.invalidate()
        let interval = TimeInterval(max(1, settings.continuousSegmentMinutes) * 60)
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.rollover() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        rolloverTimer = timer
    }

    /// Закрывает текущий отрезок и открывает следующий, не прерывая записи.
    private func rollover() async {
        guard isContinuous, state == .recording, let id = recordingID else { return }

        // Наступил новый день — начинаем новую запись, чтобы «весь день»
        // означал именно день, а не бесконечную склейку.
        if let dayStartedAt, !Calendar.current.isDate(dayStartedAt, inSameDayAs: Date()) {
            await stopContinuous()
            await startContinuous()
            return
        }

        let ready = closeSegment()
        guard let directory = recordingID.map({ Container.recordingDirectory(for: $0) }) ?? nil
        else { return }

        segmentIndex += 1
        _ = await openSources(directory: directory)

        if !ready.isEmpty { onSegmentReady?(id, ready) }
    }

    /// Финализирует файлы текущего отрезка и добавляет их к записи.
    /// - Returns: добавленные дорожки.
    @discardableResult
    private func closeSegment() -> [Recording.Track] {
        var tracks: [Recording.Track] = []
        var segmentDuration: TimeInterval = 0

        for (writer, kind) in [(micWriter, Recording.Track.Kind.mic), (systemWriter, .system)] {
            guard let writer else { continue }
            writer.finalizeFile()
            if writer.frameCount > 0 {
                tracks.append(.init(kind: kind,
                                    fileName: writer.url.lastPathComponent,
                                    startOffset: accumulatedSeconds))
                segmentDuration = max(segmentDuration, writer.duration)
            } else {
                try? FileManager.default.removeItem(at: writer.url)
            }
        }
        micWriter = nil
        systemWriter = nil

        guard !tracks.isEmpty else { return [] }
        accumulatedSeconds += segmentDuration

        if let id = recordingID {
            library.appendTracks(tracks, to: id, duration: accumulatedSeconds)
        }
        return tracks
    }

    /// Общий для обоих режимов запуск источников звука.
    /// - Returns: удалось ли начать запись хотя бы с одного источника.
    private func openSources(directory: URL) async -> Bool {
        let suffix = isContinuous ? String(format: "-%04d", segmentIndex) : ""
        var started = false

        if settings.recordMicrophone {
            if await MicRecorder.requestPermission() {
                do {
                    let writer = try WavWriter(url: directory.appendingPathComponent("mic\(suffix).wav"))
                    micWriter = writer
                    mic.onSamples = { [weak writer] samples in writer?.append(samples) }
                    mic.onLevel = { [weak self] level in self?.enqueueLevel(mic: level) }
                    if !mic.isRunning {
                        let device = settings.inputDeviceID == 0 ? nil : settings.inputDeviceID
                        try mic.start(deviceID: device, avoidBluetooth: settings.avoidBluetoothMic)
                        micDeviceName = mic.deviceName ?? micDeviceName
                    }
                    micActive = true
                    started = true
                } catch {
                    lastError = error.localizedDescription
                    micWriter?.finalizeFile()
                    micWriter = nil
                }
            } else {
                lastError = "Нет доступа к микрофону. Разрешите его в Системных настройках → Конфиденциальность."
            }
        }

        if settings.recordSystemAudio {
            do {
                let writer = try WavWriter(url: directory.appendingPathComponent("system\(suffix).wav"))
                systemWriter = writer
                system.onSamples = { [weak writer] samples in writer?.append(samples) }
                system.onLevel = { [weak self] level in self?.enqueueLevel(system: level) }
                if !system.isRunning { try await system.start() }
                systemActive = true
                started = true
            } catch {
                let message = error.localizedDescription
                lastError = lastError.map { "\($0)\n\(message)" } ?? message
                systemWriter?.finalizeFile()
                systemWriter = nil
            }
        }
        return started
    }

    func pause() {
        guard state == .recording, !isContinuous else { return }
        mic.stop()
        Task { await system.stop() }
        pauseStartedAt = Date()
        state = .paused
        micLevel = 0
        systemLevel = 0
    }

    func resume() async {
        guard state == .paused else { return }
        if let pauseStartedAt {
            pausedDuration += Date().timeIntervalSince(pauseStartedAt)
        }
        pauseStartedAt = nil

        if micActive {
            let device = settings.inputDeviceID == 0 ? nil : settings.inputDeviceID
            try? mic.start(deviceID: device, avoidBluetooth: settings.avoidBluetoothMic)
        }
        if systemActive {
            try? await system.start()
        }
        state = .recording
    }

    @discardableResult
    func stop() async -> Recording? {
        if isContinuous {
            await stopContinuous()
            return nil
        }
        guard state == .recording || state == .paused else { return nil }
        state = .finishing
        stopTimer()

        mic.stop()
        await system.stop()

        guard let id = recordingID else { state = .idle; return nil }

        var tracks: [Recording.Track] = []
        var duration: TimeInterval = 0

        if let writer = micWriter {
            writer.finalizeFile()
            if writer.frameCount > 0 {
                tracks.append(.init(kind: .mic, fileName: "mic.wav"))
                duration = max(duration, writer.duration)
            } else {
                try? FileManager.default.removeItem(at: writer.url)
            }
        }
        if let writer = systemWriter {
            writer.finalizeFile()
            if writer.frameCount > 0 {
                tracks.append(.init(kind: .system, fileName: "system.wav"))
                duration = max(duration, writer.duration)
            } else {
                try? FileManager.default.removeItem(at: writer.url)
            }
        }
        micWriter = nil
        systemWriter = nil

        guard !tracks.isEmpty, duration > 0.4 else {
            try? FileManager.default.removeItem(at: Container.recordingDirectory(for: id))
            resetState()
            lastError = "Запись получилась пустой — звука не было."
            return nil
        }

        let recording = Recording(
            id: id,
            title: defaultTitle(),
            createdAt: startedAt ?? Date(),
            duration: duration,
            source: source,
            appHint: appHint,
            tracks: tracks,
            transcriptStatus: settings.autoTranscribeAfterRecording ? .queued : .none,
            language: settings.language == "auto" ? nil : settings.language,
            modelID: nil
        )
        var saved = recording
        saved.micDeviceName = micDeviceName
        library.add(saved)
        resetState()
        Log.info("Запись сохранена: \(Fmt.duration(duration)), дорожек: \(tracks.count)")
        onFinished?(saved)
        return saved
    }

    /// Отменяет запись и удаляет её файлы.
    func discard() async {
        guard state != .idle else { return }
        stopTimer()
        mic.stop()
        await system.stop()
        micWriter?.finalizeFile()
        systemWriter?.finalizeFile()
        micWriter = nil
        systemWriter = nil
        if let id = recordingID {
            try? FileManager.default.removeItem(at: Container.recordingDirectory(for: id))
        }
        resetState()
    }

    // MARK: - Импорт файла

    /// Копирует внешний файл в контейнер и добавляет его в библиотеку.
    /// Оригинал пользователя не трогается.
    ///
    /// `autoQueue: false` нужен, когда сразу после импорта у пользователя
    /// спрашивают про говорящих: запускать распознавание до ответа бессмысленно,
    /// его пришлось бы отменять и начинать заново.
    func importFile(at url: URL, autoQueue: Bool = true) async -> Recording? {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

        let id = UUID()
        let directory = Container.recordingDirectory(for: id)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent("original." + url.pathExtension.lowercased())
            try FileManager.default.copyItem(at: url, to: destination)

            let duration = await AudioLoader.duration(of: destination)
            guard duration > 0 else {
                try? FileManager.default.removeItem(at: directory)
                lastError = "В файле «\(url.lastPathComponent)» не найдено звука."
                return nil
            }

            let recording = Recording(
                id: id,
                title: url.deletingPathExtension().lastPathComponent,
                createdAt: Date(),
                duration: duration,
                source: .imported,
                appHint: nil,
                tracks: [.init(kind: .original, fileName: destination.lastPathComponent)],
                transcriptStatus: (autoQueue && settings.autoTranscribeAfterRecording) ? .queued : .none,
                language: settings.language == "auto" ? nil : settings.language,
                modelID: nil
            )
            library.add(recording)
            Log.info("Импортирован файл \(url.lastPathComponent) (\(Fmt.duration(duration)))")
            if autoQueue { onFinished?(recording) }
            return recording
        } catch {
            try? FileManager.default.removeItem(at: directory)
            lastError = "Не удалось импортировать файл: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Внутреннее

    /// Название устройства ввода — для легенды в расшифровке.
    private static func currentMicName(_ configuredID: UInt32) -> String? {
        let devices = AudioInputDevice.available()
        if configuredID != 0, let match = devices.first(where: { $0.id == configuredID }) {
            return match.name
        }
        return devices.first(where: \.isDefault)?.name ?? devices.first?.name
    }

    private func defaultTitle() -> String {
        let base: String
        switch source {
        case .meeting: base = appHint.map { "Встреча · \($0)" } ?? "Встреча"
        case .microphone: base = "Запись"
        case .imported: base = "Импорт"
        case .continuous: base = "Весь день"
        }
        return "\(base) · \(Fmt.relativeDate(startedAt ?? Date()))"
    }

    private func cleanupFailedStart(id: UUID) {
        micWriter?.finalizeFile()
        systemWriter?.finalizeFile()
        micWriter = nil
        systemWriter = nil
        try? FileManager.default.removeItem(at: Container.recordingDirectory(for: id))
        micActive = false
        systemActive = false
        recordingID = nil
    }

    private func resetState() {
        rolloverTimer?.invalidate()
        rolloverTimer = nil
        segmentIndex = 0
        accumulatedSeconds = 0
        dayStartedAt = nil
        state = .idle
        recordingID = nil
        startedAt = nil
        pausedDuration = 0
        pauseStartedAt = nil
        elapsed = 0
        micLevel = 0
        systemLevel = 0
        micActive = false
        systemActive = false
        waveform = Array(repeating: 0, count: 96)
    }

    /// Уровни приходят из аудиопотока сотни раз в секунду; в UI отдаём ~25 раз.
    private nonisolated func enqueueLevel(mic: Float? = nil, system: Float? = nil) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let mic { self.pendingMicLevel = mic }
            if let system { self.pendingSystemLevel = system }
            guard Date().timeIntervalSince(self.levelThrottle) > 0.04 else { return }
            self.levelThrottle = Date()
            self.micLevel = self.pendingMicLevel
            self.systemLevel = self.pendingSystemLevel
            var wave = self.waveform
            wave.removeFirst()
            wave.append(max(self.pendingMicLevel, self.pendingSystemLevel))
            self.waveform = wave
        }
    }

    private func startTimer() {
        stopTimer()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.startedAt, self.state == .recording else { return }
                self.elapsed = Date().timeIntervalSince(startedAt) - self.pausedDuration
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
