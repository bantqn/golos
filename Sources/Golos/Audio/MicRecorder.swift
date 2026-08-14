import Foundation
import AVFoundation
import CoreAudio

/// Захват микрофона через AVAudioEngine.
/// Используется и для записи встреч (дорожка «Я»), и для диктовки.
final class MicRecorder {

    /// Готовые семплы 16 кГц моно.
    var onSamples: (([Float]) -> Void)?
    /// Уровень сигнала 0…1 для индикатора.
    var onLevel: ((Float) -> Void)?

    private let tap = InputTap()
    private let resampler = Resampler()
    private(set) var isRunning = false
    /// Устройство, с которого на самом деле идёт запись, — для легенды расшифровки.
    private(set) var deviceName: String?

    // MARK: - Разрешения

    static var permissionStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static func requestPermission() async -> Bool {
        if permissionStatus == .authorized { return true }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    // MARK: - Запись

    /// - Parameters:
    ///   - deviceID: `nil` — берётся системное устройство по умолчанию.
    ///   - avoidBluetooth: подменять микрофон Bluetooth-гарнитуры встроенным,
    ///     чтобы не портить звук в наушниках.
    func start(deviceID: AudioDeviceID? = nil, avoidBluetooth: Bool = true) throws {
        guard !isRunning else { return }

        let choice = AudioInputDevice.resolve(configured: deviceID, avoidBluetooth: avoidBluetooth)
        guard let device = choice.device else { throw MicError.noInputDevice }
        deviceName = device.name

        tap.onBuffer = { [weak self] buffer in
            guard let self else { return }
            let samples = self.resampler.convert(buffer)
            guard !samples.isEmpty else { return }
            self.onLevel?(AudioLevel.measure(samples).rms)
            self.onSamples?(samples)
        }

        do {
            try tap.start(deviceID: device.id)
        } catch {
            throw MicError.engineFailed(error.localizedDescription)
        }
        isRunning = true

        let rate = Int(tap.currentFormat?.sampleRate ?? 0)
        let channels = tap.currentFormat?.channelCount ?? 0
        if let note = choice.note {
            Log.info("Микрофон запущен: «\(device.name)», \(rate) Гц, \(channels) кан. — \(note)")
        } else {
            Log.info("Микрофон запущен: «\(device.name)», \(rate) Гц, \(channels) кан.")
        }
    }

    func stop() {
        guard isRunning else { return }
        tap.stop()
        tap.onBuffer = nil
        resampler.reset()
        isRunning = false
        Log.info("Микрофон остановлен")
    }

    enum MicError: LocalizedError {
        case noInputDevice
        case engineFailed(String)
        case deviceSelectionFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .noInputDevice:
                return "Микрофон не найден. Проверьте, что устройство ввода подключено и выбрано в настройках звука."
            case .engineFailed(let reason):
                return "Не удалось запустить аудиодвижок: \(reason)"
            case .deviceSelectionFailed(let status):
                return "Не удалось выбрать устройство ввода (код \(status))."
            }
        }
    }
}

/// Перечисление устройств ввода — для выпадающего списка в настройках.
struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let isDefault: Bool
    /// Как устройство подключено: `kAudioDeviceTransportType…`.
    let transport: UInt32

    /// Микрофон Bluetooth-гарнитуры. Его включение переводит наушники из A2DP
    /// в режим разговора, и звук в них портится — иногда надолго.
    var isBluetooth: Bool {
        transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }

    /// Что взять для записи и почему.
    struct Choice {
        var device: AudioInputDevice?
        /// Пояснение для журнала, если устройство подменили.
        var note: String?
    }

    /// Выбирает устройство записи.
    ///
    /// Смысл подмены: включение микрофона гарнитуры роняет качество звука в
    /// самих наушниках (замерено: выход падает с 44 100 до 16 000 Гц и
    /// возвращается далеко не сразу). Если человек слушает в наушниках и при
    /// этом диктует, разумнее взять встроенный микрофон: на распознавание речи
    /// это влияет мало, а музыку и голоса в наушниках не портит.
    ///
    /// Подмены не делаем, когда вход гарнитуры уже занят другой программой:
    /// профиль всё равно переключён, и терять микрофон рядом с ртом незачем.
    static func resolve(configured: AudioDeviceID?, avoidBluetooth: Bool) -> Choice {
        let devices = available()
        guard !devices.isEmpty else { return Choice(device: nil, note: nil) }

        let wanted = configured ?? defaultInputDeviceID()
        let chosen = devices.first { $0.id == wanted }
            ?? devices.first(where: \.isDefault)
            ?? devices.first
        guard let chosen else { return Choice(device: nil, note: nil) }

        guard avoidBluetooth, chosen.isBluetooth else { return Choice(device: chosen, note: nil) }

        // Гарнитура уже в режиме разговора — беречь нечего.
        if isInputActiveSomewhere(chosen.id) {
            return Choice(device: chosen,
                          note: "микрофон гарнитуры уже занят другой программой")
        }
        guard let builtIn = devices.first(where: \.isBuiltIn) else {
            return Choice(device: chosen, note: "встроенного микрофона нет, беру гарнитуру")
        }
        return Choice(device: builtIn,
                      note: "вместо «\(chosen.name)», чтобы не переводить наушники в режим разговора")
    }

    static func available() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }

        let defaultID = defaultInputDeviceID()
        return ids.compactMap { id in
            guard hasInputChannels(id), let name = deviceName(id) else { return nil }
            return AudioInputDevice(id: id, name: name, isDefault: id == defaultID,
                                    transport: transportType(id))
        }
    }

    private static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    static func defaultInputDeviceID() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    private static func hasInputChannels(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return false }

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr else { return false }

        let list = buffer.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    private static func deviceName(_ id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // Core Audio возвращает сюда +1 ссылку на CFString — забираем её через Unmanaged,
        // иначе объект утечёт (и компилятор справедливо ругается на &CFString).
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr,
              let name else { return nil }
        return name.takeRetainedValue() as String
    }

    /// Занят ли микрофон другим приложением — базовый признак того, что идёт звонок.
    static func isInputActiveSomewhere(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }
}
