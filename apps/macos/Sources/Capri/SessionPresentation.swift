import SwiftUI
import CapriKit

// Подписи и цвета сессий — общие для notch и основного окна.

extension Session {
    /// Что за ожидание — подпись на карточке.
    var kindLabel: String {
        switch (status, request?.kind) {
        case (.needsInput, .question?): return "вопрос"
        case (.needsInput, .permission?): return "разрешение"
        case (.needsInput, .reply?): return "ответила"
        case (.needsInput, _): return "нужен ответ"
        case (.idle, _): return "ждёт задачу"
        default: return ""
        }
    }

    var statusLabel: String {
        switch status {
        case .running: return "работает"
        case .needsInput: return "ждёт меня"
        case .idle: return "ждёт задачу"
        case .error: return "ошибка"
        case .rateLimited: return "лимит"
        case .ended: return "закрыта"
        case .unknown: return "неизвестно"
        }
    }

    var hostLabel: String { "\(SessionStore.displayHost(key.host)) · \(key.agent.rawValue)" }
    /// Одна строка о том, чего ждёт или что делает сессия.
    var headline: String {
        if let r = request { return r.summary }
        switch status {
        case .running: return "работает"
        case .idle: return lastMessage.map { $0.split(separator: "\n").first.map(String.init) ?? $0 } ?? "ждёт задачу"
        case .error: return "ошибка: \(lastMessage ?? "")"
        case .rateLimited: return "упёрлась в лимит"
        default: return status.rawValue
        }
    }
}

extension SessionStore {
    struct Hint {
        var text: String
        var color: Color
    }

    /// Строка под карточкой: судьба последнего ответа или почему ответить сейчас нельзя.
    func hint(_ s: Session) -> Hint? {
        switch deliveries[s.key] {
        case .sending?: return Hint(text: "отправляю…", color: Palette.dim)
        case .sent?: return Hint(text: "отправлено · жду подтверждения", color: Palette.dim)
        case .delivered?: return Hint(text: "доставлено ✓", color: Palette.acid)
        case .refused(let m)?: return Hint(text: m, color: Palette.crimson)
        case .notDelivered?: return Hint(text: "не подтверждено — проверьте сессию («открыть»)", color: Palette.crimson)
        case nil:
            let action: ReplyAction = s.status == .needsInput && !(s.request?.choices.isEmpty ?? true) ? .choose(1) : .text("x")
            if let r = check(s.key, action), r != .empty { return Hint(text: r.message, color: Palette.dim) }
            return nil
        }
    }
}

extension Session {
    var statusColor: Color { Self.color(status) }

    static func color(_ status: SessionStatus) -> Color {
        switch status {
        case .needsInput: return Palette.acid
        case .running, .error, .rateLimited: return Palette.crimson
        default: return Palette.dim
        }
    }
}
