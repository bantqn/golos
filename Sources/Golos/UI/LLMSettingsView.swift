import SwiftUI
import AppKit

/// Настройки обработки текста языковой моделью и промпты по программам.
struct LLMSettingsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: Settings

    @State private var apiKey: String = ""
    @State private var keyStored = false
    @State private var checkResult: String?
    @State private var checkOK = false
    @State private var isChecking = false
    @State private var models: [String] = []
    @State private var editingBundleID: String?

    var body: some View {
        VStack(spacing: 18) {
            providerCard
            appRulesCard
            PromptLabView()
        }
        .onAppear(perform: loadKeyState)
        .onChange(of: settings.llmProvider) { _, _ in
            loadKeyState()
            models = []
            checkResult = nil
        }
    }

    // MARK: - Провайдер

    private var providerCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 15) {
                SectionTitle(text: "Обработка текста моделью",
                             subtitle: "Распознавание даёт устную речь как есть. Модель приводит её в письменный вид")

                Picker("Провайдер", selection: $settings.llmProvider) {
                    ForEach(LLMProvider.allCases) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                .frame(maxWidth: 320)

                Text(settings.llmProvider.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !settings.llmProvider.isLocal && settings.llmProvider != .disabled {
                    Label("Текст диктовки будет уходить наружу этому сервису. Всё остальное в приложении "
                          + "по-прежнему считается локально.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if settings.llmProvider != .disabled {
                    Divider().opacity(0.4)
                    connectionFields
                }
            }
        }
    }

    @ViewBuilder
    private var connectionFields: some View {
        if settings.llmProvider == .claudeCLI {
            LabeledContent("Путь к claude") {
                TextField(settings.claudeCLIPath, text: $settings.claudeCLIPath)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
            }
            Text("Оставьте «claude», если он в обычном месте. Приложения запускаются с урезанным PATH, "
                 + "поэтому поиск идёт по /opt/homebrew/bin, /usr/local/bin и ~/.local/bin. "
                 + "Авторизация берётся из самого CLI — если он разлогинен, обработка не сработает.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            LabeledContent("Адрес") {
                TextField(settings.llmProvider.defaultBaseURL, text: $settings.llmBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
            }

            HStack(alignment: .firstTextBaseline) {
                Text("Модель").frame(width: 100, alignment: .leading)
                if models.isEmpty {
                    TextField(settings.llmProvider.defaultModel, text: $settings.llmModel)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 300)
                } else {
                    Picker("", selection: $settings.llmModel) {
                        ForEach(models, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 300)
                }
                Spacer()
            }

            if settings.llmProvider.needsAPIKey {
                HStack(alignment: .firstTextBaseline) {
                    Text("Ключ API").frame(width: 100, alignment: .leading)
                    SecureField(keyStored ? "сохранён в связке ключей" : "вставьте ключ", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 300)
                        .onSubmit(saveKey)
                    Button("Сохранить", action: saveKey)
                        .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    if keyStored {
                        Button("Удалить", action: removeKey)
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.danger)
                    }
                }
                Text("Ключ кладётся в связку ключей macOS, а не в файл настроек: настройки — обычный "
                     + "читаемый JSON, секретам там не место.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Температура: \(String(format: "%.1f", settings.llmTemperature))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $settings.llmTemperature, in: 0...1)
                    .frame(width: 160)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Ожидание: \(settings.llmTimeoutSeconds) с")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { Double(settings.llmTimeoutSeconds) },
                    set: { settings.llmTimeoutSeconds = Int($0) }
                ), in: 5...180, step: 5)
                .frame(width: 160)
            }
            Spacer()
        }

        if settings.llmProvider == .lmStudio || settings.llmProvider == .ollama {
            Text("Первый запрос после простоя дольше остальных: сервер подгружает модель "
                 + "в память. Дальше ответы приходят за доли секунды, пока модель не выгрузится.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        HStack(spacing: 10) {
            Button(isChecking ? "Проверяю…" : "Проверить связь", action: check)
                .buttonStyle(AccentButtonStyle(accent: settings.accent, prominent: false))
                .disabled(isChecking)
            if let checkResult {
                Label(checkResult, systemImage: checkOK ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(checkOK ? Theme.success : Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    // MARK: - Обработка по программам

    /// Главная таблица: строка на программу. Пресет здесь — свойство программы,
    /// а не отдельная сущность, которую надо куда-то привязывать: вы выбираете
    /// программу и говорите, что делать с текстом именно в ней. Отдельный
    /// вариант «Без обработки» нужен, потому что в половине программ никакая
    /// правка не нужна — там диктуют уже готовый текст.
    private var appRulesCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Обработка по программам")
                            .font(.system(.headline, design: .rounded))
                        Text("Для каждой программы своё правило. Инструкцию любого пресета можно править.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $settings.postProcessEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(settings.llmProvider == .disabled)
                }

                if settings.llmProvider == .disabled {
                    Label("Сначала выберите провайдера выше.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                }

                Text("Обработка добавляет задержку между «отпустил клавиши» и «текст вставился»: "
                     + "локальная модель — обычно около секунды, внешняя — как ответит сеть. "
                     + "Если модель не ответит или ошибётся, вставится исходный распознанный текст.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().opacity(0.4)

                defaultRow
                Divider().opacity(0.3)

                ForEach(sortedPrompts, id: \.bundleID) { entry in
                    appRow(bundleID: entry.bundleID, rule: entry.rule)
                    Divider().opacity(0.3)
                }

                HStack {
                    Menu("Добавить программу") {
                        ForEach(addableApps, id: \.bundleID) { app in
                            Button {
                                // Сразу ставим пресет, подходящий этой программе:
                                // в мессенджер и в терминал нужны разные вещи.
                                let suggested = PostProcessor.suggestedPreset(forBundleID: app.bundleID)
                                settings.appPrompts[app.bundleID] = PromptRule(
                                    enabled: true, prompt: suggested.prompt, presetID: suggested.id)
                                editingBundleID = app.bundleID
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(app.name)
                                    Text(PostProcessor.suggestedPreset(forBundleID: app.bundleID).title)
                                        .font(.caption)
                                }
                            }
                        }
                    }
                    .frame(width: 190)
                    .disabled(addableApps.isEmpty)
                    Spacer()
                }
            }
        }
    }

    /// Строка «все остальные программы» — то же правило, но без удаления.
    private var defaultRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Все остальные программы")
                        .font(.system(.callout, design: .rounded, weight: .medium))
                    Text("правило по умолчанию")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                presetMenu(
                    title: settings.postProcessUnlistedApps
                        ? (PostProcessor.preset(id: settings.defaultPresetID)?.title ?? "Своя инструкция")
                        : noProcessingTitle,
                    isOff: !settings.postProcessUnlistedApps,
                    onOff: { settings.postProcessUnlistedApps = false },
                    onPreset: { preset in
                        settings.postProcessUnlistedApps = true
                        settings.defaultPresetID = preset.id
                        settings.defaultPrompt = preset.prompt
                    }
                )

                expandButton(for: "__default__")
            }

            if editingBundleID == "__default__", settings.postProcessUnlistedApps {
                promptField(text: $settings.defaultPrompt)
            }
        }
        .padding(.vertical, 3)
    }

    private func appRow(bundleID: String, rule: PromptRule) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: "app")
                    .font(.system(size: 12))
                    .foregroundStyle(rule.enabled ? Theme.primary(settings.accent) : .secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(appName(bundleID))
                        .font(.system(.callout, design: .rounded, weight: .medium))
                    Text(bundleID)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer()

                presetMenu(
                    title: rule.enabled
                        ? (PostProcessor.preset(id: rule.presetID ?? "")?.title ?? "Своя инструкция")
                        : noProcessingTitle,
                    isOff: !rule.enabled,
                    onOff: {
                        settings.appPrompts[bundleID] = PromptRule(
                            enabled: false, prompt: rule.prompt, presetID: rule.presetID)
                    },
                    onPreset: { preset in
                        settings.appPrompts[bundleID] = PromptRule(
                            enabled: true, prompt: preset.prompt, presetID: preset.id)
                    }
                )

                expandButton(for: bundleID)

                Button {
                    settings.appPrompts.removeValue(forKey: bundleID)
                    if editingBundleID == bundleID { editingBundleID = nil }
                } label: {
                    Image(systemName: "trash").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.danger)
                .help("Убрать правило — программа вернётся к правилу по умолчанию")
            }

            if editingBundleID == bundleID, rule.enabled {
                promptField(text: Binding(
                    get: { rule.prompt },
                    set: {
                        settings.appPrompts[bundleID] = PromptRule(
                            enabled: rule.enabled, prompt: $0, presetID: rule.presetID)
                    }
                ))
            }
        }
        .padding(.vertical, 3)
    }

    private var noProcessingTitle: String { "Без обработки" }

    private func presetMenu(title: String, isOff: Bool,
                            onOff: @escaping () -> Void,
                            onPreset: @escaping (PromptPreset) -> Void) -> some View {
        Menu {
            Button("Без обработки", action: onOff)
            Divider()
            ForEach(PostProcessor.presets) { preset in
                Button {
                    onPreset(preset)
                } label: {
                    VStack(alignment: .leading) {
                        Text(preset.title)
                        Text(preset.summary).font(.caption)
                    }
                }
            }
        } label: {
            Text(title)
                .font(.system(.caption, design: .rounded, weight: .medium))
                .foregroundStyle(isOff ? .secondary : Theme.primary(settings.accent))
        }
        .frame(width: 170, alignment: .trailing)
    }

    private func expandButton(for key: String) -> some View {
        Button {
            editingBundleID = editingBundleID == key ? nil : key
        } label: {
            Image(systemName: editingBundleID == key ? "chevron.up" : "chevron.down")
                .font(.caption2)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Показать и поправить инструкцию")
    }

    private func promptField(text: Binding<String>) -> some View {
        TextEditor(text: text)
            .font(.callout)
            .frame(height: 110)
            .scrollContentBackground(.hidden)
            .padding(8)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
    }

    // MARK: - Данные

    private var sortedPrompts: [(bundleID: String, rule: PromptRule)] {
        settings.appPrompts
            .map { (bundleID: $0.key, rule: $0.value) }
            .sorted { appName($0.bundleID).localizedCaseInsensitiveCompare(appName($1.bundleID)) == .orderedAscending }
    }

    /// Программы, которые сейчас запущены, — из них удобно выбирать.
    private var addableApps: [(bundleID: String, name: String)] {
        let running = NSWorkspace.shared.runningApplications.compactMap { app -> (String, String)? in
            guard app.activationPolicy == .regular,
                  let id = app.bundleIdentifier,
                  id != Bundle.main.bundleIdentifier,
                  settings.appPrompts[id] == nil
            else { return nil }
            return (id, app.localizedName ?? id)
        }
        var seen = Set<String>()
        return running
            .filter { seen.insert($0.0).inserted }
            .map { (bundleID: $0.0, name: $0.1) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func appName(_ bundleID: String) -> String {
        if let known = KnownCallApps.all.first(where: { $0.bundleID == bundleID }) { return known.name }
        if let seen = settings.seenCallApps[bundleID] { return seen }
        if let running = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == bundleID })?.localizedName { return running }
        return bundleID
    }

    // MARK: - Действия

    private func loadKeyState() {
        keyStored = Keychain.has(settings.llmProvider.rawValue)
        apiKey = ""
    }

    private func saveKey() {
        Keychain.set(apiKey, for: settings.llmProvider.rawValue)
        apiKey = ""
        keyStored = Keychain.has(settings.llmProvider.rawValue)
        env.banner = .init(text: "Ключ сохранён в связке ключей", kind: .success)
    }

    private func removeKey() {
        Keychain.remove(settings.llmProvider.rawValue)
        keyStored = false
        apiKey = ""
    }

    private func check() {
        isChecking = true
        checkResult = nil
        let service = LLMService(settings: settings)

        Task { @MainActor in
            defer { isChecking = false }

            // Сначала пробуем получить список моделей — это заодно проверяет адрес и ключ.
            if let list = try? await service.availableModels(), !list.isEmpty {
                models = list
                if settings.llmModel.isEmpty { settings.llmModel = list.first ?? "" }
            }

            do {
                let reply = try await service.run(
                    system: "Отвечай одним словом, без знаков препинания.",
                    user: "Скажи: готово"
                )
                checkOK = true
                checkResult = "Ответ получен: \(reply.prefix(60))"
            } catch {
                checkOK = false
                checkResult = error.localizedDescription
            }
        }
    }
}
