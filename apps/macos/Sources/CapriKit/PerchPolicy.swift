import Foundation

/// Садиться ли Capri на окно приложения, которое человек только что **запустил**. Чистая логика, как `CharacterDirector`:
/// время, настройки и состояние машины — входом, без жребия (у каждого появления есть видимая причина).
/// Отзыв Тимофея 2026-11-01 («появляется и говорит фразы рандомно», «слишком часто на экран попадает») сильнее
/// решений плана: только запуск приложения (не ⌘-Tab и не любая активация), только первый запуск этого приложения за
/// день, ≥ 10 мин между посадками, ≤ 2 в час, ≤ 4 в день; тихие часы 00:30–09:00; и общий бюджет стола
/// (`ScreenBudget`) вместе со всеми остальными сценами.
public struct PerchPolicy: Equatable, Codable {
    public enum Event: Equatable {
        /// Приложение осталось передним после дебаунса. `launched` — оно только что запустилось (только тогда садится).
        case activated(bundle: String, launched: Bool)
        /// Терминал передний, под ним сессии Capri (`sessions` — ключи). `opening` — отпечаток свежего пути (ssh,
        /// tmux attach, запуск агента ≤ 3 мин назад, `TerminalWatch.opening`); nil — просто переключился на старое окно.
        /// `working` — хоть одна из них работает (иначе смотреть не на что).
        case terminal(window: UInt32, sessions: [String], opening: String?, working: Bool)
    }

    public enum Decision: Equatable {
        case perch(AppCategory)
        /// Вылезти из терминала и смотреть за сессией.
        case watch
        case skip(String)

        public var log: String {
            switch self {
            case .perch(let c): "perch \(c.rawValue)"
            case .watch: "watch"
            case .skip(let why): "skip \(why)"
            }
        }
    }

    public struct Input: Equatable {
        public var now: Double
        /// Начало «дня» лимита (последние 05:00).
        public var dayStart: Double
        public var minuteOfDay: Int
        /// «Садиться на окна».
        public var enabled: Bool
        /// «Спрятать персонажа на час» / «Прогнать с окон на час».
        public var hiddenUntil: Double?
        public var paused: Bool
        /// Переднее окно на весь экран (полноэкранное или развёрнутое без строки меню).
        public var fullscreen: Bool
        public var inCall: Bool
        public var displaysAsleep: Bool
        public var notchOpen: Bool
        public var sceneRunning: Bool
        public var idleSec: Double
        public var lowPower: Bool
        public var reduceMotion: Bool
        public var quiet: QuietHours
        public var userBlocked: Set<String>
        public var category: AppCategory
        /// nil — окно найдено и на нём есть место (`PerchLayout.spot`); иначе почему нет (`noWindow`, `noSpot`).
        public var spot: String?
        /// Сколько секунд работает Capri (после входа в систему приложения запускаются сами — это не действие человека).
        public var sinceStart: Double
        /// Сколько секунд назад кончилась любая другая сцена Capri (nil — не было).
        public var sinceScene: Double?
        /// Общий бюджет стола (`ScreenBudget.gate`, без тихих часов и звонка — они здесь свои): nil — можно.
        public var budget: String?

        public init(now: Double, dayStart: Double? = nil, minuteOfDay: Int = 12 * 60, enabled: Bool = true,
                    hiddenUntil: Double? = nil, paused: Bool = false, fullscreen: Bool = false, inCall: Bool = false,
                    displaysAsleep: Bool = false, notchOpen: Bool = false, sceneRunning: Bool = false, idleSec: Double = 0.5,
                    lowPower: Bool = false, reduceMotion: Bool = false, quiet: QuietHours = .standard,
                    userBlocked: Set<String> = [], category: AppCategory = .other, spot: String? = nil,
                    sinceStart: Double = 3600, sinceScene: Double? = nil, budget: String? = nil) {
            self.now = now; self.dayStart = dayStart ?? now - 3600; self.minuteOfDay = minuteOfDay; self.enabled = enabled
            self.hiddenUntil = hiddenUntil; self.paused = paused; self.fullscreen = fullscreen; self.inCall = inCall
            self.displaysAsleep = displaysAsleep; self.notchOpen = notchOpen; self.sceneRunning = sceneRunning
            self.idleSec = idleSec; self.lowPower = lowPower; self.reduceMotion = reduceMotion; self.quiet = quiet
            self.userBlocked = userBlocked; self.category = category; self.spot = spot
            self.sinceStart = sinceStart; self.sinceScene = sinceScene; self.budget = budget
        }
    }

