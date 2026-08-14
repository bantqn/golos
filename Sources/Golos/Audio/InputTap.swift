import AVFoundation
import CoreAudio

/// Захват со входа через свой HAL AudioUnit.
///
/// Раньше вход брался через `AVAudioEngine.inputNode`, и это ломало звук в
/// Bluetooth-наушниках. Замерено по шагам: частота устройства вывода падает с
/// 44 100 до 16 000 Гц **уже на обращении к `inputNode`** — до выбора устройства
/// и до старта движка. Причина в том, что `AVAudioEngine` привязывает вход к
/// устройству по умолчанию, а у гарнитуры это её же микрофон; его открытие
/// переводит наушники из A2DP в режим разговора, и обратно они возвращаются
/// далеко не сразу. Переключить устройство потом уже поздно — профиль сменился.
///
/// Свой AudioUnit решает это тем, что устройство задаётся **до**
/// `AudioUnitInitialize`, поэтому вход гарнитуры не открывается даже на миг.
/// Тот же замер по шагам с этим путём: 44 100 Гц от начала до конца.
final class InputTap {

    /// Данные со входа в аппаратном формате устройства.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    private var unit: AudioUnit?
    private var format: AVAudioFormat?
    private var bufferList: UnsafeMutableAudioBufferListPointer?
    private var storage: [UnsafeMutableRawPointer] = []
    private var maxFrames: UInt32 = 4096

    private(set) var isRunning = false

    // MARK: - Запуск

    func start(deviceID: AudioDeviceID) throws {
        guard !isRunning else { return }

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw TapError.noComponent
        }
        var created: AudioUnit?
        try check(AudioComponentInstanceNew(component, &created), "создание AudioUnit")
        guard let unit = created else { throw TapError.noComponent }
        self.unit = unit

        // Вход включаем, выход выключаем: единица — шина входа, ноль — выхода.
        var enable: UInt32 = 1
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                       kAudioUnitScope_Input, 1, &enable,
                                       UInt32(MemoryLayout<UInt32>.size)), "включение входа")
        var disable: UInt32 = 0
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                       kAudioUnitScope_Output, 0, &disable,
                                       UInt32(MemoryLayout<UInt32>.size)), "выключение выхода")

        // Самое важное место: устройство задаётся до инициализации.
        var device = deviceID
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                       kAudioUnitScope_Global, 0, &device,
                                       UInt32(MemoryLayout<AudioDeviceID>.size)), "выбор устройства")

        // Аппаратный формат устройства — от него берём частоту и число каналов.
        var hardware = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Input, 1, &hardware, &size),
                  "чтение формата устройства")
        guard hardware.mSampleRate > 0, hardware.mChannelsPerFrame > 0 else {
            throw TapError.noInputDevice
        }

        // Свой формат: float32 по каналам. Понижение до 16 кГц моно делает
        // ресемплер дальше — здесь важно не потерять качество раньше времени.
        guard let clientFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: hardware.mSampleRate,
            channels: AVAudioChannelCount(hardware.mChannelsPerFrame),
            interleaved: false
        ) else { throw TapError.noInputDevice }
        self.format = clientFormat

        var client = clientFormat.streamDescription.pointee
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Output, 1, &client,
                                       UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
                  "задание своего формата")

        var frames = maxFrames
        var framesSize = UInt32(MemoryLayout<UInt32>.size)
        if AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice,
                                kAudioUnitScope_Global, 0, &frames, &framesSize) == noErr {
            maxFrames = max(frames, 512)
        }

        var callback = AURenderCallbackStruct(
            inputProc: { refCon, flags, timeStamp, bus, frames, _ in
                let tap = Unmanaged<InputTap>.fromOpaque(refCon).takeUnretainedValue()
                return tap.render(flags: flags, timeStamp: timeStamp, bus: bus, frames: frames)
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback,
                                       kAudioUnitScope_Global, 0, &callback,
                                       UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                  "установка обработчика")

        allocateBuffers(channels: Int(clientFormat.channelCount))

        try check(AudioUnitInitialize(unit), "инициализация")
        try check(AudioOutputUnitStart(unit), "старт")
        isRunning = true
    }

    func stop() {
        guard let unit else { return }
        if isRunning {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
        }
        AudioComponentInstanceDispose(unit)
        self.unit = nil
        isRunning = false
        releaseBuffers()
        format = nil
    }

    var currentFormat: AVAudioFormat? { format }

    // MARK: - Данные

    private func render(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                        timeStamp: UnsafePointer<AudioTimeStamp>,
                        bus: UInt32, frames: UInt32) -> OSStatus {
        guard let unit, let bufferList, let format else { return noErr }
        guard frames <= maxFrames else { return noErr }

        // Каждый вызов заново проставляем размеры: AudioUnitRender их меняет.
        let bytes = Int(frames) * MemoryLayout<Float>.size
        for index in 0..<bufferList.count {
            bufferList[index].mDataByteSize = UInt32(bytes)
            bufferList[index].mNumberChannels = 1
            bufferList[index].mData = storage[index]
        }

        let status = AudioUnitRender(unit, flags, timeStamp, bus, frames, bufferList.unsafeMutablePointer)
        guard status == noErr else { return status }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channels = buffer.floatChannelData
        else { return noErr }
        buffer.frameLength = frames
        for index in 0..<min(bufferList.count, Int(format.channelCount)) {
            guard let source = bufferList[index].mData else { continue }
            memcpy(channels[index], source, bytes)
        }
        onBuffer?(buffer)
        return noErr
    }

    private func allocateBuffers(channels: Int) {
        releaseBuffers()
        let bytes = Int(maxFrames) * MemoryLayout<Float>.size
        let list = AudioBufferList.allocate(maximumBuffers: channels)
        for index in 0..<channels {
            let memory = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16)
            storage.append(memory)
            list[index] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bytes), mData: memory)
        }
        bufferList = list
    }

    private func releaseBuffers() {
        for memory in storage { memory.deallocate() }
        storage = []
        if let bufferList { free(bufferList.unsafeMutablePointer) }
        bufferList = nil
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status != noErr else { return }
        throw TapError.coreAudio(what: what, status: status)
    }

    enum TapError: LocalizedError {
        case noComponent
        case noInputDevice
        case coreAudio(what: String, status: OSStatus)

        var errorDescription: String? {
            switch self {
            case .noComponent:
                return "Не удалось создать аудиокомпонент для записи со входа."
            case .noInputDevice:
                return "Микрофон не найден. Проверьте, что устройство ввода подключено."
            case .coreAudio(let what, let status):
                return "Не удалось выполнить: \(what) (код \(status))."
            }
        }
    }
}
