import Foundation
import Combine

/// Одна запись в библиотеке.
struct Recording: Identifiable, Codable, Hashable {

    var id: UUID
    var title: String
    var createdAt: Date
    var duration: TimeInterval
    var source: Source
    /// Что было слышно во время записи — «Zoom», «Telegram», «Safari»…
    var appHint: String?
    var tracks: [Track]
    var transcriptStatus: TranscriptStatus
    var language: String?
    var modelID: String?
    /// Пользовательская пометка «важное».
    var starred: Bool = false
    /// Начало расшифровки для списка. Хранится в метаданных, чтобы строки
    /// не читали файлы расшифровок с диска при каждой прокрутке.
    var preview: String?
    /// Каким микрофоном записывали — для легенды в начале расшифровки.
    var micDeviceName: String?
    /// Сколько человек говорит, если это известно заранее. Заданное число
    /// заметно надёжнее автоопределения: угадывать не приходится.
    var expectedSpeakers: Int?
    /// Имена говорящих по порядку. Пусто — будут «голос 1», «голос 2».
    var speakerNames: [String] = []

    /// Читаем терпимо: отсутствующее поле — это значение по умолчанию, а не
    /// ошибка. Иначе любое новое поле делает нечитаемыми все прежние записи, а
    /// пустой список при следующем сохранении затирает библиотеку. Один раз я
    /// на этом уже потерял данные — пусть больше не повторяется.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Без названия"
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        source = try c.decodeIfPresent(Source.self, forKey: .source) ?? .imported
        appHint = try c.decodeIfPresent(String.self, forKey: .appHint)
        tracks = try c.decodeIfPresent([Track].self, forKey: .tracks) ?? []
        transcriptStatus = try c.decodeIfPresent(
            TranscriptStatus.self, forKey: .transcriptStatus) ?? TranscriptStatus.none
        language = try c.decodeIfPresent(String.self, forKey: .language)
        modelID = try c.decodeIfPresent(String.self, forKey: .modelID)
        starred = try c.decodeIfPresent(Bool.self, forKey: .starred) ?? false
        preview = try c.decodeIfPresent(String.self, forKey: .preview)
        micDeviceName = try c.decodeIfPresent(String.self, forKey: .micDeviceName)
        expectedSpeakers = try c.decodeIfPresent(Int.self, forKey: .expectedSpeakers)
        speakerNames = try c.decodeIfPresent([String].self, forKey: .speakerNames) ?? []
    }

    /// Обычный почленный инициализатор: свой `init(from:)` отменяет
    /// автоматический, а создаётся запись именно так.
    init(id: UUID, title: String, createdAt: Date, duration: TimeInterval,
         source: Source, appHint: String?, tracks: [Track],
         transcriptStatus: TranscriptStatus, language: String?, modelID: String?,
         starred: Bool = false, preview: String? = nil, micDeviceName: String? = nil,
         expectedSpeakers: Int? = nil, speakerNames: [String] = []) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.source = source
        self.appHint = appHint
        self.tracks = tracks
        self.transcriptStatus = transcriptStatus
        self.language = language
        self.modelID = modelID
        self.starred = starred
        self.preview = preview
        self.micDeviceName = micDeviceName
        self.expectedSpeakers = expectedSpeakers
        self.speakerNames = speakerNames
    }

    enum Source: String, Codable {
        case microphone, meeting, imported, continuous

        var title: String {
            switch self {
            case .microphone: return "Микрофон"
            case .meeting: return "Встреча"
            case .imported: return "Импорт"
            case .continuous: return "Весь день"
            }
        }
        var symbol: String {
            switch self {
            case .microphone: return "mic.fill"
            case .meeting: return "person.2.wave.2.fill"
            case .imported: return "square.and.arrow.down.fill"
            case .continuous: return "clock.arrow.circlepath"
            }
        }
    }

    struct Track: Codable, Hashable {
        init(kind: Kind, fileName: String, startOffset: TimeInterval = 0) {
            self.kind = kind
            self.fileName = fileName
            self.startOffset = startOffset
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .original
            fileName = try c.decode(String.self, forKey: .fileName)
            startOffset = try c.decodeIfPresent(TimeInterval.self, forKey: .startOffset) ?? 0
        }

        var kind: Kind
        var fileName: String
        /// С какой секунды от начала записи начинается этот файл.
        /// Нужно для дневной записи: она нарезана на отрезки, и таймкоды
        /// расшифровки должны считаться от начала дня, а не от начала файла.
        var startOffset: TimeInterval = 0

        enum Kind: String, Codable {
            case mic, system, mixed, original

            var speaker: Segment.Speaker {
                switch self {
                case .mic: return .me
                case .system: return .others
                case .mixed, .original: return .unknown
                }
            }
            var title: String {
                switch self {
                case .mic: return "Микрофон"
                case .system: return "Звук системы"
                case .mixed: return "Смикшировано"
                case .original: return "Исходный файл"
                }
            }
        }
    }

    enum TranscriptStatus: Codable, Hashable {
        case none
        case queued
        case running(progress: Double)
        case done(segmentCount: Int, wordCount: Int)
        case failed(String)

        var isDone: Bool { if case .done = self { return true }; return false }
        var isRunning: Bool {
            switch self {
            case .running, .queued: return true
            default: return false
            }
        }
    }

    var directory: URL { Container.recordingDirectory(for: id) }

    func url(for track: Track) -> URL {
        directory.appendingPathComponent(track.fileName)
    }

    /// Дорожка, которую логично отдать плееру.
    var playbackTrack: Track? {
        tracks.first { $0.kind == .mixed }
            ?? tracks.first { $0.kind == .original }
            ?? tracks.sorted { $0.startOffset < $1.startOffset }.first
    }

    /// Отрезки дневной записи, по порядку.
    var orderedTracks: [Track] {
        tracks.sorted {
            $0.startOffset == $1.startOffset ? $0.fileName < $1.fileName : $0.startOffset < $1.startOffset
        }
    }

    var isContinuous: Bool { source == .continuous }

    /// Раздел, в котором запись показывается на главном экране.
    var category: Category {
        switch source {
        case .meeting: return .meetings
        case .continuous: return .allDay
        case .microphone, .imported: return .notes
        }
    }

    enum Category: String, CaseIterable, Identifiable, Hashable {
        case meetings, allDay, notes

        var id: String { rawValue }

        var title: String {
            switch self {
            case .meetings: return "Встречи"
            case .allDay: return "Запись весь день"
            case .notes: return "Заметки и файлы"
            }
        }
        var symbol: String {
            switch self {
            case .meetings: return "person.2.wave.2.fill"
            case .allDay: return "clock.arrow.circlepath"
            case .notes: return "mic.fill"
            }
        }
    }

    var diskSize: Int64 { Container.size(of: directory) }

    /// Как подписать говорящего в расшифровке.
    func speakerTitle(for speaker: Segment.Speaker) -> String {
        guard case .voice(let index) = speaker else { return speaker.title }
        // Имена заданы при импорте — используем их вместо «голос N».
        if index >= 1, index <= speakerNames.count {
            let name = speakerNames[index - 1].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name }
        }
        return speaker.title
    }
}

