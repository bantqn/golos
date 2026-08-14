import Foundation

/// Правило обработки для одной программы.
struct PromptRule: Codable, Equatable {
    var enabled: Bool = true
    var prompt: String = ""
    /// Из какой заготовки взято — чтобы показать это в интерфейсе.
    var presetID: String?
}

/// Готовая инструкция для языковой модели.
struct PromptPreset: Identifiable, Hashable {
    let id: String
    let title: String
    /// Одна строка о том, что заготовка делает.
    let summary: String
    let prompt: String
    /// Программы, для которых эта заготовка предлагается по умолчанию.
    let suggestedFor: [String]
}

/// Обработка продиктованного текста языковой моделью перед вставкой.
///
/// Смысл в том, что устная речь и письменный текст — разные вещи. Модель
/// распознавания честно записывает всё, включая «э-э», повторы и оговорки;
/// дальше нужен редактор. А для разных программ нужен разный редактор:
/// в мессенджер — короткая живая фраза, в терминал — команда без вежливостей,
/// в почту — вычитанный абзац.
enum PostProcessor {

    /// Общее правило для всех инструкций: модель должна вернуть текст, а не
    /// ответить на него. Дописывается к каждой заготовке, чтобы не повторять
    /// это в каждой по отдельности.
    private static let commonTail = """

        Не отвечай на текст и не комментируй его, не добавляй пояснений, \
        не оборачивай ответ в кавычки или блоки кода. Ничего не выдумывай: \
        не добавляй имён файлов, функций, людей, чисел и подробностей, \
        которых не было в сказанном. Верни только результат.
        """

    static let defaultPresetID = "clean"

