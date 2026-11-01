import Foundation

/// Тихие часы: с `start` до `end` (минуты от полуночи), можно через полночь; `start == end` — нет тихих часов.
public struct QuietHours: Equatable, Codable {
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = ((start % 1440) + 1440) % 1440
        self.end = ((end % 1440) + 1440) % 1440
    }

    /// По умолчанию 00:30–09:00 (решение Тимофея).
    public static let standard = QuietHours(start: 30, end: 9 * 60)

    public func contains(minuteOfDay m: Int) -> Bool {
        let m = ((m % 1440) + 1440) % 1440
        if start == end { return false }
        return start < end ? (m >= start && m < end) : (m >= start || m < end)
    }

    /// «00:30–09:00».
    public var label: String { "\(Self.clock(start))–\(Self.clock(end))" }

    public static func clock(_ m: Int) -> String { String(format: "%02d:%02d", m / 60, m % 60) }
}