/// Результат распознавания одной записи.
struct Transcript: Codable {
    var recordingID: UUID
    var segments: [Segment]
    var language: String
    var modelID: String
    var createdAt: Date
    /// Сколько секунд заняло распознавание — показывается как «×12 быстрее реального времени».
    var processingSeconds: TimeInterval

    var plainText: String {
        segments.map(\.text).joined(separator: " ")
    }

    var wordCount: Int {
        plainText.split(whereSeparator: { $0.isWhitespace }).count
    }

    /// Склеивает подряд идущие реплики одного говорящего — читать удобнее.
    var paragraphs: [(speaker: Segment.Speaker, start: TimeInterval, text: String)] {
        var result: [(Segment.Speaker, TimeInterval, String)] = []
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            if var last = result.last, last.0 == segment.speaker,
               segment.start - last.1 < 600 {
                last.2 += " " + segment.text
                result[result.count - 1] = last
            } else {
                result.append((segment.speaker, segment.start, segment.text))
            }
        }
        return result.map { (speaker: $0.0, start: $0.1, text: $0.2) }
    }
}

/// Библиотека записей: список в JSON, аудио и расшифровки — отдельными файлами.
@MainActor
final class LibraryStore: ObservableObject {

    /// Настройки нужны только для архива Markdown: куда его писать и писать ли.
    /// Проставляются после создания, чтобы не заводить циклическую зависимость.
    weak var settings: Settings?

