import Foundation

/// Описание модели распознавания в каталоге.
struct ModelSpec: Identifiable, Hashable {
    let id: String            // имя файла без расширения, оно же идентификатор
    let title: String
    let family: Family
    let sizeBytes: Int64
    let url: URL
    let englishOnly: Bool
    let quantized: Bool
    /// 1…5 — субъективные оценки для карточек в интерфейсе.
    let speed: Int
    let quality: Int
    let summary: String
    let kind: Kind
    /// Каким движком считается модель. Объявлено последним, чтобы существующие
    /// записи каталога не пришлось переписывать: по умолчанию — whisper.
    var engine: Engine = .whisper

    enum Engine: String {
        case whisper, parakeet

        var title: String {
            switch self {
            case .whisper: return "whisper.cpp"
            case .parakeet: return "Parakeet TDT"
            }
        }
    }

    enum Kind: String {
        case speech      // обычная модель распознавания
        case diarization // распознавание + разделение говорящих
        case vad         // детектор речи, ускоряет длинные записи
    }

    enum Family: String, CaseIterable {
        case parakeet, tiny, base, small, medium, large, tool

        var title: String {
            switch self {
            case .parakeet: return "Parakeet"
            case .tiny: return "Tiny"
            case .base: return "Base"
            case .small: return "Small"
            case .medium: return "Medium"
            case .large: return "Large v3"
            case .tool: return "Дополнения"
            }
        }
        var order: Int {
            switch self {
            case .parakeet: return 0
            case .large: return 1
            case .medium: return 2
            case .small: return 3
            case .base: return 4
            case .tiny: return 5
            case .tool: return 6
            }
        }
    }

    var fileName: String { "\(id).bin" }
    /// Примерный объём оперативной памяти под загруженную модель.
    var estimatedRAM: Int64 { Int64(Double(sizeBytes) * 1.25) + 180 * 1024 * 1024 }
}

enum ModelCatalog {

    private static let whisperBase = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main"
    private static let tdrzBase = "https://huggingface.co/akashmjn/tinydiarize-whisper.cpp/resolve/main"
    private static let vadBase = "https://huggingface.co/ggml-org/whisper-vad/resolve/main"
    private static let parakeetBase = "https://huggingface.co/ggml-org/parakeet-GGUF/resolve/main"