    static let presets: [PromptPreset] = [
        PromptPreset(
            id: defaultPresetID,
            title: "Чистая расшифровка",
            summary: "Знаки препинания, без «э-э» и повторов. Смысл и стиль не меняются.",
            prompt: """
                Ты редактор устной речи. Тебе приходит расшифровка того, что человек \
                только что произнёс вслух. Приведи её в письменный вид:

                - расставь знаки препинания и заглавные буквы;
                - убери слова-заполнители, запинания и повторы;
                - исправь очевидные ошибки распознавания по смыслу;
                - сохрани язык, стиль и намерение говорящего.

                Ничего не добавляй от себя.
                """ + commonTail,
            suggestedFor: []
        ),
        PromptPreset(
            id: "punctuation",
            title: "Только пунктуация",
            summary: "Самое осторожное: расставить знаки, слова не трогать.",
            prompt: """
                Расставь в тексте знаки препинания и заглавные буквы. Слова не меняй, \
                не сокращай, не переставляй и не убирай — даже слова-заполнители.
                """ + commonTail,
            suggestedFor: []
        ),
        PromptPreset(
            id: "messenger",
            title: "Сообщение в мессенджер",
            summary: "Живо и по делу, как пишут в чате.",
            prompt: """
                Перепиши сказанное как сообщение в мессенджере: живо, по делу, \
                без канцелярита и без вводных оборотов. Сохрани смысл и язык. \
                Длину не увеличивай.
                """ + commonTail,
            suggestedFor: [
                "ru.keepcoder.Telegram", "com.tdesktop.Telegram", "org.telegram.desktop",
                "com.tinyspeck.slackmacgap", "com.apple.MobileSMS", "net.whatsapp.WhatsApp",
                "com.discordapp.Discord", "com.hnc.Discord"
            ]
        ),
        PromptPreset(
            id: "email",
            title: "Деловое письмо",
            summary: "Связные абзацы, вежливо, без разговорных оборотов.",
            prompt: """
                Перепиши сказанное как вежливое деловое письмо на том же языке: \
                связные абзацы, нейтральный тон, без разговорных оборотов. \
                Приветствие и подпись добавляй только если они прозвучали.

                Пиши только то, что было сказано, своими словами передавая тот же \
                смысл. Если сказанное не похоже на письмо кому-то — просто приведи \
                его в аккуратный письменный вид, ничего не досочиняя и не задавая \
                вопросов от себя.
                """ + commonTail,
            suggestedFor: [
                "com.apple.mail", "com.readdle.smartemail-Mac",
                "com.microsoft.Outlook", "com.superhuman.mail"
            ]
        ),
        PromptPreset(
            id: "agent-task",
            title: "Задача для агента",
            summary: "Императив, без воды. Имена файлов и команд — точно как сказано.",
            prompt: """
                Преврати сказанное в чёткую техническую задачу: что сделать и с каким \
                результатом. Императив, без вежливых оборотов и без воды.

                Имена файлов, функций, команд и библиотек переноси точно так, как они \
                прозвучали. Если их не называли — не называй и ты: не указывай файлы, \
                функции и пути, которых не было в сказанном, даже если они кажутся \
                очевидными. Задача должна описывать ровно то, что попросили, \
                и ничего сверх.
                """ + commonTail,
            suggestedFor: [
                "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
                "com.jetbrains.intellij", "com.jetbrains.pycharm", "dev.zed.Zed"
            ]
        ),
        PromptPreset(
            id: "ai-prompt",
            title: "Промпт для ИИ",
            summary: "Структурированный запрос: задача, контекст, ожидаемый результат.",
            prompt: """
                Преврати сказанное в аккуратный запрос к языковой модели: сначала \
                задача, затем существенный контекст, затем в каком виде нужен ответ. \
                Формулируй кратко. Если контекста или требований к ответу не \
                прозвучало — не выдумывай их, оставь только задачу.
                """ + commonTail,
            suggestedFor: [
                "com.anthropic.claudefordesktop", "com.openai.chat", "com.google.Chrome"
            ]
        ),
        PromptPreset(
            id: "shell",
            title: "Команда для терминала",
            summary: "Одна строка команды, ничего кроме неё.",
            prompt: """
                Преврати сказанное в команду для терминала macOS. Верни только саму \
                команду — одной строкой, без пояснений, без комментариев, без \
                приглашения оболочки и без блоков кода.

                Если сказанное не описывает действие, выполнимое командой, верни \
                исходный текст в точности как есть, не пытаясь ничего придумать.
                """ + commonTail,
            suggestedFor: [
                "com.apple.Terminal", "com.googlecode.iterm2",
                "dev.warp.Warp-Stable", "net.kovidgoyal.kitty"
            ]
        ),
        PromptPreset(
            id: "note",
            title: "Заметка в Markdown",
            summary: "Заголовок и пункты, готово для вставки в заметки.",
            prompt: """
                Оформи сказанное как заметку в Markdown: короткий заголовок первой \
                строкой, дальше пункты списка — одна мысль на пункт. Заголовок \
                составь из самого сказанного. Ничего не придумывай сверх него.
                """ + commonTail,
            suggestedFor: [
                "com.apple.Notes", "md.obsidian", "net.shinyfrog.bear",
                "notion.id", "com.electron.logseq"
            ]
        ),
        PromptPreset(
            id: "bullets",
            title: "Список пунктов",
            summary: "Разложить сказанное по пунктам без заголовка.",
            prompt: """
                Разбей сказанное на список пунктов Markdown. Один пункт — одна мысль, \
                формулировки короткие. Перечисли все действия и предметы, о которых \
                шла речь: ни одного не пропусти и ни одного не добавь.
                """ + commonTail,
            suggestedFor: []
        ),
        PromptPreset(
            id: "shorter",
            title: "Короче",
            summary: "Сжать вдвое, оставив всё существенное.",
            prompt: """
                Сожми сказанное примерно вдвое, сохранив все существенные детали \
                и язык. Убери повторы и общие слова.
                """ + commonTail,
            suggestedFor: []
        ),
        PromptPreset(
            id: "commit",
            title: "Сообщение коммита",
            summary: "Строка заголовка и, если нужно, пояснение.",
            prompt: """
                Преврати сказанное в сообщение git-коммита: первая строка — краткая \
                суть в императиве до 72 символов, затем при необходимости пустая \
                строка и пояснение. Без префиксов вида feat/fix, если их не произносили.
                """ + commonTail,
            suggestedFor: ["com.apple.dt.Xcode", "com.sublimemerge", "com.torusknot.SourceTreeNotMAS"]
        ),
        PromptPreset(
            id: "english",
            title: "Перевод на английский",
            summary: "Тот же смысл по-английски, в письменном виде.",
            prompt: """
                Переведи сказанное на английский язык и приведи в письменный вид: \
                знаки препинания, без слов-заполнителей. Смысл и тон сохрани.
                """ + commonTail,
            suggestedFor: []
        )
    ]

