import Foundation

/// Что Capri отправляет в сессию.
public enum ReplyAction: Equatable {
    /// Текст в строку ввода + Enter.
    case text(String)
    /// Вариант диалога по порядку, с 1.
    case choose(Int)
}

/// Вариант ответа на диалог: номер для `choose` и подпись для кнопки.
public struct ReplyChoice: Equatable, Identifiable {
    public var index: Int
    public var label: String
    public var id: Int { index }
}

extension PendingRequest {
    /// Варианты как их показывает notch. С экрана приходят «1 Yes», из хука — просто подписи.
    public var choices: [ReplyChoice] {
        options.enumerated().map { i, raw in
            if let space = raw.firstIndex(of: " "), let n = Int(raw[..<space]), n == i + 1 {
                return ReplyChoice(index: n, label: String(raw[raw.index(after: space)...]))
            }
            return ReplyChoice(index: i + 1, label: raw)
        }
    }
}

/// Почему ответ нельзя отправить (до отправки — по состоянию Capri, после — по проверке на хосте).
public enum ReplyRefusal: Equatable, Error {
    case noTmux
    case hostOffline
    case hookOutdated
    case running
    case typed(String)
    case notWaiting
    case dialogOpen
    case noDialog
    case noOption
    case paneGone
    case paneChanged
    case noAgent
    case dialogChanged
    case cursor
    case pastedNotSubmitted
    case busy
    case empty
    /// ssh не ответил вовремя: ввод мог и дойти — повторять вслепую нельзя.
    case unknown
    case failed(String)

    public var message: String {
        switch self {
        case .noTmux: return "сессия не в tmux — ответить можно только в её терминале"
        case .hostOffline: return "нет связи с хостом"
        case .hookOutdated: return "на хосте старый capri-hook — обновите: scripts/install-hooks.sh <host> --apply"
        case .running: return "сессия работает — дождитесь, пока она остановится"
        case .typed(let t): return "в строке ввода уже набрано «\(t)» — не пишу поверх"
        case .notWaiting: return "сессия больше не ждёт ответа на диалог"
        case .dialogOpen: return "на экране диалог — выберите вариант"
        case .noDialog: return "диалога на экране уже нет"
        case .noOption: return "такого варианта на экране нет"
        case .paneGone: return "панель tmux закрыта"
        case .paneChanged: return "в панели уже другой процесс"
        case .noAgent: return "в панели больше нет агента — не пишу в оболочку"
        case .dialogChanged: return "на экране уже другой диалог — обновлю, проверьте и выберите снова"
        case .cursor: return "курсор не встал на вариант — Enter не нажат, проверьте сессию"
        case .pastedNotSubmitted: return "текст вставлен, но Enter не нажат — проверьте сессию"
        case .unknown: return "хост не ответил вовремя — ответ мог дойти, проверьте сессию"
        case .busy: return "в эту сессию уже идёт отправка"
        case .empty: return "пустой ответ"
        case .failed(let s): return "не отправлено: \(s)"
        }
    }
}

public enum Reply {
    /// Минимальная версия capri-hook с режимом send.
    public static let minHookVersion = 4

    /// Проверка по состоянию Capri, до похода на хост. Хост проверит экран ещё раз прямо перед вводом.
    public static func check(_ s: Session, _ action: ReplyAction, hostConnected: Bool, hookVersion: Int) -> ReplyRefusal? {
        guard s.tmux != nil else { return .noTmux }
        guard hostConnected else { return .hostOffline }
        guard hookVersion >= minHookVersion else { return .hookOutdated }
        switch action {
        case .text(let t):
            if t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .empty }
            if s.status == .running { return .running }
            if s.status == .needsInput, !(s.request?.choices.isEmpty ?? true) { return .dialogOpen }
            if let typed = s.typedInput, !typed.isEmpty { return .typed(typed) }
        case .choose(let n):
            guard s.status == .needsInput else { return .notWaiting }
            if let count = s.request?.choices.count, count > 0, !(1...count).contains(n) { return .noOption }
        }
        return nil
    }

    /// Аргументы `capri-hook send`. Текст и ожидания по экрану идут через stdin, не в командной строке.
    public static func arguments(_ s: Session, _ action: ReplyAction) -> [String]? {
        guard let t = s.tmux, isPaneId(t.pane) else { return nil }
        var args = ["send", "--pane", t.pane, "--agent", s.key.agent.rawValue]
        if let pid = t.pid, !pid.isEmpty, pid.allSatisfy(\.isNumber) { args += ["--pid", pid] }
        switch action {
        case .text: args.append("--text-stdin")
        case .choose(let n): args += ["--choose", String(n), "--expect-stdin"]
        }
        return args
    }

    /// stdin для `send`: текст ответа или JSON «какой диалог видел пользователь» — хост сверит его
    /// с экраном и откажет, если там уже другой запрос.
    public static func stdin(_ s: Session, _ action: ReplyAction) -> Data {
        switch action {
        case .text(let t):
            return Data(t.utf8)
        case .choose(let n):
            var expect: [String: String] = [:]
            if let r = s.request {
                if let label = r.choices.first(where: { $0.index == n })?.label { expect["label"] = label }
                let first = r.summary.split(separator: "\n").first.map(String.init) ?? r.summary
                if r.kind != .notification, !first.isEmpty { expect["text"] = String(first.prefix(60)) }
            }
            return (try? JSONSerialization.data(withJSONObject: expect, options: [.sortedKeys])) ?? Data("{}".utf8)
        }
    }

    static func isPaneId(_ p: String) -> Bool {
        p.count > 1 && p.first == "%" && p.dropFirst().allSatisfy(\.isNumber)
    }

    /// Разбор ответа `capri-hook send`: nil — отправлено.
    public static func parseResult(_ out: HostCommand.Output) -> ReplyRefusal? {
        if out.timedOut { return .unknown }
        let line = out.stdout.split(separator: "\n").last.map(String.init) ?? ""
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let err = out.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(err.isEmpty ? "код \(out.status)" : String(err.suffix(160)))
        }
        if obj["ok"] as? Bool == true { return nil }
        let detail = obj["detail"] as? String ?? ""
        switch obj["reason"] as? String ?? "" {
        case "running": return .running
        case "typed": return .typed(detail)
        case "dialog": return .dialogOpen
        case "no-dialog": return .noDialog
        case "no-option": return .noOption
        case "pane-gone": return .paneGone
        case "pane-changed": return .paneChanged
        case "no-agent": return .noAgent
        case "dialog-changed": return .dialogChanged
        case "cursor": return .cursor
        case "pasted-not-submitted": return .pastedNotSubmitted
        case "busy": return .busy
        case "empty": return .empty
        case let r: return .failed(detail.isEmpty ? r : "\(r): \(detail)")
        }
    }
}
