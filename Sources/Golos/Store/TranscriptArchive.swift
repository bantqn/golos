import Foundation
import AppKit

/// Архив расшифровок в виде Markdown-файлов на диске.
///
/// Единственное место, где приложение пишет за пределами своего контейнера, —
/// и делает это по прямой просьбе: файлы должны лежать там, где их удобно
/// подхватить другой программой или локальной моделью. Папку можно сменить
/// или выключить архив совсем.
enum TranscriptArchive {

    static var defaultRoot: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let current = documents.appendingPathComponent("голос", isDirectory: true)
        let legacy = documents.appendingPathComponent("Голос", isDirectory: true)

        // Однократная безопасная миграция регистра: данные не копируются и не
        // удаляются, меняется только пользовательское имя старой папки.
        if !FileManager.default.fileExists(atPath: current.path),
           FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.moveItem(at: legacy, to: current)
        }
        return current
    }

    static func root(_ settings: Settings) -> URL {
        guard let path = settings.archiveFolderPath, !path.isEmpty else { return defaultRoot }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Подпапка по категории. Диктовка сюда не попадает: это короткие фразы,
    /// им место в истории приложения, а не отдельными файлами на диске.
    static func folder(for recording: Recording, settings: Settings) -> URL? {
        switch recording.category {
        case .meetings: return root(settings).appendingPathComponent("Встречи", isDirectory: true)
        case .allDay: return root(settings).appendingPathComponent("Весь день", isDirectory: true)
        case .notes:
            guard settings.archiveNotes else { return nil }
            return root(settings).appendingPathComponent("Заметки", isDirectory: true)
        }
    }

    /// Имя файла: дата первой, чтобы сортировка по алфавиту совпадала
    /// с хронологией. У дневной записи — только дата, файл один на день.
    static func fileName(for recording: Recording) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")

        if recording.isContinuous {
            formatter.dateFormat = "yyyy-MM-dd"
            return "\(formatter.string(from: recording.createdAt)) — Весь день.md"
        }

        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        let stamp = formatter.string(from: recording.createdAt)
        let title = recording.appHint ?? recording.source.title
        return "\(stamp) — \(sanitize(title)).md"
    }

    private static func sanitize(_ text: String) -> String {
        text.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Записывает или перезаписывает файл расшифровки.
    /// - Returns: путь к файлу либо `nil`, если архив выключен или запись не архивируется.
    @discardableResult
    static func write(_ transcript: Transcript, recording: Recording, settings: Settings) -> URL? {
        guard settings.archiveEnabled else { return nil }
        guard let folder = folder(for: recording, settings: settings) else { return nil }

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(fileName(for: recording))
            let markdown = TranscriptMarkdown.render(transcript, recording: recording)
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            Log.warn("Не удалось записать расшифровку в архив: \(error.localizedDescription)")
            return nil
        }
    }

    static func revealInFinder(_ settings: Settings) {
        let url = root(settings)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
    }

    /// Все файлы архива — для списка в интерфейсе.
    static func files(_ settings: Settings) -> [URL] {
        let base = root(settings)
        guard let enumerator = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "md" {
            result.append(url)
        }
        return result.sorted { left, right in
            let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return leftDate > rightDate
        }
    }
}