    // Лимиты (с).
    public static let minGap = 10.0 * 60
    public static let perHour = 2
    public static let perDay = 4
    /// После любой другой сцены Capri (вайб, ответ, окно) — столько тишины.
    public static let afterScene = 5.0 * 60
    /// Первые минуты после запуска Capri (вход в систему: приложения стартуют сами).
    public static let warmup = 120.0
    /// Две «кыш» подряд → час без посадок на приложения.
    public static let tiredFor = 3600.0
    /// Никто не смотрит (событие от автозапуска).
    public static let awayIdle = 120.0
    /// Сколько помнить прошлые запуски приложения (для «не открывал три дня»).
    public static let memoryDays = 30.0
    /// Терминал: одно окно — не чаще раза в 15 мин, одна сессия — раза в час (лимиты посадок — общие).
    public static let windowCooldown = 15.0 * 60
    public static let sessionCooldown = 3600.0

    /// bundle → первый запуск за текущий «день» (только он может стать посадкой).
    public private(set) var launchedToday: [String: Double] = [:]
    /// bundle → прошлый запуск до сегодняшнего (повод реплики «не открывал N дней»).
    public private(set) var previousLaunch: [String: Double] = [:]
    /// Начала посадок (лимиты часа и дня).
    public private(set) var starts: [Double] = []
    /// «Кыш» подряд (сброс — посадка, досиженная до конца).
    public private(set) var shoos = 0
    public private(set) var tiredUntil: Double?
    public private(set) var lastDecision = ""
    /// Терминал: окно (номер) / сессия (ключ) → когда смотрела; «открытия», уже ставшие поводом (даже без показа).
    public private(set) var watchedWindows: [String: Double] = [:]
    public private(set) var watchedSessions: [String: Double] = [:]
    public private(set) var usedOpenings: [String: Double] = [:]

    public init() {}

    enum CodingKeys: String, CodingKey {
        case launchedToday, previousLaunch, starts, shoos, tiredUntil, lastDecision, watchedWindows, watchedSessions, usedOpenings
    }

