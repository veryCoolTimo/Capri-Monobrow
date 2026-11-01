import Foundation

/// Что правда происходит, когда Capri садится на окно: о чём ей говорить.
public struct PerchFacts: Equatable {
    /// Имя приложения (`localizedName`).
    public var app: String
    public var category: AppCategory
    public var minuteOfDay: Int
    /// Как у `Calendar` (1 — воскресенье, 6 — пятница).
    public var weekday: Int
    /// Сессий работает / ждут ответа.
    public var working: Int
    public var waiting: Int
    /// Что играет (только если играет).
    public var track: String?
    /// Сколько дней приложение не запускали (nil — не знаем).
    public var daysAway: Int?
    /// Сколько раз Capri уже садилась сегодня.
    public var perchesToday: Int

    public init(app: String, category: AppCategory = .other, minuteOfDay: Int = 14 * 60, weekday: Int = 3, working: Int = 0,
                waiting: Int = 0, track: String? = nil, daysAway: Int? = nil, perchesToday: Int = 1) {
        self.app = app; self.category = category; self.minuteOfDay = minuteOfDay; self.weekday = weekday
        self.working = working; self.waiting = waiting; self.track = track; self.daysAway = daysAway
        self.perchesToday = perchesToday
    }
}

/// Реплика Capri. `tags` — когда уместна; пусто — всегда.
public struct PerchLine: Equatable, Codable, Hashable {
    public var text: String
    public var tags: Set<String>

    public init(_ text: String, tags: Set<String> = []) { self.text = text; self.tags = tags }
}

/// Реплики, когда Capri садится на окно (русский, тон сериала: дерзкая, самоуверенная, игривая — от «^^» до хищной
/// ухмылки; без мата и без серьёзных оценок работы). Всегда про то, что происходит (`compose`); без повтора последних 10.
public enum PerchLines {
    public static let maxChars = 48
    /// Сколько последних реплик не повторять.
    public static let memory = 10

    static func lines(_ s: [String]) -> [PerchLine] { s.map { PerchLine($0) } }

