import Foundation
import AVFoundation

/// Формат, в котором приложение хранит всё аудио: 16 кГц, моно, 16 бит.
/// Ровно то, что ждёт whisper, — не нужно ни ресемплировать при распознавании,
/// ни хранить лишние мегабайты (час записи ≈ 115 МБ).
enum AudioFormat {
    static let sampleRate: Double = 16_000
    static let channels: AVAudioChannelCount = 1

    static var processing: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32,
                      sampleRate: sampleRate,
                      channels: channels,
                      interleaved: false)!
    }
}

/// Потоковая запись WAV: заголовок дописывается в конце, когда известен размер.
/// Файл остаётся валидным даже при аварийном завершении — размеры чинятся при чтении.
final class WavWriter {

    private let handle: FileHandle
    let url: URL
    private(set) var frameCount: Int = 0
    private var closed = false
    private let lock = NSLock()

    var duration: TimeInterval { Double(frameCount) / AudioFormat.sampleRate }

    init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Self.header(frames: 0))
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    /// Принимает семплы в диапазоне −1…1 и пишет их как 16-битный PCM.
    func append(_ samples: UnsafeBufferPointer<Float>) {
        guard !samples.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }

        var pcm = [Int16](repeating: 0, count: samples.count)
        for i in 0..<samples.count {
            let clamped = max(-1.0, min(1.0, samples[i]))
            pcm[i] = Int16(clamped * 32767.0)
        }
        pcm.withUnsafeBufferPointer { buffer in
            let data = Data(buffer: buffer)
            try? handle.write(contentsOf: data)
        }
        frameCount += samples.count
    }

    func append(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { append($0) }
    }

    /// Дописывает корректные размеры в заголовок и закрывает файл.
    @discardableResult
    func finalizeFile() -> URL {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return url }
        closed = true

        try? handle.synchronize()
        try? handle.seek(toOffset: 0)
        try? handle.write(contentsOf: Self.header(frames: frameCount))
        try? handle.close()
        return url
    }

    deinit { if !closed { finalizeFile() } }

    private static func header(frames: Int) -> Data {
        let bitsPerSample = 16
        let byteRate = Int(AudioFormat.sampleRate) * Int(AudioFormat.channels) * bitsPerSample / 8
        let blockAlign = Int(AudioFormat.channels) * bitsPerSample / 8
        let dataSize = frames * blockAlign

        var data = Data()
        func u32(_ value: Int) { withUnsafeBytes(of: UInt32(clamping: value).littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ value: Int) { withUnsafeBytes(of: UInt16(clamping: value).littleEndian) { data.append(contentsOf: $0) } }

        data.append(contentsOf: Array("RIFF".utf8))
        u32(36 + dataSize)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16)                       // размер fmt-блока
        u16(1)                        // PCM
        u16(Int(AudioFormat.channels))
        u32(Int(AudioFormat.sampleRate))
        u32(byteRate)
        u16(blockAlign)
        u16(bitsPerSample)
        data.append(contentsOf: Array("data".utf8))
        u32(dataSize)
        return data
    }
}

enum AudioLoadError: LocalizedError {
    case noAudioTrack(URL)
    case unreadable(URL, String)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack(let url):
            return "В файле «\(url.lastPathComponent)» нет звуковой дорожки."
        case .unreadable(let url, let reason):
            return "Не удалось прочитать «\(url.lastPathComponent)»: \(reason)"
        }
    }
}

/// Чтение любого поддерживаемого системой медиафайла в семплы для whisper.
///
/// Через AVAssetReader, поэтому «бесплатно» поддерживаются mp3, m4a, aac, wav,
/// aiff, caf, flac, а также видео — mp4/mov/m4v: из них берётся звуковая дорожка.
enum AudioLoader {

    static let supportedExtensions = [
        "wav", "mp3", "m4a", "aac", "aiff", "aif", "caf", "flac",
        "mp4", "mov", "m4v", "mpg", "mpeg", "wma", "ogg", "opus", "amr", "3gp"
    ]

    /// Читает конкретный отрезок файла в семплы 16 кГц моно.
    ///
    /// Нужно, чтобы перечитать кусок записи после того, как стало известно,
    /// где сменился говорящий: последовательная читалка отрезки вразбивку
    /// отдавать не умеет.
    static func samples(from url: URL, start: TimeInterval, duration: TimeInterval) throws -> [Float] {
        let asset = AVURLAsset(url: url)

        let semaphore = DispatchSemaphore(value: 0)
        var tracks: [AVAssetTrack] = []
        var loadError: Error?
        Task {
            do { tracks = try await asset.loadTracks(withMediaType: .audio) }
            catch { loadError = error }
            semaphore.signal()
        }
        semaphore.wait()

        if let loadError { throw AudioLoadError.unreadable(url, loadError.localizedDescription) }
        guard let track = tracks.first else { throw AudioLoadError.noAudioTrack(url) }

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) }
        catch { throw AudioLoadError.unreadable(url, error.localizedDescription) }

        let scale: CMTimeScale = 1000
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: max(0, start), preferredTimescale: scale),
            duration: CMTime(seconds: max(0.01, duration), preferredTimescale: scale)
        )

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw AudioLoadError.unreadable(url, "формат не поддерживается системным декодером")
        }
        reader.add(output)
        reader.startReading()

        var samples: [Float] = []
        samples.reserveCapacity(Int(duration * AudioFormat.sampleRate) + 1024)
        while let buffer = output.copyNextSampleBuffer() {
            defer { CMSampleBufferInvalidate(buffer) }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(
                block, atOffset: 0, lengthAtOffsetOut: nil,
                totalLengthOut: &length, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
                let pointer, length > 0 else { continue }

            let count = length / MemoryLayout<Float>.size
            pointer.withMemoryRebound(to: Float.self, capacity: count) { floats in
                samples.append(contentsOf: UnsafeBufferPointer(start: floats, count: count))
            }
        }
        if reader.status == .failed {
            throw AudioLoadError.unreadable(url, reader.error?.localizedDescription ?? "ошибка декодирования")
        }
        return samples
    }

    /// Длительность без полной загрузки файла.
    static func duration(of url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        guard let seconds = try? await asset.load(.duration).seconds, seconds.isFinite else { return 0 }
        return seconds
    }

}

