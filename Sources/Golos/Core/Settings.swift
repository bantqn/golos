import Foundation
import Combine
import CoreAudio

/// Способ активации диктовки.
enum DictationMode: String, Codable, CaseIterable, Identifiable {
    case pushToTalk
    case toggle

    var id: String { rawValue }
    var title: String {
        switch self {
        case .pushToTalk: return "Удерживать"
        case .toggle: return "Переключать"
        }
    }
    var explanation: String {
        switch self {
        case .pushToTalk: return "Говорите, пока клавиши зажаты. Отпустили — текст вставился."
        case .toggle: return "Нажали — пишет. Нажали ещё раз — вставляет."
        }
    }
}

/// Как вставлять распознанный текст в активное приложение.
enum InsertionMode: String, Codable, CaseIterable, Identifiable {
    case paste
    case type

    var id: String { rawValue }
    var title: String {
        switch self {
        case .paste: return "Через буфер обмена"
        case .type: return "Посимвольно"
        }
    }
    var explanation: String {
        switch self {
        case .paste: return "Быстро и надёжно. Буфер обмена восстанавливается после вставки."
        case .type: return "Медленнее, зато буфер обмена не трогается совсем."
        }
    }
}

/// Сочетание клавиш в терминах Carbon Hot Keys.
struct HotKeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    /// ⌥ + Пробел по умолчанию: не конфликтует со Spotlight (⌘Space)
    /// и с системной диктовкой (двойной Control).
    static let `default` = HotKeyCombo(keyCode: 49, modifiers: UInt32(optionKeyMask))

    static let cmdKeyMask: Int = 1 << 8
    static let shiftKeyMask: Int = 1 << 9
    static let optionKeyMask: Int = 1 << 11
    static let controlKeyMask: Int = 1 << 12

    var displayString: String {
        var parts: [String] = []
        if modifiers & UInt32(Self.controlKeyMask) != 0 { parts.append("⌃") }
        if modifiers & UInt32(Self.optionKeyMask) != 0 { parts.append("⌥") }
        if modifiers & UInt32(Self.shiftKeyMask) != 0 { parts.append("⇧") }
        if modifiers & UInt32(Self.cmdKeyMask) != 0 { parts.append("⌘") }
        parts.append(Self.keyName(keyCode))
        return parts.joined()
    }

    static func keyName(_ code: UInt32) -> String {
        let names: [UInt32: String] = [
            49: "Пробел", 36: "⏎", 48: "⇥", 53: "⎋", 51: "⌫", 117: "⌦",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
            105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19",
            0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H",
            34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O",
            35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V",
            13: "W", 7: "X", 16: "Y", 6: "Z",
            29: "0", 18: "1", 19: "2", 20: "3", 21: "4",
            23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
            // Знаки препинания — без них нельзя было задать, например, ⌘`
            50: "`", 27: "-", 24: "=", 33: "[", 30: "]", 42: "\\",
            41: ";", 39: "'", 43: ",", 47: ".", 44: "/"
        ]
        return names[code] ?? "клавиша \(code)"
    }
}

/// Что делать, когда в конкретной программе начался разговор.
struct AppRule: Codable, Equatable {
    /// Начинать запись без спроса.
    var autoRecord: Bool = false
    /// Показывать системные уведомления об этой программе — и о начале
    /// разговора, и о том, что она освободила микрофон.
    var notify: Bool = true
}

/// Что делать, когда программа отпустила микрофон во время нашей записи.
enum CallEndAction: String, Codable, CaseIterable, Identifiable {
    case ask, finish, ignore

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: return "Предлагать завершить"
        case .finish: return "Завершать сразу"
        case .ignore: return "Не реагировать"
        }
    }

    var explanation: String {
        switch self {
        case .ask:
            return "Появится предложение остановить запись — в окне и уведомлением. "
                 + "Запись продолжается, пока вы не согласились."
        case .finish:
            return "Запись останавливается сама. Удобно, если после встречи вы "
                 + "просто закрываете ноутбук."
        case .ignore:
            return "Приложение промолчит и продолжит писать."
        }
    }
}

/// Все пользовательские настройки. Хранятся одним JSON внутри контейнера —
/// никаких записей в UserDefaults и prefs по всему маку.
final class Settings: ObservableObject, Codable {

