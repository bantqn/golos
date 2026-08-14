import SwiftUI
import AppKit

/// Библиотека записей.
///
/// Одна колонка с переходом внутрь записи, а не две рядом. Вложенный в колонку
/// `NavigationSplitView` сплиттер конфликтовал с её собственным изменением
/// размера, и вёрстка разъезжалась. Здесь этой проблемы нет по построению:
/// нет ни вложенных сплиттеров, ни фиксированных ширин.
struct LibraryView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var transcription: TranscriptionService

    @State private var pendingDeletion: Recording?
    @State private var renaming: Recording?
    @State private var draftTitle = ""

    private var selected: Recording? {
        guard let id = env.selectedRecording else { return nil }
        return library.recordings.first { $0.id == id }
    }

    var body: some View {
        Group {
            if let recording = selected {
                detailPage(recording)
            } else {
                listPage
            }
        }
        .animation(.easeInOut(duration: 0.2), value: env.selectedRecording)
        .confirmationDialog(
            "Удалить «\(pendingDeletion?.title ?? "")»?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("Удалить", role: .destructive) {
                if let recording = pendingDeletion {
                    if env.selectedRecording == recording.id { env.selectedRecording = nil }
                    library.delete(recording)
                }
                pendingDeletion = nil
            }
            Button("Отмена", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("Удалятся и аудио, и расшифровка. Освободится \(Fmt.bytes(pendingDeletion?.diskSize ?? 0)).")
        }
        .sheet(item: $renaming) { recording in
            renameSheet(recording)
        }
    }

    // MARK: - Список

    private var listPage: some View {
        VStack(spacing: 0) {
            header

            if library.filtered.isEmpty {
                EmptyStateView(
                    symbol: library.recordings.isEmpty ? "waveform.slash" : "magnifyingglass",
                    title: library.recordings.isEmpty ? "Пока пусто" : "Ничего не найдено",
                    message: library.recordings.isEmpty
                        ? "Запишите встречу или перетащите готовый аудиофайл на экран записи."
                        : "Попробуйте другой запрос.",
                    actionTitle: library.recordings.isEmpty ? "К записи" : nil,
                    action: library.recordings.isEmpty ? { env.route = .record } : nil
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 9) {
                        ForEach(library.filtered) { recording in
                            LibraryRow(recording: recording)
                                .onTapGesture { env.selectedRecording = recording.id }
                                .contextMenu { menu(for: recording) }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
                    .frame(maxWidth: 940)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Библиотека")
                        .font(.system(.title2, design: .rounded, weight: .semibold))
                    Text("\(Fmt.plural(library.recordings.count, "запись", "записи", "записей")) · \(Fmt.duration(library.totalDuration))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if transcription.queueCount > 0 {
                    Pill(text: "в очереди: \(transcription.queueCount)",
                         color: Theme.primary(settings.accent))
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                TextField("Поиск по названию и тексту расшифровки", text: Binding(
                    get: { library.searchQuery },
                    set: { library.searchQuery = $0 }
                ))
                .textFieldStyle(.plain)
                if !library.searchQuery.isEmpty {
                    Button { library.searchQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 14)
        .frame(maxWidth: 940)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func menu(for recording: Recording) -> some View {
        Button("Открыть") { env.selectedRecording = recording.id }
        Button("Переименовать") {
            draftTitle = recording.title
            renaming = recording
        }
        Button(recording.starred ? "Снять отметку" : "Отметить важным") {
            library.toggleStar(recording.id)
        }
        Divider()
        Button(recording.transcriptStatus.isDone ? "Расшифровать заново" : "Расшифровать") {
            transcription.enqueue(recording)
        }
        Button("Показать файлы") {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: recording.directory.path)
        }
        Divider()
        Button("Удалить", role: .destructive) { pendingDeletion = recording }
    }

    // MARK: - Запись

    private func detailPage(_ recording: Recording) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    env.selectedRecording = nil
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Библиотека")
                            .font(.system(.callout, design: .rounded, weight: .medium))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.primary(settings.accent))

                Spacer()

                Button {
                    draftTitle = recording.title
                    renaming = recording
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Переименовать")

                Button {
                    pendingDeletion = recording
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Удалить запись")
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)

            Divider().opacity(0.4)

            TranscriptDetailView(recording: recording)
                .id(recording.id)
        }
    }

    private func renameSheet(_ recording: Recording) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Переименовать запись")
                .font(.system(.headline, design: .rounded))
            TextField("Название", text: $draftTitle)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit { commitRename(recording) }
            HStack {
                Spacer()
                Button("Отмена") { renaming = nil }
                Button("Сохранить") { commitRename(recording) }
                    .buttonStyle(.borderedProminent)
                    .disabled(draftTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
    }

    private func commitRename(_ recording: Recording) {
        library.rename(recording.id, to: draftTitle)
        renaming = nil
    }
}

/// Строка списка на всю ширину: помимо названия показывает начало расшифровки.
struct LibraryRow: View {
    let recording: Recording

    @EnvironmentObject private var settings: Settings
    @State private var hovering = false

    private var preview: String? {
        guard let text = recording.preview, !text.isEmpty else { return nil }
        return text
    }

    var body: some View {
        Card(padding: 14) {
            HStack(alignment: .top, spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.gradient(settings.accent).opacity(0.16))
                        .frame(width: 38, height: 38)
                    Image(systemName: recording.source.symbol)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.gradient(settings.accent))
                }

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        if recording.starred {
                            Image(systemName: "star.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.warning)
                        }
                        Text(recording.title)
                            .font(.system(.headline, design: .rounded, weight: .medium))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        status
                    }

                    HStack(spacing: 7) {
                        Text(Fmt.relativeDate(recording.createdAt))
                        Text("·")
                        Text(Fmt.duration(recording.duration)).monospacedDigit()
                        if let hint = recording.appHint {
                            Text("·")
                            Text(hint).lineLimit(1)
                        }
                        if let modelID = recording.modelID,
                           let spec = ModelCatalog.spec(id: modelID) {
                            Text("·")
                            Text(spec.title).lineLimit(1)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                    if let preview {
                        Text(preview)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(hovering
                              ? AnyShapeStyle(Theme.primary(settings.accent).opacity(0.4))
                              : AnyShapeStyle(Color.clear), lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    @ViewBuilder
    private var status: some View {
        switch recording.transcriptStatus {
        case .none:
            Text("не расшифровано")
                .font(.caption2)
                .foregroundStyle(.quaternary)
        case .queued:
            Label("в очереди", systemImage: "clock")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        case .running(let progress):
            HStack(spacing: 5) {
                CircularMini(progress: progress, accent: settings.accent)
                Text(Fmt.percent(progress * 100))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .done(_, let words):
            Text(Fmt.plural(words, "слово", "слова", "слов"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        case .failed:
            Label("ошибка", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(Theme.danger)
        }
    }
}

/// Крошечное кольцо прогресса для строки списка.
struct CircularMini: View {
    let progress: Double
    let accent: Settings.AccentTheme

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.03, progress))
                .stroke(Theme.gradient(accent), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.3), value: progress)
        }
        .frame(width: 15, height: 15)
    }
}
