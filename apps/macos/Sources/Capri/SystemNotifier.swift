import AppKit
import UserNotifications
import CapriKit

/// Уведомления macOS о «ждёт меня»; клик открывает окно Capri на этой сессии.
final class SystemNotifier: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: ((SessionKey) -> Void)?
    private var posted: Set<String> = []

    /// Центр уведомлений есть только у собранного .app (под `swift run` UNUserNotificationCenter падает).
    private var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    func start() {
        guard available else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    /// `text` — что показать в теле (уже с учётом настроек); nil — только проект и хост.
    /// Уведомления видны на экране блокировки и хранятся в Центре уведомлений: текст режем как для Codex.
    func post(_ s: Session, text: String?) {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        let send = { [weak self] in
            let c = UNMutableNotificationContent()
            c.title = "\(s.project) ждёт ответа"
            c.subtitle = "\(SessionStore.displayHost(s.key.host)) · \(s.key.agent.rawValue)"
            c.body = text.map { String(Redactor.redact($0).prefix(80)) } ?? "\(s.kindLabel.isEmpty ? "нужен ответ" : s.kindLabel)"
            c.threadIdentifier = s.key.host
            c.userInfo = ["host": s.key.host, "agent": s.key.agent.rawValue, "id": s.key.id]
            let id = s.key.description
            center.add(UNNotificationRequest(identifier: id, content: c, trigger: nil)) { err in
                if let err { NSLog("[Capri] уведомление: %@", err.localizedDescription) }
            }
            DispatchQueue.main.async { self?.posted.insert(id) }
        }
        // Разрешение проверяем каждый раз: его могут выключить в Системных настройках.
        center.getNotificationSettings { st in
            switch st.authorizationStatus {
            case .authorized, .provisional:
                send()
            case .notDetermined:
                center.requestAuthorization(options: [.alert]) { ok, _ in if ok { send() } }
            default:
                NSLog("[Capri] уведомления macOS выключены в Системных настройках")
            }
        }
    }

    func removeExcept(_ waiting: Set<SessionKey>) {
        guard available, !posted.isEmpty else { return }
        let keep = Set(waiting.map(\.description))
        let stale = posted.subtracting(keep)
        guard !stale.isEmpty else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: Array(stale))
        posted.subtract(stale)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let host = info["host"] as? String, let agent = (info["agent"] as? String).flatMap(Agent.init(rawValue:)),
           let id = info["id"] as? String {
            let key = SessionKey(host: host, agent: agent, id: id)
            DispatchQueue.main.async { [weak self] in self?.onOpen?(key) }
        }
        done()
    }

    /// Capri — фоновое приложение: показываем баннер и когда оно «активно». Звук уже сыграл notch.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .list])
    }
}
