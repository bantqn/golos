import Foundation
import UserNotifications
import AppKit

/// Системные уведомления.
///
/// Нужны для одного сценария: приложение заметило разговор, а окно закрыто или
/// перекрыто, и предложение записать иначе останется незамеченным. У уведомления
/// есть кнопка «Записать» — согласиться можно не переключаясь в приложение.
@MainActor
final class Notifier: NSObject, ObservableObject {

    static let shared = Notifier()

    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined

    /// Вызывается, когда пользователь нажал «Записать» в уведомлении.
    var onRecordRequested: ((String?) -> Void)?
    /// Нажал «Завершить запись» в уведомлении об окончании разговора.
    var onFinishRequested: (() -> Void)?
    /// Нажал «Не уведомлять» — уведомления об этой программе больше не нужны.
    var onMuteAppRequested: ((String) -> Void)?

    private let categoryID = "call-detected"
    private let endCategoryID = "call-ended"
    private let recordActionID = "record"
    private let finishActionID = "finish"
    private let muteActionID = "mute-app"
    private let center = UNUserNotificationCenter.current()

    private override init() {
        super.init()
    }

    func configure() {
        center.delegate = self

        let record = UNNotificationAction(
            identifier: recordActionID,
            title: "Записать",
            options: [.foreground]
        )
        // Отключить уведомления можно прямо из уведомления: искать нужную
        // строку в настройках, когда программа отвлекла не вовремя, — лишний труд.
        let mute = UNNotificationAction(
            identifier: muteActionID,
            title: "Не уведомлять об этой программе",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: categoryID,
            actions: [record, mute],
            intentIdentifiers: [],
            options: []
        )

        let finish = UNNotificationAction(
            identifier: finishActionID,
            title: "Завершить запись",
            options: [.foreground]
        )
        let endCategory = UNNotificationCategory(
            identifier: endCategoryID,
            actions: [finish, mute],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category, endCategory])
        refreshAuthorization()
    }

    func refreshAuthorization() {
        center.getNotificationSettings { [weak self] settings in
            Task { @MainActor in self?.authorization = settings.authorizationStatus }
        }
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            if let error {
                Log.warn("Уведомления недоступны: \(error.localizedDescription)")
            }
            Log.info("Разрешение на уведомления: \(granted ? "выдано" : "отказано")")
            Task { @MainActor in self?.refreshAuthorization() }
        }
    }

    func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Отправка

    func notifyCallDetected(appName: String, bundleID: String?) {
        guard authorization == .authorized || authorization == .provisional else { return }

        let content = UNMutableNotificationContent()
        content.title = "Похоже, идёт разговор"
        content.body = "\(appName) занял микрофон. Записать встречу?"
        content.sound = .default
        content.categoryIdentifier = categoryID
        if let bundleID { content.userInfo = ["bundleID": bundleID] }

        // Без триггера — доставить сразу.
        let request = UNNotificationRequest(
            identifier: "call-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error { Log.warn("Не удалось показать уведомление: \(error.localizedDescription)") }
        }
    }

    /// Разговор закончился, а запись всё ещё идёт.
    func notifyCallEnded(appName: String, bundleID: String?, elapsed: TimeInterval) {
        guard authorization == .authorized || authorization == .provisional else { return }

        let content = UNMutableNotificationContent()
        content.title = "\(appName) освободил микрофон"
        content.body = "Похоже, разговор закончился. Запись идёт уже \(Fmt.duration(elapsed)) — завершить?"
        content.sound = .default
        content.categoryIdentifier = endCategoryID
        if let bundleID { content.userInfo = ["bundleID": bundleID] }

        center.add(UNNotificationRequest(
            identifier: "call-end-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )) { error in
            if let error { Log.warn("Не удалось показать уведомление: \(error.localizedDescription)") }
        }
    }

    func notifyRecordingFinished(title: String, duration: TimeInterval) {
        guard authorization == .authorized || authorization == .provisional else { return }

        let content = UNMutableNotificationContent()
        content.title = "Запись сохранена"
        content.body = "\(title) · \(Fmt.duration(duration))"
        content.sound = nil

        center.add(UNNotificationRequest(
            identifier: "saved-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        ))
    }
}

extension Notifier: UNUserNotificationCenterDelegate {

    /// Показывать уведомление, даже когда приложение активно: окно может быть
    /// перекрыто чужим, и без этого сообщение просто не появится.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let bundleID = response.notification.request.content.userInfo["bundleID"] as? String
        let action = response.actionIdentifier
        Task { @MainActor in
            switch action {
            case "record": Notifier.shared.onRecordRequested?(bundleID)
            case "finish": Notifier.shared.onFinishRequested?()
            case "mute-app": if let bundleID { Notifier.shared.onMuteAppRequested?(bundleID) }
            default: break
            }
            completionHandler()
        }
    }
}
