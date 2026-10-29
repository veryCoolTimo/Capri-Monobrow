import Foundation

/// Судьба ответов из Capri: отправка → хост принял ввод → подтверждение по состоянию сессии.
///
/// Подтверждение строгое (не «пришло хоть какое-то событие»):
/// - текст — сессия перешла в `running` (UserPromptSubmit или экран «работает»);
/// - вариант диалога — сессия больше не ждёт или ждёт уже другой запрос.
/// Пропавшая или закрытая сессия — «не подтверждено», а не «доставлено».
public struct DeliveryTracker: Equatable {
    public enum Status: Equatable {
        case sending
        case sent(at: Double, choose: Bool, request: PendingRequest?, timeout: Double)
        case delivered
        case refused(String)
        case notDelivered
    }

    public static let textTimeout: Double = 5
    /// Отказ в Claude хука не даёт: подтверждение приходит по экрану (снимок раз в 2 с + пауза 3 с).
    public static let chooseTimeout: Double = 8

    public private(set) var items: [SessionKey: Status] = [:]

    public init() {}

    public subscript(key: SessionKey) -> Status? { items[key] }

    /// Идёт отправка или ждём подтверждения — второй ответ в ту же сессию не шлём.
    public func isBusy(_ key: SessionKey) -> Bool {
        switch items[key] {
        case .sending?, .sent?: return true
        default: return false
        }
    }

    public mutating func sending(_ key: SessionKey) { items[key] = .sending }
    public mutating func refused(_ key: SessionKey, _ message: String) { items[key] = .refused(message) }

    /// Хост принял ввод. `before` — сессия до отправки: событие хука может прийти раньше ответа ssh.
    public mutating func sent(_ key: SessionKey, before: Session, action: ReplyAction, at now: Double) {
        let choose: Bool
        if case .choose = action { choose = true } else { choose = false }
        items[key] = .sent(at: now, choose: choose, request: before.request,
                           timeout: choose ? Self.chooseTimeout : Self.textTimeout)
    }

    public mutating func clear(_ key: SessionKey) {
        if isBusy(key) { return }
        items[key] = nil
    }

    /// Сверка с новым состоянием. `resolve` — склейка `pane:%N` с сессией из хуков.
    /// Возвращает ключи, подтверждённые сейчас.
    public mutating func update(_ sessions: [SessionKey: Session], resolve: (SessionKey) -> SessionKey?) -> [SessionKey] {
        var confirmed: [SessionKey] = []
        for (key, status) in items {
            guard case let .sent(_, choose, request, _) = status else { continue }
            guard let target = resolve(key), let s = sessions[target], s.status != .ended else {
                items[key] = .notDelivered
                continue
            }
            if target != key {        // сессия склеилась — статус переезжает к её новому ключу
                items[key] = nil
                items[target] = status
            }
            let done = choose
                ? s.status != .needsInput || s.request?.summary != request?.summary
                : s.status == .running
            if done {
                items[target] = .delivered
                confirmed.append(target)
            }
        }
        return confirmed
    }

    /// Не подтвердилось вовремя. Возвращает ключи, ставшие «не подтверждено».
    public mutating func expire(now: Double) -> [SessionKey] {
        var expired: [SessionKey] = []
        for (key, status) in items {
            if case let .sent(at, _, _, timeout) = status, now - at > timeout {
                items[key] = .notDelivered
                expired.append(key)
            }
        }
        return expired
    }

    /// Убрать «доставлено» (через пару секунд после подтверждения).
    public mutating func dropDelivered(_ key: SessionKey) {
        if items[key] == .delivered { items[key] = nil }
    }
}
