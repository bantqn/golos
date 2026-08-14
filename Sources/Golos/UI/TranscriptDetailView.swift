import SwiftUI
import AVFoundation
import AppKit

/// Простой плеер для прослушивания записи вместе с текстом.
@MainActor
final class AudioPlayerModel: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func load(_ url: URL) {
        stop()
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.prepareToPlay()
        self.player = player
        duration = player.duration
        position = 0
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            stopTimer()
        } else {
            player.play()
            isPlaying = true
            startTimer()
        }
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = max(0, min(duration, time))
        position = player.currentTime
        if !player.isPlaying { toggle() }
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        position = 0
        duration = 0
        stopTimer()
    }

    private func startTimer() {
        stopTimer()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.position = player.currentTime
                if !player.isPlaying && self.isPlaying {
                    self.isPlaying = false
                    self.stopTimer()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

struct TranscriptDetailView: View {
    let recording: Recording

    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var transcription: TranscriptionService
    @StateObject private var player = AudioPlayerModel()

    @State private var editingSegment: UUID?
    @State private var draftText = ""
    @State private var exportFormat: ExportFormat = .markdown
    @State private var showExporter = false
    @State private var showSpeakers = false
    @State private var draftExpected: Int?
    @State private var draftNames: [String] = []

    private var transcript: Transcript? { library.transcript(for: recording.id) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            content
        }
        .background(.clear)
        .onAppear(perform: loadAudio)
        .onDisappear { player.stop() }
        .fileExporter(
            isPresented: $showExporter,
            document: TextDocument(text: exportedText),
            contentType: exportFormat.contentType,
            defaultFilename: recording.title
        ) { _ in }
    }

    // MARK: - Шапка

    private var header: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(recording.title)
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .lineLimit(2)
                    HStack(spacing: 7) {
                        Pill(text: recording.source.title, color: Theme.primary(settings.accent))
                        if let hint = recording.appHint { Pill(text: hint) }
                        Text(Fmt.date(recording.createdAt))
                        Text("·")
                        Text(Fmt.duration(recording.duration)).monospacedDigit()
                        if let transcript {
                            Text("·")
                            Text(ModelCatalog.spec(id: transcript.modelID)?.title ?? transcript.modelID)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                actions
            }

            if !recording.tracks.isEmpty { playerBar }
        }
        .padding(18)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if let transcript {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(transcript.plainText, forType: .string)
                    env.banner = .init(text: "Текст скопирован", kind: .success)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help("Скопировать весь текст")

                Menu {
                    ForEach(ExportFormat.allCases) { format in
                        Button(format.title) {
                            exportFormat = format
                            showExporter = true
                        }
                    }
                    Divider()
                    Button("Сохранить в папку приложения") {
                        saveToContainer()
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 24)
                .help("Экспорт")
            }

            if canDiarize {
                Button {
                    draftExpected = recording.expectedSpeakers
                    draftNames = recording.speakerNames
                    showSpeakers = true
                } label: {
                    Image(systemName: "person.2.badge.gearshape")
                }
                .buttonStyle(.plain)
                .help("Кто говорит: число голосов и имена")
                .popover(isPresented: $showSpeakers, arrowEdge: .bottom) { speakerPopover }
            }

            Button {
                transcription.enqueue(recording)
            } label: {
                Label(recording.transcriptStatus.isDone ? "Заново" : "Расшифровать",
                      systemImage: "text.viewfinder")
            }
            .buttonStyle(AccentButtonStyle(accent: settings.accent,
                                           prominent: !recording.transcriptStatus.isDone))
            .disabled(recording.transcriptStatus.isRunning || recording.tracks.isEmpty)
        }
    }

    private var playerBar: some View {
        HStack(spacing: 12) {
            Button(action: player.toggle) {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.gradient(settings.accent))
            }
            .buttonStyle(.plain)
            .disabled(player.duration == 0)

            Text(Fmt.duration(player.position))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule()
                        .fill(Theme.gradient(settings.accent))
                        .frame(width: geo.size.width * progressFraction)
                }
                .contentShape(Rectangle())
                .onTapGesture { location in
                    guard player.duration > 0 else { return }
                    player.seek(to: player.duration * (location.x / geo.size.width))
                }
            }
            .frame(height: 6)

            Text(Fmt.duration(player.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .leading)

            if recording.tracks.count > 1 {
                Menu {
                    ForEach(recording.tracks, id: \.fileName) { track in
                        Button(track.kind.title) { player.load(recording.url(for: track)) }
                    }
                } label: {
                    Image(systemName: "waveform.badge.plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 22)
                .help("Выбрать дорожку")
            }
        }
    }

    private var progressFraction: CGFloat {
        player.duration > 0 ? CGFloat(player.position / player.duration) : 0
    }

    // MARK: - Содержимое

    @ViewBuilder
    private var content: some View {
        switch recording.transcriptStatus {
        case .done:
            if let transcript { transcriptBody(transcript) } else { missingTranscript }

        case .running(let progress):
            VStack(spacing: 16) {
                Spacer()
                ThinkingDots(accent: settings.accent)
                Text("Распознаю речь")
                    .font(.system(.title3, design: .rounded, weight: .medium))
                    .shimmer()
                GradientProgress(value: progress, accent: settings.accent)
                    .frame(width: 260)
                if let job = transcription.current, job.realtimeFactor > 0.1 {
                    Text("×\(String(format: "%.1f", job.realtimeFactor)) от реального времени")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(30)

        case .queued:
            EmptyStateView(symbol: "clock", title: "В очереди",
                           message: "Распознавание начнётся, как только освободится движок.")

        case .failed(let message):
            EmptyStateView(
                symbol: "exclamationmark.triangle",
                title: "Расшифровка не удалась",
                message: message,
                actionTitle: "Попробовать снова",
                action: { transcription.enqueue(recording) }
            )

        case .none:
            EmptyStateView(
                symbol: "text.viewfinder",
                title: "Ещё не расшифровано",
                message: "Запись сохранена. Нажмите «Расшифровать», чтобы получить текст — всё считается локально.",
                actionTitle: "Расшифровать",
                action: { transcription.enqueue(recording) }
            )
        }
    }

    private var missingTranscript: some View {
        EmptyStateView(symbol: "questionmark.folder", title: "Файл расшифровки не найден",
                       message: "Похоже, он был удалён вручную. Запустите распознавание заново.",
                       actionTitle: "Расшифровать", action: { transcription.enqueue(recording) })
    }

    private func transcriptBody(_ transcript: Transcript) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    summary(transcript)
                    speakerHint(transcript)

                    ForEach(transcript.segments) { segment in
                        SegmentRow(
                            segment: segment,
                            isCurrent: isCurrent(segment),
                            speakerLabel: recording.speakerTitle(for: segment.speaker),
                            showSpeaker: transcript.segments.contains { $0.speaker != .unknown },
                            accent: settings.accent,
                            isEditing: editingSegment == segment.id,
                            draft: $draftText,
                            onSeek: { player.seek(to: segment.start) },
                            onBeginEdit: {
                                draftText = segment.text
                                editingSegment = segment.id
                            },
                            onCommit: {
                                library.updateSegmentText(
                                    recordingID: recording.id, segmentID: segment.id, text: draftText)
                                editingSegment = nil
                            },
                            onCancel: { editingSegment = nil }
                        )
                        .id(segment.id)
                    }
                }
                .padding(18)
            }
            .onChange(of: player.position) {
                guard player.isPlaying,
                      let current = transcript.segments.first(where: { isCurrent($0) })
                else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(current.id, anchor: .center)
                }
            }
        }
    }

    private func summary(_ transcript: Transcript) -> some View {
        Card(padding: 14) {
            HStack(spacing: 22) {
                summaryItem("Реплик", "\(transcript.segments.count)")
                if let voices = voiceSummary(transcript) {
                    summaryItem("голосов", voices)
                }
                summaryItem("Слов", "\(transcript.wordCount)")
                summaryItem("Язык", Languages.title(for: transcript.language))
                summaryItem("Считалось", Fmt.duration(transcript.processingSeconds))
                let factor = recording.duration / max(0.1, transcript.processingSeconds)
                summaryItem("Скорость", "×\(String(format: "%.1f", factor))")
                Spacer()
            }
        }
    }

    // MARK: - Роли

    /// Разделять по голосам есть смысл только там, где на дорожке может быть
    /// больше одного человека: у микрофона говорящий известен заранее.
    private var canDiarize: Bool {
        settings.diarizationEnabled
            && recording.tracks.contains { $0.kind != .mic }
    }

    private var speakerPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Кто говорит")
                .font(.system(.headline, design: .rounded))

            SpeakerSetupView(expected: $draftExpected, names: $draftNames)

            Divider().opacity(0.4)

            HStack {
                Button("Только сохранить") { saveSpeakers(rerun: false) }
                    .buttonStyle(.plain)
                    .font(.callout)
                Spacer()
                Button("Сохранить и пересчитать") { saveSpeakers(rerun: true) }
                    .buttonStyle(.borderedProminent)
            }

            Text("Пересчёт заново распознаёт запись: роли определяются по звуку, "
                 + "а не по готовому тексту.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 350)
    }

    private func saveSpeakers(rerun: Bool) {
        var updated = recording
        updated.expectedSpeakers = draftExpected
        let cleaned = draftNames.map { $0.trimmingCharacters(in: .whitespaces) }
        updated.speakerNames = cleaned.contains(where: { !$0.isEmpty }) ? cleaned : []
        library.update(updated)
        showSpeakers = false
        if rerun { transcription.enqueue(updated) }
    }

    /// Подсказка ровно в том случае, когда разделение не сработало.
    ///
    /// Автоопределение отказывается делить запись, если голоса близки по тону —
    /// иначе оно принимало бы одного человека за нескольких. Молча оставлять
    /// пользователя с неразделённой расшифровкой неправильно: он не может знать,
    /// что число говорящих можно задать руками.
    @ViewBuilder
    private func speakerHint(_ transcript: Transcript) -> some View {
        if canDiarize, voiceSummary(transcript) == nil, recording.expectedSpeakers == nil,
           transcript.segments.count > 1 || recording.duration > 60 {
            Card(padding: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "person.2.slash")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Роли не разделились")
                            .font(.system(.callout, design: .rounded, weight: .medium))
                        Text("Слишком похожий тон не позволяет надёжно разделить голоса. "
                             + "Укажите, сколько человек говорит, — и роли разложатся точно.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Указать") {
                        draftExpected = recording.expectedSpeakers ?? 2
                        draftNames = recording.speakerNames
                        showSpeakers = true
                    }
                    .buttonStyle(AccentButtonStyle(accent: settings.accent, prominent: false))
                }
            }
        }
    }

    private func summaryItem(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.tertiary)
            Text(value)
                .font(.system(.callout, design: .rounded, weight: .medium))
                .monospacedDigit()
        }
    }

    /// Сколько разных голосов в расшифровке — и заданы ли они вручную.
    private func voiceSummary(_ transcript: Transcript) -> String? {
        let voices = Set(transcript.segments.compactMap { segment -> Int? in
            if case .voice(let index) = segment.speaker { return index } else { return nil }
        })
        guard !voices.isEmpty else { return nil }
        return recording.expectedSpeakers == nil ? "\(voices.count)" : "\(voices.count) (задано)"
    }

    private func isCurrent(_ segment: Segment) -> Bool {
        player.isPlaying && player.position >= segment.start && player.position < segment.end
    }

    // MARK: - Действия

    private func loadAudio() {
        guard let track = recording.playbackTrack else { return }
        let url = recording.url(for: track)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        player.load(url)
    }

    private var exportedText: String {
        guard let transcript else { return "" }
        return Exporter.render(transcript, recording: recording, format: exportFormat)
    }

    private func saveToContainer() {
        guard let transcript else { return }
        let text = Exporter.render(transcript, recording: recording, format: exportFormat)
        guard let url = try? Exporter.writeToContainer(text, recording: recording, format: exportFormat) else {
            env.banner = .init(text: "Не удалось сохранить файл", kind: .error)
            return
        }
        env.banner = .init(text: "Сохранено: \(url.lastPathComponent)", kind: .success)
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: Container.exports.path)
    }
}