    public static let bank: [AppCategory: [PerchLine]] = [
        .browser: lines([
            "Сорок вкладок — и ни одной про меня.",
            "Опять гуглишь то, что я и так знаю?",
            "Только не ютуб. Ладно, ютуб. Я с тобой.",
            "Я посижу тут, пока ты «на минутку».",
            "Закрой хоть одну вкладку. Ради меня. ^^",
            "Интернет большой. Я — интереснее.",
            "Что ищем? Скажи, я найду быстрее.",
            "Этот сайт я уже запомнила. Наизусть.",
        ]),
        .messenger: lines([
            "Кому пишем? Мне можно не отвечать, я тут.",
            "Только не «ок». Это грубо, я знаю.",
            "Сто непрочитанных. Я считала.",
            "Пиши-пиши. Я не подглядываю. Почти.",
            "Голосовое? Смело. Я бы послушала.",
            "Отправь стикер. Доверься мне. ^^",
            "Печатаешь… печатаешь… стёр. Классика.",
            "Ответь им уже. Они ждут. Как и я.",
        ]),
        .mail: lines([
            "Письма… Сделать вид, что их нет?",
            "«Срочно» в теме. Ну-ну.",
            "Созвон в календаре? Я буду тихой. Наверное.",
            "Ответь «понял, спасибо» — и свободен.",
            "Опять рассылка. Отписаться — это сила.",
            "Календарь забит. А меня ты вписал?",
            "Входящие пухнут. Я бы всё удалила. ^^",
        ]),
        .ide: lines([
            "О, код. Посмотрю, как ты ошибаешься.",
            "Индексирует? Я подожду. Мне не впервой.",
            "Я никому не скажу про force unwrap.",
            "Компилируется? Нет? Классика.",
            "Ещё один TODO. Коллекционируешь?",
            "Тесты потом? Ну-ну. ^^",
            "Дай мне клавиатуру. Шучу. Пока шучу.",
            "Этот баг на меня похож. Красивый.",
        ]),
        .terminal: lines([
            "Чёрный экран, белые буквы — уютно.",
            "rm -rf только не на меня, ок?",
            "Я тоже живу в терминале. Почти.",
            "sudo? Какой ты сегодня смелый.",
            "Ещё команда — и я в системе. ^^",
            "Курсор мигает. Это я тебе подмигиваю.",
            "Стрелка вверх, энтер. Знаю, знаю.",
        ]),
        .design: lines([
            "Сдвинь на пиксель. Нет, обратно.",
            "Добавь розовый. Поверь мне.",
            "Красиво. Почти как я.",
            "Ещё один слой «final_final_2»?",
            "Выровняй по сетке. Я всё вижу.",
            "Зелёный хорош. Я в этом разбираюсь. ^^",
            "Шрифт смени. Шучу. Нет, не шучу.",
        ]),
        .finance: lines([
            "Цифры, цифры… Мне нравится только ноль.",
            "Не смотри так на график. Он стесняется.",
            "Купить меня нельзя. Я бесценна. ^^",
            "Всё сходится? У меня — всегда.",
            "Красное? Мой любимый цвет, кстати.",
            "Считай. Ошибки, если что, твои.",
        ]),
        .video: lines([
            "Кино? Подвинься, я тоже смотрю.",
            "Одну серию. Я засекаю. ^^",
            "Спойлер: я круче главного героя.",
            "Пауза на самом интересном? Злой.",
            "Ещё серия? Я не осуждаю. Почти.",
            "Попкорн есть? Тогда я тихо.",
        ]),
        .notes: lines([
            "Записывай. Я запомню лучше, но ладно.",
            "Новый план? Двенадцатый за неделю.",
            "Пиши красиво. Я потом прочитаю.",
            "Список дел длинный. Впиши меня первой.",
            "Мысль поймал? Держи, а то убежит.",
            "Заметка «важное». Ещё одна. ^^",
        ]),
        .files: lines([
            "Что ищем? Я бы нашла быстрее.",
            "Загрузки. Там бардак, я видела.",
            "«Новая папка 7». Сильно.",
            "Перетащи меня в корзину. Попробуй. ^^",
            "Тут столько файлов. Я в каждом была.",
            "Отсортируй по дате. Ну пожалуйста.",
        ]),
        .settings: lines([
            "Не трогай то, что меня выключает.",
            "Ищешь, где меня отключить? Нет такого.",
            "Тёмная тема — правильный выбор.",
            "Что крутим? Я слежу за каждым кликом.",
            "Обновиться? Только меня не потеряй.",
            "Настройки… Тут самое интересное. ^^",
        ]),
        .music: lines([
            "Включай. Я буду кивать.",
            "Дай угадаю: опять тот же плейлист.",
            "Погромче. Ещё. Вот так. ^^",
            "Хороший вкус. Почти как мой.",
            "Что ставим? Я уже двигаюсь.",
            "Только не грустное. Хотя ладно.",
        ]),
        .other: lines([
            "О, новенькое. Что это у нас?",
            "Ладно, посмотрим, что ты тут делаешь.",
            "Ты открыл — я пришла. Всё честно.",
            "Я тут посижу. Не обращай внимания. ^^",
            "Интересно. Объяснишь потом?",
            "Не помню такого. Значит, будет весело.",
            "Это что, работа? Ого.",
        ]),
    ]

    // MARK: реплики по фактам (отзыв Тимофея 2026-11-01: «не рандомные фразы, а про то, что происходит»)

