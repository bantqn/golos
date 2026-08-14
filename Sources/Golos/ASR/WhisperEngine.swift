import Foundation
import CWhisper

/// Один распознанный фрагмент речи.
struct Segment: Codable, Identifiable, Hashable {
    var id = UUID()
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    /// Кто говорит: определяется по дорожке (микрофон = я, система = собеседник).
    var speaker: Speaker = .unknown

    /// Кто говорит.
    ///
    /// `me` и `others` определяются по источнику звука — микрофон против системы.
    /// `voice` появляется после разделения по голосам внутри одной дорожки:
    /// в системной записи встречи участников бывает несколько.
    enum Speaker: Hashable {
        case me
        case others
        case unknown
        case voice(Int)

        var title: String {
            switch self {
            case .me: return "Я"
            case .others: return "Собеседник"
            case .unknown: return "Речь"
            case .voice(let index): return "голос \(index)"
            }
        }
    }
}

extension Segment.Speaker: Codable {

    /// Пишем строкой, читаем и строку, и объект: расшифровки, сохранённые до
    /// появления разделения по голосам, должны открываться как раньше.
    private static let voicePrefix = "voice:"

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "me": self = .me
        case "others": self = .others
        case "unknown": self = .unknown
        default:
            guard raw.hasPrefix(Self.voicePrefix),
                  let index = Int(raw.dropFirst(Self.voicePrefix.count))
            else {
                self = .unknown
                return
            }
            self = .voice(index)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .me: try container.encode("me")
        case .others: try container.encode("others")
        case .unknown: try container.encode("unknown")
        case .voice(let index): try container.encode("\(Self.voicePrefix)\(index)")
        }
    }
}

enum WhisperError: LocalizedError {
    case modelMissing(URL)
    case modelLoadFailed(URL)
    case inferenceFailed(Int32)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .modelMissing(let url):
            return "Файл модели не найден: \(url.lastPathComponent)"
        case .modelLoadFailed(let url):
            return "Не удалось загрузить модель \(url.lastPathComponent). Возможно, файл повреждён — скачайте его заново."
        case .inferenceFailed(let code):
            return "Движок распознавания вернул ошибку (код \(code))."
        case .cancelled:
            return "Распознавание отменено."
        }
    }
}

/// Настройки одного прогона распознавания.
struct WhisperOptions {
    var modelURL: URL
    /// Код языка ISO-639-1 либо `nil` для автоопределения.
    var language: String?
    var translateToEnglish: Bool = false
    var threads: Int = max(1, ProcessInfo.processInfo.activeProcessorCount - 2)
    /// 1 — жадный поиск (быстро), >1 — лучевой (точнее, но медленнее).
    var beamSize: Int = 1
    /// Сколько кандидатов сэмплировать при жадном поиске.
    /// whisper выделяет по полному KV-кэшу на каждого, поэтому по умолчанию один:
    /// пятёрка из стандартных параметров whisper тянула гигабайты на large-моделях.
    var bestOf: Int = 1
    var useGPU: Bool = true
    /// Подсказка для декодера: имена, термины, стиль пунктуации.
    var initialPrompt: String = ""
    /// Модель VAD (silero). Если задана — тишина пропускается, длинные записи идут заметно быстрее.
    var vadModelURL: URL?
    var maxSegmentCharacters: Int = 0
    /// Разбивать реплики по смене говорящего (только модели с суффиксом `-tdrz`).
    var enableSpeakerTurns: Bool = false
}

/// Обёртка над C-API whisper.cpp.
///
/// Контекст модели дорогой в загрузке, поэтому последний использованный
/// держится в памяти: диктовка подряд не платит за перезагрузку каждый раз.
/// Все вызовы сериализованы — whisper_context не потокобезопасен.
final class WhisperEngine: SpeechEngine, @unchecked Sendable {

    private let queue: DispatchQueue

