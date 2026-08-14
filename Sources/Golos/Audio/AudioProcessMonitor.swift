import CoreAudio
import AppKit

/// Кто именно прямо сейчас пишет с микрофона.
///
/// Раньше приложение знало только факт «устройство кем-то занято» и догадывалось
/// о программе по активному окну. Отсюда росли две беды: висящий в фоне Telegram
/// объявлялся источником разговора, а пока мы писали сами, различить чужой
/// микрофон от своего было нельзя вовсе — то есть заметить конец разговора не
/// получалось.
///
/// CoreAudio с macOS 14.2 отдаёт список процессов, работающих со звуком, с
/// признаком «пишет со входа» у каждого. Проверено замером: во время захвата в
/// списке оказывается ровно наш процесс, после остановки — никто. Свой процесс
/// мы исключаем, поэтому чужой микрофон видно и во время собственной записи.
enum AudioProcessMonitor {

    struct User: Equatable {
        var pid: pid_t
        /// Идентификатор программы, а не вспомогательного процесса: у браузеров
        /// микрофон держит helper, а человеку важен сам браузер.
        var bundleID: String
        var name: String
    }

    /// Доступен ли точный способ. На более старых системах остаётся прежний
    /// признак занятости устройства целиком.
    static var isAvailable: Bool {
        if #available(macOS 14.2, *) { return !processObjects().isEmpty }
        return false
    }

    /// Программы, которые сейчас пишут со входа. Свой процесс не считается.
    static func inputUsers(excluding ownPID: pid_t = getpid()) -> [User] {
        guard #available(macOS 14.2, *) else { return [] }

        var found: [User] = []
        var seen = Set<String>()
        for object in processObjects() {
            guard number(object, kAudioProcessPropertyIsRunningInput) == 1 else { continue }
            guard let pid = number(object, kAudioProcessPropertyPID).map({ pid_t(bitPattern: $0) }),
                  pid != ownPID
            else { continue }

            let raw = string(object, kAudioProcessPropertyBundleID)
            guard let identity = identity(bundleID: raw, pid: pid) else { continue }
            guard seen.insert(identity.bundleID).inserted else { continue }
            found.append(User(pid: pid, bundleID: identity.bundleID, name: identity.name))
        }
        return found
    }

    // MARK: - Кто это

    /// Служебные процессы системы, которые подключаются к микрофону заодно с
    /// настоящим потребителем. Замерено: при обычном захвате рядом с нами в
    /// списке оказывается `com.apple.CoreSpeech`. Считать их разговором нельзя.
    private static let systemHelpers: Set<String> = [
        "com.apple.CoreSpeech", "com.apple.assistantd", "com.apple.Siri",
        "com.apple.SiriNCService", "com.apple.accessibility.heard",
        "com.apple.audiomxd", "com.apple.replayd", "com.apple.systemsoundserverd",
        "com.apple.cmio.ContinuityCaptureAgent", "com.apple.controlcenter",
        "com.apple.universalaccessd", "com.apple.mediaremoted",
        "com.apple.TelephonyUtilities", "com.apple.cloudpaird"
    ]

    /// Превращает процесс в программу, о которой имеет смысл говорить человеку.
    private static func identity(bundleID raw: String?, pid: pid_t) -> (bundleID: String, name: String)? {
        // Без bundle id это почти наверняка демон.
        guard let raw, !raw.isEmpty else { return nil }
        guard !systemHelpers.contains(raw) else { return nil }

        let normalized = normalize(raw)
        guard !systemHelpers.contains(normalized) else { return nil }

        if let known = KnownCallApps.all.first(where: { $0.bundleID == normalized }) {
            return (bundleID: normalized, name: known.name)
        }

        // Настоящая программа — та, у которой есть окно и место в Dock.
        // Вспомогательный процесс браузера сюда попадает через своего родителя:
        // имя ищется по нормализованному идентификатору.
        let running = NSWorkspace.shared.runningApplications
        if let app = running.first(where: { $0.bundleIdentifier == normalized }),
           app.activationPolicy == .regular {
            return (bundleID: normalized, name: app.localizedName ?? normalized)
        }
        if let app = NSRunningApplication(processIdentifier: pid),
           app.activationPolicy == .regular {
            return (bundleID: app.bundleIdentifier ?? normalized,
                    name: app.localizedName ?? normalized)
        }
        return nil
    }

    /// `com.google.Chrome.helper.Renderer` → `com.google.Chrome`.
    private static func normalize(_ bundleID: String) -> String {
        let markers = [".helper", ".Helper"]
        for marker in markers {
            if let range = bundleID.range(of: marker) {
                return String(bundleID[bundleID.startIndex..<range.lowerBound])
            }
        }
        return bundleID
    }

    // MARK: - CoreAudio

    @available(macOS 14.2, *)
    private static func processObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
              size > 0
        else { return [] }

        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids
    }

    private static func number(_ object: AudioObjectID,
                               _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var result: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr else {
            return nil
        }
        return result
    }

    private static func string(_ object: AudioObjectID,
                               _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }
}