    // Распознавание
    @Published var transcriptionModelID: String = "ggml-large-v3-turbo-q5_0"
    @Published var dictationModelID: String = "ggml-small-q5_1"
    @Published var language: String = "ru"
    @Published var translateToEnglish: Bool = false
    @Published var beamSize: Int = 2
    @Published var dictationBeamSize: Int = 1
    @Published var useGPU: Bool = true
    @Published var threads: Int = max(1, ProcessInfo.processInfo.activeProcessorCount - 2)
    @Published var vocabulary: String = ""
    @Published var useVAD: Bool = false

    // Память
    /// Сколько гигабайт всегда оставлять системе.
    @Published var memoryHeadroomGB: Double = 4
    /// Через сколько секунд простоя выгружать модель из памяти.
    @Published var modelIdleUnloadSeconds: Int = 60
    /// Выгружать модели, когда окно неактивно.
    @Published var unloadWhenInactive: Bool = true

    // Запись
    @Published var recordMicrophone: Bool = true
    @Published var recordSystemAudio: Bool = true
    @Published var autoTranscribeAfterRecording: Bool = true
    @Published var keepAudioAfterTranscription: Bool = true
    @Published var inputDeviceID: UInt32 = 0          // 0 — системный по умолчанию
    @Published var detectCalls: Bool = true
    @Published var autoStartOnCall: Bool = false
    /// Показывать системное уведомление, когда замечен разговор.
    @Published var notifyOnCall: Bool = true
    /// Правила по программам. Ключ — bundle id. Чего нет в словаре, подчиняется
    /// общим переключателям выше.
    @Published var appRules: [String: AppRule] = [:]
    /// Программы, которые уже занимали микрофон: bundle id → имя.
    /// Пополняется само, чтобы в настройках были строки для тех программ,
    /// которыми вы действительно пользуетесь.
    @Published var seenCallApps: [String: String] = [:]

    // Эхо между дорожками
    /// Убирать из расшифровки фразы, попавшие в микрофон из динамиков.
    @Published var suppressEcho: Bool = true
    /// Какой дорожке верить, когда фраза попала в обе.
    @Published var echoPriority: EchoPriority = .system
    /// Насколько похожими должны быть тексты, чтобы счесть их одной фразой.
    @Published var echoSimilarity: Double = 0.55

    // Разделение по голосам
    /// Делить реплики системной дорожки по голосам участников.
    @Published var diarizationEnabled: Bool = true
    /// Сколько голосов допускаем максимум.
    @Published var maxSpeakers: Int = 4
    /// Не включать микрофон Bluetooth-гарнитуры: вместо него брать встроенный.
    /// Иначе наушники уходят из A2DP в режим разговора и звук в них портится.
    @Published var avoidBluetoothMic: Bool = true

    /// Что делать, когда разговор закончился, а запись ещё идёт.
    @Published var callEndAction: CallEndAction = .ask
    /// Сколько секунд ждать, прежде чем счесть разговор законченным. Небольшая
    /// пауза нужна, потому что программы на миг отпускают микрофон при смене
    /// устройства или переключении на демонстрацию экрана.
    @Published var callEndDelaySeconds: Int = 12

    /// Насколько должна различаться высота тона, чтобы счесть голоса разными.
    /// Значение подобрано замером: ниже 0.25 приложение начинало делить одного
    /// человека на нескольких. Больше — делит осторожнее.
    @Published var diarizationThreshold: Double = 0.30
    /// Спрашивать при импорте, сколько человек говорит и как их зовут.
    /// Заданное число надёжнее автоопределения, поэтому по умолчанию спрашиваем.
    @Published var askSpeakersOnImport: Bool = true

    // Постоянная запись (дневная)
    /// На сколько минут резать непрерывную запись. Один файл на весь день —
    /// это гигабайты, которые нельзя ни расшифровать по частям, ни быстро открыть.
    @Published var continuousSegmentMinutes: Int = 10
    /// Расшифровывать каждый готовый отрезок сразу, не дожидаясь конца дня.
    @Published var continuousTranscribeIncrementally: Bool = true

