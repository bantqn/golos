import Foundation
import CWhisper

/// Обёртка над C-API Parakeet из whisper.cpp.
///
/// Parakeet TDT — модель другой архитектуры (transducer, а не encoder-decoder).
/// Практическая разница: она заметно быстрее whisper при сравнимом качестве и
/// не умеет ни перевода, ни выбора языка — язык определяется сама. Поэтому часть
/// настроек `WhisperOptions` здесь просто не применяется, и интерфейс об этом
/// честно предупреждает.
final class ParakeetEngine: SpeechEngine, @unchecked Sendable {

    private let queue: DispatchQueue

    private var context: OpaquePointer?
    private var loadedKey: String?
    private var lastUsed = Date()
    private var evictionTimer: DispatchSourceTimer?
    private let stateLock = NSLock()
    private var loadedModelName: String?
    private var idleUnload: TimeInterval = 60

    var idleUnloadSeconds: TimeInterval {
        get {
            stateLock.lock(); defer { stateLock.unlock() }
            return idleUnload
        }
        set {
            stateLock.lock()
            idleUnload = max(0, newValue)
            stateLock.unlock()
        }
    }

    var loadedModel: String? {
        stateLock.lock(); defer { stateLock.unlock() }
        return loadedModelName
    }

    var isModelLoaded: Bool { loadedModel != nil }

    private func setLoadedModel(_ name: String?) {
        stateLock.lock()
        loadedModelName = name
        stateLock.unlock()
    }

    init(label: String) {
        queue = DispatchQueue(label: "ai.cybergusli.golos.parakeet.\(label)", qos: .userInitiated)

        parakeet_log_set({ level, message, _ in
            guard level.rawValue >= GGML_LOG_LEVEL_WARN.rawValue, let message else { return }
            let text = String(cString: message).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if level.rawValue >= GGML_LOG_LEVEL_ERROR.rawValue {
                Log.error("parakeet: \(text)")
            } else {
                Log.warn("parakeet: \(text)")
            }
        }, nil)
        startEvictionTimer()
    }

    // MARK: - Жизненный цикл модели

    private func key(for options: WhisperOptions) -> String {
        "\(options.modelURL.path)|gpu=\(options.useGPU)"
    }

    func preload(_ options: WhisperOptions) {
        queue.async { [weak self] in
            _ = try? self?.ensureContext(options)
        }
    }

    private func ensureContext(_ options: WhisperOptions) throws -> OpaquePointer {
        dispatchPrecondition(condition: .onQueue(queue))
        lastUsed = Date()

        let wanted = key(for: options)
        if let context, loadedKey == wanted { return context }

        unloadLocked()

        guard FileManager.default.fileExists(atPath: options.modelURL.path) else {
            throw WhisperError.modelMissing(options.modelURL)
        }

        var params = parakeet_context_default_params()
        params.use_gpu = options.useGPU

        let started = Date()
        guard let ctx = parakeet_init_from_file_with_params(options.modelURL.path, params) else {
            throw WhisperError.modelLoadFailed(options.modelURL)
        }
        context = ctx
        loadedKey = wanted
        setLoadedModel(options.modelURL.deletingPathExtension().lastPathComponent)
        Log.info("Parakeet \(options.modelURL.lastPathComponent) загружена за \(String(format: "%.2f", Date().timeIntervalSince(started))) с (GPU: \(options.useGPU)), процесс занимает \(Fmt.bytes(MemoryGuard.footprintBytes))")
        return ctx
    }

    private func unloadLocked() {
        if let context {
            parakeet_free(context)
            let name = loadedModelName ?? "модель"
            setLoadedModel(nil)
            Log.info("\(name) выгружена, процесс занимает \(Fmt.bytes(MemoryGuard.footprintBytes))")
        }
        context = nil
        loadedKey = nil
    }

    func unload() {
        queue.async { [weak self] in self?.unloadLocked() }
    }

