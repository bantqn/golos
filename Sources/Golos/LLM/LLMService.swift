import Foundation

/// Откуда брать языковую модель для обработки текста.
enum LLMProvider: String, Codable, CaseIterable, Identifiable {
    case disabled
    case ollama
    case lmStudio
    case openAICompatible
    case openAI
    case anthropic
    case claudeCLI

    var id: String { rawValue }

    var title: String {
        switch self {
        case .disabled: return "Выключено"
        case .ollama: return "Ollama (локально)"
        case .lmStudio: return "LM Studio (локально)"
        case .openAICompatible: return "Совместимый с OpenAI"
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .claudeCLI: return "Claude CLI"
        }
    }

    var explanation: String {
        switch self {
        case .disabled:
            return "Текст вставляется как распознан, без обработки."
        case .ollama:
            return "Локальный Ollama. Ничего не уходит из машины."
        case .lmStudio:
            return "Локальный сервер LM Studio: ничего не уходит из машины. "
                + "Сервер должен быть запущен — в самом LM Studio на вкладке Developer "
                + "или командой lms server start. Модель он подгружает по требованию."
        case .openAICompatible:
            return "Любой сервис с API как у OpenAI: Ollama Cloud, OpenRouter, свой сервер. Нужен адрес и ключ."
        case .openAI:
            return "api.openai.com по ключу API. Подписка ChatGPT здесь не работает — это отдельная платная услуга."
        case .anthropic:
            return "api.anthropic.com по ключу API."
        case .claudeCLI:
            return "Вызов установленного claude в режиме -p. Использует авторизацию, уже настроенную в CLI, — ключ не нужен."
        }
    }

    /// Локальные провайдеры не отправляют текст за пределы машины.
    var isLocal: Bool {
        switch self {
        case .ollama, .lmStudio: return true
        case .disabled: return true
        case .openAICompatible, .openAI, .anthropic, .claudeCLI: return false
        }
    }

    var needsAPIKey: Bool {
        switch self {
        case .openAI, .anthropic, .openAICompatible: return true
        case .disabled, .ollama, .lmStudio, .claudeCLI: return false
        }
    }

    /// Адрес по умолчанию.
    ///
    /// Именно 127.0.0.1, а не localhost: Ollama слушает только IPv4, и по имени
    /// localhost запрос может уйти на ::1 и не дойти.
    var defaultBaseURL: String {
        switch self {
        case .ollama: return "http://127.0.0.1:11434"
        case .lmStudio: return "http://127.0.0.1:1234"
        case .openAI: return "https://api.openai.com"
        case .anthropic: return "https://api.anthropic.com"
        case .openAICompatible: return ""
        case .disabled, .claudeCLI: return ""
        }
    }

    var defaultModel: String {
        switch self {
        case .ollama: return "qwen3:8b"
        case .lmStudio: return ""
        case .openAI: return "gpt-4o-mini"
        case .anthropic: return "claude-sonnet-4-5"
        case .openAICompatible: return ""
        case .disabled, .claudeCLI: return ""
        }
    }
}

enum LLMError: LocalizedError {
    case notConfigured(String)
    case http(Int, String)
    case emptyResponse
    case cliFailed(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let what): return "Обработка не настроена: \(what)"
        case .http(let code, let body):
            let short = body.count > 300 ? String(body.prefix(300)) + "…" : body
            return "Сервис ответил ошибкой \(code): \(short)"
        case .emptyResponse: return "Сервис вернул пустой ответ"
        case .cliFailed(let message): return "claude не справился: \(message)"
        case .transport(let message): return "Не удалось связаться с сервисом: \(message)"
        }
    }
}

/// Обращение к языковой модели.
///
/// Три пути на все провайдеры: формат OpenAI (он же у Ollama, LM Studio и
/// большинства совместимых сервисов), формат Anthropic и вызов claude как
/// подпроцесса. Больше кода не нужно — различия сводятся к адресу и заголовкам.
struct LLMService {

    let provider: LLMProvider
    let baseURL: String
    let model: String
    let temperature: Double
    let timeout: TimeInterval
    let claudePath: String
    let apiKey: String?

    init(settings: Settings) {
        provider = settings.llmProvider
        let configured = settings.llmBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        baseURL = configured.isEmpty ? settings.llmProvider.defaultBaseURL : configured
        let configuredModel = settings.llmModel.trimmingCharacters(in: .whitespacesAndNewlines)
        model = configuredModel.isEmpty ? settings.llmProvider.defaultModel : configuredModel
        temperature = settings.llmTemperature
        timeout = TimeInterval(settings.llmTimeoutSeconds)
        claudePath = settings.claudeCLIPath.isEmpty ? "claude" : settings.claudeCLIPath
        apiKey = Keychain.get(settings.llmProvider.rawValue)
    }

    /// Прогоняет текст через модель с заданной инструкцией.
    func run(system: String, user: String) async throws -> String {
        switch provider {
        case .disabled:
            throw LLMError.notConfigured("не выбран провайдер")
        case .claudeCLI:
            return try await runCLI(system: system, user: user)
        case .anthropic:
            return try await runAnthropic(system: system, user: user)
        case .ollama, .lmStudio, .openAI, .openAICompatible:
            return try await runOpenAICompatible(system: system, user: user)
        }
    }

