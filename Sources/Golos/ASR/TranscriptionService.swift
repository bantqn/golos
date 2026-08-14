import Foundation
import Combine

/// Флаг отмены, который читает движок из своего рабочего потока.
/// Обычное свойство @MainActor тут не годится: whisper дёргает abort_callback
/// не на главном потоке, и обращение к актору оттуда уронило бы процесс.
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock(); defer { lock.unlock() }
        value = true
    }
}

/// Очередь расшифровок. Одновременно выполняется одна задача:
/// whisper и так забирает все ядра и GPU, параллелить смысла нет.
///
/// Аудио читается окнами через `AudioWindowReader`, поэтому расход памяти
/// не зависит от длины записи: что двадцать минут, что четыре часа — в памяти
/// всегда лежит одно окно. Модель выгружается, как только очередь опустела.
@MainActor
final class TranscriptionService: ObservableObject {

    struct Job: Identifiable, Equatable {
        /// Не id записи: у дневной записи заданий много, по одному на отрезок.
        let id = UUID()
        let recordingID: UUID
        var title: String
        /// Что именно расшифровываем.
        var scope: Scope = .whole

        /// Целиком — обычная запись; отрезками — дневная, которая
        /// расшифровывается по ходу дня и дописывается к общему тексту.
        enum Scope: Equatable {
            case whole
            case segments([Recording.Track])
        }
        var progress: Double = 0
        var stage: String = "Подготовка"
        var startedAt = Date()
        /// Во сколько раз быстрее реального времени идёт распознавание.
        var realtimeFactor: Double = 0
    }

    @Published private(set) var current: Job?
    @Published private(set) var pending: [Job] = []
    /// Реплики появляются по мере распознавания — лента заполняется на глазах.
    @Published private(set) var liveSegments: [Segment] = []
    @Published var lastError: String?

    private var cancellation = CancellationFlag()
    private var worker: Task<Void, Never>?

    private unowned let settings: Settings
    private unowned let library: LibraryStore
    private unowned let models: ModelStore

    init(settings: Settings, library: LibraryStore, models: ModelStore) {
        self.settings = settings
        self.library = library
        self.models = models
    }

    var isRunning: Bool { current != nil }

    var queueCount: Int { pending.count + (current == nil ? 0 : 1) }

    // MARK: - Очередь

    func enqueue(_ recording: Recording) {
        guard current?.recordingID != recording.id,
              !pending.contains(where: { $0.recordingID == recording.id && $0.scope == .whole })
        else { return }
        pending.append(Job(recordingID: recording.id, title: recording.title))
        library.updateStatus(recording.id, .queued)
        drain()
    }

    /// Ставит в очередь отрезок дневной записи. Результат дописывается
    /// к уже накопленной расшифровке, а не заменяет её.
    func enqueueSegments(recordingID: UUID, tracks: [Recording.Track], title: String) {
        guard !tracks.isEmpty else { return }
        pending.append(Job(recordingID: recordingID, title: title, scope: .segments(tracks)))
        drain()
    }

    func cancelCurrent() {
        cancellation.set()
        worker?.cancel()
    }

    func remove(from queue: UUID) {
        pending.removeAll { $0.recordingID == queue }
        library.updateStatus(queue, .none)
    }

    private func drain() {
        guard current == nil else { return }
        guard !pending.isEmpty else {
            // Очередь пуста — держать модель в памяти больше не нужно.
            Engines.unloadAll()
            liveSegments = []
            MemoryGuard.releaseFreedPages()
            return
        }
        let job = pending.removeFirst()
        guard let recording = library.recordings.first(where: { $0.id == job.recordingID }) else {
            drain()
            return
        }
        current = job
        liveSegments = []
        cancellation = CancellationFlag()
        worker = Task { await run(recording, scope: job.scope) }
    }

    // MARK: - Выполнение

    private func run(_ recording: Recording, scope: Job.Scope) async {
        let isIncremental = scope != .whole
        defer {
            current = nil
            worker = nil
            drain()
        }

        guard let modelID = resolveModelID(), let spec = ModelCatalog.spec(id: modelID) else {
            let message = "Модель для расшифровки не скачана. Откройте раздел «Модели» и загрузите хотя бы одну."
            lastError = message
            library.updateStatus(recording.id, .failed(message))
            return
        }
        let modelURL = models.fileURL(for: spec)
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            let message = "Файл модели «\(spec.title)» не найден — скачайте её заново."
            lastError = message
            library.updateStatus(recording.id, .failed(message))
            return
        }