    /// Шаблоны про приложение, которое он только что запустил (`{app}` — его имя). Банк выше — только когда имя не
    /// влезает в пузырь.
    public static let templates: [AppCategory: [String]] = [
        .browser: ["{app}. Сколько вкладок на этот раз?", "{app}? Что ищем — я найду быстрее.",
                   "{app}. Только не на минутку, да?", "Открыл {app}. Я посижу, посмотрю.",
                   "{app}. Закроешь хоть одну вкладку? ^^", "{app}? Интернет подождёт, я — нет."],
        .messenger: ["{app}? Кому пишем?", "{app}. Только не «ок», это грубо.",
                     "Открыл {app}. Сколько непрочитанных?", "{app}. Пиши, я не подглядываю. Почти.",
                     "{app}? Ответь им уже. ^^", "{app}. Голосовое? Смело."],
        .mail: ["{app}? Сделаем вид, что писем нет?", "{app}. «Срочно» в теме? Ну-ну.",
                "{app}. Отпишись от рассылок. ^^", "{app}. «Понял, спасибо» — и свободен.",
                "{app}? Входящие опять пухнут.", "{app}. Меня в календарь впишешь?"],
        .ide: ["{app}? Посмотрю, как ты ошибаешься.", "{app}. Индексирует? Я подожду.",
               "Открыл {app}. Тесты потом, да? ^^", "{app}. Про force unwrap — никому.",
               "{app}? Ещё один TODO в коллекцию.", "{app}. С первого раза соберётся? Нет."],
        .terminal: ["{app}. Чёрный экран — уютно.", "{app}? rm -rf только не на меня.",
                    "{app}. Курсор мигает — это я. ^^", "{app}. sudo? Смелый сегодня.",
                    "{app}? Стрелка вверх, энтер. Знаю.", "{app}. Я тоже тут живу. Почти."],
        .design: ["{app}? Сдвинь на пиксель. Обратно.", "{app}. Добавь розовый, поверь мне.",
                  "Открыл {app}. Опять «final_final_2»?", "{app}. Выровняй по сетке, я вижу.",
                  "{app}? Красиво. Почти как я. ^^", "{app}. Шрифт смени. Шучу. Нет."],
        .finance: ["{app}? Мне нравится только ноль.", "{app}. Не смотри так на график.",
                   "Открыл {app}. Всё сходится? ^^", "{app}. Красное — мой любимый цвет.",
                   "{app}? Ошибки, если что, твои.", "{app}. Купить меня нельзя."],
        .video: ["{app}? Подвинься, я тоже смотрю.", "{app}. Одну серию. Я засекаю. ^^",
                 "Открыл {app}. Попкорн есть?", "{app}. Пауза на самом интересном?",
                 "{app}? Ещё серия? Не осуждаю.", "{app}. Спойлер: я круче героя."],
        .notes: ["{app}? Записывай, я запомню лучше.", "{app}. Новый план? Двенадцатый.",
                 "Открыл {app}. Впиши меня первой. ^^", "{app}. Мысль поймал? Держи.",
                 "{app}? Опять заметка «важное».", "{app}. Пиши красиво, я прочитаю."],
        .files: ["{app}? Что ищем? Я быстрее.", "{app}. В загрузках бардак, я видела.",
                 "Открыл {app}. «Новая папка 7»? ^^", "{app}. Отсортируй по дате, а?",
                 "{app}? Только меня в корзину не надо.", "{app}. Я в каждом файле была."],
        .settings: ["{app}? Меня не выключай, ладно?", "{app}. Ищешь, где меня отключить?",
                    "Открыл {app}. Что крутим? ^^", "{app}. Тёмная тема — правильно.",
                    "{app}? Слежу за каждым кликом.", "{app}. Обновишься — не потеряй меня."],
        .music: ["{app}? Включай, я буду кивать.", "{app}. Опять тот же плейлист?",
                 "Открыл {app}. Погромче. ^^", "{app}. Что ставим? Я уже двигаюсь.",
                 "{app}? Только не грустное.", "{app}. Хороший вкус. Почти как мой."],
        .other: ["{app}? Что это у нас?", "Открыл {app}. Посмотрим, что тут.",
                 "{app}. Ты открыл — я пришла. ^^", "{app}? Объяснишь потом?",
                 "{app}. Не помню такого. Будет весело.", "{app}. Это что, работа? Ого."],
    ]

