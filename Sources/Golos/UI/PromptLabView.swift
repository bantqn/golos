import SwiftUI
import AppKit

/// Песочница для инструкций постобработки.
///
/// Смысл в том, что вслепую промпт не настроить: разница между «убери
/// заполнители» и «перепиши как сообщение» видна только на живом тексте.
/// Здесь можно взять неряшливую расшифровку, поправить инструкцию и сразу
/// посмотреть, что вернёт модель — не диктуя каждый раз заново.
struct PromptLabView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: Settings

    /// Для какой программы правим инструкцию. `nil` — инструкция по умолчанию.
    @State private var targetBundleID: String?
    @State private var presetID: String = PostProcessor.defaultPresetID
    @State private var promptText: String = ""
    @State private var sampleText: String = PostProcessor.samples.first?.text ?? ""
    @State private var result: String = ""
    @State private var errorText: String?
    @State private var elapsed: TimeInterval?
    @State private var isRunning = false
    @State private var loaded = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                header
                Divider().opacity(0.4)
                targetRow
                promptEditor
                Divider().opacity(0.4)
                comparison
                actions
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            loadPrompt(for: targetBundleID)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Проверка инструкций")
                .font(.system(.headline, design: .rounded))
            Text("Возьмите пример продиктованного, поправьте инструкцию и посмотрите, "
                 + "что вернёт модель. Ничего не диктуя и не рискуя вставить мусор в чужое окно.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Для какой программы

    private var targetRow: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                Text("Настраиваю для")
                    .font(.system(.callout, design: .rounded, weight: .medium))

                Menu(targetTitle) {
                    Button("Инструкции по умолчанию") { switchTarget(nil) }
                    if !settings.appPrompts.isEmpty {
                        Divider()
                        Section("С своим правилом") {
                            ForEach(existingTargets, id: \.bundleID) { item in
                                Button(item.name) { switchTarget(item.bundleID) }
                            }
                        }
                    }
                    Divider()
                    Section("Запущенные программы") {
                        ForEach(runningApps, id: \.bundleID) { item in
                            Button(item.name) { switchTarget(item.bundleID) }
                        }
                    }
                }
                .frame(maxWidth: 260)

                Spacer()

                Menu("Заготовка") {
                    ForEach(PostProcessor.presets) { preset in
                        Button {
                            presetID = preset.id
                            promptText = preset.prompt
                        } label: {
                            VStack(alignment: .leading) {
                                Text(preset.title)
                                Text(preset.summary).font(.caption)
                            }
                        }
                    }
                }
                .frame(width: 150)
            }

            if let summary = PostProcessor.preset(id: presetID)?.summary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if let bundleID = targetBundleID {
                let suggested = PostProcessor.suggestedPreset(forBundleID: bundleID)
                if suggested.id != presetID {
                    Button {
                        presetID = suggested.id
                        promptText = suggested.prompt
                    } label: {
                        Label("Для этой программы обычно подходит «\(suggested.title)»",
                              systemImage: "wand.and.stars")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.primary(settings.accent))
                }
            }
        }
    }

    private var targetTitle: String {
        guard let bundleID = targetBundleID else { return "Все программы (по умолчанию)" }
        return appName(bundleID)
    }

    // MARK: - Инструкция

    private var promptEditor: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Инструкция модели")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $promptText)
                .font(.callout)
                .frame(height: 110)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
        }
    }

    // MARK: - До и после

    private var comparison: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Как продиктовано")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Menu("Примеры") {
                        ForEach(PostProcessor.samples, id: \.title) { sample in
                            Button(sample.title) { sampleText = sample.text }
                        }
                    }
                    .frame(width: 110)
                }
                TextEditor(text: $sampleText)
                    .font(.callout)
                    .frame(height: 130)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Что вернула модель")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let elapsed {
                        Text("\(String(format: "%.1f", elapsed)) с")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    if !result.isEmpty {
                        Button {
                            TextInjector.copyToClipboard(result)
                            env.banner = .init(text: "Скопировано", kind: .success)
                        } label: {
                            Image(systemName: "doc.on.doc").font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }

                ScrollView {
                    Group {
                        if let errorText {
                            Label(errorText, systemImage: "exclamationmark.triangle.fill")
                                .font(.callout)
                                .foregroundStyle(Theme.danger)
                        } else if result.isEmpty {
                            Text(isRunning ? "Считаю…" : "Нажмите «Прогнать».")
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                        } else {
                            Text(result)
                                .font(.callout)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .frame(height: 130)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
            }
        }
    }

    // MARK: - Кнопки

    private var actions: some View {
        HStack(spacing: 10) {
            Button(isRunning ? "Считаю…" : "Прогнать") { run() }
                .buttonStyle(AccentButtonStyle(accent: settings.accent))
                .disabled(isRunning || settings.llmProvider == .disabled
                          || promptText.trimmingCharacters(in: .whitespaces).isEmpty)

            Button("Сохранить инструкцию") { save() }
                .buttonStyle(AccentButtonStyle(accent: settings.accent, prominent: false))
                .disabled(promptText.trimmingCharacters(in: .whitespaces).isEmpty)

            if targetBundleID != nil {
                Button("Убрать правило") {
                    if let bundleID = targetBundleID {
                        settings.appPrompts.removeValue(forKey: bundleID)
                        switchTarget(nil)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.danger)
            }

            Spacer()

            if settings.llmProvider == .disabled {
                Text("Провайдер не выбран")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
            } else {
                Text("\(settings.llmProvider.title) · \(settings.llmModel)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Действия

    private func switchTarget(_ bundleID: String?) {
        targetBundleID = bundleID
        loadPrompt(for: bundleID)
        result = ""
        errorText = nil
        elapsed = nil
    }

    private func loadPrompt(for bundleID: String?) {
        if let bundleID, let rule = settings.appPrompts[bundleID] {
            promptText = rule.prompt
            presetID = rule.presetID ?? PostProcessor.defaultPresetID
        } else if let bundleID {
            // Новой программе сразу подставляем подходящую заготовку.
            let suggested = PostProcessor.suggestedPreset(forBundleID: bundleID)
            promptText = suggested.prompt
            presetID = suggested.id
        } else {
            promptText = settings.defaultPrompt
            presetID = settings.defaultPresetID
        }
    }

    private func save() {
        if let bundleID = targetBundleID {
            settings.appPrompts[bundleID] = PromptRule(
                enabled: true, prompt: promptText, presetID: presetID)
            env.banner = .init(text: "Инструкция для «\(appName(bundleID))» сохранена", kind: .success)
        } else {
            settings.defaultPrompt = promptText
            settings.defaultPresetID = presetID
            settings.postProcessUnlistedApps = true
            env.banner = .init(text: "Инструкция по умолчанию сохранена", kind: .success)
        }
    }

    private func run() {
        isRunning = true
        errorText = nil
        result = ""
        let started = Date()
        let prompt = promptText
        let text = sampleText

        Task { @MainActor in
            defer { isRunning = false }
            do {
                result = try await PostProcessor.run(text, instruction: prompt, settings: settings)
            } catch {
                errorText = error.localizedDescription
            }
            elapsed = Date().timeIntervalSince(started)
        }
    }

    // MARK: - Программы

    private var existingTargets: [(bundleID: String, name: String)] {
        settings.appPrompts.keys
            .map { (bundleID: $0, name: appName($0)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var runningApps: [(bundleID: String, name: String)] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .compactMap { app -> (bundleID: String, name: String)? in
                guard app.activationPolicy == .regular,
                      let id = app.bundleIdentifier,
                      id != Bundle.main.bundleIdentifier,
                      seen.insert(id).inserted
                else { return nil }
                return (bundleID: id, name: app.localizedName ?? id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func appName(_ bundleID: String) -> String {
        if let known = KnownCallApps.all.first(where: { $0.bundleID == bundleID }) { return known.name }
        if let seen = settings.seenCallApps[bundleID] { return seen }
        if let running = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == bundleID })?.localizedName { return running }
        return bundleID
    }
}
