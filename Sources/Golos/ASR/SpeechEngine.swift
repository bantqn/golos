import Foundation

/// Общий интерфейс движка распознавания.
///
/// Реализаций две — whisper.cpp и Parakeet. У них разные C-API, но снаружи
/// они ведут себя одинаково: держат модель в памяти, выгружают её по простою
/// и отдают реплики с таймкодами. Всё остальное приложение работает через
/// этот протокол и не знает, какая модель выбрана.
protocol SpeechEngine: AnyObject {

    /// Сколько секунд простоя терпим, прежде чем выгрузить модель.
    var idleUnloadSeconds: TimeInterval { get set }

    /// Имя модели, которая сейчас в памяти, либо `nil`.
    var loadedModel: String? { get }

    var isModelLoaded: Bool { get }

    /// Загружает модель заранее, не блокируя вызывающего.
    func preload(_ options: WhisperOptions)

    func unload()
    func unloadAndWait() async

    /// Синхронно распознаёт массив семплов 16 кГц моно.
    func transcribe(
        samples: [Float],
        options: WhisperOptions,
        timeOffset: TimeInterval,
        onProgress: ((Double) -> Void)?,
        onSegment: ((Segment) -> Void)?,
        isCancelled: (() -> Bool)?
    ) throws -> [Segment]
}

extension SpeechEngine {
    func transcribe(samples: [Float], options: WhisperOptions) throws -> [Segment] {
        try transcribe(samples: samples, options: options, timeOffset: 0,
                       onProgress: nil, onSegment: nil, isCancelled: nil)
    }
}

/// Для какой задачи нужен движок.
///
/// Роли разделены, чтобы короткая продиктованная фраза не ждала, пока
/// досчитается часовая встреча: у каждой роли свой контекст и своя очередь.
enum EngineRole {
    case bulk        // записи и файлы
    case dictation   // диктовка
}

/// Реестр движков: по одному экземпляру на пару «бэкенд × роль».
///
/// Экземпляров четыре, но памяти это не стоит: неиспользуемые не держат
/// модель, а выгружают её по простою.
enum Engines {

    private static let whisperBulk = WhisperEngine(label: "whisper-bulk")
    private static let whisperDictation = WhisperEngine(label: "whisper-dictation")
    private static let parakeetBulk = ParakeetEngine(label: "parakeet-bulk")
    private static let parakeetDictation = ParakeetEngine(label: "parakeet-dictation")

    static var all: [SpeechEngine] {
        [whisperBulk, whisperDictation, parakeetBulk, parakeetDictation]
    }

    static func engine(for spec: ModelSpec, role: EngineRole) -> SpeechEngine {
        switch (spec.engine, role) {
        case (.whisper, .bulk): return whisperBulk
        case (.whisper, .dictation): return whisperDictation
        case (.parakeet, .bulk): return parakeetBulk
        case (.parakeet, .dictation): return parakeetDictation
        }
    }

    static func unloadAll() {
        for engine in all { engine.unload() }
    }

    /// Выгружает движки, кроме тех, что сейчас заняты работой.
    ///
    /// Занятый движок трогать бессмысленно: выгрузка встанет в его очередь и
    /// всё равно дождётся конца расчёта, зато следующее окно придётся грузить
    /// заново — чистая потеря времени без выигрыша в памяти.
    static func unloadIdle(keepBulk: Bool, keepDictation: Bool) {
        for engine in all {
            switch role(of: engine) {
            case .bulk where keepBulk: continue
            case .dictation where keepDictation: continue
            default: engine.unload()
            }
        }
    }

    static func role(of engine: SpeechEngine) -> EngineRole {
        (engine === whisperDictation || engine === parakeetDictation) ? .dictation : .bulk
    }

    /// Освобождает память всех движков кроме указанного и дожидается этого.
    /// Нужно перед загрузкой большой модели: два контекста одновременно —
    /// самый быстрый способ довести машину до свопа.
    static func freeMemory(excluding keep: SpeechEngine) async {
        for engine in all where engine !== keep {
            await engine.unloadAndWait()
        }
    }

    static func setIdleUnloadSeconds(_ seconds: TimeInterval) {
        for engine in all { engine.idleUnloadSeconds = seconds }
    }

    /// Модели, лежащие в памяти прямо сейчас, — для интерфейса.
    static var loadedModels: [String] {
        all.compactMap(\.loadedModel)
    }

    static var anyModelLoaded: Bool {
        all.contains { $0.isModelLoaded }
    }
}