    @Published private(set) var recordings: [Recording] = []
    @Published var searchQuery: String = ""

    /// Кэш разобранных расшифровок. Двухчасовая встреча — это тысячи реплик,
    /// поэтому держим только несколько последних, а не всё, что открывали.
    private var transcriptCache: [UUID: Transcript] = [:]
    private var cacheOrder: [UUID] = []
    private let cacheLimit = 12

    init() { load() }

    // MARK: - Список

    func load() {
        guard let data = try? Data(contentsOf: Container.libraryFile) else {
            recordings = []
            return
        }
        do {
            recordings = try JSONDecoder.golos.decode([Recording].self, from: data)
                .sorted { $0.createdAt > $1.createdAt }
        } catch {
            // Пустой список тут опаснее всего: следующее же сохранение затрёт
            // файл, и записи исчезнут из библиотеки, оставшись на диске.
            // Поэтому непрочитанный файл откладываем в сторону и говорим об этом.
            let backup = Container.libraryFile
                .deletingLastPathComponent()
                .appendingPathComponent("library-нечитаемая.json")
            try? data.write(to: backup, options: .atomic)
            Log.error("Список записей не прочитан (\(error)). Копия сохранена: \(backup.path)")
            recordings = []
            brokenLibraryFile = backup
        }
    }

    /// Проставляется, если библиотеку прочитать не удалось, — интерфейс должен
    /// сказать об этом, а не делать вид, что записей никогда не было.
    @Published private(set) var brokenLibraryFile: URL?

    private func save() {
        guard let data = try? JSONEncoder.golos.encode(recordings) else { return }
        try? data.write(to: Container.libraryFile, options: .atomic)
    }

    func add(_ recording: Recording) {
        recordings.insert(recording, at: 0)
        save()
    }

    func update(_ recording: Recording) {
        guard let index = recordings.firstIndex(where: { $0.id == recording.id }) else { return }
        recordings[index] = recording
        save()
    }

    func updateStatus(_ id: UUID, _ status: Recording.TranscriptStatus) {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        recordings[index].transcriptStatus = status
        // Прогресс меняется часто — на диск пишем только устойчивые состояния.
        if !status.isRunning { save() }
    }

    /// Дописывает отрезки к дневной записи и обновляет её длительность.
    func appendTracks(_ tracks: [Recording.Track], to id: UUID, duration: TimeInterval) {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        recordings[index].tracks.append(contentsOf: tracks)
        recordings[index].duration = duration
        save()
    }

    func setDuration(_ duration: TimeInterval, for id: UUID) {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        recordings[index].duration = duration
        save()
    }

    func recording(id: UUID) -> Recording? {
        recordings.first { $0.id == id }
    }

    func rename(_ id: UUID, to title: String) {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        recordings[index].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        save()
    }

    func toggleStar(_ id: UUID) {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        recordings[index].starred.toggle()
        save()
    }

    func delete(_ recording: Recording) {
        try? FileManager.default.removeItem(at: recording.directory)
        try? FileManager.default.removeItem(at: Container.transcriptFile(for: recording.id))
        transcriptCache[recording.id] = nil
        cacheOrder.removeAll { $0 == recording.id }
        recordings.removeAll { $0.id == recording.id }
        save()
    }

    func deleteAll() {
        for recording in recordings {
            try? FileManager.default.removeItem(at: recording.directory)
            try? FileManager.default.removeItem(at: Container.transcriptFile(for: recording.id))
        }
        trimCaches()
        recordings = []
        save()
    }

    /// Удаляет аудио, оставляя расшифровку, — освобождает основной объём.
    func discardAudio(for recording: Recording) {
        try? FileManager.default.removeItem(at: recording.directory)
        var updated = recording
        updated.tracks = []
        update(updated)
    }