    func unloadAndWait() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.unloadLocked()
                continuation.resume()
            }
        }
    }

    private func startEvictionTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            guard let self, self.context != nil else { return }
            if Date().timeIntervalSince(self.lastUsed) >= self.idleUnloadSeconds {
                self.unloadLocked()
            }
        }
        timer.resume()
        evictionTimer = timer
    }

    // MARK: - Распознавание

    func transcribe(
        samples: [Float],
        options: WhisperOptions,
        timeOffset: TimeInterval = 0,
        onProgress: ((Double) -> Void)? = nil,
        onSegment: ((Segment) -> Void)? = nil,
        isCancelled: (() -> Bool)? = nil
    ) throws -> [Segment] {
        try queue.sync {
            let ctx = try ensureContext(options)
            defer { lastUsed = Date() }

            var params = parakeet_full_default_params(PARAKEET_SAMPLING_GREEDY)
            params.n_threads = Int32(options.threads)
            params.no_context = true

            let box = CallbackBox(onProgress: onProgress, onSegment: onSegment,
                                  isCancelled: isCancelled, timeOffset: timeOffset)
            let boxPointer = Unmanaged.passUnretained(box).toOpaque()

            params.progress_callback = { _, _, progress, userData in
                guard let userData else { return }
                let box = Unmanaged<CallbackBox>.fromOpaque(userData).takeUnretainedValue()
                box.onProgress?(Double(progress) / 100.0)
            }
            params.progress_callback_user_data = boxPointer

            params.new_segment_callback = { ctx, _, newCount, userData in
                guard let userData, let ctx else { return }
                let box = Unmanaged<CallbackBox>.fromOpaque(userData).takeUnretainedValue()
                guard box.onSegment != nil else { return }
                let total = parakeet_full_n_segments(ctx)
                for i in (total - newCount)..<total {
                    if let segment = ParakeetEngine.makeSegment(ctx: ctx, index: i, offset: box.timeOffset) {
                        box.onSegment?(segment)
                    }
                }
            }
            params.new_segment_callback_user_data = boxPointer

            params.abort_callback = { userData in
                guard let userData else { return false }
                let box = Unmanaged<CallbackBox>.fromOpaque(userData).takeUnretainedValue()
                return box.isCancelled?() ?? false
            }
            params.abort_callback_user_data = boxPointer

            let code = samples.withUnsafeBufferPointer { buffer in
                parakeet_full(ctx, params, buffer.baseAddress, Int32(buffer.count))
            }

            if isCancelled?() == true { throw WhisperError.cancelled }
            guard code == 0 else { throw WhisperError.inferenceFailed(code) }

            let count = parakeet_full_n_segments(ctx)
            var result: [Segment] = []
            result.reserveCapacity(Int(count))
            for i in 0..<count {
                if let segment = Self.makeSegment(ctx: ctx, index: i, offset: timeOffset) {
                    result.append(segment)
                }
            }
            return result
        }
    }

    private static func makeSegment(ctx: OpaquePointer, index: Int32, offset: TimeInterval) -> Segment? {
        guard let raw = parakeet_full_get_segment_text(ctx, index) else { return nil }
        let text = String(cString: raw).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        // Таймкоды, как и в whisper, приходят в сотых долях секунды.
        let start = Double(parakeet_full_get_segment_t0(ctx, index)) / 100.0 + offset
        let end = Double(parakeet_full_get_segment_t1(ctx, index)) / 100.0 + offset
        return Segment(start: start, end: end, text: text)
    }

    private final class CallbackBox {
        let onProgress: ((Double) -> Void)?
        let onSegment: ((Segment) -> Void)?
        let isCancelled: (() -> Bool)?
        let timeOffset: TimeInterval

        init(onProgress: ((Double) -> Void)?,
             onSegment: ((Segment) -> Void)?,
             isCancelled: (() -> Bool)?,
             timeOffset: TimeInterval) {
            self.onProgress = onProgress
            self.onSegment = onSegment
            self.isCancelled = isCancelled
            self.timeOffset = timeOffset
        }
    }
}