    private var context: OpaquePointer?
    private var loadedKey: String?
    /// Модель выгружается, если ей давно не пользовались, — не держим гигабайты зря.
    private var lastUsed = Date()
    private var evictionTimer: DispatchSourceTimer?
    private let stateLock = NSLock()
    private var loadedModelName: String?

    private var idleUnload: TimeInterval = 60

    /// Сколько секунд простоя терпим, прежде чем выгрузить модель.
    /// Значение приходит из настроек; ноль означает «выгружать сразу после работы».
    var idleUnloadSeconds: TimeInterval {
        get {
            stateLock.lock(); defer { stateLock.unlock() }
            return idleUnload
        }
        set {
            stateLock.lock()
            idleUnload = max(0, newValue)
            stateLock.unlock()
        }
    }

    /// Имя модели, которая сейчас в памяти, — для интерфейса. Без блокировки очереди:
    /// её может занимать долгий расчёт, а UI обновляется каждую секунду.
    var loadedModel: String? {
        stateLock.lock(); defer { stateLock.unlock() }
        return loadedModelName
    }

    private func setLoadedModel(_ name: String?) {
        stateLock.lock()
        loadedModelName = name
        stateLock.unlock()
    }

    init(label: String) {
        queue = DispatchQueue(label: "ai.cybergusli.golos.whisper.\(label)", qos: .userInitiated)

        // Metal-ядра компилируются из исходника при первом запуске: в бандле лежит
        // ggml-metal.metal со встроенными заголовками. Путь передаётся через окружение
        // до первой инициализации GPU-бэкенда.
        if let resources = Bundle.main.resourceURL?.path,
           FileManager.default.fileExists(atPath: resources + "/ggml-metal.metal") {
            setenv("GGML_METAL_PATH_RESOURCES", resources, 1)
        }

        // ggml на уровне INFO печатает каждую скомпилированную GPU-функцию — это тысячи
        // строк на запуск. В журнал пускаем только предупреждения и ошибки.
        whisper_log_set({ level, message, _ in
            guard level.rawValue >= GGML_LOG_LEVEL_WARN.rawValue, let message else { return }
            let text = String(cString: message).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if level.rawValue >= GGML_LOG_LEVEL_ERROR.rawValue {
                Log.error("whisper: \(text)")
            } else {
                Log.warn("whisper: \(text)")
            }
        }, nil)
        startEvictionTimer()
    }

    // MARK: - Жизненный цикл модели

    private func key(for options: WhisperOptions) -> String {
        "\(options.modelURL.path)|gpu=\(options.useGPU)"
    }

    /// Загружает модель в память заранее, чтобы первая диктовка не ждала.
    func preload(_ options: WhisperOptions) {
        queue.async { [weak self] in
            _ = try? self?.ensureContext(options)
        }
    }

    private func ensureContext(_ options: WhisperOptions) throws -> OpaquePointer {
        dispatchPrecondition(condition: .onQueue(queue))
        lastUsed = Date()

        let wanted = key(for: options)
        if let context, loadedKey == wanted { return context }

        unloadLocked()

        guard FileManager.default.fileExists(atPath: options.modelURL.path) else {
            throw WhisperError.modelMissing(options.modelURL)
        }

        var params = whisper_context_default_params()
        params.use_gpu = options.useGPU
        params.flash_attn = options.useGPU

        let started = Date()
        guard let ctx = whisper_init_from_file_with_params(options.modelURL.path, params) else {
            throw WhisperError.modelLoadFailed(options.modelURL)
        }
        context = ctx
        loadedKey = wanted
        setLoadedModel(options.modelURL.deletingPathExtension().lastPathComponent)
        Log.info("Модель \(options.modelURL.lastPathComponent) загружена за \(String(format: "%.2f", Date().timeIntervalSince(started))) с (GPU: \(options.useGPU)), процесс занимает \(Fmt.bytes(MemoryGuard.footprintBytes))")
        return ctx
    }

