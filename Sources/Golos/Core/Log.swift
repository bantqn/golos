import Foundation
import os

/// Логи пишутся и в unified logging, и в файл внутри контейнера,
/// чтобы можно было приложить их к отчёту об ошибке не выходя из приложения.
enum Log {

    private static let logger = Logger(subsystem: "ai.cybergusli.golos", category: "app")
    private static let queue = DispatchQueue(label: "ai.cybergusli.golos.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static var fileURL: URL { Container.logs.appendingPathComponent("golos.log") }

    static func info(_ message: String) { write("INFO ", message); logger.info("\(message, privacy: .public)") }
    static func warn(_ message: String) { write("WARN ", message); logger.warning("\(message, privacy: .public)") }
    static func error(_ message: String) { write("ERROR", message); logger.error("\(message, privacy: .public)") }

    private static func write(_ level: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(level)] \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            let url = fileURL
            let fm = FileManager.default
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: data)
                return
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            // Простая ротация: держим файл не больше 4 МБ.
            let size = (try? handle.seekToEnd()) ?? 0
            if size > 4 * 1024 * 1024 {
                try? handle.truncate(atOffset: 0)
            }
            try? handle.write(contentsOf: data)
        }
    }

    /// Дожидается, пока всё записанное окажется на диске.
    /// Нужно перед завершением процесса: запись идёт асинхронно.
    static func flush() {
        queue.sync { }
    }

    static func clear() {
        queue.async { try? FileManager.default.removeItem(at: fileURL) }
    }
}
