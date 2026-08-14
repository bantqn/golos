import CoreAudio

/// Сведения об устройстве вывода.
///
/// Нужны ровно для одного: понять, не ушла ли Bluetooth-гарнитура в режим
/// разговора. Прямого признака профиля CoreAudio не даёт, но частота
/// дискретизации выхода его выдаёт однозначно — у этих наушников 44 100 Гц в
/// обычном режиме и 16 000 Гц в режиме разговора.
enum AudioOutputInfo {

    static func defaultDeviceID() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                   0, nil, &size, &id)
        return id
    }

    static func defaultSampleRate() -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(defaultDeviceID(), &address,
                                         0, nil, &size, &value) == noErr else { return 0 }
        return Int(value)
    }

    static func defaultName() -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(defaultDeviceID(), &address,
                                         0, nil, &size, &value) == noErr,
              let value else { return "?" }
        return value.takeRetainedValue() as String
    }

    /// Похоже ли, что выход сейчас в режиме разговора: у гарнитур это узкая
    /// полоса, у обычных устройств такой частоты не бывает.
    static func looksLikeCallMode() -> Bool {
        let rate = defaultSampleRate()
        return rate > 0 && rate <= 24_000
    }
}