/// Последовательное чтение длинного аудио окнами фиксированного размера.
///
/// Файл никогда не оказывается в памяти целиком: двухчасовая встреча в виде
/// массива Float заняла бы 460 МБ, а с учётом удвоения при росте массива —
/// почти гигабайт. Здесь в памяти живёт только текущее окно и перекрытие с
/// предыдущим, то есть десятки мегабайт независимо от длины записи.
final class AudioWindowReader {

    struct Window {
        /// Семплы 16 кГц моно.
        let samples: [Float]
        /// Смещение начала окна от начала файла.
        let offset: TimeInterval
        /// Реплики, начавшиеся раньше этой отметки, уже отдало предыдущее окно.
        let dropBefore: TimeInterval
    }

    private let url: URL
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let windowSize: Int
    private let overlapSize: Int

    /// Накопитель: сюда стекаются декодированные семплы до полного окна.
    private var buffer: [Float] = []
    /// Сколько семплов уже отдано наружу — из этого считается смещение.
    private var emittedSamples = 0
    private var finished = false

    let duration: TimeInterval

    init(url: URL, windowSeconds: Int, overlapSeconds: Int = 2) throws {
        self.url = url
        let rate = Int(AudioFormat.sampleRate)
        windowSize = max(rate * 30, windowSeconds * rate)
        overlapSize = overlapSeconds * rate

        let asset = AVURLAsset(url: url)

        // AVAsset грузит дорожки асинхронно, а читатель нужен синхронно —
        // поэтому здесь единственное место с ожиданием.
        let semaphore = DispatchSemaphore(value: 0)
        var tracks: [AVAssetTrack] = []
        var seconds: TimeInterval = 0
        var loadError: Error?

        Task {
            do {
                tracks = try await asset.loadTracks(withMediaType: .audio)
                let value = try await asset.load(.duration).seconds
                seconds = value.isFinite ? value : 0
            } catch {
                loadError = error
            }
            semaphore.signal()
        }
        semaphore.wait()

        if let loadError { throw AudioLoadError.unreadable(url, loadError.localizedDescription) }
        guard let track = tracks.first else { throw AudioLoadError.noAudioTrack(url) }
        duration = seconds

        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw AudioLoadError.unreadable(url, error.localizedDescription)
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw AudioLoadError.unreadable(url, "формат не поддерживается системным декодером")
        }
        reader.add(output)
        reader.startReading()

        // Резервируем один раз, чтобы массив не удваивался в процессе.
        buffer.reserveCapacity(windowSize + Int(AudioFormat.sampleRate))
    }

    /// Следующее окно либо `nil`, когда файл закончился.
    func next() throws -> Window? {
        guard !finished else { return nil }

        while buffer.count < windowSize {
            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                finished = true
                break
            }
            append(from: sampleBuffer)
            CMSampleBufferInvalidate(sampleBuffer)
        }

        if reader.status == .failed {
            throw AudioLoadError.unreadable(
                url, reader.error?.localizedDescription ?? "ошибка декодирования")
        }

        guard !buffer.isEmpty else { return nil }

        let rate = AudioFormat.sampleRate
        let offset = Double(emittedSamples) / rate
        let dropBefore = emittedSamples == 0 ? 0 : offset + Double(overlapSize) / rate * 0.5

        if finished || buffer.count <= windowSize {
            // Последнее окно: отдаём остаток целиком.
            let window = buffer
            buffer = []
            finished = true
            return Window(samples: window, offset: offset, dropBefore: dropBefore)
        }

        let window = Array(buffer[0..<windowSize])
        let consumed = windowSize - overlapSize
        buffer.removeFirst(consumed)
        emittedSamples += consumed
        return Window(samples: window, offset: offset, dropBefore: dropBefore)
    }

    /// Прогресс от 0 до 1 — для индикатора.
    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, Double(emittedSamples) / AudioFormat.sampleRate / duration)
    }

    func cancel() {
        reader.cancelReading()
        buffer = []
        finished = true
    }

    private func append(from sampleBuffer: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            block, atOffset: 0, lengthAtOffsetOut: nil,
            totalLengthOut: &length, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
            let pointer, length > 0 else { return }

        let count = length / MemoryLayout<Float>.size
        pointer.withMemoryRebound(to: Float.self, capacity: count) { floats in
            buffer.append(contentsOf: UnsafeBufferPointer(start: floats, count: count))
        }
    }
}