        // Движок выбирается по модели: whisper и Parakeet — разные C-API.
        let engine = Engines.engine(for: spec, role: .bulk)

        // Другие движки могли оставить свои модели в памяти. Освобождаем место
        // и ждём, иначе проверка бюджета ниже увидит ещё не отпущенные гигабайты.
        await Engines.freeMemory(excluding: engine)

        if let rejection = MemoryGuard.rejection(for: spec, settings: settings) {
            lastError = rejection
            library.updateStatus(recording.id, .failed(rejection))
            return
        }

        let started = Date()
        var allSegments: [Segment] = []
        let tracks: [Recording.Track]
        switch scope {
        case .whole: tracks = transcribableTracks(of: recording)
        case .segments(let list): tracks = list
        }
        guard !tracks.isEmpty else {
            if !isIncremental {
                library.updateStatus(recording.id, .failed("У записи нет звуковых дорожек."))
            }
            return
        }

        var options = settings.transcriptionOptions(modelURL: modelURL, vadModelURL: models.vadModelURL)

        // Ширина луча множит число декодеров, а с ними и KV-кэши. Если памяти
        // в обрез, лучше сузить луч, чем уйти в своп. У Parakeet лучевого
        // поиска нет вовсе, поэтому параметр к нему не применяется.
        if spec.engine == .whisper {
            let clamped = MemoryGuard.clampBeamSize(options.beamSize, model: spec, settings: settings)
            if clamped < options.beamSize {
                Log.warn("Ширина луча снижена с \(options.beamSize) до \(clamped): мало свободной памяти")
            }
            options.beamSize = clamped
        }

        let windowSeconds = MemoryGuard.windowSeconds(settings)
        let beamNote = spec.engine == .whisper ? ", луч \(options.beamSize)" : ""
        Log.info("Расшифровка «\(recording.title)»: \(spec.id)\(beamNote), окно \(windowSeconds) с")

        for (trackIndex, track) in tracks.enumerated() {
            if cancellation.isSet { break }

            // У дневной записи дорожки всегда подписаны: смысл режима — знать,
            // где говорили вы, а где собеседник.
            let speaker: Segment.Speaker = (tracks.count > 1 || recording.isContinuous)
                ? track.kind.speaker : .unknown
            let base = Double(trackIndex) / Double(tracks.count)
            let span = 1.0 / Double(tracks.count)

            updateStage(track.kind == .mic ? "Дорожка микрофона" :
                        track.kind == .system ? "Звук системы" : "Распознаю речь")

            do {
                let segments = try await transcribeTrack(
                    engine: engine,
                    url: recording.url(for: track),
                    options: options,
                    windowSeconds: windowSeconds,
                    baseOffset: track.startOffset,
                    speaker: speaker,
                    onProgress: { [weak self] fraction in
                        Task { @MainActor in
                            guard let self else { return }
                            let overall = base + fraction * span
                            self.updateProgress(overall, audioSeconds: recording.duration, since: started)
                            if !isIncremental {
                                self.library.updateStatus(recording.id, .running(progress: overall))
                            }
                        }
                    }
                )
                // Разделяем по голосам всё, кроме дорожки микрофона: там
                // говорящий известен заранее — это владелец компьютера.
                if settings.diarizationEnabled, track.kind != .mic, !segments.isEmpty {
                    updateStage("Различаю голоса")
                    let divided = await diarize(
                        segments: segments, recording: recording, track: track,
                        engine: engine, options: options, baseOffset: track.startOffset
                    )
                    allSegments.append(contentsOf: divided)
                } else {
                    allSegments.append(contentsOf: segments)
                }
            } catch {
                let message = error.localizedDescription
                if !isIncremental { library.updateStatus(recording.id, .failed(message)) }
                lastError = message
                return
            }
        }

        if cancellation.isSet {
            if !isIncremental { library.updateStatus(recording.id, .none) }
            return
        }

        allSegments.sort { $0.start < $1.start }

