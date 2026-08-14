import Foundation
import AVFoundation

/// Приводит любой входной поток к 16 кГц моно float32.
/// Держит один AVAudioConverter на всё время записи: пересоздание
/// на каждом буфере съедало бы заметную долю CPU.
final class Resampler {

    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private let outputFormat = AudioFormat.processing

    /// - Returns: семплы 16 кГц моно, либо пустой массив, если конвертер не удалось построить.
    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard buffer.frameLength > 0 else { return [] }
        let format = buffer.format

        if inputFormat == nil || inputFormat! != format {
            converter = AVAudioConverter(from: format, to: outputFormat)
            converter?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            inputFormat = format
        }
        guard let converter else { return [] }

        // Формат уже целевой — конвертация не нужна.
        if format.sampleRate == outputFormat.sampleRate,
           format.channelCount == 1,
           format.commonFormat == .pcmFormatFloat32,
           let channel = buffer.floatChannelData {
            return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
        }

        let ratio = outputFormat.sampleRate / format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, statusOut in
            if consumed {
                statusOut.pointee = .noDataNow
                return nil
            }
            consumed = true
            statusOut.pointee = .haveData
            return buffer
        }

        if status == .error {
            Log.warn("Ресемплинг не удался: \(error?.localizedDescription ?? "—")")
            return []
        }
        guard let channel = output.floatChannelData, output.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }

    func reset() {
        converter?.reset()
    }
}

/// Уровень сигнала для индикаторов: RMS и пик в диапазоне 0…1.
enum AudioLevel {
    static func measure(_ samples: [Float]) -> (rms: Float, peak: Float) {
        guard !samples.isEmpty else { return (0, 0) }
        var sum: Float = 0
        var peak: Float = 0
        for sample in samples {
            sum += sample * sample
            peak = max(peak, abs(sample))
        }
        let rms = (sum / Float(samples.count)).squareRoot()
        // Логарифмическая шкала читается глазом гораздо лучше линейной.
        let normalized = rms > 0 ? max(0, min(1, (20 * log10(rms) + 60) / 60)) : 0
        return (normalized, min(1, peak))
    }
}
