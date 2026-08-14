import SwiftUI
import UniformTypeIdentifiers

struct RecordView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var transcription: TranscriptionService
    @EnvironmentObject private var recorder: RecordingController
    @EnvironmentObject private var calls: CallDetector
    @EnvironmentObject private var dictation: DictationController

    @State private var showImporter = false
    @State private var isDropTargeted = false
    /// Импортированные файлы, для которых ещё не спросили про говорящих.
    @State private var pendingSpeakerSetup: [Recording] = []


    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                callBanner
                finishBanner
                mainCard
                sourcesRow
                continuousCard
                todaySummary
                if transcription.isRunning { liveTranscription }
                importCard
                categorySection(.meetings)
                categorySection(.allDay)
                categorySection(.notes)
                dictationHistoryCard
            }
            .padding(24)
            .frame(maxWidth: 940)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.audio, .movie, .mpeg4Audio, .mp3, .wav, .aiff],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            Task { await runImport(urls) }
        }
        .sheet(isPresented: Binding(
            get: { !pendingSpeakerSetup.isEmpty },
            set: { if !$0 { pendingSpeakerSetup = [] } }
        )) {
            ImportSpeakersSheet(
                recordings: pendingSpeakerSetup,
                onDone: { count, names in applySpeakers(count: count, names: names) },
                onSkip: { applySpeakers(count: nil, names: []) }
            )
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .alert("Не получилось", isPresented: Binding(
            get: { recorder.lastError != nil },
            set: { if !$0 { recorder.lastError = nil } }
        )) {
            Button("Понятно", role: .cancel) { recorder.lastError = nil }
            if recorder.lastError?.contains("записи экрана") == true {
                Button("Открыть настройки") { SystemAudioRecorder.openPermissionSettings() }
            }
        } message: {
            Text(recorder.lastError ?? "")
        }
    }

    // MARK: - Обнаружен звонок

    @ViewBuilder
    private var callBanner: some View {
        if let detection = calls.current, !recorder.isBusy, settings.detectCalls {
            Card {
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(Theme.primary(settings.accent).opacity(0.16))
                            .frame(width: 40, height: 40)
                        Image(systemName: "person.2.wave.2.fill")
                            .foregroundStyle(Theme.gradient(settings.accent))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Похоже, идёт разговор в \(detection.appName)")
                            .font(.system(.headline, design: .rounded))
                        Text("Микрофон занят другим приложением. Записать встречу?")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Не сейчас") { calls.dismissCurrent() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    Button("Записать") { env.startRecordingCall(detection) }
                        .buttonStyle(AccentButtonStyle(accent: settings.accent))
                }
            }
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: calls.current)
        }
    }

    // MARK: - Разговор закончился

    @ViewBuilder
    private var finishBanner: some View {
        if let proposal = env.finishProposal, recorder.isBusy {
            FinishProposalCard(
                appName: proposal.appName,
                elapsed: recorder.elapsed,
                accent: settings.accent,
                onMute: proposal.bundleID.map { bundleID in
                    {
                        env.muteNotifications(forBundleID: bundleID)
                        env.finishProposal = nil
                    }
                },
                onKeep: { env.finishProposal = nil },
                onFinish: {
                    env.finishProposal = nil
                    env.toggleRecording()
                }
            )
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: env.finishProposal)
        }
    }

    // MARK: - Основная карточка

    private var mainCard: some View {
        Card(padding: 24) {
            VStack(spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(stateTitle)
                            .font(.system(.title2, design: .rounded, weight: .semibold))
                            .contentTransition(.opacity)
                        Text(stateSubtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Fmt.duration(recorder.elapsed))
                        .font(.system(size: 34, weight: .light, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(recorder.isBusy ? .primary : .tertiary)
                        .contentTransition(.numericText())
                }

                LiveWaveform(
                    levels: recorder.waveform,
                    accent: settings.accent,
                    active: recorder.state == .recording
                )
                .frame(height: 84)
                .opacity(recorder.isBusy ? 1 : 0.35)

                HStack(spacing: 18) {
                    RecordButton(
                        isRecording: recorder.state == .recording || recorder.state == .paused,
                        isBusy: recorder.state == .preparing || recorder.state == .finishing,
                        accent: settings.accent
                    ) {
                        env.toggleRecording()
                    }

                    if recorder.isBusy, !recorder.isContinuous {
                        Button {
                            Task {
                                recorder.state == .paused ? await recorder.resume() : recorder.pause()
                            }
                        } label: {
                            Label(recorder.state == .paused ? "Продолжить" : "Пауза",
                                  systemImage: recorder.state == .paused ? "play.fill" : "pause.fill")
                        }
                        .buttonStyle(AccentButtonStyle(accent: settings.accent, prominent: false))

                        Button(role: .destructive) {
                            Task { await recorder.discard() }
                        } label: {
                            Label("Отменить", systemImage: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.danger)
                    }

                    Spacer()

                    levelMeters
                }
            }
        }
    }

    private var levelMeters: some View {
        VStack(alignment: .trailing, spacing: 8) {
            meterRow(title: "Микрофон", level: recorder.micLevel,
                     active: recorder.micActive, symbol: "mic.fill")
            meterRow(title: "Звук системы", level: recorder.systemLevel,
                     active: recorder.systemActive, symbol: "speaker.wave.2.fill")
        }
        .frame(width: 190)
    }

    private func meterRow(title: String, level: Float, active: Bool, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .foregroundStyle(active
                                 ? AnyShapeStyle(Theme.primary(settings.accent))
                                 : AnyShapeStyle(.tertiary))
                .frame(width: 14)
            Text(title)
                .font(.caption2)
                .foregroundStyle(active ? .secondary : .tertiary)
                .frame(width: 84, alignment: .leading)
            GradientProgress(value: Double(level), accent: settings.accent, height: 5)
                .opacity(active ? 1 : 0.3)
        }
    }

    // MARK: - Источники

    private var sourcesRow: some View {
        HStack(spacing: 12) {
            sourceToggle(
                title: "Микрофон",
                subtitle: "Ваш голос — дорожка «Я»",
                symbol: "mic.fill",
                isOn: $settings.recordMicrophone
            )
            sourceToggle(
                title: "Звук системы",
                subtitle: "Zoom, Телемост, Telegram, браузер",
                symbol: "speaker.wave.3.fill",
                isOn: $settings.recordSystemAudio
            )
        }
    }

    private func sourceToggle(title: String, subtitle: String, symbol: String, isOn: Binding<Bool>) -> some View {
        Card(padding: 15) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(isOn.wrappedValue
                              ? AnyShapeStyle(Theme.gradient(settings.accent).opacity(0.18))
                              : AnyShapeStyle(Color.primary.opacity(0.06)))
                        .frame(width: 34, height: 34)
                    Image(systemName: symbol)
                        .font(.system(size: 14))
                        .foregroundStyle(isOn.wrappedValue
                                         ? AnyShapeStyle(Theme.gradient(settings.accent))
                                         : AnyShapeStyle(Color.secondary))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(.subheadline, design: .rounded, weight: .medium))
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Toggle("", isOn: isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(recorder.isBusy)
            }
        }
    }

    // MARK: - Постоянная запись

    private var continuousCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 11) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(recorder.isContinuous
                                  ? AnyShapeStyle(Theme.gradient(settings.accent).opacity(0.22))
                                  : AnyShapeStyle(Color.primary.opacity(0.06)))
                            .frame(width: 36, height: 36)
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 15))
                            .foregroundStyle(recorder.isContinuous
                                             ? AnyShapeStyle(Theme.gradient(settings.accent))
                                             : AnyShapeStyle(Color.secondary))
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Запись весь день")
                            .font(.system(.headline, design: .rounded))
                        Text(recorder.isContinuous
                             ? "Идёт \(Fmt.duration(recorder.elapsed)) · отрезки по \(settings.continuousSegmentMinutes) мин"
                             : "Непрерывная запись микрофона и звука системы с расшифровкой по ходу дня")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()

                    if recorder.isContinuous {
                        Button("Остановить") { Task { await recorder.stopContinuous() } }
                            .buttonStyle(AccentButtonStyle(accent: settings.accent, prominent: false))
                    } else {
                        Button("Включить") { Task { await recorder.startContinuous() } }
                            .buttonStyle(AccentButtonStyle(accent: settings.accent))
                            .disabled(recorder.isBusy)
                    }
                }

                Text("Всё, что прозвучало за день, попадает в одну запись: реплики помечаются «Я» "
                     + "и «Собеседник» по источнику звука, а текст накапливается в общей расшифровке — "
                     + "её можно выгрузить одним файлом и отдать агенту. "
                     + "Считайте расход диска: около \(Fmt.bytes(Int64(230 * 1024 * 1024))) в час на две дорожки.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Сводка за сегодня

    private var todaySummary: some View {
        let today = Stats.today(recordings: library.recordings, dictations: dictation.history)
        return HStack(spacing: 12) {
            StatTile(symbol: "waveform.badge.mic", title: "Продиктовано сегодня",
                     value: "\(today.dictationWords) слов",
                     detail: Fmt.plural(today.dictationCount, "диктовка", "диктовки", "диктовок"),
                     tint: Theme.primary(settings.accent))
            StatTile(symbol: "text.viewfinder", title: "Расшифровано сегодня",
                     value: "\(today.transcribedWords) слов",
                     detail: Fmt.plural(today.recordingCount, "запись", "записи", "записей"),
                     tint: Theme.success)
            StatTile(symbol: "clock", title: "Звука за сегодня",
                     value: Fmt.duration(today.totalSeconds),
                     detail: "диктовка и записи")
            Button {
                env.route = .stats
            } label: {
                Card(padding: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 7) {
                            Image(systemName: "chart.bar.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.primary(settings.accent))
                            Text("Статистика")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("Открыть")
                            .font(.system(.title3, design: .rounded, weight: .semibold))
                        Text("по дням, неделям, месяцам")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Разделы по типам записей

    @ViewBuilder
    private func categorySection(_ category: Recording.Category) -> some View {
        let items = library.recordings(in: category)
        if !items.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: category.symbol)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.gradient(settings.accent))
                        Text(category.title)
                            .font(.system(.headline, design: .rounded))
                        Text(Fmt.plural(items.count, "запись", "записи", "записей"))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button("Все") { env.route = .library }
                            .buttonStyle(.plain)
                            .font(.callout)
                            .foregroundStyle(Theme.primary(settings.accent))
                    }

                    ForEach(items.prefix(3)) { recording in
                        recordingRow(recording)
                        if recording.id != items.prefix(3).last?.id {
                            Divider().opacity(0.3)
                        }
                    }
                }
            }
        }
    }

    private func recordingRow(_ recording: Recording) -> some View {
        HStack(alignment: .top, spacing: 11) {
            VStack(alignment: .leading, spacing: 3) {
                Text(recording.title)
                    .font(.system(.callout, design: .rounded, weight: .medium))
                    .lineLimit(1)
                if let preview = recording.preview, !preview.isEmpty {
                    Text(preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    Text(Fmt.relativeDate(recording.createdAt))
                    Text("·")
                    Text(Fmt.duration(recording.duration)).monospacedDigit()
                    if case .done(_, let words) = recording.transcriptStatus {
                        Text("·")
                        Text("\(words) слов")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            Spacer()

            if recording.transcriptStatus.isDone {
                Button {
                    copyTranscript(recording)
                } label: {
                    Image(systemName: "doc.on.doc").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Скопировать текст расшифровки")
            }

            Button {
                env.open(recording: recording)
            } label: {
                Image(systemName: "chevron.right").font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { env.open(recording: recording) }
    }

    private func copyTranscript(_ recording: Recording) {
        guard let transcript = library.transcript(for: recording.id) else { return }
        let markdown = TranscriptMarkdown.render(transcript, recording: recording)
        TextInjector.copyToClipboard(markdown)
        env.banner = .init(text: "Расшифровка скопирована в Markdown", kind: .success)
    }

    // MARK: - История диктовки

    @ViewBuilder
    private var dictationHistoryCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("История диктовки")
                        .font(.system(.headline, design: .rounded))
                    Spacer()
                    if !dictation.history.isEmpty {
                        Text(Fmt.plural(dictation.history.count, "запись", "записи", "записей"))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Button("Настроить") { env.route = .dictation }
                        .buttonStyle(.plain)
                        .font(.callout)
                        .foregroundStyle(Theme.primary(settings.accent))
                }

                if dictation.history.isEmpty {
                    Text("Здесь появится всё, что вы продиктуете сочетанием \(settings.dictationHotKey.displayString). "
                         + "Полезно, если вставка ушла не в то окно — текст можно скопировать повторно.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(dictation.history.prefix(6)) { entry in
                        HStack(alignment: .top, spacing: 11) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.text)
                                    .font(.callout)
                                    .lineLimit(2)
                                    .textSelection(.enabled)
                                HStack(spacing: 6) {
                                    Text(Fmt.shortTime(entry.createdAt))
                                    if let app = entry.targetApp { Text("→ \(app)") }
                                    Text("· \(Stats.wordCount(entry.text)) слов")
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
                        .padding(.vertical, 4)
                        if entry.id != dictation.history.prefix(6).last?.id {
                            Divider().opacity(0.3)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Живая расшифровка

    @ViewBuilder
    private var liveTranscription: some View {
        if let job = transcription.current {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        ThinkingDots(accent: settings.accent)
                        Text(job.stage)
                            .font(.system(.subheadline, design: .rounded, weight: .medium))
                            .shimmer()
                        Spacer()
                        if job.realtimeFactor > 0.1 {
                            Pill(text: "×\(String(format: "%.1f", job.realtimeFactor)) к реальному времени",
                                 color: Theme.primary(settings.accent))
                        }
                        Text(Fmt.percent(job.progress * 100))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Button {
                            transcription.cancelCurrent()
                        } label: {
                            Image(systemName: "stop.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Остановить распознавание")
                    }

                    GradientProgress(value: job.progress, accent: settings.accent)

                    if !transcription.liveSegments.isEmpty {
                        ScrollViewReader { proxy in
                            ScrollView {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(transcription.liveSegments.suffix(30)) { segment in
                                        HStack(alignment: .top, spacing: 8) {
                                            Text(Fmt.duration(segment.start))
                                                .font(.caption2.monospacedDigit())
                                                .foregroundStyle(.tertiary)
                                                .frame(width: 42, alignment: .trailing)
                                            Text(segment.text)
                                                .font(.callout)
                                                .textSelection(.enabled)
                                        }
                                        .id(segment.id)
                                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 190)
                            .onChange(of: transcription.liveSegments.count) {
                                withAnimation(.easeOut(duration: 0.25)) {
                                    proxy.scrollTo(transcription.liveSegments.last?.id, anchor: .bottom)
                                }
                            }
                        }
                    }
                }
            }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    // MARK: - Импорт

    private var importCard: some View {
        Card {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            isDropTargeted ? Theme.primary(settings.accent) : Color.primary.opacity(0.15),
                            style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                        )
                        .frame(width: 44, height: 44)
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 16))
                        .foregroundStyle(isDropTargeted ? Theme.primary(settings.accent) : .secondary)
                        .scaleEffect(isDropTargeted ? 1.15 : 1)
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isDropTargeted)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Перетащите аудио или видео сюда")
                        .font(.system(.subheadline, design: .rounded, weight: .medium))
                    Text("mp3, m4a, wav, flac, mp4, mov — файл копируется в контейнер приложения")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Выбрать файл…") { showImporter = true }
                    .buttonStyle(AccentButtonStyle(accent: settings.accent, prominent: false))
            }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(Theme.primary(settings.accent).opacity(0.08))
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Вспомогательное

    private var stateTitle: String {
        switch recorder.state {
        case .idle: return "Готов к записи"
        case .preparing: return "Подключаю источники…"
        case .recording: return "Идёт запись"
        case .paused: return "Пауза"
        case .finishing: return "Сохраняю…"
        }
    }

    private var stateSubtitle: String {
        switch recorder.state {
        case .idle:
            var parts: [String] = []
            if settings.recordMicrophone { parts.append("микрофон") }
            if settings.recordSystemAudio { parts.append("звук системы") }
            return parts.isEmpty
                ? "Включите хотя бы один источник"
                : "Источники: " + parts.joined(separator: " и ")
        case .preparing: return "Запрашиваю доступ к устройствам"
        case .recording:
            return recorder.systemActive && recorder.micActive
                ? "Две дорожки: ваш голос и звук собеседников — они разделятся в расшифровке"
                : "Одна дорожка"
        case .paused: return "Запись приостановлена, файл не потерян"
        case .finishing: return "Закрываю файлы"
        }
    }

    /// Импортирует файлы и, если так настроено, спрашивает про говорящих.
    ///
    /// Спрашиваем до расшифровки, а не после: заданное число голосов меняет то,
    /// как приложение делит запись, и уточнять его потом означало бы гонять
    /// распознавание второй раз.
    @MainActor
    private func runImport(_ urls: [URL]) async {
        let ask = settings.diarizationEnabled && settings.askSpeakersOnImport
        var imported: [Recording] = []
        for url in urls {
            guard AudioLoader.supportedExtensions.contains(url.pathExtension.lowercased())
                    || urls.count == 1
            else { continue }
            if let recording = await recorder.importFile(at: url, autoQueue: !ask) {
                imported.append(recording)
            }
        }
        if ask, !imported.isEmpty { pendingSpeakerSetup = imported }
    }

    private func applySpeakers(count: Int?, names: [String]) {
        let cleaned = names.map { $0.trimmingCharacters(in: .whitespaces) }
        for recording in pendingSpeakerSetup {
            var updated = recording
            updated.expectedSpeakers = count
            updated.speakerNames = cleaned.contains(where: { !$0.isEmpty }) ? cleaned : []
            library.update(updated)
            if settings.autoTranscribeAfterRecording { transcription.enqueue(updated) }
        }
        let last = pendingSpeakerSetup.last?.id
        pendingSpeakerSetup = []
        if let last { env.selectedRecording = last }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { continue }
            handled = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url,
                      AudioLoader.supportedExtensions.contains(url.pathExtension.lowercased())
                else { return }
                Task { @MainActor in await runImport([url]) }
            }
        }
        return handled
    }
}

/// Компактная карточка записи для горизонтальной ленты.
struct RecordingChip: View {
    let recording: Recording
    @EnvironmentObject private var settings: Settings

    var body: some View {
        Card(padding: 13) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: recording.source.symbol)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.primary(settings.accent))
                    Text(Fmt.duration(recording.duration))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    statusDot
                }
                Text(recording.title)
                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(Fmt.relativeDate(recording.createdAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 208, height: 108)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var statusDot: some View {
        switch recording.transcriptStatus {
        case .done: Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10)).foregroundStyle(Theme.success)
        case .running, .queued: ProgressView().controlSize(.mini).scaleEffect(0.6)
        case .failed: Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 10)).foregroundStyle(Theme.danger)
        case .none: EmptyView()
        }
    }
}

