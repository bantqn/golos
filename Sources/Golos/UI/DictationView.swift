import SwiftUI
import AppKit

struct DictationView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var models: ModelStore
    @EnvironmentObject private var dictation: DictationController

    @State private var recordingHotKey = false
    @State private var sandbox = ""


    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                statusCard
                permissionsCard
                quickSettings
                hudCard
                sandboxCard
                historyCard
            }
            .padding(24)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Статус

    private var statusCard: some View {
        Card(padding: 24) {
            HStack(spacing: 26) {
                orb

                VStack(alignment: .leading, spacing: 10) {
                    Text(title)
                        .font(.system(.title2, design: .rounded, weight: .semibold))
                        .contentTransition(.opacity)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        hotKeyButton
                        Toggle("Включена", isOn: $settings.dictationEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                        Text(settings.dictationEnabled ? "Включена" : "Выключена")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    if settings.dictationEnabled && !dictation.hotKeyRegistered {
                        Label("Сочетание занято другой программой — выберите другое",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.warning)
                    }
                }
                Spacer()
            }
        }
    }

    private var orb: some View {
        ZStack {
            switch dictation.phase {
            case .listening:
                BreathingOrb(accent: settings.accent, level: dictation.level,
                             size: 58, animated: !settings.reduceMotion)
            case .recognizing, .processing:
                ZStack {
                    Circle()
                        .stroke(Theme.primary(settings.accent).opacity(0.2), lineWidth: 5)
                        .frame(width: 58, height: 58)
                    Circle()
                        .trim(from: 0, to: 0.28)
                        .stroke(Theme.gradient(settings.accent),
                                style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .frame(width: 58, height: 58)
                        .rotationEffect(.degrees(spin))
                        .onAppear {
                            withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) {
                                spin = 360
                            }
                        }
                }
                .frame(width: 128, height: 128)
            default:
                ZStack {
                    Circle()
                        .fill(Theme.gradient(settings.accent).opacity(settings.dictationEnabled ? 0.9 : 0.25))
                        .frame(width: 58, height: 58)
                        .shadow(color: Theme.primary(settings.accent).opacity(0.35), radius: 16)
                    Image(systemName: "waveform.badge.mic")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 128, height: 128)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: dictation.phase)
    }

    @State private var spin: Double = 0

    private var title: String {
        switch dictation.phase {
        case .listening: return dictation.isLatched ? "Слушаю · зафиксировано" : "Слушаю"
        case .recognizing: return "Распознаю…"
        case .processing: return "Обрабатываю моделью…"
        case .inserted: return "Готово — текст вставлен"
        case .copiedOnly: return "Текст в буфере обмена"
        case .failed: return "Не получилось"
        case .idle: return "Диктовка в любое приложение"
        }
    }

    private var subtitle: String {
        switch dictation.phase {
        case .listening:
            let stop = settings.dictationMode == .pushToTalk ? "Отпустите клавиши" : "Нажмите ещё раз"
            return "Говорите. \(stop) — и текст появится там, где стоит курсор. Escape — отменить без вставки."
        case .recognizing: return "Считаю на этом маке, ничего никуда не отправляется."
        case .processing:
            return settings.llmProvider.isLocal
                ? "Прогоняю текст через локальную модель \(settings.llmProvider.title)."
                : "Отправил текст в \(settings.llmProvider.title) на обработку."
        case .inserted(let text): return text
        case .copiedOnly(let text): return text
        case .failed(let message): return message
        case .idle:
            return "Зажмите сочетание в любой программе — почта, мессенджер, редактор кода — и продиктуйте текст. "
                + "Он вставится прямо в поле ввода. Escape во время диктовки отменяет её без распознавания."
        }
    }

    private var hotKeyButton: some View {
        Button {
            recordingHotKey.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: recordingHotKey ? "record.circle" : "command")
                    .font(.caption)
                Text(recordingHotKey ? "Нажмите сочетание…" : settings.dictationHotKey.displayString)
                    .font(.system(.callout, design: .rounded, weight: .medium))
                    .monospaced()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(recordingHotKey
                               ? Theme.primary(settings.accent).opacity(0.2)
                               : Color.primary.opacity(0.07))
            )
        }
        .buttonStyle(.plain)
        .background(HotKeyCaptureView(isActive: $recordingHotKey) { combo in
            settings.dictationHotKey = combo
            recordingHotKey = false
        })
    }

    // MARK: - Разрешения

    private var permissionsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Что нужно системе")
                    .font(.system(.headline, design: .rounded))

                permissionRow(
                    granted: MicRecorder.permissionStatus == .authorized,
                    title: "Микрофон",
                    detail: "Чтобы слышать вашу речь",
                    action: { Task { _ = await MicRecorder.requestPermission() } }
                )
                permissionRow(
                    granted: TextInjector.isTrusted,
                    title: "Универсальный доступ",
                    detail: "Чтобы вставить текст в активное окно",
                    action: {
                        TextInjector.requestTrust()
                        TextInjector.openAccessibilitySettings()
                    }
                )
                permissionRow(
                    granted: models.hasAnyModel,
                    title: "Модель распознавания",
                    detail: "Скачивается один раз, дальше работает офлайн",
                    action: { env.route = .models }
                )
            }
        }
    }

    private func permissionRow(granted: Bool, title: String, detail: String,
                               action: @escaping () -> Void) -> some View {
        HStack(spacing: 11) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 15))
                .foregroundStyle(granted ? Theme.success : Theme.warning)
                .contentTransition(.symbolEffect(.replace))

            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(.callout, design: .rounded, weight: .medium))
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Настроить", action: action)
                    .buttonStyle(AccentButtonStyle(accent: settings.accent, prominent: false))
            }
        }
    }

    // MARK: - Быстрые настройки

    private var quickSettings: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Text("Поведение")
                    .font(.system(.headline, design: .rounded))

                ModelPicker(
                    title: "Модель для диктовки",
                    hint: "отдельно от моделей для записей",
                    symbol: "waveform.badge.mic",
                    selection: $settings.dictationModelID
                ) { spec in
                    env.banner = .init(text: "Для диктовки: \(spec.title)", kind: .success)
                }

                Divider().opacity(0.4)

                Picker("Активация", selection: $settings.dictationMode) {
                    ForEach(DictationMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text(settings.dictationMode.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Вставка", selection: $settings.insertionMode) {
                    ForEach(InsertionMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text(settings.insertionMode.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Звуковые сигналы начала и конца", isOn: $settings.dictationSound)
                Toggle("Убирать точку в конце фразы", isOn: $settings.trimTrailingPeriod)

                Toggle("Оставлять текст в буфере обмена", isOn: $settings.keepTextInClipboard)
                Text("Страховка на случай, если приложение не приняло вставку: проверить это "
                     + "технически невозможно, а продиктованную фразу заново не произнесёшь. "
                     + "Ценой того, что прежнее содержимое буфера не возвращается.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Показывать текст по ходу речи", isOn: $settings.livePreview)
                Text("Черновик появляется в плашке, не дожидаясь конца фразы. Настоящего "
                     + "потокового распознавания у whisper нет, поэтому черновик получается "
                     + "повторным проходом по накопленному звуку — процессор занят всё время, "
                     + "пока вы говорите. Для фраз длиннее 25 секунд черновик отключается сам.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Плашка

    private var hudCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Плашка на экране")
                        .font(.system(.headline, design: .rounded))
                    Spacer()
                    if dictation.hudPinned {
                        Pill(text: "показана", color: Theme.success)
                    }
                }

                Text("Плашку можно перетащить за любое место — положение запоминается. "
                     + "Шестерёнка на ней раскрывает основные настройки, чтобы не открывать окно.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Прозрачность")
                        Spacer()
                        Text("\(Int((1 - settings.hudOpacity) * 100))%")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(
                        get: { 1 - settings.hudOpacity },
                        set: { settings.hudOpacity = 1 - $0 }
                    ), in: 0...0.75)
                }

                HStack(spacing: 10) {
                    if dictation.hudPinned {
                        Button("Скрыть плашку") { dictation.hideHUDSetup() }
                            .buttonStyle(AccentButtonStyle(accent: settings.accent, prominent: false))
                    } else {
                        Button("Показать и настроить") { dictation.showHUDForSetup() }
                            .buttonStyle(AccentButtonStyle(accent: settings.accent))
                    }
                    Button("Вернуть на место") { dictation.resetHUDPosition() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }

    // MARK: - Песочница

    private var sandboxCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Попробовать здесь")
                        .font(.system(.headline, design: .rounded))
                    Spacer()
                    if !sandbox.isEmpty {
                        Button("Очистить") { sandbox = "" }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Поставьте курсор в поле и зажмите \(settings.dictationHotKey.displayString).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $sandbox)
                    .font(.body)
                    .frame(height: 90)
                    .scrollContentBackground(.hidden)
                    .padding(9)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(dictation.phase == .listening
                                          ? Theme.primary(settings.accent).opacity(0.6)
                                          : Color.clear, lineWidth: 1.5)
                    )
                    .animation(.easeOut(duration: 0.25), value: dictation.phase)
            }
        }
    }

    // MARK: - История

    private var historyCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Последние диктовки")
                        .font(.system(.headline, design: .rounded))
                    Spacer()
                    if !dictation.history.isEmpty {
                        Button("Очистить историю") { dictation.clearHistory() }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if dictation.history.isEmpty {
                    Text("Здесь появится всё, что вы продиктуете. Полезно, если вставка ушла не в то окно — текст можно скопировать повторно.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(dictation.history.prefix(12)) { entry in
                        HStack(alignment: .top, spacing: 11) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.text)
                                    .font(.callout)
                                    .lineLimit(3)
                                    .textSelection(.enabled)
                                HStack(spacing: 6) {
                                    Text(Fmt.shortTime(entry.createdAt))
                                    if let app = entry.targetApp {
                                        Text("→ \(app)")
                                    }
                                    Text("· \(String(format: "%.1f", entry.recognitionSeconds)) с на распознавание")
                                }
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Button {
                                dictation.copy(entry)
                                env.banner = .init(text: "Скопировано", kind: .success)
                            } label: {
                                Image(systemName: "doc.on.doc").font(.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 5)
                        if entry.id != dictation.history.prefix(12).last?.id {
                            Divider().opacity(0.35)
                        }
                    }
                }
            }
        }
    }
}

