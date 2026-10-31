import Foundation

/// Когда персонажу можно выйти на стол. Чистая логика: время, настройки и состояние машины приходят входом,
/// случайность — из `TickNoise` по зерну (тесты детерминированы). Демо из меню и `scene …` идут мимо директора.
public struct CharacterDirector: Equatable {
    public enum Event: String, CaseIterable, Codable {
        /// Сессия доработала (`running → idle`).
        case sessionFinished
        /// Фоновый таймер.
        case ambient
        /// Первое воспроизведение музыки после долгой тишины — вайб на столе.
        case musicStarted
        /// Старт или смена трека — вайб в notch.
        case trackChanged
    }

    public enum Rate: String, CaseIterable, Codable {
        case rare, sometimes

        /// Интервал фоновых сцен (с).
        public var ambient: ClosedRange<Double> {
            switch self {
            case .rare: 45 * 60...90 * 60
            case .sometimes: 30 * 60...60 * 60
            }
        }
    }

    public enum Decision: Equatable {
        /// Сцена на столе.
        case play(SceneKind)
        /// Кивание в notch (без стола).
        case notchVibe
        case skip(String)

        public var log: String {
            switch self {
            case .play(let k): "play \(k.rawValue)"
            case .notchVibe: "play notch-vibe"
            case .skip(let why): "skip \(why)"
            }
        }
    }

    /// Состояние машины и настройки на момент решения.
    public struct Input: Equatable {
        public var now: Double
        /// «Персонаж на рабочем столе».
        public var enabled: Bool
        public var hiddenUntil: Double?
        /// «Сцены по событиям сессий».
        public var sessionEvents: Bool
        /// «Изображать захват экрана».
        public var takeover: Bool
        /// «Реагировать на музыку».
        public var music: Bool
        public var rate: Rate
        /// Пауза уведомлений Capri.
        public var paused: Bool
        public var fullscreen: Bool
        /// Экраны спят или экран заблокирован.
        public var displaysAsleep: Bool
        /// Notch раскрыт или в peek.
        public var notchOpen: Bool
        public var sceneRunning: Bool
        /// Секунд без ввода (HIDIdleTime).
        public var idleSec: Double
        public var lowPower: Bool
        public var reduceMotion: Bool

        public init(now: Double, enabled: Bool = true, hiddenUntil: Double? = nil, sessionEvents: Bool = true,
                    takeover: Bool = false, music: Bool = true, rate: Rate = .sometimes, paused: Bool = false,
                    fullscreen: Bool = false, displaysAsleep: Bool = false, notchOpen: Bool = false,
                    sceneRunning: Bool = false, idleSec: Double = 10, lowPower: Bool = false, reduceMotion: Bool = false) {
            self.now = now; self.enabled = enabled; self.hiddenUntil = hiddenUntil; self.sessionEvents = sessionEvents
            self.takeover = takeover; self.music = music; self.rate = rate; self.paused = paused
            self.fullscreen = fullscreen; self.displaysAsleep = displaysAsleep; self.notchOpen = notchOpen
            self.sceneRunning = sceneRunning; self.idleSec = idleSec; self.lowPower = lowPower; self.reduceMotion = reduceMotion
        }
    }

    // Лимиты (с).
    public static let minGap = 20.0 * 60
    public static let perHour = 4
    public static let sessionCooldown = 10.0 * 60
    public static let musicCooldown = 30.0 * 60
    public static let notchVibeCooldown = 3.0 * 60
    public static let takeoverGap = 2.0 * 3600
    /// «Человек прямо сейчас печатает / двигает мышь» и «никто не смотрит».
    public static let busyIdle = 3.0
    public static let awayIdle = 120.0

    /// Начала сцен на столе (для лимитов).
    public private(set) var starts: [Double] = []
    public private(set) var last: [Event: Double] = [:]
    public private(set) var lastTakeover: Double?
    public private(set) var lastNotchVibe: Double?
    /// Когда следующая фоновая сцена.
    public private(set) var nextAmbient: Double
    /// Последнее решение — для `dump`.
    public private(set) var lastDecision: String = ""
    public var seed: Int
    private var draws = 0

    public init(now: Double, seed: Int = 0, rate: Rate = .sometimes) {
        self.seed = seed
        nextAmbient = 0
        nextAmbient = now + Self.interval(rate, seed: seed, n: 0)
    }

    /// Интервал до фоновой сцены — равномерно в диапазоне частоты, по зерну.
    public static func interval(_ rate: Rate, seed: Int, n: Int) -> Double {
        let r = rate.ambient
        return r.lowerBound + (r.upperBound - r.lowerBound) * TickNoise.unit(n, 600 + seed)
    }

    /// Фоновая сцена по времени.
    public func ambientDue(_ now: Double) -> Bool { now >= nextAmbient }

    /// Общие запреты для сцен на столе; nil — можно.
    public static func blocked(_ i: Input) -> String? {
        if !i.enabled { return "off" }
        if let h = i.hiddenUntil, h > i.now { return "hidden" }
        if i.paused { return "paused" }
        if i.fullscreen { return "fullscreen" }
        if i.displaysAsleep { return "asleep" }
        if i.notchOpen { return "notch" }
        if i.sceneRunning { return "running" }
        if i.lowPower { return "lowPower" }
        if i.reduceMotion { return "reduceMotion" }
        if i.idleSec < busyIdle { return "busy" }
        if i.idleSec > awayIdle { return "away" }
        return nil
    }

