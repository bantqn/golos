import Foundation
import Combine

/// Состояние одной модели с точки зрения интерфейса.
enum ModelState: Equatable {
    case notInstalled
    case downloading(progress: Double, receivedBytes: Int64, speedBytesPerSecond: Double)
    case paused(receivedBytes: Int64)
    case installed(sizeOnDisk: Int64)
    case failed(String)

    var isDownloading: Bool { if case .downloading = self { return true }; return false }
    var isInstalled: Bool { if case .installed = self { return true }; return false }
}

/// Скачивание, проверка и удаление моделей.
/// Все файлы живут в `Container.models`, ничего наружу не пишется.
@MainActor
final class ModelStore: ObservableObject {

    @Published private(set) var states: [String: ModelState] = [:]
    /// Суммарный объём скачанных моделей.
    @Published private(set) var totalSizeOnDisk: Int64 = 0

    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var resumeData: [String: Data] = [:]
    private var session: URLSession!
    private let delegate = DownloadDelegate()

    init() {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForResource = 60 * 60 * 6   // большие модели на медленном канале
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        delegate.store = self
        refresh()
    }

    // MARK: - Состояние на диске

    func refresh() {
        var newStates: [String: ModelState] = [:]
        var total: Int64 = 0

        for spec in ModelCatalog.all {
            let url = fileURL(for: spec)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int64, size > 0 {
                // Незавершённая загрузка распознаётся по размеру, сильно меньшему ожидаемого.
                if size < spec.sizeBytes / 2 {
                    newStates[spec.id] = .failed("Файл повреждён — скачайте заново")
                } else {
                    newStates[spec.id] = .installed(sizeOnDisk: size)
                    total += size
                }
            } else if let existing = states[spec.id], existing.isDownloading, tasks[spec.id] != nil {
                newStates[spec.id] = existing
            } else if let existing = states[spec.id], case .paused = existing {
                newStates[spec.id] = existing
            } else {
                newStates[spec.id] = .notInstalled
            }
        }
        // Прогресс сохраняем только у тех загрузок, чья задача ещё жива.
        // Без проверки задачи только что докачанная модель получала обратно
        // состояние «идёт загрузка»: файл на диске, а интерфейс показывает
        // прогресс и не даёт ни отменить, ни удалить.
        for (id, state) in states where state.isDownloading && tasks[id] != nil {
            newStates[id] = state
        }
        states = newStates
        totalSizeOnDisk = total
    }

    func fileURL(for spec: ModelSpec) -> URL {
        Container.models.appendingPathComponent(spec.fileName)
    }