    private func unloadLocked() {
        if let context {
            whisper_free(context)
            let name = loadedModelName ?? "модель"
            setLoadedModel(nil)
            Log.info("\(name) выгружена, процесс занимает \(Fmt.bytes(MemoryGuard.footprintBytes))")
        }
        context = nil
        loadedKey = nil
    }

    func unload() {
        queue.async { [weak self] in self?.unloadLocked() }
    }

    /// Выгружает модель и дожидается этого. Нужно перед загрузкой большой модели
    /// другим движком: два контекста в памяти одновременно — прямой путь в своп.
    func unloadAndWait() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.unloadLocked()
                continuation.resume()
            }
        }
    }

    /// Раз в десять секунд проверяем, не пора ли освободить память.
    /// Проверка идёт на очереди движка, поэтому во время расчёта она просто ждёт
    /// и не может выгрузить модель из-под работающего whisper_full.
    private func startEvictionTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            guard let self, self.context != nil else { return }
            if Date().timeIntervalSince(self.lastUsed) >= self.idleUnloadSeconds {
                self.unloadLocked()
            }
        }
        timer.resume()
        evictionTimer = timer
    }

    var isModelLoaded: Bool { loadedModel != nil }

    // MARK: - Распознавание

    /// Синхронно распознаёт массив семплов 16 кГц моно.
    /// - Parameters:
    ///   - timeOffset: сдвиг, который прибавляется к таймкодам (для кусочной обработки).
    ///   - onProgress: 0…1, вызывается из рабочего потока.
    ///   - onSegment: новый фрагмент по мере готовности — для «живой» ленты.
    ///   - isCancelled: опрашивается движком; вернёт `true` — расчёт прерывается.
    func transcribe(
        samples: [Float],
        options: WhisperOptions,
        timeOffset: TimeInterval = 0,
        onProgress: ((Double) -> Void)? = nil,
        onSegment: ((Segment) -> Void)? = nil,
        isCancelled: (() -> Bool)? = nil
    ) throws -> [Segment] {
        try queue.sync {
            let ctx = try ensureContext(options)
            defer { lastUsed = Date() }

            let strategy: whisper_sampling_strategy =
                options.beamSize > 1 ? WHISPER_SAMPLING_BEAM_SEARCH : WHISPER_SAMPLING_GREEDY
            var params = whisper_full_default_params(strategy)

            params.n_threads = Int32(options.threads)
            params.translate = options.translateToEnglish
            params.no_context = true
            params.print_progress = false
            params.print_realtime = false
            params.print_timestamps = false
            params.print_special = false
            params.suppress_blank = true
            params.single_segment = false
            params.tdrz_enable = options.enableSpeakerTurns
            params.max_len = Int32(options.maxSegmentCharacters)
            if options.maxSegmentCharacters > 0 { params.split_on_word = true }
            // Число декодеров = max(best_of, beam_size), и каждый декодер — это
            // отдельный KV-кэш. Держим ровно столько, сколько попросили.
            params.greedy.best_of = Int32(max(1, options.bestOf))
            params.beam_search.beam_size = Int32(max(1, options.beamSize))

            // Строки нужно держать живыми на всё время вызова whisper_full.
            let languageBuffer = options.language.map { strdup($0) } ?? strdup("auto")
            let promptBuffer = options.initialPrompt.isEmpty ? nil : strdup(options.initialPrompt)
            let vadBuffer = options.vadModelURL.map { strdup($0.path) }
            defer {
                free(languageBuffer)
                if let promptBuffer { free(promptBuffer) }
                if let vadBuffer { free(vadBuffer) }
            }
            params.language = UnsafePointer(languageBuffer)
            params.detect_language = false
            if let promptBuffer { params.initial_prompt = UnsafePointer(promptBuffer) }
            if let vadBuffer {
                params.vad = true
                params.vad_model_path = UnsafePointer(vadBuffer)
            }

            let box = CallbackBox(
                onProgress: onProgress,
                onSegment: onSegment,
                isCancelled: isCancelled,
                timeOffset: timeOffset
            )
            let boxPointer = Unmanaged.passUnretained(box).toOpaque()

            params.progress_callback = { _, _, progress, userData in
                guard let userData else { return }
                let box = Unmanaged<CallbackBox>.fromOpaque(userData).takeUnretainedValue()
                box.onProgress?(Double(progress) / 100.0)
            }
            params.progress_callback_user_data = boxPointer

            params.new_segment_callback = { ctx, _, newCount, userData in
                guard let userData, let ctx, let box = Optional(
                    Unmanaged<CallbackBox>.fromOpaque(userData).takeUnretainedValue()
                ), box.onSegment != nil else { return }
                let total = whisper_full_n_segments(ctx)
                for i in (total - newCount)..<total {
                    if let segment = WhisperEngine.makeSegment(ctx: ctx, index: i, offset: box.timeOffset) {
                        box.onSegment?(segment)
                    }
                }
            }
            params.new_segment_callback_user_data = boxPointer

            params.abort_callback = { userData in
                guard let userData else { return false }
                let box = Unmanaged<CallbackBox>.fromOpaque(userData).takeUnretainedValue()
                return box.isCancelled?() ?? false
            }
            params.abort_callback_user_data = boxPointer

            let code = samples.withUnsafeBufferPointer { buffer in
                whisper_full(ctx, params, buffer.baseAddress, Int32(buffer.count))
            }

            if isCancelled?() == true { throw WhisperError.cancelled }
            guard code == 0 else { throw WhisperError.inferenceFailed(code) }

            let count = whisper_full_n_segments(ctx)
            var result: [Segment] = []
            result.reserveCapacity(Int(count))
            for i in 0..<count {
                if let segment = Self.makeSegment(ctx: ctx, index: i, offset: timeOffset) {
                    result.append(segment)
                }
            }
            return result
        }
    }

    private static func makeSegment(ctx: OpaquePointer, index: Int32, offset: TimeInterval) -> Segment? {
        guard let raw = whisper_full_get_segment_text(ctx, index) else { return nil }
        let text = String(cString: raw).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        // Таймкоды whisper — в сотых долях секунды.
        let start = Double(whisper_full_get_segment_t0(ctx, index)) / 100.0 + offset
        let end = Double(whisper_full_get_segment_t1(ctx, index)) / 100.0 + offset
        return Segment(start: start, end: end, text: text)
    }

    /// Определяет язык по первым 30 секундам. Возвращает код ISO-639-1 и уверенность.
    func detectLanguage(samples: [Float], options: WhisperOptions) throws -> (code: String, confidence: Double) {
        try queue.sync {
            let ctx = try ensureContext(options)
            let window = Array(samples.prefix(16_000 * 30))
            var probs = [Float](repeating: 0, count: Int(whisper_lang_max_id()) + 1)

            let result = window.withUnsafeBufferPointer { buffer -> Int32 in
                guard whisper_pcm_to_mel(ctx, buffer.baseAddress, Int32(buffer.count), Int32(options.threads)) == 0
                else { return -1 }
                return probs.withUnsafeMutableBufferPointer { probsBuffer in
                    whisper_lang_auto_detect(ctx, 0, Int32(options.threads), probsBuffer.baseAddress)
                }
            }
            guard result >= 0, let code = whisper_lang_str(result) else { return ("ru", 0) }
            return (String(cString: code), Double(probs[Int(result)]))
        }
    }

    private final class CallbackBox {
        let onProgress: ((Double) -> Void)?
        let onSegment: ((Segment) -> Void)?
        let isCancelled: (() -> Bool)?
        let timeOffset: TimeInterval

        init(onProgress: ((Double) -> Void)?,
             onSegment: ((Segment) -> Void)?,
             isCancelled: (() -> Bool)?,
             timeOffset: TimeInterval) {
            self.onProgress = onProgress
            self.onSegment = onSegment
            self.isCancelled = isCancelled
            self.timeOffset = timeOffset
        }
    }
}
