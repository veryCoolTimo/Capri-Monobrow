import Foundation

// Действия голосовых команд, которые можно проверить без Мака: скрипты Заметок и Напоминаний, ссылки из ответа
// веб-поиска, удержание клавиши.

/// AppleScript для Apple Заметок и Напоминаний (выполняет Capri через `osascript`; первый раз macOS спрашивает
/// разрешение «Автоматизация» — только по действию человека).
public enum AppleScripts {
    public static let notesBundle = "com.apple.Notes"
    public static let remindersBundle = "com.apple.reminders"

    /// Новая заметка в папке по умолчанию. Первая строка — заголовок (Заметки берут его из начала текста).
    public static func note(_ text: String) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let html = "<div>" + escapeHTML(String(clean.prefix(4000))) + "</div>"
        return """
        tell application id \(MusicScript.quote(notesBundle))
        make new note at default folder of default account with properties {body:\(MusicScript.quote(html))}
        end tell
        """
    }

    /// Напоминание в списке по умолчанию; срок — по частям даты (без разбора строки даты, она зависит от языка
    /// системы). Сначала день = 1, чтобы смена месяца не переполнила дату (31 → февраль).
    public static func reminder(_ text: String, due: Date?, calendar: Calendar = .current) -> String {
        let name = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        guard let due else {
            return """
            tell application id \(MusicScript.quote(remindersBundle))
            tell default list to make new reminder with properties {name:\(MusicScript.quote(name))}
            end tell
            """
        }
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: due)
        return """
        set d to current date
        set day of d to 1
        set year of d to \(c.year ?? 2026)
        set month of d to \(c.month ?? 1)
        set day of d to \(c.day ?? 1)
        set hours of d to \(c.hour ?? 9)
        set minutes of d to \(c.minute ?? 0)
        set seconds of d to 0
        tell application id \(MusicScript.quote(remindersBundle))
        tell default list to make new reminder with properties {name:\(MusicScript.quote(name)), due date:d, remind me date:d}
        end tell
        """
    }

    static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\n", with: "<br>")
    }
}

/// Ответ Codex с веб-поиском: текст без ссылок + до трёх ссылок (http/https) кнопками. Ссылку открывает только клик.
public enum SearchAnswer {
    public struct Link: Equatable {
        public var title: String
        public var url: URL
    }

    public static func split(_ text: String, max: Int = 3) -> (text: String, links: [Link]) {
        var links: [Link] = []
        var out = text
        func add(_ title: String, _ raw: String) {
            let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: ").,;»\"'"))
            guard let u = URL(string: trimmed), let scheme = u.scheme?.lowercased(), scheme == "https" || scheme == "http",
                  let host = u.host, !host.isEmpty else { return }
            guard !links.contains(where: { $0.url == u }) else { return }
            let t = title.trimmingCharacters(in: .whitespaces)
            links.append(Link(title: t.isEmpty || t == trimmed ? host.replacingOccurrences(of: "www.", with: "") : String(t.prefix(60)), url: u))
        }
        // [название](https://…) → «название» в тексте, ссылка — в список.
        if let md = try? NSRegularExpression(pattern: #"\[([^\]\n]{0,200})\]\((https?://[^)\s]+)\)"#) {
            let ns = out as NSString
            for m in md.matches(in: out, range: NSRange(location: 0, length: ns.length)).reversed() {
                let title = ns.substring(with: m.range(at: 1)), url = ns.substring(with: m.range(at: 2))
                add(title, url)
                out = (out as NSString).replacingCharacters(in: m.range, with: title)
            }
            links.reverse()   // шли с конца
        }
        // Голые ссылки — из текста убрать.
        if let bare = try? NSRegularExpression(pattern: #"\(?<?https?://[^\s<>()]+[)>]?"#) {
            let ns = out as NSString
            for m in bare.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                add("", ns.substring(with: m.range).trimmingCharacters(in: CharacterSet(charactersIn: "(<>)")))
            }
            out = bare.stringByReplacingMatches(in: out, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        }
        // Остатки «Источники:», пустые строки и двойные пробелы.
        var lines = out.components(separatedBy: "\n").map { $0.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces) }
        lines = lines.filter { l in
            let low = l.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "-*•:· "))
            let label = ["источник", "ссылки", "sources", "source", "links"].contains { low.hasPrefix($0) }
            return !l.isEmpty && !(label && !links.isEmpty) && !["источники", "источник", "ссылки", "sources", "source", "links"].contains(low)
                && l.trimmingCharacters(in: CharacterSet(charactersIn: "-*•·,;. ")).count > 0
        }
        return (lines.joined(separator: "\n"), Array(links.prefix(max)))
    }
}

