import Foundation

/// Что человек сказал Capri голосом (push-to-talk) → что делать. Чистый разбор, без побочных эффектов.
/// Неоднозначное — помощнику (как ввод с клавиатуры): лучше переспросить, чем сделать не то.
public enum VoiceIntent: Equatable {
    /// «Включи …», «пауза», «дальше».
    case music(MusicCommand)
    /// «Запиши …» → Apple Заметки.
    case note(String)
    /// «Напомни через 20 минут / в 18:00 / завтра в 9 …» → Apple Напоминания; `due` nil — без срока.
    case reminder(text: String, due: Date?)
    /// «Найди / поищи / посмотри в интернете …» → Codex с веб-поиском только для этой просьбы.
    case search(String)
    /// «Ответь votek2 …» → текст ответа сессии, отправка — только после подтверждения.
    case reply(session: String, text: String)
    /// Всё остальное — помощнику.
    case assistant(String)
    /// Пусто или одно обращение («Капри»).
    case empty

    /// Разбор фразы. `sessions` — имена сессий (как их зовёт Capri и tmux), `known` — музыка сейчас известна.
    public static func parse(_ raw: String, sessions: [String] = [], musicKnown: Bool = false,
                             now: Date = Date(), calendar: Calendar = .current) -> VoiceIntent {
        let text = stripAddress(raw)
        guard !text.isEmpty else { return .empty }
        let low = lower(text)

        if let cmd = MusicCommand.parse(text, known: musicKnown) { return .music(cmd) }
        if let r = reply(text, low: low, sessions: sessions) { return r }
        if let r = reminder(text, low: low, now: now, calendar: calendar) { return r }
        if let n = note(text, low: low) { return n }
        if let s = search(text, low: low) { return s }
        return .assistant(text)
    }

    // MARK: обращение

    static let addressWords: Set<String> = ["капри", "capri", "kapri", "каприз", "эй", "hey", "слушай"]

    /// Без «Капри,» / «Эй, Капри» в начале и пробелов по краям.
    public static func stripAddress(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        var changed = true
        while changed {
            changed = false
            guard let first = s.split(separator: " ", maxSplits: 1).first else { break }
            let word = lower(String(first)).trimmingCharacters(in: .punctuationCharacters)
            if addressWords.contains(word) {
                s = String(String(s.dropFirst(first.count)).drop { $0 == " " || $0.isPunctuation })
                changed = true
            }
        }
        // Финальная точка распознавания («Пауза.») — не часть просьбы.
        while let last = s.last, ".!…".contains(last) { s.removeLast() }
        return s.trimmingCharacters(in: .whitespaces)
    }

    static func lower(_ s: String) -> String { s.lowercased().replacingOccurrences(of: "ё", with: "е") }