    /// Состояние прошлых версий (без полей терминала) читается — иначе после обновления каждое приложение снова
    /// «первое за день».
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        launchedToday = try c.decodeIfPresent([String: Double].self, forKey: .launchedToday) ?? [:]
        previousLaunch = try c.decodeIfPresent([String: Double].self, forKey: .previousLaunch) ?? [:]
        starts = try c.decodeIfPresent([Double].self, forKey: .starts) ?? []
        shoos = try c.decodeIfPresent(Int.self, forKey: .shoos) ?? 0
        tiredUntil = try c.decodeIfPresent(Double.self, forKey: .tiredUntil)
        lastDecision = try c.decodeIfPresent(String.self, forKey: .lastDecision) ?? ""
        watchedWindows = try c.decodeIfPresent([String: Double].self, forKey: .watchedWindows) ?? [:]
        watchedSessions = try c.decodeIfPresent([String: Double].self, forKey: .watchedSessions) ?? [:]
        usedOpenings = try c.decodeIfPresent([String: Double].self, forKey: .usedOpenings) ?? [:]
    }

    /// Общие запреты (nil — можно). «Печатает» не мешает: человек только что сам переключился.
    public static func blocked(_ i: Input) -> String? {
        if !i.enabled { return "off" }
        if let h = i.hiddenUntil, h > i.now { return "hidden" }
        if i.paused { return "paused" }
        if i.quiet.contains(minuteOfDay: i.minuteOfDay) { return "quiet" }
        if i.fullscreen { return "fullscreen" }
        if i.inCall { return "call" }
        if i.displaysAsleep { return "asleep" }
        if i.notchOpen { return "notch" }
        if i.sceneRunning { return "running" }
        if i.lowPower { return "lowPower" }
        if i.reduceMotion { return "reduceMotion" }
        if i.idleSec > awayIdle { return "away" }
        if i.sinceStart < warmup { return "warmup" }
        if let a = i.sinceScene, a < afterScene { return "afterScene" }
        if let b = i.budget { return b }
        return nil
    }

    func limited(_ now: Double, dayStart: Double) -> String? {
        if let l = starts.last, now - l < Self.minGap { return "gap" }
        if starts.filter({ now - $0 < 3600 }).count >= Self.perHour { return "hourly" }
        if starts.filter({ $0 >= dayStart }).count >= Self.perDay { return "daily" }
        return nil
    }

    /// Решение. Любой запуск приложения (кроме «никогда»/игр/звонков) тратит «первый запуск за день» — даже если
    /// посадка не случилась (тихие часы, лимит): второй запуск того же приложения сегодня не повод. Не тратит только
    /// «окна ещё нет» (`noWindow`) — окно запущенного приложения может появиться чуть позже.
    public mutating func decide(_ e: Event, _ i: Input) -> Decision {
        let d = evaluate(e, i)
        if case .terminal(let window, let sessions, let opening, _) = e {
            lastDecision = "terminal \(window): \(d.log)"
            // «Открытие» тратится любым решением, кроме «пока не работает» (человек может сейчас дать задачу — тогда
            // это ещё повод) и «окна нет».
            if let o = opening, d != .skip("notWorking"), d != .skip("noWindow"), d != .skip("noSpot") { usedOpenings[o] = i.now }
            if d == .watch {
                starts.append(i.now)
                watchedWindows[String(window)] = i.now
                for k in sessions { watchedSessions[k] = i.now }
            }
            prune(i.now)
            return d
        }
        guard case .activated(let bundle, let launched) = e else { return d }
        lastDecision = "\(bundle): \(d.log)"
        if launched, d != .skip("noWindow"), AppCatalog.reason(bundle: bundle, category: i.category, userBlocked: []) == nil,
           isFirstToday(bundle, dayStart: i.dayStart) {
            if let prev = launchedToday[bundle], prev < i.dayStart { previousLaunch[bundle] = prev }
            launchedToday[bundle] = i.now
        }
        if case .perch = d {
            starts.append(i.now)
        }
        prune(i.now)
        return d
    }

    /// Всё, кроме места на окне, без записи (nil — можно искать окно). Показ сначала спрашивает это,
    /// и только потом читает список окон.
    public func gate(_ e: Event, _ i: Input) -> String? {
        if case .terminal(let window, let sessions, let opening, let working) = e {
            // Усталость («кыш» дважды) терминал не трогает — это ответ на его собственное действие.
            guard let opening else { return "notOpened" }
            if usedOpenings[opening] != nil { return "notOpened" }
            if !working { return "notWorking" }
            if let w = watchedWindows[String(window)], i.now - w < Self.windowCooldown { return "windowCooldown" }
            if sessions.contains(where: { k in watchedSessions[k].map { i.now - $0 < Self.sessionCooldown } ?? false }) {
                return "sessionCooldown"
            }
            if let why = Self.blocked(i) { return why }
            return limited(i.now, dayStart: i.dayStart)
        }
        guard case .activated(let bundle, let launched) = e else { return "event" }
        if let why = AppCatalog.reason(bundle: bundle, category: i.category, userBlocked: i.userBlocked) { return why }
        if !launched { return "notLaunched" }
        if !isFirstToday(bundle, dayStart: i.dayStart) { return "notFirst" }
        if let why = Self.blocked(i) { return why }
        if let t = tiredUntil, t > i.now { return "tired" }
        return limited(i.now, dayStart: i.dayStart)
    }

    private func evaluate(_ e: Event, _ i: Input) -> Decision {
        if case .terminal = e {
            if let why = gate(e, i) { return .skip(why) }
            if let why = i.spot { return .skip(why) }
            return .watch
        }
        if let why = gate(e, i) { return .skip(why) }
        if let why = i.spot { return .skip(why) }
        return .perch(i.category)
    }

    /// Сегодня (с 05:00) это приложение ещё не запускали.
    public func isFirstToday(_ bundle: String, dayStart: Double) -> Bool {
        launchedToday[bundle].map { $0 < dayStart } ?? true
    }

    /// Сколько полных дней приложение не запускали до сегодняшнего запуска (nil — не знаем).
    public func daysAway(_ bundle: String, now: Double) -> Int? {
        guard let prev = previousLaunch[bundle] else { return nil }
        return Int((now - prev) / 86400)
    }

    /// Посадок за последний час и сегодня (для отладки и `dump perch`).
    public func counts(now: Double, dayStart: Double) -> (hour: Int, day: Int) {
        (starts.filter { now - $0 < 3600 }.count, starts.filter { $0 >= dayStart }.count)
    }

    private mutating func prune(_ now: Double) {
        starts = starts.filter { now - $0 < 26 * 3600 }
        let keep = Self.memoryDays * 86400
        launchedToday = launchedToday.filter { now - $0.value < keep }
        previousLaunch = previousLaunch.filter { now - $0.value < keep }
        watchedWindows = watchedWindows.filter { now - $0.value < 2 * 3600 }
        watchedSessions = watchedSessions.filter { now - $0.value < 2 * 3600 }
        usedOpenings = usedOpenings.filter { now - $0.value < 2 * 3600 }
    }

    /// Прогнали кликом по глазам. Вторая «кыш» подряд — час без посадок на приложения.
    public mutating func shooed(at now: Double) {
        shoos += 1
        if shoos >= 2 {
            tiredUntil = now + Self.tiredFor
            shoos = 0
        }
    }

    /// Посадка досижена до конца (не прогнали) — счёт «кыш» с нуля.
    public mutating func sat() { shoos = 0 }

    /// Начало «дня» лимита: последние 05:00 по местному времени.
    public static func dayStart(now: Double, calendar: Calendar = .current) -> Double {
        let d = Date(timeIntervalSince1970: now)
        var c = calendar.dateComponents([.year, .month, .day], from: d)
        c.hour = 5
        guard let five = calendar.date(from: c) else { return now - 86400 }
        if five.timeIntervalSince1970 <= now { return five.timeIntervalSince1970 }
        // Вчерашние 05:00 — календарём, не «минус 86400»: в день перевода часов сутки не 24 часа.
        return calendar.date(byAdding: .day, value: -1, to: five)?.timeIntervalSince1970 ?? five.timeIntervalSince1970 - 86400
    }
}
