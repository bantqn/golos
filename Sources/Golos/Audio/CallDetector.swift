import Foundation
import AppKit
import Combine

/// Программы, которые почти наверняка означают звонок.
/// Отдельно от детектора: список — просто данные, и настройкам он тоже нужен.
enum KnownCallApps {
/// Приложения, которые почти наверняка означают звонок.
static let all: [(bundleID: String, name: String)] = [
    ("us.zoom.xos", "Zoom"),
    ("com.microsoft.teams", "Microsoft Teams"),
    ("com.microsoft.teams2", "Microsoft Teams"),
    ("com.tinyspeck.slackmacgap", "Slack"),
    ("ru.keepcoder.Telegram", "Telegram"),
    ("com.tdesktop.Telegram", "Telegram"),
    ("org.telegram.desktop", "Telegram"),
    ("com.apple.FaceTime", "FaceTime"),
    ("com.skype.skype", "Skype"),
    ("com.webex.meetingmanager", "Webex"),
    ("com.cisco.webexmeetingsapp", "Webex"),
    ("com.discordapp.Discord", "Discord"),
    ("ru.yandex.desktop.telemost", "Яндекс Телемост"),
    ("com.google.Chrome", "Chrome"),
    ("com.apple.Safari", "Safari"),
    ("org.mozilla.firefox", "Firefox"),
    ("company.thebrowser.Browser", "Arc"),
    ("com.microsoft.edgemac", "Edge"),
    ("com.brave.Browser", "Brave"),
    ("ru.yandex.desktop.yandex-browser", "Яндекс Браузер")
]
}

/// Определяет, что прямо сейчас идёт разговор.
///
/// Признак — занятость микрофона другим процессом: она одинаково срабатывает
/// на Zoom, Telegram, FaceTime и на браузер с Телемостом или Meet, не требуя
/// отдельной поддержки каждого приложения. Название приложения подбирается
/// эвристикой по списку запущенных процессов и служит только подсказкой в интерфейсе.
@MainActor
final class CallDetector: ObservableObject {

    struct Detection: Equatable {
        var appName: String
        var bundleID: String?
        var startedAt: Date
    }

    @Published private(set) var current: Detection?
    @Published private(set) var isEnabled = false
    /// Программы, которые прямо сейчас пишут с микрофона. Наш собственный
    /// процесс сюда не попадает.
    @Published private(set) var active: [AudioProcessMonitor.User] = []

    /// Пока приложение само занимает микрофон, предлагать запись не нужно.
    ///
    /// Раньше это выключало детектор целиком — иначе он докладывал о разговоре,
    /// который затеяли мы сами. Теперь чужой микрофон отличим от своего, поэтому
    /// наблюдение продолжается: без него не узнать, что программа освободила
    /// микрофон, то есть разговор закончился.
    var isSuppressed = false

    /// Замеченные программы: bundle id → имя. Нужны, чтобы в настройках
    /// появлялись строки для тех программ, которыми вы реально пользуетесь,
    /// а не только для зашитого списка.
    var onAppSeen: ((String, String) -> Void)?

    /// Вызывается один раз в начале разговора.
    var onCallStarted: ((Detection) -> Void)?

    /// Вызывается, когда программа отпустила микрофон, — разговор закончился.
    var onCallEnded: ((Detection) -> Void)?

    private var timer: Timer?
    private var wasActive = false
    /// Идущие разговоры по программам: нужно, чтобы отличить новый от текущего
    /// и понять, какой именно закончился.
    private var ongoing: [String: Detection] = [:]
    /// Сколько опросов подряд программы не видно. Одного пропуска мало: список
    /// процессов CoreAudio перестраивается на ходу, и случайно пропущенный опрос
    /// не должен объявлять разговор законченным.
    private var misses: [String: Int] = [:]
    private let missesBeforeEnd = 2

    func start() {
        guard timer == nil else { return }
        isEnabled = true
        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isEnabled = false
        current = nil
        active = []
        wasActive = false
        ongoing = [:]
        misses = [:]
    }

