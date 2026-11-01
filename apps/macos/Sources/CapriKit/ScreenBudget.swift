import Foundation

/// Один общий бюджет появлений Capri на рабочем столе — для всех путей сразу: сессия доработала, музыка, ответ сессии,
/// «думает»/ответ помощника, окно музыки, посадка на окно, «смотрит в терминал». Отзыв Тимофея 2026-11-01
/// («слишком часто на экран попадает»): у каждого пути были свои лимиты, и никто не считал чужие появления.
/// Теперь каждый путь сначала спрашивает `gate`, а при показе пишет `record`; конец любой сцены — `ended`.
/// Чистая логика: время — входом.
public struct ScreenBudget: Equatable, Codable {
    /// Между началами любых двух появлений на столе.
    public static let minGap = 10.0 * 60
    public static let perHour = 2
    public static let perDay = 6
    /// После конца любой сцены на столе — столько тишины.
    public static let afterScene = 5.0 * 60

    /// Начала появлений (последние сутки с запасом).
    public private(set) var starts: [Double] = []
    /// Когда кончилась последняя сцена на столе.
    public private(set) var lastEnd: Double?

    public init() {}

    /// Что запрещает стол целиком, без счёта: главный выключатель «Capri на рабочем столе», тихие часы, звонок.
    public struct Conditions: Equatable {
        public var now: Double
        public var minuteOfDay: Int
        /// «Capri выходит на рабочий стол» (`capri.desktop`).
        public var desktop: Bool
        public var quiet: QuietHours
        public var inCall: Bool
        public init(now: Double, minuteOfDay: Int = 12 * 60, desktop: Bool = true, quiet: QuietHours = .standard, inCall: Bool = false) {
            self.now = now; self.minuteOfDay = minuteOfDay; self.desktop = desktop; self.quiet = quiet; self.inCall = inCall
        }
    }

    /// Тихие причины (nil — можно): `desktopOff`, `quiet`, `call`.
    public static func blocked(_ c: Conditions) -> String? {
        if !c.desktop { return "desktopOff" }
        if c.quiet.contains(minuteOfDay: c.minuteOfDay) { return "quiet" }
        if c.inCall { return "call" }
        return nil
    }

    /// Счёт (nil — можно): `budgetGap`, `budgetHourly`, `budgetDaily`, `budgetAfterScene`.
    public func limited(now: Double, dayStart: Double) -> String? {
        if let l = starts.last, now - l < Self.minGap { return "budgetGap" }
        if starts.filter({ now - $0 < 3600 }).count >= Self.perHour { return "budgetHourly" }
        if starts.filter({ $0 >= dayStart }).count >= Self.perDay { return "budgetDaily" }
        if let e = lastEnd, now - e < Self.afterScene { return "budgetAfterScene" }
        return nil
    }

    /// Всё вместе: сначала тихие причины, потом счёт.
    public func gate(_ c: Conditions, dayStart: Double) -> String? {
        Self.blocked(c) ?? limited(now: c.now, dayStart: dayStart)
    }

    /// Тихая причина (не счёт): музыка тогда молчит и в notch.
    public static func isQuiet(_ reason: String?) -> Bool { reason == "quiet" || reason == "call" }

    /// Сцена на столе началась.
    public mutating func record(_ now: Double) {
        starts.append(now)
        starts = starts.filter { now - $0 < 26 * 3600 }
    }

    /// Сцена на столе кончилась (любым путём).
    public mutating func ended(_ now: Double) { lastEnd = now }

    /// Сколько появлений за последний час и с начала дня (для `dump`).
    public func counts(now: Double, dayStart: Double) -> (hour: Int, day: Int) {
        (starts.filter { now - $0 < 3600 }.count, starts.filter { $0 >= dayStart }.count)
    }
}