/// Невидимая NSView, которая ловит следующее нажатие клавиш для записи сочетания.
struct HotKeyCaptureView: NSViewRepresentable {
    @Binding var isActive: Bool
    let onCapture: (HotKeyCombo) -> Void

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.onCapture = onCapture
        return view
    }

    func updateNSView(_ nsView: CaptureView, context: Context) {
        nsView.onCapture = onCapture
        if isActive {
            DispatchQueue.main.async { nsView.window?.makeFirstResponder(nsView) }
        }
        nsView.isCapturing = isActive
    }

    final class CaptureView: NSView {
        var onCapture: ((HotKeyCombo) -> Void)?
        var isCapturing = false

        override var acceptsFirstResponder: Bool { isCapturing }

        override func keyDown(with event: NSEvent) {
            guard isCapturing, capture(event) else {
                super.keyDown(with: event)
                return
            }
        }

        /// Сочетания с ⌘ AppKit рассылает как «эквиваленты клавиш», а не как
        /// keyDown, — без этого перехвата ⌘` и любое другое ⌘-сочетание
        /// до записи просто не доходило.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard isCapturing else { return super.performKeyEquivalent(with: event) }
            return capture(event)
        }

        private func capture(_ event: NSEvent) -> Bool {
            guard let combo = HotKeyRecorder.combo(from: event) else {
                NSSound.beep()
                return false
            }
            onCapture?(combo)
            return true
        }
    }
}