    func fileURL(forID id: String) -> URL? {
        guard let spec = ModelCatalog.spec(id: id) else { return nil }
        let url = fileURL(for: spec)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func state(for id: String) -> ModelState {
        states[id] ?? .notInstalled
    }

    /// Есть ли у модели живая задача загрузки. Интерфейс по этому признаку
    /// решает, показывать ли кнопки паузы и отмены.
    func hasActiveDownload(_ id: String) -> Bool {
        tasks[id] != nil
    }

    func isInstalled(_ id: String) -> Bool {
        state(for: id).isInstalled
    }

    var installedSpeechModels: [ModelSpec] {
        ModelCatalog.speechModels.filter { isInstalled($0.id) }
    }

    var hasAnyModel: Bool { !installedSpeechModels.isEmpty }

    /// Путь к модели VAD, если она скачана.
    var vadModelURL: URL? { fileURL(forID: ModelCatalog.vadModelID) }

    // MARK: - Загрузка

    func download(_ spec: ModelSpec) {
        guard tasks[spec.id] == nil else { return }

        let free = Container.freeDiskSpace()
        if free > 0 && free < spec.sizeBytes + 500 * 1024 * 1024 {
            states[spec.id] = .failed("Недостаточно места: нужно \(Fmt.bytes(spec.sizeBytes)), свободно \(Fmt.bytes(free))")
            return
        }

        let task: URLSessionDownloadTask
        if let data = resumeData[spec.id] {
            task = session.downloadTask(withResumeData: data)
            resumeData[spec.id] = nil
        } else {
            task = session.downloadTask(with: spec.url)
        }
        task.taskDescription = spec.id
        tasks[spec.id] = task
        states[spec.id] = .downloading(progress: 0, receivedBytes: 0, speedBytesPerSecond: 0)
        delegate.startTracking(spec.id)
        task.resume()
        Log.info("Начата загрузка модели \(spec.id) (\(Fmt.bytes(spec.sizeBytes)))")
    }

    func pause(_ spec: ModelSpec) {
        guard let task = tasks[spec.id] else { return }
        let received: Int64
        if case .downloading(_, let bytes, _) = state(for: spec.id) { received = bytes } else { received = 0 }
        task.cancel { [weak self] data in
            Task { @MainActor in
                guard let self else { return }
                if let data { self.resumeData[spec.id] = data }
                self.tasks[spec.id] = nil
                self.states[spec.id] = .paused(receivedBytes: received)
            }
        }
    }

    func cancel(_ spec: ModelSpec) {
        tasks[spec.id]?.cancel()
        tasks[spec.id] = nil
        resumeData[spec.id] = nil
        // Не выставляем состояние вручную: если файл уже дошёл до диска,
        // правда о нём — на диске, а не в нашей переменной.
        try? FileManager.default.removeItem(at: partialFileURL(for: spec))
        refresh()
    }

    /// Незавершённая загрузка живёт в tmp — там же, куда её кладёт делегат.
    private func partialFileURL(for spec: ModelSpec) -> URL {
        Container.tmp.appendingPathComponent("\(spec.id).part")
    }

    func delete(_ spec: ModelSpec) {
        cancel(spec)
        try? FileManager.default.removeItem(at: fileURL(for: spec))
        // Модель могла быть загружена в память — освобождаем.
        Engines.unloadAll()
        refresh()
        Log.info("Модель \(spec.id) удалена")
    }

    // MARK: - Приём результата загрузки

    fileprivate func finish(id: String, tempURL: URL) {
        guard let spec = ModelCatalog.spec(id: id) else { return }
        let destination = fileURL(for: spec)
        do {
            try FileManager.default.createDirectory(at: Container.models, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: tempURL, to: destination)

            guard Self.looksLikeGGML(destination) else {
                try? FileManager.default.removeItem(at: destination)
                states[id] = .failed("Скачанный файл не похож на модель ggml")
                tasks[id] = nil
                return
            }
            tasks[id] = nil
            refresh()
            Log.info("Модель \(id) установлена")
        } catch {
            states[id] = .failed(error.localizedDescription)
            tasks[id] = nil
        }
    }

    fileprivate func fail(id: String, error: Error) {
        tasks[id] = nil
        // Отмена пользователем — не ошибка.
        if (error as NSError).code == NSURLErrorCancelled { return }
        states[id] = .failed(error.localizedDescription)
        Log.error("Загрузка \(id) не удалась: \(error.localizedDescription)")
    }

    fileprivate func update(id: String, received: Int64, expected: Int64, speed: Double) {
        let total = expected > 0 ? expected : (ModelCatalog.spec(id: id)?.sizeBytes ?? 0)
        let progress = total > 0 ? min(1, Double(received) / Double(total)) : 0
        states[id] = .downloading(progress: progress, receivedBytes: received, speedBytesPerSecond: speed)
    }

    /// Файлы ggml начинаются с магического числа 0x67676d6c — дешёвая защита
    /// от сохранённой HTML-страницы с ошибкой вместо модели.
    /// На диске оно лежит в порядке little-endian, то есть байтами «lmgg».
    private static func looksLikeGGML(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4), data.count == 4 else { return false }
        return data == Data("lmgg".utf8) || data == Data("ggml".utf8)
    }
}

/// Делегат URLSession: считает прогресс и скорость.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {

    weak var store: ModelStore?
    private var startTimes: [String: Date] = [:]
    private var lastReport: [String: Date] = [:]
    private let lock = NSLock()

    func startTracking(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        startTimes[id] = Date()
        lastReport[id] = .distantPast
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }

        lock.lock()
        let start = startTimes[id] ?? Date()
        let last = lastReport[id] ?? .distantPast
        // Не чаще десяти обновлений в секунду — иначе SwiftUI захлёбывается.
        guard Date().timeIntervalSince(last) > 0.1 else { lock.unlock(); return }
        lastReport[id] = Date()
        lock.unlock()

        let elapsed = max(0.001, Date().timeIntervalSince(start))
        let speed = Double(totalBytesWritten) / elapsed

        Task { @MainActor [weak store] in
            store?.update(id: id, received: totalBytesWritten,
                          expected: totalBytesExpectedToWrite, speed: speed)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        // Файл во временной папке исчезнет после выхода из метода — переносим синхронно.
        let staging = Container.tmp.appendingPathComponent("\(id)-\(UUID().uuidString).part")
        try? FileManager.default.createDirectory(at: Container.tmp, withIntermediateDirectories: true)
        do {
            try FileManager.default.moveItem(at: location, to: staging)
        } catch {
            Task { @MainActor [weak store] in store?.fail(id: id, error: error) }
            return
        }
        Task { @MainActor [weak store] in store?.finish(id: id, tempURL: staging) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription, let error else { return }
        Task { @MainActor [weak store] in store?.fail(id: id, error: error) }
    }
}