    /// Лимиты частоты: не чаще раза в 20 мин и 4 раз в час.
    func limited(_ now: Double) -> String? {
        if let l = starts.last, now - l < Self.minGap { return "gap" }
        if starts.filter({ now - $0 < 3600 }).count >= Self.perHour { return "hourly" }
        return nil
    }

    /// Решение по событию. `.play` записывает запуск (лимиты, кулдауны, следующий фоновый).
    public mutating func decide(_ event: Event, _ i: Input) -> Decision {
        let d = evaluate(event, i)
        lastDecision = "\(event.rawValue): \(d.log)"
        switch d {
        case .play(let kind):
            starts.append(i.now)
            starts = starts.filter { i.now - $0 < 3600 }
            last[event] = i.now
            if kind == .takeover { lastTakeover = i.now }
            if event == .ambient { scheduleAmbient(i.now, rate: i.rate) }
        case .notchVibe:
            lastNotchVibe = i.now
            last[event] = i.now
        case .skip(let why):
            // Фоновую сцену, которую нельзя показать по «вечным» причинам, переносим, чтобы не стучать каждую минуту.
            if event == .ambient, ["off", "hidden", "fullscreen", "asleep", "away", "lowPower", "reduceMotion", "paused"].contains(why) {
                scheduleAmbient(i.now, rate: i.rate, short: true)
            }
        }
        return d
    }

    private func evaluate(_ event: Event, _ i: Input) -> Decision {
        if event == .trackChanged {
            // Кивание в notch: мимо общих лимитов, но со своим кулдауном; персонаж может быть выключен.
            guard i.music else { return .skip("musicOff") }
            if let h = i.hiddenUntil, h > i.now { return .skip("hidden") }
            if i.reduceMotion { return .skip("reduceMotion") }
            // Пауза уведомлений, полноэкранное приложение, спящие экраны — тоже тишина.
            if i.paused { return .skip("paused") }
            if i.fullscreen { return .skip("fullscreen") }
            if i.displaysAsleep { return .skip("asleep") }
            if let l = lastNotchVibe, i.now - l < Self.notchVibeCooldown { return .skip("cooldown") }
            return .notchVibe
        }
        if event == .musicStarted, !i.music { return .skip("musicOff") }
        if event == .sessionFinished, !i.sessionEvents { return .skip("sessionEventsOff") }
        if let why = Self.blocked(i) { return .skip(why) }
        switch event {
        case .sessionFinished:
            if let l = last[.sessionFinished], i.now - l < Self.sessionCooldown { return .skip("cooldown") }
        case .musicStarted:
            if let l = last[.musicStarted], i.now - l < Self.musicCooldown { return .skip("cooldown") }
        case .ambient:
            guard ambientDue(i.now) else { return .skip("notDue") }
        case .trackChanged: break
        }
        if let why = limited(i.now) { return .skip(why) }
        switch event {
        case .sessionFinished: return .play(.teleport)
        case .musicStarted: return .play(.vibe)
        case .ambient: return .play(pickAmbient(i))
        case .trackChanged: return .notchVibe
        }
    }

    /// Фон: захват (если включён и прошло ≥ 2 ч) с вероятностью 1/4, иначе телепорт 70% / окно 30%.
    func pickAmbient(_ i: Input) -> SceneKind {
        let n = starts.count + Int(i.now / 60)
        if i.takeover, lastTakeover.map({ i.now - $0 >= Self.takeoverGap }) ?? true, TickNoise.unit(n, 700 + seed) < 0.25 {
            return .takeover
        }
        return TickNoise.unit(n, 701 + seed) < 0.7 ? .teleport : .window
    }

    /// Следующая фоновая сцена: через интервал частоты (или через 10 мин, если сейчас нельзя по долгой причине).
    public mutating func scheduleAmbient(_ now: Double, rate: Rate, short: Bool = false) {
        draws += 1
        nextAmbient = now + (short ? 10 * 60 : Self.interval(rate, seed: seed, n: draws))
    }
}

/// Переходы сессий, на которые реагирует персонаж (по парам ключ → статус; редьюсер не трогаем).
public enum SceneTriggers {
    /// Сессии, которые только что доработали: были `running`, стали `idle`. Новые и исчезнувшие — нет.
    public static func finished(prev: [SessionKey: SessionStatus], next: [SessionKey: SessionStatus]) -> [SessionKey] {
        next.compactMap { key, status in
            status == .idle && prev[key] == .running ? key : nil
        }.sorted { $0.description < $1.description }
    }

    /// Кто-то начал ждать ответа — идущая сцена обрывается.
    public static func needsInputAppeared(prev: [SessionKey: SessionStatus], next: [SessionKey: SessionStatus]) -> Bool {
        next.contains { key, status in status == .needsInput && prev[key] != .needsInput }
    }
}
