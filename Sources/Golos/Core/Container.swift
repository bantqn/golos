import Foundation

/// Единственное место на диске, где живёт приложение.
///
/// Всё — модели, записи, расшифровки, настройки, логи — лежит внутри
/// `~/Library/Application Support/Golos`. Приложение никогда не пишет
/// ничего за пределами этой папки (кроме буфера обмена при вставке текста).
/// Полное удаление = удалить .app и эту папку.
enum Container {

    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Golos", isDirectory: true)
    }()

    /// Скачанные ggml-модели whisper.
    static var models: URL { root.appendingPathComponent("models", isDirectory: true) }
    /// Аудиофайлы записей: одна папка на сессию.
    static var recordings: URL { root.appendingPathComponent("recordings", isDirectory: true) }
    /// JSON-расшифровки, по одной на сессию.
    static var transcripts: URL { root.appendingPathComponent("transcripts", isDirectory: true) }
    /// Временные файлы (буфер диктовки, промежуточные конвертации).
    static var tmp: URL { root.appendingPathComponent("tmp", isDirectory: true) }
    /// Логи движка распознавания и приложения.
    static var logs: URL { root.appendingPathComponent("logs", isDirectory: true) }
    /// Экспортированные пользователем файлы по умолчанию.
    static var exports: URL { root.appendingPathComponent("exports", isDirectory: true) }

    static var settingsFile: URL { root.appendingPathComponent("settings.json") }
    static var libraryFile: URL { root.appendingPathComponent("library.json") }

    static var allDirectories: [URL] {
        [root, models, recordings, transcripts, tmp, logs, exports]
    }

    /// Создаёт структуру папок. Вызывается один раз на старте.
    static func bootstrap() {
        for dir in allDirectories {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Записи и расшифровки не нужны в резервных копиях iCloud/Time Machine по умолчанию —
        // но решение за пользователем, поэтому ничего не исключаем принудительно.
        cleanTemporary()
    }

    static func cleanTemporary() {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: nil) else { return }
        for item in items { try? FileManager.default.removeItem(at: item) }
    }

    static func recordingDirectory(for id: UUID) -> URL {
        recordings.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func transcriptFile(for id: UUID) -> URL {
        transcripts.appendingPathComponent("\(id.uuidString).json")
    }

    /// Суммарный размер содержимого папки в байтах.
    static func size(of directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// Свободное место на томе с контейнером.
    static func freeDiskSpace() -> Int64 {
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }
}