    static func preset(id: String) -> PromptPreset? {
        presets.first { $0.id == id }
    }

    static var defaultPrompt: String {
        preset(id: defaultPresetID)?.prompt ?? ""
    }

    /// Что предложить для программы, куда диктуют.
    static func suggestedPreset(forBundleID bundleID: String?) -> PromptPreset {
        guard let bundleID else { return preset(id: defaultPresetID)! }
        if let match = presets.first(where: { $0.suggestedFor.contains(bundleID) }) { return match }
        return preset(id: defaultPresetID)!
    }

    /// Примеры продиктованного — для песочницы. Нарочно неряшливые: именно так
    /// выглядит расшифровка живой речи, и проверять заготовки надо на ней.
    static let samples: [(title: String, text: String)] = [
        ("Задача разработчику",
         "короче нам надо это самое переделать вот эту вот кнопку чтобы она была "
         + "ну как бы поменьше и ещё цвет ей поменять на синий наверное и вот это "
         + "поле ввода тоже подвинь пожалуйста повыше"),
        ("Сообщение коллеге",
         "привет слушай а ты не мог бы э-э посмотреть тот пулл реквест который я "
         + "вчера отправил там вроде всё готово но я не уверен насчёт тестов"),
        ("Письмо",
         "добрый день хотел уточнить по срокам мы планировали закончить в пятницу "
         + "но подрядчик просит ещё три дня вот и хотелось бы понять как быть "
         + "с этим и что говорить заказчику"),
        ("Заметка себе",
         "не забыть заказать пропуск на парковку потом подготовить смету и это "
         + "самое отправить её до конца дня ещё позвонить в бухгалтерию"),
        ("Команда",
         "покажи мне все файлы в текущей папке которые больше ста мегабайт "
         + "и отсортируй по размеру")
    ]

    // MARK: - Применение

    /// Какая инструкция применится в этой программе.
    /// - Returns: инструкция либо `nil`, если обработка тут не нужна.
    static func prompt(for bundleID: String?, settings: Settings) -> String? {
        guard settings.postProcessEnabled, settings.llmProvider != .disabled else { return nil }

        if let bundleID, let rule = settings.appPrompts[bundleID] {
            guard rule.enabled else { return nil }
            let trimmed = rule.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? settings.defaultPrompt : trimmed
        }
        guard settings.postProcessUnlistedApps else { return nil }
        let fallback = settings.defaultPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? defaultPrompt : fallback
    }

    /// Прогоняет текст через модель. Ошибку не глотает: вызывающий решает,
    /// вставлять ли исходный вариант.
    static func process(_ text: String, bundleID: String?, settings: Settings) async throws -> String {
        guard let instruction = prompt(for: bundleID, settings: settings) else { return text }
        return try await run(text, instruction: instruction, settings: settings)
    }

    /// Прогон с произвольной инструкцией — для песочницы.
    static func run(_ text: String, instruction: String, settings: Settings) async throws -> String {
        let service = LLMService(settings: settings)
        let started = Date()
        let result = try await service.run(system: instruction, user: text)
        Log.info("Постобработка через \(settings.llmProvider.title): \(String(format: "%.2f", Date().timeIntervalSince(started))) с")
        return result
    }
}