    var filtered: [Recording] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return recordings }
        return recordings.filter { recording in
            if recording.title.lowercased().contains(query) { return true }
            if recording.appHint?.lowercased().contains(query) == true { return true }
            if recording.preview?.lowercased().contains(query) == true { return true }
            // Полный текст лежит в отдельных файлах, поэтому по нему ищем только
            // с трёх символов: иначе каждое нажатие клавиши перечитывало бы диск.
            guard query.count >= 3, let transcript = transcript(for: recording.id) else { return false }
            return transcript.plainText.lowercased().contains(query)
        }
    }

    func recordings(in category: Recording.Category) -> [Recording] {
        recordings.filter { $0.category == category }
    }

    var totalDuration: TimeInterval {
        recordings.reduce(0) { $0 + $1.duration }
    }

    // MARK: - Расшифровки

    func transcript(for id: UUID) -> Transcript? {
        if let cached = transcriptCache[id] {
            touch(id)
            return cached
        }
        guard let data = try? Data(contentsOf: Container.transcriptFile(for: id)),
              let decoded = try? JSONDecoder.golos.decode(Transcript.self, from: data)
        else { return nil }
        cache(decoded, for: id)
        return decoded
    }

    /// Сбрасывает кэш расшифровок — вызывается при нехватке памяти.
    func trimCaches() {
        transcriptCache.removeAll()
        cacheOrder.removeAll()
    }

    private func cache(_ transcript: Transcript, for id: UUID) {
        transcriptCache[id] = transcript
        touch(id)
        while cacheOrder.count > cacheLimit {
            let evicted = cacheOrder.removeFirst()
            transcriptCache[evicted] = nil
        }
    }

    private func touch(_ id: UUID) {
        cacheOrder.removeAll { $0 == id }
        cacheOrder.append(id)
    }

    /// Дописывает реплики в существующую расшифровку.
    /// Нужно для дневной записи: она расшифровывается отрезками по ходу дня,
    /// и каждый готовый отрезок добавляется к уже накопленному тексту.
    func appendSegments(_ segments: [Segment], to recordingID: UUID,
                        language: String, modelID: String, processingSeconds: TimeInterval) {
        guard !segments.isEmpty else { return }

        var transcript = self.transcript(for: recordingID) ?? Transcript(
            recordingID: recordingID,
            segments: [],
            language: language,
            modelID: modelID,
            createdAt: Date(),
            processingSeconds: 0
        )
        transcript.segments.append(contentsOf: segments)
        transcript.segments.sort { $0.start < $1.start }
        transcript.processingSeconds += processingSeconds
        transcript.modelID = modelID
        saveTranscript(transcript)
    }

    func saveTranscript(_ transcript: Transcript) {
        cache(transcript, for: transcript.recordingID)
        guard let data = try? JSONEncoder.golos.encode(transcript) else { return }
        try? data.write(to: Container.transcriptFile(for: transcript.recordingID), options: .atomic)

        if let index = recordings.firstIndex(where: { $0.id == transcript.recordingID }) {
            recordings[index].transcriptStatus = .done(
                segmentCount: transcript.segments.count,
                wordCount: transcript.wordCount
            )
            recordings[index].language = transcript.language
            recordings[index].modelID = transcript.modelID
            recordings[index].preview = String(
                transcript.plainText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
            save()

            // Архив в Markdown обновляется тем же движением: у дневной записи
            // расшифровка дописывается по ходу дня, и файл должен догонять её.
            if let settings {
                TranscriptArchive.write(transcript, recording: recordings[index], settings: settings)
            }
        }
    }

    func updateSegmentText(recordingID: UUID, segmentID: UUID, text: String) {
        guard var transcript = transcript(for: recordingID),
              let index = transcript.segments.firstIndex(where: { $0.id == segmentID })
        else { return }
        transcript.segments[index].text = text
        saveTranscript(transcript)
        objectWillChange.send()
    }
}

extension JSONEncoder {
    static var golos: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        return encoder
    }
}

extension JSONDecoder {
    static var golos: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