    /// Остаток исходной строки после `n` слов (регистр и знаки сохранены), без двоеточия/запятой в начале.
    static func dropWords(_ text: String, _ n: Int) -> String {
        var words = text.split(separator: " ", omittingEmptySubsequences: true)
        words.removeFirst(min(n, words.count))
        return words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ",:;—- ").union(.whitespaces))
    }

    /// Слова в нижнем регистре без знаков по краям.
    static func words(_ low: String) -> [String] {
        low.split(separator: " ").map { $0.trimmingCharacters(in: .punctuationCharacters) }
    }

    // MARK: ответ сессии

    static let replyVerbs: Set<String> = ["ответь", "ответить", "напиши", "скажи", "передай", "reply", "answer", "tell"]

    static func reply(_ text: String, low: String, sessions: [String]) -> VoiceIntent? {
        var w = words(low)
        guard let verb = w.first, replyVerbs.contains(verb) else { return nil }
        var skip = 1
        // «ответь в votek2», «ответь сессии votek2», «reply to votek2».
        while skip < w.count, ["в", "во", "сессии", "сессию", "to", "session", "на"].contains(w[skip]) { skip += 1 }
        w = Array(w.dropFirst(skip))
        let names = sessions.map { ($0, SessionMatch.key($0)) }.filter { !$0.1.isEmpty }
        // Самое длинное совпадение из 1–3 слов.
        for n in stride(from: min(3, w.count), through: 1, by: -1) {
            let key = SessionMatch.key(w.prefix(n).joined(separator: " "))
            guard let hit = names.first(where: { $0.1 == key }) else { continue }
            let rest = dropWords(text, skip + n)
            guard !rest.isEmpty else { return .assistant(text) }
            return .reply(session: hit.0, text: rest)
        }
        // Глагол есть, а сессии с таким именем нет — пусть помощник разберётся (он видит все сессии).
        return .assistant(text)
    }

    // MARK: заметка

    static func note(_ text: String, low: String) -> VoiceIntent? {
        let w = words(low)
        guard let first = w.first else { return nil }
        var n = 0
        if ["запиши", "записать", "заметка", "запомни"].contains(first) { n = 1 }
        else if w.count > 1, ["сделай", "создай", "добавь"].contains(first), ["заметку", "заметка"].contains(w[1]) { n = 2 }
        else if first == "note" { n = 1 }
        else if w.count > 2, ["take", "make"].contains(first), w[1] == "a", w[2] == "note" { n = 3 }
        guard n > 0 else { return nil }
        // «запиши в заметки: …», «запиши себе …».
        var tail = Array(w.dropFirst(n))
        while let t = tail.first, ["в", "заметки", "заметку", "себе", "что", "that"].contains(t) { tail.removeFirst(); n += 1 }
        let body = dropWords(text, n)
        guard !body.isEmpty else { return .assistant(text) }
        // «запомни, что я говорил про…» — вопрос, а не заметка: только явные «запиши»/«заметка».
        if first == "запомни", body.count < 3 { return .assistant(text) }
        return .note(body)
    }

    // MARK: поиск

    static func search(_ text: String, low: String) -> VoiceIntent? {
        let w = words(low)
        guard let first = w.first else { return nil }
        let web: Set<String> = ["интернете", "интернет", "сети", "гугле", "google", "web", "вебе", "онлайн"]
        var n = 0
        if ["найди", "поищи", "погугли", "загугли", "гугли", "search", "google"].contains(first) { n = 1 }
        else if ["посмотри", "глянь", "узнай", "look"].contains(first), w.dropFirst().prefix(3).contains(where: web.contains) { n = 1 }
        else if w.count > 1, first == "look", w[1] == "up" { n = 2 }
        guard n > 0 else { return nil }
        let rest = Array(w.dropFirst(n))
        // «найди сессию, которая ждёт» — про сессии, это помощнику.
        let local: Set<String> = ["сессию", "сессии", "сессия", "терминал", "session", "sessions", "окно", "файл"]
        if rest.prefix(2).contains(where: local.contains) { return .assistant(text) }
        // «в интернете», «for», «мне», «в гугле» после глагола.
        var skip = n
        var r = rest[...]
        while let t = r.first, ["в", "во", "мне", "for", "the", "web", "on", "по"].contains(t) || web.contains(t) { r = r.dropFirst(); skip += 1 }
        let q = dropWords(text, skip)
        guard q.count >= 2 else { return .assistant(text) }
        return .search(q)
    }

    // MARK: напоминание

    static func reminder(_ text: String, low: String, now: Date, calendar: Calendar) -> VoiceIntent? {
        let w = words(low)
        guard let first = w.first else { return nil }
        var n = 0
        if ["напомни", "напомнить", "remind"].contains(first) { n = 1 }
        else if w.count > 1, ["поставь", "создай", "сделай", "добавь"].contains(first), ["напоминание", "напоминалку"].contains(w[1]) { n = 2 }
        guard n > 0 else { return nil }
        if w.count > n, ["мне", "me"].contains(w[n]) { n += 1 }
        let rest = dropWords(text, n)
        let restLow = lower(rest)
        // «напомни, что я вчера говорил» — вопрос помощнику, если срока нет.
        let parsed = ReminderTime.extract(restLow, now: now, calendar: calendar)
        var body = parsed.map { cut(rest, $0.range) } ?? rest
        body = trimLinkers(body)
        if parsed == nil {
            let q = words(restLow).first ?? ""
            if ["что", "как", "какой", "какая", "какие", "где", "кто", "о", "про", "сколько", "почему", "зачем", "what", "how", "where", "who"].contains(q) {
                return .assistant(text)
            }
        }
        guard !body.isEmpty else { return .assistant(text) }
        return .reminder(text: body, due: parsed?.date)
    }

    /// Убрать из `s` диапазон, найденный в его нижнем регистре (длины совпадают: `lowercased` для кириллицы и
    /// латиницы длину не меняет, «ё»→«е» — тоже).
    static func cut(_ s: String, _ r: Range<Int>) -> String {
        let chars = Array(s)
        guard r.lowerBound >= 0, r.upperBound <= chars.count else { return s }
        let out = String(chars[..<r.lowerBound]) + " " + String(chars[r.upperBound...])
        return out.split(separator: " ").joined(separator: " ")
    }

    /// «чтобы», «что», «to», «о том что» на краях текста напоминания.
    static func trimLinkers(_ s: String) -> String {
        var w = s.split(separator: " ").map(String.init)
        let lead: Set<String> = ["чтобы", "что", "to", "о", "об", "про", "том", "about", "that"]
        while let f = w.first, lead.contains(lower(f).trimmingCharacters(in: .punctuationCharacters)) { w.removeFirst() }
        var out = w.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ",:;—- ").union(.whitespaces))
        while let last = out.last, ",:;—-".contains(last) { out.removeLast() }
        return out.trimmingCharacters(in: .whitespaces)
    }
}

