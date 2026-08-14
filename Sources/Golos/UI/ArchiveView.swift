import SwiftUI
import AppKit

/// Архив расшифровок: список Markdown-файлов с просмотром и правкой на месте.
struct ArchiveView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: Settings

    @State private var files: [URL] = []
    @State private var selected: URL?
    @State private var text: String = ""
    @State private var loadedText: String = ""
    @State private var rendered = true

    private var isDirty: Bool { text != loadedText }

    var body: some View {
        Group {
            if let selected {
                filePage(selected)
            } else {
                listPage
            }
        }
        .onAppear(perform: reload)
    }

    // MARK: - Список файлов

    private var listPage: some View {
        VStack(spacing: 0) {
            header

            if files.isEmpty {
                EmptyStateView(
                    symbol: "folder",
                    title: "Архив пуст",
                    message: settings.archiveEnabled
                        ? "Файлы появятся здесь после первой расшифровки встречи или дневной записи."
                        : "Архив выключен в настройках — расшифровки не выгружаются в файлы.",
                    actionTitle: settings.archiveEnabled ? nil : "Открыть настройки",
                    action: settings.archiveEnabled ? nil : { env.route = .settings }
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 9) {
                        ForEach(files, id: \.path) { url in
                            fileRow(url)
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Транскрипции")
                        .font(.system(.title2, design: .rounded, weight: .semibold))
                    Text(TranscriptArchive.root(settings).path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Показать в Finder") { TranscriptArchive.revealInFinder(settings) }
                    .buttonStyle(AccentButtonStyle(accent: settings.accent, prominent: false))
                Button { reload() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 14)
        .frame(maxWidth: 940)
        .frame(maxWidth: .infinity)
    }

    private func fileRow(_ url: URL) -> some View {
        Card(padding: 14) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Theme.gradient(settings.accent).opacity(0.16))
                        .frame(width: 34, height: 34)
                    Image(systemName: "doc.text")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.gradient(settings.accent))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.deletingPathExtension().lastPathComponent)
                        .font(.system(.callout, design: .rounded, weight: .medium))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(url.deletingLastPathComponent().lastPathComponent)
                        Text("·")
                        Text(Fmt.bytes(fileSize(url)))
                        if let date = modified(url) {
                            Text("·")
                            Text(Fmt.relativeDate(date))
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { open(url) }
        .contextMenu {
            Button("Открыть") { open(url) }
            Button("Показать в Finder") {
                NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
            }
            Button("Скопировать текст") {
                if let content = try? String(contentsOf: url, encoding: .utf8) {
                    TextInjector.copyToClipboard(content)
                    env.banner = .init(text: "Скопировано", kind: .success)
                }
            }
        }
    }

    // MARK: - Просмотр и правка

    private func filePage(_ url: URL) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    closeFile()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text("Транскрипции").font(.system(.callout, design: .rounded, weight: .medium))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.primary(settings.accent))

                Spacer()

                Text(url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()

                Picker("", selection: $rendered) {
                    Text("Просмотр").tag(true)
                    Text("Правка").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 170)

                if isDirty {
                    Button("Сохранить") { save(url) }
                        .buttonStyle(AccentButtonStyle(accent: settings.accent))
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)

            Divider().opacity(0.4)

            if rendered {
                ScrollView {
                    // Markdown отдаётся штатному рендереру SwiftUI: заголовки,
                    // списки и выделение он показывает, экзотику — нет.
                    Text(attributed)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(24)
                        .frame(maxWidth: 900)
                        .frame(maxWidth: .infinity)
                }
            } else {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(18)
            }
        }
    }

    private var attributed: AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    // MARK: - Файловые действия

    private func reload() {
        files = TranscriptArchive.files(settings)
    }

    private func open(_ url: URL) {
        text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        loadedText = text
        rendered = true
        selected = url
    }

    private func closeFile() {
        selected = nil
        text = ""
        loadedText = ""
        reload()
    }

    private func save(_ url: URL) {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            loadedText = text
            env.banner = .init(text: "Файл сохранён", kind: .success)
        } catch {
            env.banner = .init(text: "Не удалось сохранить: \(error.localizedDescription)", kind: .error)
        }
    }

    private func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    private func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