    // Диктовка
    @Published var dictationEnabled: Bool = true
    @Published var dictationHotKey: HotKeyCombo = .default
    @Published var dictationMode: DictationMode = .pushToTalk
    @Published var insertionMode: InsertionMode = .paste
    @Published var dictationSound: Bool = true
    @Published var trimTrailingPeriod: Bool = false
    /// Показывать текст по ходу речи. Стоит денег: буфер перераспознаётся
    /// повторно каждые полторы секунды, то есть процессор занят всё время, пока
    /// вы говорите, а не только после.
    @Published var livePreview: Bool = true
    /// Оставлять распознанный текст в буфере обмена.
    /// Надёжная страховка: определить, действительно ли приложение приняло
    /// вставку, невозможно, а потерянную фразу не восстановить.
    @Published var keepTextInClipboard: Bool = true

    // Обработка языковой моделью
    @Published var llmProvider: LLMProvider = .disabled
    @Published var llmBaseURL: String = ""
    @Published var llmModel: String = ""
    @Published var llmTemperature: Double = 0.2
    @Published var llmTimeoutSeconds: Int = 45
    @Published var claudeCLIPath: String = "claude"
    /// Прогонять продиктованное через модель перед вставкой.
    @Published var postProcessEnabled: Bool = false
    /// Инструкция для программ, у которых нет своего правила.
    @Published var defaultPrompt: String = PostProcessor.defaultPrompt
    /// Из какой заготовки взята инструкция по умолчанию.
    @Published var defaultPresetID: String = PostProcessor.defaultPresetID
    /// Свои инструкции для отдельных программ: bundle id → правило.
    @Published var appPrompts: [String: PromptRule] = [:]
    /// Обрабатывать и в тех программах, для которых правила нет.
    @Published var postProcessUnlistedApps: Bool = true

    // Плашка диктовки
    @Published var hudOpacity: Double = 0.86
    /// Положение плашки на экране. Пусто — значит снизу по центру.
    @Published var hudPositionX: Double?
    @Published var hudPositionY: Double?

    // Архив расшифровок в Markdown
    /// Складывать расшифровки .md на диск рядом с документами.
    @Published var archiveEnabled: Bool = true
    /// Папка архива. Пусто — «Документы/голос».
    @Published var archiveFolderPath: String?
    /// Архивировать ещё и заметки с импортом, не только встречи и дневную запись.
    @Published var archiveNotes: Bool = false

    // Интерфейс
    @Published var showMenuBarIcon: Bool = true
    @Published var reduceMotion: Bool = false
    /// Медленно плывущий фон. Выключен по умолчанию: непрерывная анимация
    /// на всё окно стоит около 13% процессора, сколько её ни оптимизируй.
    @Published var animatedBackground: Bool = false
    @Published var accent: AccentTheme = .aurora
    /// Тёмная тема выбрана по умолчанию. Пользователь может зафиксировать
    /// светлую тему или снова передать выбор macOS.
    @Published var appearance: AppearanceMode = .dark

    enum AppearanceMode: String, Codable, CaseIterable, Identifiable {
        case dark, light, system

        var id: String { rawValue }
        var title: String {
            switch self {
            case .dark: return "Тёмная"
            case .light: return "Светлая"
            case .system: return "Как в системе"
            }
        }
    }

    enum AccentTheme: String, Codable, CaseIterable, Identifiable {
        case aurora, ember, mint, violet
        var id: String { rawValue }
        var title: String {
            switch self {
            case .aurora: return "Аврора"
            case .ember: return "Уголь"
            case .mint: return "Мята"
            case .violet: return "Фиалка"
            }
        }
    }

    // MARK: - Persistence

    private var saveCancellable: AnyCancellable?

    init() { observe() }