    /// Склонение: 1 сессия, 2 сессии, 5 сессий.
    public static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let m10 = n % 10, m100 = n % 100
        if m10 == 1, m100 != 11 { return one }
        if (2...4).contains(m10), !(12...14).contains(m100) { return few }
        return many
    }

    /// Имя для пузыря: без разметки, ≤ `maxName` знаков (длиннее — nil, тогда реплика без имени).
    public static let maxName = 16
    public static func clean(_ s: String, max n: Int) -> String? {
        let bad = CharacterSet(charactersIn: "`*#[]{}<>|\\\n\r\t")
        let t = String(s.unicodeScalars.filter { !bad.contains($0) }).trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        return t.count <= n ? t : nil
    }

    /// Трек — коротко: длиннее 18 знаков обрезается с «…».
    public static func shortTrack(_ s: String) -> String? {
        let bad = CharacterSet(charactersIn: "`*#[]{}<>|\\\n\r\t«»\"")
        let t = String(s.unicodeScalars.filter { !bad.contains($0) }).trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !t.lowercased().contains("http") else { return nil }
        return t.count <= 18 ? t : String(t.prefix(17)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Группы реплик по поводу, от самого важного: ждут сессии → играет трек → давно не открывал → сессии работают →
    /// приложение и время суток. Каждая реплика называет то, что правда сейчас происходит.
    public static func candidates(_ f: PerchFacts) -> [[String]] {
        let app = clean(f.app, max: maxName)
        var groups: [[String]] = []
        func fill(_ ts: [String]) -> [String] {
            guard let app else { return ts.filter { !$0.contains("{app}") } }
            return ts.map { $0.replacingOccurrences(of: "{app}", with: app) }
        }
        if f.waiting > 0 {
            let n = f.waiting
            let wait = n == 1 ? "ждёт сессия" : "ждут \(n) \(plural(n, "сессия", "сессии", "сессий"))"
            let first = n == 1 ? "сессия" : "\(n) \(plural(n, "сессия", "сессии", "сессий"))"
            groups.append(fill(["{app}? А тебя \(wait). ^^", "{app} подождёт. Тебя \(wait).",
                                "Сначала \(first), потом {app}.", "Пока ты в {app}, тебя \(wait)."]))
        }
        if let raw = f.track, let t = shortTrack(raw) {
            groups.append(fill(["{app} под «\(t)»? Одобряю.", "«\(t)» и {app}. Неплохо.",
                                "{app}, пока играет «\(t)». Ок.", "Под «\(t)» и {app} — можно."]))
        }
        if let d = f.daysAway, d >= 2 {
            let days = "\(d) \(plural(d, "день", "дня", "дней"))"
            groups.append(fill(["{app}? \(days) не открывал. Скучал?", "О, {app}. Не виделись \(days).",
                                "{app} — впервые за \(days). ^^"]))
        }
        if f.working > 0 {
            let n = f.working
            let work = n == 1 ? "сессия пашет" : "\(n) \(plural(n, "сессия", "сессии", "сессий")) пашут"
            groups.append(fill(["{app}, пока \(work)? Удобно. ^^", "Тут {app}, а там \(work).",
                                "\(n == 1 ? "Сессия работает" : "Сессии работают"), ты в {app}. Хитро."]))
        }
        var tail: [String] = []
        let clock = QuietHours.clock(((f.minuteOfDay % 1440) + 1440) % 1440)
        switch f.minuteOfDay {
        case 0..<300: tail += ["{app} в \(clock)? Спать не будем, да?", "\(clock), а ты открыл {app}. Ночь наша."]
        case 300..<720: tail += ["Утро, и сразу {app}. Смело.", "{app} с утра? Ну давай."]
        case 1080..<1440:
            if f.weekday == 6 { tail += ["Пятница, вечер, а ты в {app}?"] }
            tail += ["Вечерний {app}. Самое время.", "{app} в \(clock). Ещё работаем?"]
        default: break
        }
        if f.perchesToday == 0 { tail.append("Первый раз сегодня — {app}. Я тут.") }
        tail += templates[f.category] ?? templates[.other]!
        groups.append(fill(tail))
        // Имя не влезло — без имени (банк категории).
        if app == nil { groups.append((bank[f.category] ?? bank[.other]!).map(\.text)) }
        return groups.map { $0.filter(valid) }.filter { !$0.isEmpty }
    }

    /// Реплика по фактам: первая группа, где есть свежая (не из последних `memory`), — случайная из неё по зерну;
    /// всё было недавно — та, что звучала раньше всех.
    public static func compose(_ f: PerchFacts, recent: [String] = [], seed: Int) -> String {
        let groups = candidates(f)
        let window = Array(recent.suffix(memory))
        for g in groups {
            let fresh = g.filter { !window.contains($0) }
            if !fresh.isEmpty { return fresh[Int(TickNoise.unit(seed, 903) * Double(fresh.count)) % fresh.count] }
        }
        let all = groups.flatMap { $0 }
        return all.min { (window.lastIndex(of: $0) ?? -1) < (window.lastIndex(of: $1) ?? -1) } ?? "Открыл — я пришла. ^^"
    }

    static let banned = ["хуй", "хуё", "пизд", "бля", "еба", "ёба", "ебл", "сука", "мудак", "мудил", "fuck", "shit", "bitch"]

    /// Реплика годится: 3…48 знаков, одна строка без пробелов по краям, без ссылок, разметки и мата.
    public static func valid(_ s: String) -> Bool {
        guard s.count >= 3, s.count <= maxChars, s == s.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        if s.contains(where: { $0.isNewline }) { return false }
        if s.rangeOfCharacter(from: CharacterSet(charactersIn: "`*#[]{}<>|\\")) != nil { return false }
        let low = s.lowercased()
        if low.contains("http") || low.contains("www.") || low.contains("://") { return false }
        if banned.contains(where: { low.contains($0) }) { return false }
        return true
    }

    /// Ответ Codex (`{"browser": ["…"], …}`) → реплики по категориям; негодные и неизвестные категории отброшены,
    /// не больше 12 на категорию. Битый JSON — пусто.
    public static func parseGenerated(_ json: String) -> [AppCategory: [PerchLine]] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var out: [AppCategory: [PerchLine]] = [:]
        for (k, v) in obj {
            guard let c = AppCategory(rawValue: k), AppCategory.speaking.contains(c), let arr = v as? [Any] else { continue }
            var seen: Set<String> = []
            let ok = arr.compactMap { $0 as? String }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { valid($0) && seen.insert($0).inserted }
            if !ok.isEmpty { out[c] = Array(ok.prefix(12)).map { PerchLine($0) } }
        }
        return out
    }
}