/// Предложение остановить запись, когда программа отпустила микрофон.
///
/// Не останавливаем сами (если так не настроено): человек мог продолжить
/// разговор в другой программе или диктовать себе заметку. Но и молчать нельзя —
/// забытая запись пишет часами, а потом столько же расшифровывается.
struct FinishProposalCard: View {
    let appName: String
    let elapsed: TimeInterval
    let accent: Settings.AccentTheme
    /// `nil`, если программу опознать не удалось: тогда и отключать нечего.
    let onMute: (() -> Void)?
    let onKeep: () -> Void
    let onFinish: () -> Void

    var body: some View {
        Card {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Theme.warning.opacity(0.16))
                        .frame(width: 40, height: 40)
                    Image(systemName: "mic.slash.fill")
                        .foregroundStyle(Theme.warning)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(appName) освободил микрофон")
                        .font(.system(.headline, design: .rounded))
                    Text("Похоже, разговор закончился. Запись идёт \(Fmt.duration(elapsed)) — завершить?")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if let onMute {
                    Button("Не спрашивать об этой программе", action: onMute)
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                Button("Продолжить", action: onKeep)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Button("Завершить", action: onFinish)
                    .buttonStyle(AccentButtonStyle(accent: accent))
                    .fixedSize()
            }
        }
    }
}
