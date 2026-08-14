import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreGraphics

/// Захват звука системы через ScreenCaptureKit.
///
/// Это универсальный путь: он снимает всё, что звучит на маке, поэтому одинаково
/// работает для Zoom, Google Meet и Яндекс Телемоста в браузере, звонков Telegram,
/// FaceTime и любого плеера. Отдельных интеграций с приложениями не требуется.
///
/// Собственный звук приложения исключается, чтобы воспроизведение записи
/// не попадало обратно в запись.
final class SystemAudioRecorder: NSObject {

    var onSamples: (([Float]) -> Void)?
    var onLevel: ((Float) -> Void)?
    /// Поток упал сам по себе (например, пользователь отозвал разрешение).
    var onStreamStopped: ((Error) -> Void)?

    private var stream: SCStream?
    private let resampler = Resampler()
    private let outputQueue = DispatchQueue(label: "ai.cybergusli.golos.sysaudio", qos: .userInitiated)
    private(set) var isRunning = false

    // MARK: - Разрешения

    /// Захват системного звука требует доступа к записи экрана — так устроен ScreenCaptureKit.
    /// Видео при этом не пишется: кадр 2×2 пикселя выбрасывается.
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    static func openPermissionSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Запись

    func start() async throws {
        guard !isRunning else { return }

        guard Self.hasPermission else { throw SystemAudioError.permissionDenied }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw SystemAudioError.contentUnavailable(error.localizedDescription)
        }
        guard let display = content.displays.first else { throw SystemAudioError.noDisplay }

        // Исключаем себя из захвата, чтобы не поймать эхо собственного воспроизведения.
        let ownBundleID = Bundle.main.bundleIdentifier
        let excluded = content.applications.filter { $0.bundleIdentifier == ownBundleID }
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // Видео нам не нужно, но SCStream его требует: берём минимальный кадр и редкую частоту.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 6
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
            try await stream.startCapture()
        } catch {
            throw SystemAudioError.startFailed(error.localizedDescription)
        }

        self.stream = stream
        isRunning = true
        Log.info("Захват системного звука запущен")
    }

    func stop() async {
        guard isRunning, let stream else { return }
        isRunning = false
        self.stream = nil
        try? await stream.stopCapture()
        resampler.reset()
        Log.info("Захват системного звука остановлен")
    }

    enum SystemAudioError: LocalizedError {
        case permissionDenied
        case noDisplay
        case contentUnavailable(String)
        case startFailed(String)

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Нет доступа к записи экрана. Он нужен macOS для захвата системного звука — видео при этом не записывается."
            case .noDisplay:
                return "Не найден дисплей для захвата звука."
            case .contentUnavailable(let reason):
                return "ScreenCaptureKit недоступен: \(reason)"
            case .startFailed(let reason):
                return "Не удалось запустить захват системного звука: \(reason)"
            }
        }
    }
}

extension SystemAudioRecorder: SCStreamOutput {

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, isRunning, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let buffer = Self.pcmBuffer(from: sampleBuffer) else { return }

        let samples = resampler.convert(buffer)
        guard !samples.isEmpty else { return }
        onLevel?(AudioLevel.measure(samples).rms)
        onSamples?(samples)
    }

    /// CMSampleBuffer → AVAudioPCMBuffer без копирования полезной нагрузки.
    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)
        else { return nil }

        var streamDescription = asbd.pointee
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else { return nil }

        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0 else { return nil }

        var blockBuffer: CMBlockBuffer?
        let listSize = MemoryLayout<AudioBufferList>.size
            + MemoryLayout<AudioBuffer>.size * Int(max(1, format.channelCount) - 1)

        // Память под AudioBufferList живёт ровно столько же, сколько PCM-буфер:
        // `bufferListNoCopy` не копирует список, а держит на него указатель,
        // поэтому освобождать её можно только в деаллокаторе.
        let storage = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: 16)
        let listPointer = storage.bindMemory(to: AudioBufferList.self, capacity: 1)

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: listPointer,
            bufferListSize: listSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else {
            storage.deallocate()
            return nil
        }

        // Блок-буфер с самими семплами удерживается замыканием, пока жив PCM-буфер.
        let retained = blockBuffer
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: listPointer,
                                            deallocator: { _ in
            _ = retained
            storage.deallocate()
        }) else {
            storage.deallocate()
            return nil
        }
        return buffer
    }
}

extension SystemAudioRecorder: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.error("Поток системного звука остановлен: \(error.localizedDescription)")
        isRunning = false
        self.stream = nil
        DispatchQueue.main.async { [weak self] in self?.onStreamStopped?(error) }
    }
}