    /// Скрыть текущее предложение, не выключая детектор целиком.
    func dismissCurrent() {
        current = nil
    }

    private func poll() {
        if AudioProcessMonitor.isAvailable {
            pollProcesses()
        } else {
            pollDevice()
        }
    }

    /// Точный путь: видно, какая именно программа пишет со входа.
    private func pollProcesses() {
        let users = AudioProcessMonitor.inputUsers()
        active = users
        let byID = Dictionary(users.map { ($0.bundleID, $0) }, uniquingKeysWith: { first, _ in first })

        // Закончившиеся разговоры — те, кого не видно несколько опросов подряд.
        for (bundleID, detection) in ongoing {
            guard byID[bundleID] == nil else {
                misses[bundleID] = 0
                continue
            }
            let count = (misses[bundleID] ?? 0) + 1
            misses[bundleID] = count
            guard count >= missesBeforeEnd else { continue }

            ongoing.removeValue(forKey: bundleID)
            misses.removeValue(forKey: bundleID)
            if current?.bundleID == bundleID { current = nil }
            Log.info("Разговор закончился: \(detection.appName) отпустил микрофон")
            onCallEnded?(detection)
        }

        // Новые разговоры.
        for user in users where ongoing[user.bundleID] == nil {
            let detection = Detection(appName: user.name, bundleID: user.bundleID, startedAt: Date())
            ongoing[user.bundleID] = detection
            onAppSeen?(user.bundleID, user.name)
            Log.info("Обнаружен разговор: \(user.name) (\(user.bundleID))")

            // Пока пишем сами, предлагать нечего — но следить продолжаем.
            guard !isSuppressed else { continue }
            current = detection
            onCallStarted?(detection)
        }
    }

    /// Запасной путь для систем без списка процессов: известен только факт
    /// занятости устройства, поэтому программа угадывается по активному окну,
    /// а во время собственной записи детектор молчит.
    private func pollDevice() {
        guard !isSuppressed else {
            if current != nil { current = nil }
            wasActive = false
            return
        }

        let deviceID = AudioInputDevice.defaultInputDeviceID()
        let active = AudioInputDevice.isInputActiveSomewhere(deviceID)

        guard active else {
            if wasActive { current = nil }
            wasActive = false
            return
        }
        guard !wasActive else { return }
        wasActive = true

        guard let candidate = guessApp() else {
            // Не смогли понять, кто говорит, — молчим, а не выдумываем.
            Log.info("Микрофон занят, но активную программу определить не удалось")
            return
        }

        onAppSeen?(candidate.bundleID, candidate.name)
        let detection = Detection(
            appName: candidate.name,
            bundleID: candidate.bundleID,
            startedAt: Date()
        )
        current = detection
        Log.info("Обнаружен разговор: \(detection.appName) (\(candidate.bundleID))")
        onCallStarted?(detection)
    }

    /// Кто занял микрофон.
    ///
    /// macOS не сообщает, какой именно процесс держит устройство, — доступен
    /// только факт «кем-то занято». Поэтому ориентируемся на активную программу:
    /// именно в ней человек в этот момент говорит. Прежняя версия перебирала все
    /// запущенные приложения и выдавала первое «звонковое» из списка — из-за
    /// этого висящий в фоне Telegram объявлялся источником разговора, которого
    /// не было.
    private func guessApp() -> (bundleID: String, name: String)? {
        let running = NSWorkspace.shared.runningApplications
        guard let frontmost = running.first(where: \.isActive),
              let bundleID = frontmost.bundleIdentifier
        else { return nil }

        // Себя не считаем.
        guard bundleID != Bundle.main.bundleIdentifier else { return nil }

        let known = KnownCallApps.all.first { $0.bundleID == bundleID }
        let name = known?.name ?? frontmost.localizedName ?? bundleID
        return (bundleID: bundleID, name: name)
    }
}