    /// Проверка связи: возвращает список моделей, если сервис их отдаёт.
    func availableModels() async throws -> [String] {
        switch provider {
        case .ollama, .lmStudio, .openAI, .openAICompatible:
            guard let url = URL(string: baseURL + "/v1/models") else {
                throw LLMError.notConfigured("неверный адрес")
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = timeout
            if let apiKey, !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            let (data, response) = try await send(request)
            try check(response, data: data)

            struct Models: Decodable {
                struct Item: Decodable { let id: String }
                let data: [Item]
            }
            let decoded = try JSONDecoder().decode(Models.self, from: data)
            return decoded.data.map(\.id).sorted()

        case .anthropic, .claudeCLI, .disabled:
            return []
        }
    }

    // MARK: - Формат OpenAI

    private func runOpenAICompatible(system: String, user: String) async throws -> String {
        guard !baseURL.isEmpty, let url = URL(string: baseURL + "/v1/chat/completions") else {
            throw LLMError.notConfigured("не задан адрес сервиса")
        }
        guard !model.isEmpty else { throw LLMError.notConfigured("не задана модель") }
        if provider.needsAPIKey, apiKey?.isEmpty != false {
            throw LLMError.notConfigured("не задан ключ API")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let body: [String: Any] = [
            "model": model,
            "temperature": temperature,
            "stream": false,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await send(request)
        try check(response, data: data)

        struct Reply: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message?
            }
            let choices: [Choice]
        }
        let decoded = try JSONDecoder().decode(Reply.self, from: data)
        let text = decoded.choices.first?.message?.content ?? ""
        return try cleaned(text)
    }

    // MARK: - Формат Anthropic

    private func runAnthropic(system: String, user: String) async throws -> String {
        guard let key = apiKey, !key.isEmpty else {
            throw LLMError.notConfigured("не задан ключ API")
        }
        guard let url = URL(string: baseURL + "/v1/messages") else {
            throw LLMError.notConfigured("неверный адрес")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
            "temperature": temperature,
            "system": system,
            "messages": [["role": "user", "content": user]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await send(request)
        try check(response, data: data)

        struct Reply: Decodable {
            struct Block: Decodable { let type: String; let text: String? }
            let content: [Block]
        }
        let decoded = try JSONDecoder().decode(Reply.self, from: data)
        let text = decoded.content.compactMap { $0.type == "text" ? $0.text : nil }.joined()
        return try cleaned(text)
    }

    // MARK: - Claude CLI

    /// Запускает `claude -p` и читает ответ со стандартного вывода.
    /// Ключ не нужен: CLI пользуется своей собственной авторизацией.
    private func runCLI(system: String, user: String) async throws -> String {
        let executable = try resolveExecutable(claudePath)

        let process = Process()
        process.executableURL = executable
        process.arguments = ["-p", "--append-system-prompt", system]

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            throw LLMError.cliFailed("не удалось запустить \(executable.path): \(error.localizedDescription)")
        }

        input.fileHandleForWriting.write(Data(user.utf8))
        try? input.fileHandleForWriting.close()

        // Читаем до конца, затем ждём выхода: иначе процесс может встать
        // на заполненном буфере вывода.
        let outData = output.fileHandleForReading.readDataToEndOfFile()
        let errData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "код \(process.terminationStatus)"
            throw LLMError.cliFailed(message.isEmpty ? "код \(process.terminationStatus)" : message)
        }
        return try cleaned(String(data: outData, encoding: .utf8) ?? "")
    }

    private func resolveExecutable(_ path: String) throws -> URL {
        if path.hasPrefix("/") {
            guard FileManager.default.isExecutableFile(atPath: path) else {
                throw LLMError.cliFailed("файл \(path) не запускается")
            }
            return URL(fileURLWithPath: path)
        }
        // Приложения запускаются с урезанным PATH, поэтому ищем сами
        // в обычных местах установки.
        let candidates = [
            "/opt/homebrew/bin/", "/usr/local/bin/", "/usr/bin/",
            NSHomeDirectory() + "/.local/bin/", NSHomeDirectory() + "/.claude/local/"
        ]
        for directory in candidates {
            let candidate = directory + path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        throw LLMError.cliFailed("не нашёл \(path). Укажите полный путь в настройках")
    }

    // MARK: - Общее

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch {
            throw LLMError.transport(error.localizedDescription)
        }
    }

    private func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.http(http.statusCode, body)
        }
    }

    /// Убирает у ответа обёртки, которые модели любят добавлять сами.
    ///
    /// Две привычки, встреченные на практике: рассуждения в теге `<think>`
    /// у моделей вроде qwen3 и обрамление ответа в блок кода, хотя просили
    /// просто текст. Причём блок бывает не в начале ответа, а после
    /// собственного заголовка модели, — поэтому ищем его где угодно.
    private func cleaned(_ text: String) throws -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if let range = result.range(of: "</think>") {
            result = String(result[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        result = unwrapCodeFence(result)

        guard !result.isEmpty else { throw LLMError.emptyResponse }
        return result
    }

    /// Достаёт содержимое блока кода, если ответ сводится к нему.
    private func unwrapCodeFence(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let fenceIndices = lines.indices.filter {
            lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("```")
        }
        guard fenceIndices.count >= 2 else {
            // Непарная ограда — просто выкидываем её строку.
            guard fenceIndices.count == 1 else { return text }
            var kept = lines
            kept.remove(at: fenceIndices[0])
            return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let inner = lines[(fenceIndices[0] + 1)..<fenceIndices[1]]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inner.isEmpty else { return text }

        // Всё вне блока — вводные слова модели. Если содержимое блока весомее,
        // берём его: просили результат, а не рассказ о нём.
        let outside = (lines[..<fenceIndices[0]] + lines[(fenceIndices[1] + 1)...])
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return outside.count <= inner.count ? inner : text
    }
}