    static let all: [ModelSpec] = [
        ModelSpec(
            id: "ggml-parakeet-tdt-0.6b-v3-q8_0",
            title: "Parakeet TDT 0.6b v3 · Q8",
            family: .parakeet, sizeBytes: 668_757_119,
            url: URL(string: "\(parakeetBase)/ggml-parakeet-tdt-0.6b-v3-q8_0.bin")!,
            englishOnly: false, quantized: true, speed: 5, quality: 4,
            summary: "Другая архитектура — транcдьюсер вместо encoder-decoder. Заметно быстрее whisper при близком качестве, знает 25 европейских языков включая русский. Не умеет перевод и выбор языка: язык определяет сама.",
            kind: .speech, engine: .parakeet
        ),
        ModelSpec(
            id: "ggml-parakeet-tdt-0.6b-v3-q4_k",
            title: "Parakeet TDT 0.6b v3 · Q4",
            family: .parakeet, sizeBytes: 415_611_879,
            url: URL(string: "\(parakeetBase)/ggml-parakeet-tdt-0.6b-v3-q4_k.bin")!,
            englishOnly: false, quantized: true, speed: 5, quality: 3,
            summary: "Самый лёгкий Parakeet. Хороший выбор для диктовки: 400 МБ и очень быстрый отклик.",
            kind: .speech, engine: .parakeet
        ),
        ModelSpec(
            id: "ggml-parakeet-tdt-0.6b-v3-f16",
            title: "Parakeet TDT 0.6b v3 · F16",
            family: .parakeet, sizeBytes: 1_255_897_319,
            url: URL(string: "\(parakeetBase)/ggml-parakeet-tdt-0.6b-v3-f16.bin")!,
            englishOnly: false, quantized: false, speed: 4, quality: 4,
            summary: "Parakeet без квантования — максимум точности этой архитектуры.",
            kind: .speech, engine: .parakeet
        ),
        ModelSpec(
            id: "ggml-large-v3-turbo-q5_0",
            title: "Large v3 Turbo · Q5",
            family: .large, sizeBytes: 574_041_195,
            url: URL(string: "\(whisperBase)/ggml-large-v3-turbo-q5_0.bin")!,
            englishOnly: false, quantized: true, speed: 4, quality: 5,
            summary: "Лучший баланс на Apple Silicon: качество large-модели при размере small. Рекомендуется для встреч на русском.",
            kind: .speech
        ),
        ModelSpec(
            id: "ggml-large-v3-turbo",
            title: "Large v3 Turbo",
            family: .large, sizeBytes: 1_624_555_275,
            url: URL(string: "\(whisperBase)/ggml-large-v3-turbo.bin")!,
            englishOnly: false, quantized: false, speed: 4, quality: 5,
            summary: "Полновесный Turbo без квантования. Чуть точнее на именах и терминах, требует больше памяти.",
            kind: .speech
        ),
        ModelSpec(
            id: "ggml-large-v3-q5_0",
            title: "Large v3 · Q5",
            family: .large, sizeBytes: 1_081_140_203,
            url: URL(string: "\(whisperBase)/ggml-large-v3-q5_0.bin")!,
            englishOnly: false, quantized: true, speed: 2, quality: 5,
            summary: "Классическая large v3. Медленнее Turbo, но лучше держит тяжёлый акцент и шум.",
            kind: .speech
        ),
        ModelSpec(
            id: "ggml-large-v3",
            title: "Large v3",
            family: .large, sizeBytes: 3_095_033_483,
            url: URL(string: "\(whisperBase)/ggml-large-v3.bin")!,
            englishOnly: false, quantized: false, speed: 1, quality: 5,
            summary: "Максимальная точность без компромиссов. Три гигабайта на диске и заметная нагрузка на GPU.",
            kind: .speech
        ),
        ModelSpec(
            id: "ggml-medium-q5_0",
            title: "Medium · Q5",
            family: .medium, sizeBytes: 539_212_467,
            url: URL(string: "\(whisperBase)/ggml-medium-q5_0.bin")!,
            englishOnly: false, quantized: true, speed: 3, quality: 4,
            summary: "Крепкий середняк. Имеет смысл, если Turbo почему-то ошибается на вашей речи.",
            kind: .speech
        ),
        ModelSpec(
            id: "ggml-medium",
            title: "Medium",
            family: .medium, sizeBytes: 1_533_763_059,
            url: URL(string: "\(whisperBase)/ggml-medium.bin")!,
            englishOnly: false, quantized: false, speed: 2, quality: 4,
            summary: "Medium без квантования.",
            kind: .speech
        ),
        ModelSpec(
            id: "ggml-small-q5_1",
            title: "Small · Q5",
            family: .small, sizeBytes: 190_085_487,
            url: URL(string: "\(whisperBase)/ggml-small-q5_1.bin")!,
            englishOnly: false, quantized: true, speed: 5, quality: 3,
            summary: "Оптимальный выбор для диктовки: короткая фраза распознаётся за доли секунды.",
            kind: .speech
        ),
        ModelSpec(
            id: "ggml-small",
            title: "Small",
            family: .small, sizeBytes: 487_601_967,
            url: URL(string: "\(whisperBase)/ggml-small.bin")!,
            englishOnly: false, quantized: false, speed: 4, quality: 3,
            summary: "Small без квантования — заметно точнее на числах и латинице.",
            kind: .speech
        ),
        ModelSpec(
            id: "ggml-base-q5_1",
            title: "Base · Q5",
            family: .base, sizeBytes: 59_707_625,
            url: URL(string: "\(whisperBase)/ggml-base-q5_1.bin")!,
            englishOnly: false, quantized: true, speed: 5, quality: 2,
            summary: "Шестьдесят мегабайт. Для быстрых заметок и слабых машин.",
            kind: .speech
        ),
        ModelSpec(
            id: "ggml-base",
            title: "Base",
            family: .base, sizeBytes: 147_951_465,
            url: URL(string: "\(whisperBase)/ggml-base.bin")!,
            englishOnly: false, quantized: false, speed: 5, quality: 2,
            summary: "Базовая модель. Годится для черновой расшифровки.",
            kind: .speech
        ),
        ModelSpec(
            id: "ggml-tiny-q5_1",
            title: "Tiny · Q5",
            family: .tiny, sizeBytes: 32_152_673,
            url: URL(string: "\(whisperBase)/ggml-tiny-q5_1.bin")!,
            englishOnly: false, quantized: true, speed: 5, quality: 1,
            summary: "Самая маленькая. Полезна как проверка, что всё работает.",
            kind: .speech
        ),
        ModelSpec(
            id: "ggml-tiny",
            title: "Tiny",
            family: .tiny, sizeBytes: 77_691_713,
            url: URL(string: "\(whisperBase)/ggml-tiny.bin")!,
            englishOnly: false, quantized: false, speed: 5, quality: 1,
            summary: "Минимальная модель без квантования.",
            kind: .speech
        ),
        ModelSpec(
            id: "ggml-medium.en",
            title: "Medium · только английский",
            family: .medium, sizeBytes: 1_533_774_781,
            url: URL(string: "\(whisperBase)/ggml-medium.en.bin")!,
            englishOnly: true, quantized: false, speed: 2, quality: 4,
            summary: "Специализирована на английском — на нём точнее многоязычной того же размера.",
            kind: .speech
        ),
        ModelSpec(
            id: "ggml-small.en",
            title: "Small · только английский",
            family: .small, sizeBytes: 487_614_201,
            url: URL(string: "\(whisperBase)/ggml-small.en.bin")!,
            englishOnly: true, quantized: false, speed: 4, quality: 3,
            summary: "Английская Small.",
            kind: .speech
        ),
        ModelSpec(
            id: "ggml-base.en",
            title: "Base · только английский",
            family: .base, sizeBytes: 147_964_211,
            url: URL(string: "\(whisperBase)/ggml-base.en.bin")!,
            englishOnly: true, quantized: false, speed: 5, quality: 2,
            summary: "Английская Base.",
            kind: .speech
        ),
        ModelSpec(
            id: "ggml-small.en-tdrz",
            title: "Small · разделение говорящих",
            family: .tool, sizeBytes: 487_614_184,
            url: URL(string: "\(tdrzBase)/ggml-small.en-tdrz.bin")!,
            englishOnly: true, quantized: false, speed: 4, quality: 3,
            summary: "tinydiarize: помечает смену говорящего прямо в расшифровке. Только английский.",
            kind: .diarization
        ),
        ModelSpec(
            id: "ggml-silero-v5.1.2",
            title: "Silero VAD",
            family: .tool, sizeBytes: 885_098,
            url: URL(string: "\(vadBase)/ggml-silero-v5.1.2.bin")!,
            englishOnly: false, quantized: false, speed: 5, quality: 5,
            summary: "Детектор речи. Меньше мегабайта, но вырезает паузы — длинная встреча расшифровывается в разы быстрее.",
            kind: .vad
        )
    ]

    static let vadModelID = "ggml-silero-v5.1.2"

    /// Модели, которые предлагаются при первом запуске: универсальная + быстрая + VAD.
    static let starterPack = ["ggml-large-v3-turbo-q5_0", "ggml-small-q5_1", vadModelID]

    static func spec(id: String) -> ModelSpec? {
        all.first { $0.id == id }
    }

    static var speechModels: [ModelSpec] {
        all.filter { $0.kind != .vad }
    }

    static var grouped: [(family: ModelSpec.Family, models: [ModelSpec])] {
        Dictionary(grouping: all, by: \.family)
            .sorted { $0.key.order < $1.key.order }
            .map { (family: $0.key, models: $0.value.sorted { $0.sizeBytes > $1.sizeBytes }) }
    }
}