    enum CodingKeys: String, CodingKey {
        case transcriptionModelID, dictationModelID, language, translateToEnglish
        case beamSize, dictationBeamSize, useGPU, threads, vocabulary, useVAD
        case memoryHeadroomGB, modelIdleUnloadSeconds, unloadWhenInactive
        case recordMicrophone, recordSystemAudio, autoTranscribeAfterRecording
        case keepAudioAfterTranscription, inputDeviceID, detectCalls, autoStartOnCall
        case notifyOnCall, appRules, seenCallApps
        case suppressEcho, echoPriority, echoSimilarity
        case continuousSegmentMinutes, continuousTranscribeIncrementally
        case diarizationEnabled, maxSpeakers, diarizationThreshold, askSpeakersOnImport
        case callEndAction, callEndDelaySeconds, avoidBluetoothMic
        case dictationEnabled, dictationHotKey, dictationMode, insertionMode
        case dictationSound, trimTrailingPeriod, livePreview, keepTextInClipboard
        case llmProvider, llmBaseURL, llmModel, llmTemperature, llmTimeoutSeconds
        case claudeCLIPath, postProcessEnabled, defaultPrompt, defaultPresetID
        case appPrompts, postProcessUnlistedApps
        case hudOpacity, hudPositionX, hudPositionY
        case archiveEnabled, archiveFolderPath, archiveNotes
        case showMenuBarIcon, reduceMotion, animatedBackground, accent, appearance
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decode(T.self, forKey: key)) ?? fallback
        }
        transcriptionModelID = value(.transcriptionModelID, transcriptionModelID)
        dictationModelID = value(.dictationModelID, dictationModelID)
        language = value(.language, language)
        translateToEnglish = value(.translateToEnglish, false)
        beamSize = value(.beamSize, 2)
        dictationBeamSize = value(.dictationBeamSize, 1)
        useGPU = value(.useGPU, true)
        threads = value(.threads, threads)
        vocabulary = value(.vocabulary, "")
        useVAD = value(.useVAD, false)
        memoryHeadroomGB = value(.memoryHeadroomGB, 4)
        modelIdleUnloadSeconds = value(.modelIdleUnloadSeconds, 60)
        unloadWhenInactive = value(.unloadWhenInactive, true)
        recordMicrophone = value(.recordMicrophone, true)
        recordSystemAudio = value(.recordSystemAudio, true)
        autoTranscribeAfterRecording = value(.autoTranscribeAfterRecording, true)
        keepAudioAfterTranscription = value(.keepAudioAfterTranscription, true)
        inputDeviceID = value(.inputDeviceID, 0)
        detectCalls = value(.detectCalls, true)
        autoStartOnCall = value(.autoStartOnCall, false)
        notifyOnCall = value(.notifyOnCall, true)
        appRules = value(.appRules, [:])
        seenCallApps = value(.seenCallApps, [:])
        suppressEcho = value(.suppressEcho, true)
        echoPriority = value(.echoPriority, EchoPriority.system)
        echoSimilarity = value(.echoSimilarity, 0.55)
        diarizationEnabled = value(.diarizationEnabled, true)
        maxSpeakers = value(.maxSpeakers, 4)
        diarizationThreshold = value(.diarizationThreshold, 0.30)
        askSpeakersOnImport = value(.askSpeakersOnImport, true)
        avoidBluetoothMic = value(.avoidBluetoothMic, true)
        callEndAction = value(.callEndAction, CallEndAction.ask)
        callEndDelaySeconds = value(.callEndDelaySeconds, 12)
        continuousSegmentMinutes = value(.continuousSegmentMinutes, 10)
        continuousTranscribeIncrementally = value(.continuousTranscribeIncrementally, true)
        dictationEnabled = value(.dictationEnabled, true)
        dictationHotKey = value(.dictationHotKey, HotKeyCombo.default)
        dictationMode = value(.dictationMode, DictationMode.pushToTalk)
        insertionMode = value(.insertionMode, InsertionMode.paste)
        dictationSound = value(.dictationSound, true)
        trimTrailingPeriod = value(.trimTrailingPeriod, false)
        livePreview = value(.livePreview, true)
        keepTextInClipboard = value(.keepTextInClipboard, true)
        llmProvider = value(.llmProvider, LLMProvider.disabled)
        llmBaseURL = value(.llmBaseURL, "")
        llmModel = value(.llmModel, "")
        llmTemperature = value(.llmTemperature, 0.2)
        llmTimeoutSeconds = value(.llmTimeoutSeconds, 45)
        claudeCLIPath = value(.claudeCLIPath, "claude")
        postProcessEnabled = value(.postProcessEnabled, false)
        defaultPrompt = value(.defaultPrompt, PostProcessor.defaultPrompt)
        defaultPresetID = value(.defaultPresetID, PostProcessor.defaultPresetID)
        appPrompts = value(.appPrompts, [:])
        postProcessUnlistedApps = value(.postProcessUnlistedApps, true)
        hudOpacity = value(.hudOpacity, 0.86)
        hudPositionX = try? c.decode(Double.self, forKey: .hudPositionX)
        hudPositionY = try? c.decode(Double.self, forKey: .hudPositionY)
        archiveEnabled = value(.archiveEnabled, true)
        archiveFolderPath = try? c.decode(String.self, forKey: .archiveFolderPath)
        archiveNotes = value(.archiveNotes, false)
        showMenuBarIcon = value(.showMenuBarIcon, true)
        reduceMotion = value(.reduceMotion, false)
        animatedBackground = value(.animatedBackground, false)
        accent = value(.accent, AccentTheme.aurora)
        appearance = value(.appearance, AppearanceMode.dark)
        observe()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(transcriptionModelID, forKey: .transcriptionModelID)
        try c.encode(dictationModelID, forKey: .dictationModelID)
        try c.encode(language, forKey: .language)
        try c.encode(translateToEnglish, forKey: .translateToEnglish)
        try c.encode(beamSize, forKey: .beamSize)
        try c.encode(dictationBeamSize, forKey: .dictationBeamSize)
        try c.encode(useGPU, forKey: .useGPU)
        try c.encode(threads, forKey: .threads)
        try c.encode(vocabulary, forKey: .vocabulary)
        try c.encode(useVAD, forKey: .useVAD)
        try c.encode(memoryHeadroomGB, forKey: .memoryHeadroomGB)
        try c.encode(modelIdleUnloadSeconds, forKey: .modelIdleUnloadSeconds)
        try c.encode(unloadWhenInactive, forKey: .unloadWhenInactive)
        try c.encode(recordMicrophone, forKey: .recordMicrophone)
        try c.encode(recordSystemAudio, forKey: .recordSystemAudio)
        try c.encode(autoTranscribeAfterRecording, forKey: .autoTranscribeAfterRecording)
        try c.encode(keepAudioAfterTranscription, forKey: .keepAudioAfterTranscription)
        try c.encode(inputDeviceID, forKey: .inputDeviceID)
        try c.encode(detectCalls, forKey: .detectCalls)
        try c.encode(autoStartOnCall, forKey: .autoStartOnCall)
        try c.encode(notifyOnCall, forKey: .notifyOnCall)
        try c.encode(appRules, forKey: .appRules)
        try c.encode(seenCallApps, forKey: .seenCallApps)
        try c.encode(suppressEcho, forKey: .suppressEcho)
        try c.encode(echoPriority, forKey: .echoPriority)
        try c.encode(echoSimilarity, forKey: .echoSimilarity)
        try c.encode(diarizationEnabled, forKey: .diarizationEnabled)
        try c.encode(maxSpeakers, forKey: .maxSpeakers)
        try c.encode(diarizationThreshold, forKey: .diarizationThreshold)
        try c.encode(askSpeakersOnImport, forKey: .askSpeakersOnImport)
        try c.encode(avoidBluetoothMic, forKey: .avoidBluetoothMic)
        try c.encode(callEndAction, forKey: .callEndAction)
        try c.encode(callEndDelaySeconds, forKey: .callEndDelaySeconds)
        try c.encode(continuousSegmentMinutes, forKey: .continuousSegmentMinutes)
        try c.encode(continuousTranscribeIncrementally, forKey: .continuousTranscribeIncrementally)
        try c.encode(dictationEnabled, forKey: .dictationEnabled)
        try c.encode(dictationHotKey, forKey: .dictationHotKey)
        try c.encode(dictationMode, forKey: .dictationMode)
        try c.encode(insertionMode, forKey: .insertionMode)
        try c.encode(dictationSound, forKey: .dictationSound)
        try c.encode(trimTrailingPeriod, forKey: .trimTrailingPeriod)
        try c.encode(livePreview, forKey: .livePreview)
        try c.encode(keepTextInClipboard, forKey: .keepTextInClipboard)
        try c.encode(llmProvider, forKey: .llmProvider)
        try c.encode(llmBaseURL, forKey: .llmBaseURL)
        try c.encode(llmModel, forKey: .llmModel)
        try c.encode(llmTemperature, forKey: .llmTemperature)
        try c.encode(llmTimeoutSeconds, forKey: .llmTimeoutSeconds)
        try c.encode(claudeCLIPath, forKey: .claudeCLIPath)
        try c.encode(postProcessEnabled, forKey: .postProcessEnabled)
        try c.encode(defaultPrompt, forKey: .defaultPrompt)
        try c.encode(defaultPresetID, forKey: .defaultPresetID)
        try c.encode(appPrompts, forKey: .appPrompts)
        try c.encode(postProcessUnlistedApps, forKey: .postProcessUnlistedApps)
        try c.encode(hudOpacity, forKey: .hudOpacity)
        try c.encodeIfPresent(hudPositionX, forKey: .hudPositionX)
        try c.encodeIfPresent(hudPositionY, forKey: .hudPositionY)
        try c.encode(archiveEnabled, forKey: .archiveEnabled)
        try c.encodeIfPresent(archiveFolderPath, forKey: .archiveFolderPath)
        try c.encode(archiveNotes, forKey: .archiveNotes)
        try c.encode(showMenuBarIcon, forKey: .showMenuBarIcon)
        try c.encode(reduceMotion, forKey: .reduceMotion)
        try c.encode(animatedBackground, forKey: .animatedBackground)
        try c.encode(accent, forKey: .accent)
        try c.encode(appearance, forKey: .appearance)
    }

    /// Автосохранение с задержкой, чтобы не писать файл на каждое движение слайдера.
    private func observe() {
        saveCancellable = objectWillChange
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] in self?.save() }
    }

    static func load() -> Settings {
        guard let data = try? Data(contentsOf: Container.settingsFile),
              let decoded = try? JSONDecoder().decode(Settings.self, from: data)
        else { return Settings() }
        return decoded
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: Container.settingsFile, options: .atomic)
    }

    /// Правило для программы: своё, если задано, иначе общие переключатели.
    func rule(forBundleID bundleID: String?) -> AppRule {
        if let bundleID, let rule = appRules[bundleID] { return rule }
        return AppRule(autoRecord: autoStartOnCall, notify: notifyOnCall)
    }

    func setRule(_ rule: AppRule, forBundleID bundleID: String) {
        appRules[bundleID] = rule
    }

    func clearRule(forBundleID bundleID: String) {
        appRules.removeValue(forKey: bundleID)
    }

    func noteSeenApp(bundleID: String, name: String) {
        guard seenCallApps[bundleID] != name else { return }
        seenCallApps[bundleID] = name
    }

    /// Программы для таблицы правил: зашитый список плюс замеченные вживую.
    var ruleCandidates: [(bundleID: String, name: String)] {
        var byID: [String: String] = [:]
        for app in KnownCallApps.all where byID[app.bundleID] == nil {
            byID[app.bundleID] = app.name
        }
        for (id, name) in seenCallApps { byID[id] = name }
        return byID
            .map { (bundleID: $0.key, name: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Собирает параметры движка для длинных записей.
    func transcriptionOptions(modelURL: URL, vadModelURL: URL?) -> WhisperOptions {
        WhisperOptions(
            modelURL: modelURL,
            language: language == "auto" ? nil : language,
            translateToEnglish: translateToEnglish,
            threads: threads,
            beamSize: beamSize,
            bestOf: 1,
            useGPU: useGPU,
            initialPrompt: vocabulary,
            vadModelURL: useVAD ? vadModelURL : nil
        )
    }

    /// Параметры для диктовки: важна скорость, поэтому жадный поиск и короткий контекст.
    func dictationOptions(modelURL: URL) -> WhisperOptions {
        WhisperOptions(
            modelURL: modelURL,
            language: language == "auto" ? nil : language,
            translateToEnglish: false,
            threads: threads,
            beamSize: dictationBeamSize,
            bestOf: 1,
            useGPU: useGPU,
            initialPrompt: vocabulary,
            vadModelURL: nil
        )
    }
}

/// Языки, которые предлагаются в интерфейсе. whisper знает ~99, но список
/// из сотни пунктов в выпадающем меню бесполезен — показываем частотные.
enum Languages {
    static let common: [(code: String, title: String)] = [
        ("auto", "Определять автоматически"),
        ("ru", "Русский"),
        ("en", "Английский"),
        ("uk", "Украинский"),
        ("de", "Немецкий"),
        ("fr", "Французский"),
        ("es", "Испанский"),
        ("it", "Итальянский"),
        ("pt", "Португальский"),
        ("pl", "Польский"),
        ("tr", "Турецкий"),
        ("kk", "Казахский"),
        ("hy", "Армянский"),
        ("ka", "Грузинский"),
        ("he", "Иврит"),
        ("ar", "Арабский"),
        ("zh", "Китайский"),
        ("ja", "Японский"),
        ("ko", "Корейский")
    ]

    static func title(for code: String) -> String {
        common.first { $0.code == code }?.title ?? code.uppercased()
    }
}
