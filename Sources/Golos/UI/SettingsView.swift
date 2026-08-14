import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var models: ModelStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var calls: CallDetector

    @State private var devices: [AudioInputDevice] = []
    @State private var showEraseConfirmation = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                recognitionCard
                memoryCard
                recordingCard
                callRulesCard
                LLMSettingsView()
                archiveCard
                appearanceCard
                privacyCard
                aboutCard
            }
            .padding(24)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
        .onAppear { devices = AudioInputDevice.available() }
        .confirmationDialog("Удалить все данные приложения?",
                            isPresented: $showEraseConfirmation, titleVisibility: .visible) {
            Button("Удалить всё", role: .destructive) { env.eraseAllData() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Записи, расшифровки, история диктовок и скачанные модели будут стёрты безвозвратно. Настройки останутся.")
        }
    }

    // MARK: - Распознавание

    private var recognitionCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                SectionTitle(text: "Распознавание",
                             subtitle: "Ничего не уходит в сеть: модель считает прямо здесь")

                ModelPicker(
                    title: "Модель для записей и файлов",
                    hint: "качество важнее скорости",
                    symbol: "rectangle.stack.fill",
                    selection: $settings.transcriptionModelID
                ) { spec in
                    env.banner = .init(text: "Для записей: \(spec.title)", kind: .success)
                }

                ModelPicker(
                    title: "Модель для диктовки",
                    hint: "скорость важнее всего",
                    symbol: "waveform.badge.mic",
                    selection: $settings.dictationModelID
                ) { spec in
                    env.banner = .init(text: "Для диктовки: \(spec.title)", kind: .success)
                }

                Divider().opacity(0.4)

                LabeledContent("Язык") {
                    Picker("", selection: $settings.language) {
                        ForEach(Languages.common, id: \.code) { language in
                            Text(language.title).tag(language.code)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 240)
                }

                Toggle("Переводить на английский", isOn: $settings.translateToEnglish)
                    .help("Whisper умеет сразу переводить речь на английский вместо расшифровки на языке оригинала")

                Divider().opacity(0.4)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Ширина луча при поиске")
                        Spacer()
                        Text("\(settings.beamSize)")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(
                        get: { Double(settings.beamSize) },
                        set: { settings.beamSize = Int($0) }
                    ), in: 1...8, step: 1)
                    Text("Больше — точнее и медленнее. 1 — жадный поиск, 5 — разумный максимум для встреч.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Потоков процессора")
                        Spacer()
                        Text("\(settings.threads)")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(
                        get: { Double(settings.threads) },
                        set: { settings.threads = Int($0) }
                    ), in: 1...Double(ProcessInfo.processInfo.activeProcessorCount), step: 1)
                }

                Toggle("Использовать GPU (Metal)", isOn: $settings.useGPU)
                    .onChange(of: settings.useGPU) {
                        Engines.unloadAll()
                        env.warmUpEngine()
                    }

                Toggle("Пропускать тишину с помощью VAD", isOn: $settings.useVAD)
                    .disabled(models.vadModelURL == nil)
                if models.vadModelURL == nil {
                    Label("Нужна модель Silero VAD — меньше мегабайта", systemImage: "arrow.down.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .onTapGesture { env.route = .models }
                }

                Divider().opacity(0.4)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Словарь и подсказка")
                        .font(.system(.callout, design: .rounded, weight: .medium))
                    TextEditor(text: $settings.vocabulary)
                        .font(.callout)
                        .frame(height: 62)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
                    Text("Имена, названия продуктов, термины — через запятую. Модель будет писать их правильно.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Память

    private var memoryCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                SectionTitle(text: "Память",
                             subtitle: "Модель — самая тяжёлая часть приложения. Здесь решается, сколько ей можно")

                HStack(spacing: 12) {
                    StatTile(symbol: "app.badge.checkmark", title: "Занимает «голос»",
                             value: Fmt.bytes(MemoryGuard.footprintBytes),
                             detail: engineStateText,
                             tint: Theme.primary(settings.accent))
                    StatTile(symbol: "memorychip", title: "Свободно в системе",
                             value: Fmt.bytes(MemoryGuard.availableBytes),
                             detail: "из \(Fmt.bytes(MemoryGuard.totalBytes))")
                    StatTile(symbol: "lock.shield", title: "Неприкосновенный запас",
                             value: Fmt.bytes(MemoryGuard.headroom(settings)),
                             detail: "система его не отдаст модели",
                             tint: Theme.success)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Оставлять системе")
                        Spacer()
                        Text("\(String(format: "%.0f", settings.memoryHeadroomGB)) ГБ")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.memoryHeadroomGB, in: 1...16, step: 1)
                    Text("Модель не загрузится, если после неё останется меньше этого запаса. "
                         + "Тогда приложение предложит вариант поменьше вместо того, чтобы загнать мак в своп.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Выгружать модель после простоя")
                        Spacer()
                        Text(settings.modelIdleUnloadSeconds == 0
                             ? "сразу"
                             : "\(settings.modelIdleUnloadSeconds) с")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(
                        get: { Double(settings.modelIdleUnloadSeconds) },
                        set: { settings.modelIdleUnloadSeconds = Int($0) }
                    ), in: 0...300, step: 15)
                    Text("«Сразу» экономит максимум памяти, но каждая диктовка будет ждать загрузки модели "
                         + "примерно секунду. Шестьдесят секунд — разумный компромисс.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Toggle("Выгружать модели, когда окно неактивно", isOn: $settings.unloadWhenInactive)
                Text("Через полминуты после переключения на другую программу память освобождается — "
                     + "если в этот момент ничего не записывается и не считается.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("Выгрузить модели сейчас") { env.unloadModelsNow() }
                        .buttonStyle(AccentButtonStyle(accent: settings.accent, prominent: false))
                        .disabled(!anyModelLoaded)
                    Spacer()
                }
            }
        }
    }

    private var anyModelLoaded: Bool { Engines.anyModelLoaded }

    private var engineStateText: String {
        let loaded = Engines.loadedModels
        return loaded.isEmpty ? "модели не в памяти" : "в памяти: \(loaded.joined(separator: ", "))"
    }

    // MARK: - Запись

    private var recordingCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                SectionTitle(text: "Запись")

                LabeledContent("Микрофон") {
                    Picker("", selection: $settings.inputDeviceID) {
                        Text("Системный по умолчанию").tag(UInt32(0))
                        ForEach(devices) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 240)
                }

                Toggle("Не включать микрофон Bluetooth-наушников",
                       isOn: $settings.avoidBluetoothMic)
                Text("Наушники, у которых включили микрофон, уходят из музыкального режима "
                     + "в режим разговора, и звук в них портится — иногда надолго. "
                     + "Замерено: выход падает с 44 100 до 16 000 Гц. Поэтому для диктовки и "
                     + "записи берётся встроенный микрофон: на распознавание это влияет мало, "
                     + "а музыку и голоса в наушниках не портит. Если микрофон гарнитуры уже "
                     + "занят звонком, подмены не будет — портить уже нечего. "
                     + "Переключатель важнее выбора в списке выше: пока он включён, "
                     + "микрофон наушников не используется, даже если выбран вручную.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                headphonesState

                Toggle("Расшифровывать сразу после записи", isOn: $settings.autoTranscribeAfterRecording)
                Toggle("Сохранять аудио после расшифровки", isOn: $settings.keepAudioAfterTranscription)
                if !settings.keepAudioAfterTranscription {
                    Label("Аудио будет удаляться — останется только текст. Место экономится, но переслушать не выйдет.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                }

                Divider().opacity(0.4)

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Отсекать эхо между дорожками", isOn: $settings.suppressEcho)
                    Text("Звук собеседника из динамиков попадает обратно в микрофон, и одна фраза "
                         + "оказывается в расшифровке дважды — как «Собеседник» и как «Я». "
                         + "Дубль определяется по совпадению во времени и похожести текста.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if settings.suppressEcho {
                        Picker("Что оставлять", selection: $settings.echoPriority) {
                            ForEach(EchoPriority.allCases) { item in
                                Text(item.title).tag(item)
                            }
                        }
                        .pickerStyle(.segmented)
                        Text(settings.echoPriority.explanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack {
                            Text("Порог похожести")
                            Spacer()
                            Text("\(Int(settings.echoSimilarity * 100))%")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.echoSimilarity, in: 0.3...0.9)
                        Text("Ниже — отсекается смелее, но можно потерять живой повтор. "
                             + "Выше — остаются только очевидные дубли.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Divider().opacity(0.4)

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Разделять по голосам", isOn: $settings.diarizationEnabled)
                    Text("Реплики раскладываются по участникам: «голос 1», «голос 2». Приложение "
                         + "сначала строит по звуку шкалу «кто когда говорит», а потом раскладывает "
                         + "по ней текст — поэтому язык неважен и неважно, как модель распознавания "
                         + "нарезала реплики. Уверенно различает заметно разные голоса и путается "
                         + "на похожих; людей между разными записями не узнаёт.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if settings.diarizationEnabled {
                        Toggle("Спрашивать при импорте, кто говорит", isOn: $settings.askSpeakersOnImport)
                        Text("Перед расшифровкой можно указать число говорящих и их имена. "
                             + "Заданное число надёжнее автоопределения: приложению не нужно "
                             + "угадывать его по звуку. Это же можно поправить у готовой записи.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack {
                            Text("Не больше голосов")
                            Spacer()
                            Text("\(settings.maxSpeakers)")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(
                            get: { Double(settings.maxSpeakers) },
                            set: { settings.maxSpeakers = Int($0) }
                        ), in: 2...8, step: 1)

                        HStack {
                            Text("Осторожность деления")
                            Spacer()
                            Text(String(format: "%.2f", settings.diarizationThreshold))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.diarizationThreshold, in: 0.15...0.6)
                        Text("Меньше — делит смелее, но может принять одного человека за нескольких. "
                             + "Значение по умолчанию подобрано замером на записях с одним и с двумя голосами.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Divider().opacity(0.4)

                Toggle("Замечать начало разговоров", isOn: $settings.detectCalls)
                Text("Определяется по занятости микрофона — работает для Zoom, Телемоста в браузере, Telegram и любых других звонков.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Начинать запись автоматически", isOn: $settings.autoStartOnCall)
                    .disabled(!settings.detectCalls)
                if settings.autoStartOnCall {
                    Label("Каждый звонок будет записан без спроса. Убедитесь, что собеседники не против.",
                          systemImage: "exclamationmark.bubble")
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                }

                Divider().opacity(0.4)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Когда программа отпустила микрофон")
                        .font(.system(.callout, design: .rounded, weight: .medium))
                    Picker("", selection: $settings.callEndAction) {
                        ForEach(CallEndAction.allCases) { action in
                            Text(action.title).tag(action)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)

                    Text(settings.callEndAction.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if settings.callEndAction != .ignore {
                        HStack {
                            Text("Ждать перед этим")
                            Spacer()
                            Text("\(settings.callEndDelaySeconds) с")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(
                            get: { Double(settings.callEndDelaySeconds) },
                            set: { settings.callEndDelaySeconds = Int($0) }
                        ), in: 2...60, step: 1)
                        Text("Пауза нужна, потому что программы отпускают микрофон на секунду при "
                             + "смене устройства или включении демонстрации экрана. Если микрофон "
                             + "снова занят, запись просто продолжается.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !AudioProcessMonitor.isAvailable {
                        Label("На этой системе видно только то, что микрофон кем-то занят, "
                              + "без разбора программ, — конец разговора определить не получится.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: - Правила по программам

    private var callRulesCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(text: "Разговоры по программам",
                             subtitle: "Для каждой программы отдельно: писать сразу и стоит ли уведомлять")

                HStack(spacing: 10) {
                    Image(systemName: notificationsGranted ? "bell.badge.fill" : "bell.slash")
                        .foregroundStyle(notificationsGranted ? Theme.success : Theme.warning)
                    Text(notificationsGranted
                         ? "Системные уведомления разрешены"
                         : "Системные уведомления не разрешены — предложение записать не появится, пока окно закрыто")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if !notificationsGranted {
                        Button("Разрешить") { Notifier.shared.requestAuthorization() }
                            .buttonStyle(AccentButtonStyle(accent: settings.accent, prominent: false))
                    }
                }

                Divider().opacity(0.4)

                HStack {
                    Text("Программа").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Писать сразу").frame(width: 110, alignment: .center)
                    Text("Уведомлять").frame(width: 110, alignment: .center)
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)

                ForEach(ruleApps, id: \.bundleID) { app in
                    ruleRow(bundleID: app.bundleID, name: app.name)
                }

                Divider().opacity(0.4)

                Text("Список пополняется сам: программа, занявшая микрофон хотя бы раз, "
                     + "появляется здесь — и её уведомления можно выключить. То же самое "
                     + "делает кнопка «Не уведомлять об этой программе» прямо в уведомлении. "
                     + "Выключенные уведомления не отменяют автозапись: «не отвлекай» и "
                     + "«не пиши» — разные желания.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Прочие программы подчиняются общим переключателям в разделе «Запись»: "
                     + "сейчас — \(settings.autoStartOnCall ? "писать сразу" : "спрашивать")"
                     + (settings.notifyOnCall ? " с уведомлением." : " без уведомления."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Зашитый список плюс замеченные вживую программы: иначе выключить
    /// уведомления о программе, которой нет в списке, было бы негде.
    /// Дубликаты по имени убираем: у Telegram и Teams по нескольку bundle id.
    private var ruleApps: [(bundleID: String, name: String)] {
        var seen = Set<String>()
        let known = KnownCallApps.all.filter { seen.insert($0.name).inserted }
        let extra = settings.ruleCandidates
            .filter { seen.insert($0.name).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return known + extra
    }

    /// Что сейчас с наушниками. Показываем, потому что в режим разговора их может
    /// перевести и чужая программа — и тогда видно, кто именно это сделал,
    /// вместо необъяснимо испортившегося звука.
    @ViewBuilder
    private var headphonesState: some View {
        if AudioOutputInfo.looksLikeCallMode() {
            let culprits = calls.active.map(\.name).joined(separator: ", ")
            Label(culprits.isEmpty
                  ? "Наушники сейчас в режиме разговора — звук в них хуже обычного. "
                    + "Обычно это проходит само через полминуты после того, как микрофон освободят."
                  : "Наушники в режиме разговора: микрофон занят — \(culprits). "
                    + "Пока эта программа его держит, звук в наушниках будет хуже обычного.",
                  systemImage: "headphones.slash")
                .font(.caption)
                .foregroundStyle(Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
        } else if settings.avoidBluetoothMic, let headset = bluetoothInput {
            Label("Подключены «\(headset.name)» — писать будем со встроенного микрофона, "
                  + "звук в наушниках не пострадает.",
                  systemImage: "headphones")
                .font(.caption)
                .foregroundStyle(Theme.success)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Подключённая Bluetooth-гарнитура, чей микрофон стал бы устройством ввода.
    private var bluetoothInput: AudioInputDevice? {
        devices.first { $0.isBluetooth && ($0.isDefault || $0.id == settings.inputDeviceID) }
    }

    private var notificationsGranted: Bool {
        Notifier.shared.authorization == .authorized || Notifier.shared.authorization == .provisional
    }

    private func ruleRow(bundleID: String, name: String) -> some View {
        let rule = settings.rule(forBundleID: bundleID)
        return HStack {
            Text(name)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)

            Toggle("", isOn: Binding(
                get: { rule.autoRecord },
                set: { settings.setRule(AppRule(autoRecord: $0, notify: rule.notify), forBundleID: bundleID) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .frame(width: 110, alignment: .center)

            Toggle("", isOn: Binding(
                get: { rule.notify },
                set: { settings.setRule(AppRule(autoRecord: rule.autoRecord, notify: $0), forBundleID: bundleID) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .frame(width: 110, alignment: .center)
        }
    }

    // MARK: - Архив расшифровок

    private var archiveCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(text: "Архив расшифровок",
                             subtitle: "Единственное, что приложение пишет за пределами своей папки")

                Toggle("Складывать расшифровки в Markdown", isOn: $settings.archiveEnabled)
                Toggle("Архивировать и заметки с импортом", isOn: $settings.archiveNotes)
                    .disabled(!settings.archiveEnabled)

                Text("Встречи и дневные записи раскладываются по подпапкам. Диктовка не архивируется: "
                     + "это короткие фразы, им место в истории приложения. В начале каждого файла — "
                     + "легенда: какая это запись, из какой программы, где чей голос и какой моделью распознано.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Text(TranscriptArchive.root(settings).path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Выбрать папку…") { chooseArchiveFolder() }
                        .buttonStyle(AccentButtonStyle(accent: settings.accent, prominent: false))
                    if settings.archiveFolderPath != nil {
                        Button("По умолчанию") { settings.archiveFolderPath = nil }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Button("Открыть архив") { env.route = .archive }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.primary(settings.accent))
                    Spacer()
                }
            }
        }
    }

    private func chooseArchiveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Выбрать"
        panel.directoryURL = TranscriptArchive.root(settings)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.archiveFolderPath = url.path
    }

    // MARK: - Внешний вид

    private var appearanceCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                SectionTitle(text: "Внешний вид")

                VStack(alignment: .leading, spacing: 7) {
                    Text("Тема").font(.system(.callout, design: .rounded, weight: .medium))
                    Picker("Тема", selection: $settings.appearance) {
                        ForEach(Settings.AppearanceMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text("Тёмная используется по умолчанию; «Как в системе» меняется вместе с оформлением macOS.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Акцент").font(.system(.callout, design: .rounded, weight: .medium))
                    HStack(spacing: 10) {
                        ForEach(Settings.AccentTheme.allCases) { theme in
                            Button {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                    settings.accent = theme
                                }
                            } label: {
                                VStack(spacing: 6) {
                                    Circle()
                                        .fill(Theme.gradient(theme))
                                        .frame(width: 34, height: 34)
                                        .overlay(
                                            Circle()
                                                .strokeBorder(Color.primary.opacity(settings.accent == theme ? 0.8 : 0),
                                                              lineWidth: 2)
                                                .padding(-3)
                                        )
                                        .scaleEffect(settings.accent == theme ? 1.08 : 1)
                                    Text(theme.title)
                                        .font(.caption2)
                                        .foregroundStyle(settings.accent == theme ? .primary : .secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                    }
                }

                Toggle("Значок в строке меню", isOn: $settings.showMenuBarIcon)

                Toggle("Живой фон", isOn: $settings.animatedBackground)
                Text("Фоновые пятна медленно плывут. Красиво, но непрерывная анимация на всё окно "
                     + "занимает около 13% процессора всё время, пока открыто окно, — поэтому по умолчанию выключено.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Меньше движения", isOn: $settings.reduceMotion)
                Text("Отключает плавающий фон и пульсацию — полезно, если анимации отвлекают или машина под нагрузкой.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Приватность и данные

    private var privacyCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(text: "Данные")

                HStack(spacing: 12) {
                    StatTile(symbol: "folder.fill", title: "Всего в контейнере",
                             value: Fmt.bytes(env.containerSize))
                    StatTile(symbol: "cube.box.fill", title: "Модели",
                             value: Fmt.bytes(models.totalSizeOnDisk))
                    StatTile(symbol: "waveform", title: "Записи",
                             value: Fmt.bytes(Container.size(of: Container.recordings)))
                }

                Text("Приложение хранит всё в одной папке и больше нигде: \(Container.root.path)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                HStack(spacing: 10) {
                    Button("Показать папку") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: Container.root.path)
                    }
                    .buttonStyle(AccentButtonStyle(accent: settings.accent, prominent: false))

                    Button("Открыть журнал") {
                        NSWorkspace.shared.open(Log.fileURL)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                    Spacer()

                    Button("Удалить все данные") { showEraseConfirmation = true }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.danger)
                }
            }
        }
    }

    // MARK: - О программе

    private var aboutCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(text: "О приложении")
                Text("«голос» — локальный распознаватель речи. Движок — whisper.cpp с ускорением через Metal, модели — ggml от проекта whisper.cpp. Сеть используется ровно в одном месте: при скачивании моделей.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Показать вводный экран") { env.showOnboarding = true }
                    .buttonStyle(AccentButtonStyle(accent: settings.accent, prominent: false))

                HStack(spacing: 18) {
                    labelled("Версия", Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                    labelled("Движок", "whisper.cpp")
                    labelled("Ускорение", settings.useGPU ? "Metal" : "CPU")
                    labelled("Машина", "\(ProcessInfo.processInfo.activeProcessorCount) ядер · \(Fmt.bytes(Int64(ProcessInfo.processInfo.physicalMemory)))")
                }
            }
        }
    }

    private func labelled(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.tertiary)
            Text(value).font(.system(.callout, design: .rounded, weight: .medium))
        }
    }
}