/// Имя сессии, как его можно сказать: «вотек два» = «votek2» = «Votek-2».
public enum SessionMatch {
    static let translit: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ж": "zh", "з": "z", "и": "i", "й": "i",
        "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u",
        "ф": "f", "х": "h", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "sh", "ъ": "", "ы": "y", "ь": "", "э": "e",
        "ю": "yu", "я": "ya"
    ]
    static let numbers: [String: String] = [
        "ноль": "0", "один": "1", "одна": "1", "раз": "1", "два": "2", "две": "2", "три": "3", "четыре": "4", "пять": "5",
        "шесть": "6", "семь": "7", "восемь": "8", "девять": "9", "десять": "10",
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7",
        "eight": "8", "nine": "9", "ten": "10"
    ]

    /// Ключ сравнения: латиница, числа словами → цифры, c→k, без пробелов и знаков.
    public static func key(_ s: String) -> String {
        let low = VoiceIntent.lower(s)
        var out = ""
        for word in low.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" || $0 == "." }) {
            let w = String(word).trimmingCharacters(in: .punctuationCharacters)
            if let d = numbers[w] { out += d; continue }
            for ch in w {
                if let t = translit[ch] { out += t }
                else if ch.isLetter || ch.isNumber { out.append(ch) }
            }
        }
        return out.replacingOccurrences(of: "c", with: "k").replacingOccurrences(of: "w", with: "v")
    }
}

/// Срок напоминания в тексте: «через 20 минут», «через полчаса», «в 18:00», «в 6 вечера», «завтра в 9»,
/// «in 20 minutes», «at 6 pm». Возвращает дату и где в тексте (в символах нижнего регистра) это было.
public enum ReminderTime {
    public struct Found: Equatable {
        public var date: Date
        public var range: Range<Int>
    }

    static let units: [(prefixes: [String], seconds: Double)] = [
        (["секунд", "сек", "second"], 1),
        (["минут", "мин", "minute", "min"], 60),
        (["час", "hour"], 3600),
        (["день", "дня", "дней", "сутки", "day"], 86_400)
    ]

