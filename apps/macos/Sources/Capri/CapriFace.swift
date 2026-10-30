import SwiftUI
import AppKit

/// Настроение Capri — какой кадр и какое движение показывать.
enum CapriMood: Equatable {
    /// Ничего не происходит: моргает, дышит.
    case idle
    /// Поле ввода в фокусе.
    case listening
    /// Ждём ответ Codex.
    case thinking
    /// Идёт ответ: рот по слогам.
    case speaking
    /// Кто-то ждёт тебя.
    case alert
    /// Ошибка: глитч.
    case error
}

/// Вид Capri. `.bust` — голова и плечи (помощник, чат), `.mask` — только маска с глазами (свёрнутый notch).
/// Кадры — арт, сгенерированный Codex по рефам (`CapriArt`). `active` — анимировать (виден и нужен).
struct CapriFace: View {
    enum Style { case bust, mask }
    var mood: CapriMood
    var style: Style = .bust
    var active = true

    static let fps = 12.0

    var body: some View {
        switch style {
        case .bust: CapriSprite(mood: mood, active: active)
        case .mask: CapriMaskSprite(mood: mood, active: active)
        }
    }
}

/// Мини-маска в свёрнутом notch: перерисовка только в кадры моргания (`EyesSchedule`), «тебя ждут» — свой кадр.
struct CapriMaskSprite: View {
    var mood: CapriMood
    var active = true
    private var still: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    var body: some View {
        TimelineView(EyesSchedule(paused: !active || still || mood == .alert)) { ctx in
            let frame: CapriArt.Frame = mood == .alert ? .maskAlert
                : (!still && (EyesSchedule.blink(at: ctx.date) ?? 0) > 0.5 ? .maskBlink : .mask)
            if let im = CapriArt.images[frame] {
                Image(nsImage: im).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            }
        }
        .accessibilityLabel(Text("Capri"))
    }
}

/// Расписание перерисовки мини-маски: кадры моргания (раз в `blinkCycle` с). Между ними кадр не перерисовывается —
/// свёрнутый notch не тратит CPU. Даты строго растут.
struct EyesSchedule: TimelineSchedule {
    static let blinkCycle = 4.3
    static let frame = 1.0 / CapriFace.fps
    var paused: Bool

    /// Моргание в момент `date`: полузакрыт, закрыт, полузакрыт (по рисунку), иначе nil.
    static func blink(at date: Date) -> Double? {
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: blinkCycle)
        switch Int(phase / frame) { case 0, 2: return 0.55; case 1: return 1; default: return nil }
    }

    func entries(from start: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var queue: [Date] = [start]
        var last = start
        var cycle = (start.timeIntervalSinceReferenceDate / Self.blinkCycle).rounded(.up)
        var k = 0
        return AnyIterator {
            if !queue.isEmpty {
                last = queue.removeFirst()
                return last
            }
            guard !paused else { return nil }
            // Моргание: три рисунка и рисунок «открыто», затем следующий цикл.
            while true {
                let date = Date(timeIntervalSinceReferenceDate: cycle * Self.blinkCycle + Double(k) * Self.frame + 0.001)
                k += 1
                if k > 3 { k = 0; cycle += 1 }
                if date > last { last = date; return date }
            }
        }
    }
}