        // голос собеседника из динамиков попадает и в микрофон — одна фраза
        // оказывается в расшифровке дважды. Убираем дубль, если обе дорожки
        // писались одновременно.
        let hasBothTracks = tracks.contains { $0.kind == .mic } && tracks.contains { $0.kind == .system }
        if settings.suppressEcho && hasBothTracks {
            let result = EchoFilter.deduplicate(
                allSegments,
                priority: settings.echoPriority,
                similarityThreshold: settings.echoSimilarity
            )
            if result.removed > 0 {
                Log.info("Отсечено эхо: \(result.removed) дублирующихся реплик")
            }
            allSegments = result.kept
        }

        // Отрезок дневной записи дописывается к общему тексту.
        if isIncremental {
            library.appendSegments(
                allSegments, to: recording.id,
                language: settings.language, modelID: modelID,
                processingSeconds: Date().timeIntervalSince(started)
            )
            Log.info("Отрезок дневной записи расшифрован: \(allSegments.count) реплик")
            return
        }

        let transcript = Transcript(
            recordingID: recording.id,
            segments: allSegments,
            language: settings.language,
            modelID: modelID,
            createdAt: Date(),
            processingSeconds: Date().timeIntervalSince(started)
        )
        library.saveTranscript(transcript)

        if !settings.keepAudioAfterTranscription {
            library.discardAudio(for: recording)
        }
        let factor = recording.duration / max(0.1, transcript.processingSeconds)
        Log.info("Расшифровка готова: \(allSegments.count) реплик, ×\(String(format: "%.1f", factor)) от реального времени")
    }

    /// Читает дорожку окнами и распознаёт каждое окно по отдельности.
    /// Всё тяжёлое происходит в отдельной задаче, память ограничена одним окном.
    private func transcribeTrack(
        engine: SpeechEngine,
        url: URL,
        options: WhisperOptions,
        windowSeconds: Int,
        baseOffset: TimeInterval,
        speaker: Segment.Speaker,
        onProgress: @escaping (Double) -> Void
    ) async throws -> [Segment] {

        let flag = cancellation

        return try await Task.detached(priority: .userInitiated) { [weak self] () throws -> [Segment] in
            let reader = try AudioWindowReader(url: url, windowSeconds: windowSeconds)
            defer { reader.cancel() }

            var result: [Segment] = []
            let totalSeconds = reader.duration

            while let window = try reader.next() {
                if flag.isSet { break }

                // Тишину не отдаём движку вовсе: на дорожке микрофона её бывает
                // большая часть записи, а модель на ней всё равно тратит время.
                guard !Self.isSilent(window.samples) else {
                    onProgress(Self.fraction(offset: window.offset, of: totalSeconds))
                    continue
                }

                let windowSpan = Double(window.samples.count) / AudioFormat.sampleRate
                let windowStart = Self.fraction(offset: window.offset, of: totalSeconds)
                let windowEnd = Self.fraction(offset: window.offset + windowSpan, of: totalSeconds)

                do {
                    let segments = try engine.transcribe(
                        samples: window.samples,
                        options: options,
                        timeOffset: window.offset + baseOffset,
                        onProgress: { inner in
                            onProgress(windowStart + inner * (windowEnd - windowStart))
                        },
                        onSegment: { segment in
                            guard segment.start >= window.dropBefore + baseOffset else { return }
                            var tagged = segment
                            tagged.speaker = speaker
                            Task { @MainActor in self?.appendLive(tagged) }
                        },
                        isCancelled: { flag.isSet }
                    )
                    for segment in segments where segment.start >= window.dropBefore + baseOffset {
                        var tagged = segment
                        tagged.speaker = speaker
                        result.append(tagged)
                    }
                } catch WhisperError.cancelled {
                    break
                }
                onProgress(windowEnd)
            }
            return result
        }.value
    }

    // MARK: - Разделение по голосам

    /// Расставляет говорящих и, если нужно, перенарезает реплики.
    ///
    /// Порядок такой: сначала по звуку строится шкала «кто когда говорит», потом
    /// каждая реплика распознавания сопоставляется с этой шкалой. Если реплика
    /// целиком попадает в один отрезок — просто подписываем. Если растянулась на
    /// несколько (а Parakeet умеет отдать девять минут одной репликой), то этот
    /// кусок перечитывается и распознаётся заново по частям, по одной на голос.
    private func diarize(segments: [Segment], recording: Recording, track: Recording.Track,
                         engine: SpeechEngine, options: WhisperOptions,
                         baseOffset: TimeInterval) async -> [Segment] {

        let url = recording.url(for: track)
        let diarizerOptions = Diarizer.Options(
            maxSpeakers: settings.maxSpeakers,
            threshold: 0.15,
            minPitchSeparation: settings.diarizationThreshold
        )
        let expected = recording.expectedSpeakers
        let flag = cancellation

        return await Task.detached(priority: .userInitiated) { () -> [Segment] in
            let turns = Diarizer.speakerTurns(
                audioURL: url, expectedSpeakers: expected, options: diarizerOptions)
            guard turns.count > 1 else {
                // Один голос или шкалу построить не удалось — оставляем как есть.
                return segments
            }

            // Parakeet отдаёт всю запись одной репликой, и её конец не имеет
            // отношения к содержимому: у девятиминутного файла он был 70 с, хотя
            // текст покрывал все девять минут. Если реплики покрывают заметно
            // меньше дорожки, их границам верить нельзя — тогда текст
            // собирается заново целиком по шкале голосов.
            let trackEnd = turns.last?.end ?? 0
            let covered = segments.reduce(0.0) { $0 + max(0, $1.end - $1.start) }
            if trackEnd > 0, covered < trackEnd * 0.7 {
                let rebuilt = Self.transcribeByTurns(
                    turns: turns, span: (start: 0, end: trackEnd), audioURL: url,
                    engine: engine, options: options, baseOffset: baseOffset, flag: flag)
                if rebuilt.isEmpty { return segments }
                Log.info("Реплики распознаны заново по шкале голосов: было \(segments.count), "
                         + "стало \(rebuilt.count) — границам исходных реплик верить нельзя "
                         + "(покрывали \(Int(covered)) с из \(Int(trackEnd)))")
                return rebuilt
            }

            var result: [Segment] = []
            for segment in segments {
                if flag.isSet { return segments }

                let local = (start: segment.start - baseOffset, end: segment.end - baseOffset)
                let covering = turns.compactMap { turn -> (Diarizer.Turn, TimeInterval)? in
                    let overlap = min(local.end, turn.end) - max(local.start, turn.start)
                    return overlap > 0 ? (turn, overlap) : nil
                }
                guard let dominant = covering.max(by: { $0.1 < $1.1 }) else {
                    result.append(segment)
                    continue
                }

                let length = max(0.01, local.end - local.start)
                let slices = Self.slices(covering: covering.map(\.0), within: local)

                // Реплика уверенно принадлежит одному говорящему.
                if dominant.1 / length >= 0.7 || slices.count < 2 {
                    var labelled = segment
                    labelled.speaker = .voice(dominant.0.voice)
                    result.append(labelled)
                    continue
                }

                // Реплика накрывает нескольких — перечитываем её по отрезкам.
                let pieces = Self.transcribe(
                    slices: slices, audioURL: url, engine: engine,
                    options: options, baseOffset: baseOffset, flag: flag)

                if pieces.isEmpty {
                    var labelled = segment
                    labelled.speaker = .voice(dominant.0.voice)
                    result.append(labelled)
                } else {
                    Log.info("Реплика на \(Int(length)) с перенарезана на \(pieces.count) по сменам голоса")
                    result.append(contentsOf: pieces)
                }
            }
            return result
        }.value
    }

    /// Куски, на которые режется одна реплика: по одному на смену голоса.
    ///
    /// Куски обязаны покрывать реплику целиком и без щелей. Отбрасывать слишком
    /// короткие нельзя: вместе с ними исчезли бы и слова, которые в них сказаны,
    /// — а расшифровка молча потеряла бы часть разговора. Поэтому короткий
    /// отрезок не выбрасывается, а прилепляется к предыдущему куску.
    private struct Slice {
        var start: TimeInterval
        var end: TimeInterval
        var voice: Int
    }

    /// Распознаёт заново весь промежуток, нарезав его по сменам голоса.
    private nonisolated static func transcribeByTurns(
        turns: [Diarizer.Turn], span: (start: TimeInterval, end: TimeInterval),
        audioURL: URL, engine: SpeechEngine, options: WhisperOptions,
        baseOffset: TimeInterval, flag: CancellationFlag
    ) -> [Segment] {
        let slices = slices(covering: turns, within: span)
        guard slices.count > 1 else { return [] }
        return transcribe(slices: slices, audioURL: audioURL, engine: engine,
                          options: options, baseOffset: baseOffset, flag: flag)
    }

    /// Распознаёт каждый кусок отдельно и подписывает его голосом.
    private nonisolated static func transcribe(
        slices: [Slice], audioURL: URL, engine: SpeechEngine, options: WhisperOptions,
        baseOffset: TimeInterval, flag: CancellationFlag
    ) -> [Segment] {
        var pieces: [Segment] = []
        for slice in slices {
            if flag.isSet { break }
            guard let samples = try? AudioLoader.samples(
                from: audioURL, start: slice.start, duration: slice.end - slice.start),
                  !samples.isEmpty
            else { continue }

            guard let sub = try? engine.transcribe(
                samples: samples, options: options,
                timeOffset: slice.start + baseOffset,
                onProgress: nil, onSegment: nil, isCancelled: { flag.isSet }
            ) else { continue }

            for piece in sub where !piece.text.isEmpty {
                var labelled = piece
                labelled.speaker = .voice(slice.voice)
                pieces.append(labelled)
            }
        }
        return pieces
    }

    private nonisolated static func slices(covering turns: [Diarizer.Turn],
                                           within local: (start: TimeInterval, end: TimeInterval),
                                           minimum: TimeInterval = 1.0) -> [Slice] {
        var slices: [Slice] = []
        for turn in turns.sorted(by: { $0.start < $1.start }) {
            let from = max(local.start, turn.start)
            let to = min(local.end, turn.end)
            guard to > from else { continue }

            if var last = slices.last, last.voice == turn.voice || to - from < minimum {
                // Тот же голос — продолжение куска; слишком короткий отрезок —
                // тоже, иначе речь из него пропадёт.
                last.end = to
                slices[slices.count - 1] = last
            } else {
                slices.append(Slice(start: from, end: to, voice: turn.voice))
            }
        }
        // Края подтягиваем к границам реплики: щелей быть не должно.
        if !slices.isEmpty {
            slices[0].start = local.start
            slices[slices.count - 1].end = local.end
        }
        return slices
    }

    // MARK: - Вспомогательное

    private nonisolated static func fraction(offset: TimeInterval, of total: TimeInterval) -> Double {
        guard total > 0 else { return 0 }
        return max(0, min(1, offset / total))
    }

    private func appendLive(_ segment: Segment) {
        liveSegments.append(segment)
        // Лента нужна только для «живого» отображения последних реплик:
        // всё остальное уже лежит в результате, держать это в памяти незачем.
        if liveSegments.count > 120 { liveSegments.removeFirst(liveSegments.count - 120) }
    }

    private func updateStage(_ stage: String) {
        current?.stage = stage
    }

    private func updateProgress(_ value: Double, audioSeconds: TimeInterval, since started: Date) {
        guard var job = current else { return }
        job.progress = max(0, min(1, value))
        let elapsed = Date().timeIntervalSince(started)
        if elapsed > 1, value > 0.02 {
            job.realtimeFactor = (audioSeconds * value) / elapsed
        }
        current = job
    }

    private func transcribableTracks(of recording: Recording) -> [Recording.Track] {
        let usable = recording.tracks.filter { track in
            FileManager.default.fileExists(atPath: recording.url(for: track).path)
        }
        // Если есть готовый микс, отдельные дорожки не нужны.
        if let mixed = usable.first(where: { $0.kind == .mixed }) { return [mixed] }
        return usable
    }

    private func resolveModelID() -> String? {
        if models.isInstalled(settings.transcriptionModelID) { return settings.transcriptionModelID }
        // Настроенной модели нет — берём лучшую из установленных, которая влезает в память.
        return models.installedSpeechModels
            .sorted { ($0.quality, $0.sizeBytes) > ($1.quality, $1.sizeBytes) }
            .first { MemoryGuard.fits($0.estimatedRAM, settings: settings) }?.id
            ?? models.installedSpeechModels.min { $0.sizeBytes < $1.sizeBytes }?.id
    }

    /// Дорожка считается пустой, если пик за всё окно ниже порога слышимости.
    private nonisolated static func isSilent(_ samples: [Float]) -> Bool {
        // Хватает выборочной проверки: шаг в 200 семплов на 16 кГц — это 80 раз в секунду.
        for index in stride(from: 0, to: samples.count, by: 200) {
            if abs(samples[index]) > 0.01 { return false }
        }
        return true
    }
}