    static let numberWords: [String: Int] = [
        "одну": 1, "один": 1, "одна": 1, "две": 2, "два": 2, "три": 3, "четыре": 4, "пять": 5, "шесть": 6, "семь": 7,
        "восемь": 8, "девять": 9, "десять": 10, "одиннадцать": 11, "двенадцать": 12, "пятнадцать": 15,
        "двадцать": 20, "тридцать": 30, "сорок": 40, "пятьдесят": 50, "полтора": 0, "полторы": 0,
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "five": 5, "ten": 10, "fifteen": 15, "twenty": 20, "thirty": 30
    ]

    public static func extract(_ low: String, now: Date, calendar: Calendar) -> Found? {
        let tokens = tokenize(low)
        if let f = relative(tokens, now: now) { return f }
        if let f = absolute(tokens, now: now, calendar: calendar) { return f }
        return nil
    }

    struct Token { var text: String; var range: Range<Int> }

    /// Слова с позициями (в символах), знаки по краям слова отрезаны.
    static func tokenize(_ s: String) -> [Token] {
        var out: [Token] = []
        var start: Int?
        let chars = Array(s)
        for i in 0...chars.count {
            let ch: Character = i < chars.count ? chars[i] : " "
            if ch == " " {
                if let st = start {
                    var a = st, b = i
                    while a < b, chars[a].isPunctuation, chars[a] != ":" { a += 1 }
                    while b > a, chars[b - 1].isPunctuation, chars[b - 1] != ":" { b -= 1 }
                    if a < b { out.append(Token(text: String(chars[a..<b]), range: a..<b)) }
                }
                start = nil
            } else if start == nil { start = i }
        }
        return out
    }

    /// Число из токенов с позиции `i`: «20», «двадцать пять», «полчаса» не здесь. → (значение, сколько токенов).
    static func number(_ t: [Token], _ i: Int) -> (Double, Int)? {
        guard i < t.count else { return nil }
        let w = t[i].text.replacingOccurrences(of: ",", with: ".")
        if let v = Double(w) { return (v, 1) }
        if w == "полтора" || w == "полторы" { return (1.5, 1) }
        guard let v = numberWords[w] else { return nil }
        if v >= 20, i + 1 < t.count, let u = numberWords[t[i + 1].text], u > 0, u < 10 { return (Double(v + u), 2) }
        return (Double(v), 1)
    }

    static func unit(_ w: String) -> Double? {
        for u in units where u.prefixes.contains(where: { w.hasPrefix($0) }) { return u.seconds }
        return nil
    }

    /// «через 20 минут», «через час», «через полчаса», «in 5 minutes», «через 2 часа 15 минут».
    static func relative(_ t: [Token], now: Date) -> Found? {
        for i in t.indices where t[i].text == "через" || t[i].text == "in" {
            var j = i + 1
            var total = 0.0
            while j < t.count {
                let w = t[j].text
                if w == "полчаса" || w == "пол-часа" { total += 1800; j += 1; continue }
                if w == "полминуты" { total += 30; j += 1; continue }
                if let u = unit(w) { total += u; j += 1; continue }   // «через час», «через минуту»
                if let (v, used) = number(t, j), j + used < t.count, let u = unit(t[j + used].text) {
                    total += v * u
                    j += used + 1
                    if j < t.count, t[j].text == "и" || t[j].text == "and" { j += 1 }
                    continue
                }
                break
            }
            guard total > 0, total <= 30 * 86_400 else { continue }
            return Found(date: now.addingTimeInterval(total), range: t[i].range.lowerBound..<t[j - 1].range.upperBound)
        }
        return nil
    }