/// Одна реплика: таймкод, говорящий, текст. По двойному клику — правка.
struct SegmentRow: View {
    let segment: Segment
    let isCurrent: Bool
    /// Готовая подпись: имя из настроек записи или «голос 2».
    let speakerLabel: String
    let showSpeaker: Bool
    let accent: Settings.AccentTheme
    let isEditing: Bool
    @Binding var draft: String
    let onSeek: () -> Void
    let onBeginEdit: () -> Void
    let onCommit: () -> Void
    let onCancel: () -> Void

    @State private var hovering = false

    /// Разным голосам — разные цвета, иначе в стене реплик роли не различить.
    private var speakerColor: Color {
        switch segment.speaker {
        case .me: return Theme.primary(accent)
        case .others, .unknown: return Theme.success
        case .voice(let index): return Theme.voiceColors[(index - 1) % Theme.voiceColors.count]
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onSeek) {
                Text(Fmt.duration(segment.start))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isCurrent
                                     ? AnyShapeStyle(Theme.primary(accent))
                                     : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.plain)
            .frame(width: 48, alignment: .trailing)

            if showSpeaker {
                Pill(text: speakerLabel, color: speakerColor, filled: false)
                    .frame(width: 92, alignment: .leading)
            }

            if isEditing {
                VStack(alignment: .leading, spacing: 7) {
                    TextEditor(text: $draft)
                        .font(.body)
                        .frame(minHeight: 60)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    HStack {
                        Spacer()
                        Button("Отмена", action: onCancel).buttonStyle(.plain).font(.caption)
                        Button("Сохранить", action: onCommit).buttonStyle(.borderedProminent).controlSize(.small)
                    }
                }
            } else {
                Text(segment.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(isCurrent ? Theme.primary(accent).opacity(0.13) : Color.clear)
                    )
                    .onTapGesture(count: 2, perform: onBeginEdit)
            }

            if hovering && !isEditing {
                Button(action: onBeginEdit) {
                    Image(systemName: "pencil").font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Исправить текст")
            }
        }
        .animation(.easeOut(duration: 0.2), value: isCurrent)
        .onHover { hovering = $0 }
    }
}

/// Обёртка для `fileExporter`.
struct TextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, .json] }
    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        text = String(data: data, encoding: .utf8) ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