/// Подсказки Codex для голосовых просьб.
public enum VoicePrompts {
    /// Инструкции треда веб-поиска: только поиск и ответ — без команд и файлов.
    public static let developer = """
    Ты — помощник в приложении Capri. Сейчас тебе можно пользоваться веб-поиском, и только им: \
    не запускай команды, не читай и не меняй файлы. Отвечай коротко и по делу.
    """

    /// Веб-поиск по голосовой просьбе: коротко и с источниками.
    public static func search(_ query: String) -> String {
        """
        Человек попросил голосом найти в интернете: «\(String(query.prefix(500)))».
        Найди это веб-поиском и ответь коротко: 2–4 предложения, на языке просьбы, без вступлений. \
        В конце дай 1–3 ссылки на источники в виде [название](https://…). \
        Если просьба непонятна (ошибка распознавания речи), скажи это одной фразой.
        """
    }
}

/// Удержание ⌃⌥Space: короткое нажатие — открыть/закрыть помощника (как раньше), удержание — голос.
/// Чистая машина состояний: время передаётся снаружи.
public struct PushToTalk {
    public enum Action: Equatable {
        /// Нажали: заранее включить микрофон в буфер (первое слово не теряется).
        case prepare
        /// Держат дольше порога: слушаем (notch «слушает», звук — в хелпер).
        case listen
        /// Отпустили быстро: это был обычный вызов помощника, буфер выбросить.
        case tap
        /// Отпустили после удержания: фраза закончилась.
        case finish
        /// Держали слишком коротко после порога или дольше предела — фразу забыть.
        case cancel
    }

    public static let holdThreshold = 0.28
    /// Дольше — наверняка залипла клавиша: стоп.
    public static let maxHold = 45.0

    public enum Phase: Equatable { case idle, pressed(Double), listening(Double) }
    public private(set) var phase: Phase = .idle

    public init() {}

    public mutating func press(at t: Double) -> [Action] {
        guard phase == .idle else { return [] }   // автоповтор клавиши
        phase = .pressed(t)
        return [.prepare]
    }

    /// Проверка по таймеру после нажатия (и на всякий случай — при отпускании).
    public mutating func tick(at t: Double) -> [Action] {
        switch phase {
        case .pressed(let p) where t - p >= Self.holdThreshold:
            phase = .listening(p)
            return [.listen]
        case .listening(let p) where t - p >= Self.maxHold:
            phase = .idle
            return [.finish]
        default: return []
        }
    }

    public mutating func release(at t: Double) -> [Action] {
        switch phase {
        case .idle: return []
        case .pressed(let p):
            phase = .idle
            return t - p >= Self.holdThreshold ? [.listen, .finish] : [.tap]
        case .listening:
            phase = .idle
            return [.finish]
        }
    }

    /// Снаружи оборвали (ошибка микрофона, notch раскрыли мышью).
    public mutating func reset() { phase = .idle }
}

/// Ответ Capri в peek (голосовой вопрос при закрытом помощнике): сколько держать и что подсказать под ним.
public enum PeekAnswerTiming {
    /// Время на чтение: ~14 знаков в секунду плюс 3 с, от 6 до 20 с.
    public static func seconds(_ text: String) -> Double {
        min(20, max(6, Double(text.count) / 14 + 3))
    }

    /// Подсказка: ждёт подтверждения — «подтвердить», есть ссылки — «ссылки», иначе — продолжить разговор.
    public static func hint(confirm: Bool, links: Bool) -> String {
        confirm ? "нажми — подтвердить" : links ? "нажми — ссылки" : "нажми — продолжить"
    }
}