    /// «в 18:00», «в 18.30», «в 6 вечера», «в 9 утра», «завтра в 9», «сегодня в 21», «в 18 часов», «at 6 pm», «завтра».
    static func absolute(_ t: [Token], now: Date, calendar cal: Calendar) -> Found? {
        var dayShift: Int?
        var dayIndex: Int?
        for (i, tok) in t.enumerated() {
            switch tok.text {
            case "сегодня", "today": dayShift = 0; dayIndex = i
            case "завтра", "tomorrow": dayShift = 1; dayIndex = i
            case "послезавтра": dayShift = 2; dayIndex = i
            default: continue
            }
            break
        }
        var hit: (h: Int, m: Int, range: Range<Int>, marker: Int?)?
        for i in t.indices where ["в", "во", "к", "at", "by"].contains(t[i].text) && i + 1 < t.count {
            guard let (h, m, used) = clock(t, i + 1) else { continue }
            var end = i + used
            var marker: Int?
            if end + 1 < t.count {
                let next = t[end + 1].text
                if ["утра", "am", "a.m"].contains(next) { marker = 0; end += 1 }
                else if ["дня", "вечера", "pm", "p.m"].contains(next) { marker = 12; end += 1 }
                else if next == "ночи" { marker = h == 12 ? 0 : (h < 5 ? 0 : 12); end += 1 }
            }
            hit = (h, m, t[i].range.lowerBound..<t[end].range.upperBound, marker)
            break
        }
        let base = cal.startOfDay(for: now)
        guard let hit else {
            // Только «завтра» — в 9 утра.
            guard let shift = dayShift, shift > 0, let di = dayIndex,
                  let day = cal.date(byAdding: .day, value: shift, to: base),
                  let d = cal.date(bySettingHour: 9, minute: 0, second: 0, of: day) else { return nil }
            return Found(date: d, range: t[di].range)
        }
        var h = hit.h
        if let mk = hit.marker { h = mk == 12 ? (h < 12 ? h + 12 : h) : (h == 12 ? 0 : h) }
        guard (0...23).contains(h), (0...59).contains(hit.m) else { return nil }
        var range = hit.range
        if let di = dayIndex {
            range = min(range.lowerBound, t[di].range.lowerBound)..<max(range.upperBound, t[di].range.upperBound)
        }
        let shift = dayShift ?? 0
        guard let day = cal.date(byAdding: .day, value: shift, to: base),
              var d = cal.date(bySettingHour: h, minute: hit.m, second: 0, of: day) else { return nil }
        if dayShift == nil, d <= now {
            // «в 6» в 15:00 — это 18:00; «в 9» в 20:00 — завтра в 9.
            if hit.marker == nil, h < 12, let pm = cal.date(bySettingHour: h + 12, minute: hit.m, second: 0, of: day), pm > now {
                d = pm
            } else if let next = cal.date(byAdding: .day, value: 1, to: d) {
                d = next
            }
        }
        return Found(date: d, range: range)
    }

    /// «18:00», «18.30», «18 30», «18 часов 30 минут», «9», «девять» → (часы, минуты, токенов).
    static func clock(_ t: [Token], _ i: Int) -> (Int, Int, Int)? {
        let w = t[i].text
        for sep in [":", "."] where w.contains(sep) {
            let p = w.split(separator: Character(sep)).map(String.init)
            guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]) else { return nil }
            return (h, m, 1)
        }
        guard let (v, used) = number(t, i), v == v.rounded(), v >= 0, v <= 24 else { return nil }
        let h = Int(v)
        var j = i + used
        if j < t.count, t[j].text.hasPrefix("час") || t[j].text == "o'clock" { j += 1 }
        // «в 18 30» и «в 18 часов 30 минут».
        if j < t.count, let mm = Int(t[j].text), mm < 60, t[j].text.count == 2 {
            j += 1
            if j < t.count, t[j].text.hasPrefix("мин") { j += 1 }
            return (h, mm, j - i)
        }
        return (h, 0, j - i)
    }
}
