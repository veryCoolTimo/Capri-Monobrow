import SwiftUI
import AppKit

/// Capri — своя стилизация (не копия чужого арта): тёмный угловатый визор в малиновой рамке, рваные
/// «осколки» сверху и два скошенных светящихся глаза. В свёрнутом notch живут только глаза.
enum CapriMood: Equatable {
    /// Ничего не происходит: моргает, медленно смотрит по сторонам.
    case idle
    /// Поле ввода в фокусе: глаза шире, смотрят на поле.
    case listening
    /// Ждём ответ Codex: глаза сужены, бегают.
    case thinking
    /// Идёт ответ: глаза-дуги, «рот» шевелится.
    case speaking
    /// Кто-то ждёт тебя: кислотно-зелёные глаза, взгляд вверх к вырезу, подскок.
    case alert
    /// Ошибка: малиновые «x», короткий glitch.
    case error
}

/// Параметры лица в момент времени; между настроениями — плавная интерполяция.
private struct FaceParams {
    var open: Double = 1          // высота глаз (0 — закрыты)
    var lookX: Double = 0         // −1…1
    var lookY: Double = 0         // −1 (вверх)…1
    var r = 0.98, g = 0.22, b = 0.42   // цвет глаз
    var happy: Double = 0         // 1 — глаза-дуги
    var mouth: Double = 0         // 0…1 — ширина «рта»
    var bounce: Double = 0        // смещение головы вверх, 0…1
    var cross: Double = 0         // 1 — глаза «x»
    var jitter: Double = 0        // glitch-сдвиг по x
    var alertMark: Double = 0     // ▲ над головой

    static func lerp(_ a: FaceParams, _ b: FaceParams, _ t: Double) -> FaceParams {
        func m(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
        var o = FaceParams()
        o.open = m(a.open, b.open); o.lookX = m(a.lookX, b.lookX); o.lookY = m(a.lookY, b.lookY)
        o.r = m(a.r, b.r); o.g = m(a.g, b.g); o.b = m(a.b, b.b)
        o.happy = m(a.happy, b.happy); o.mouth = m(a.mouth, b.mouth); o.bounce = m(a.bounce, b.bounce)
        o.cross = m(a.cross, b.cross); o.jitter = m(a.jitter, b.jitter); o.alertMark = m(a.alertMark, b.alertMark)
        return o
    }

    /// `still` — «Уменьшить движение»: без дрейфа, подскоков и моргания.
    /// `blinkCycle` — общий период моргания (у мини-глаз он должен совпадать с расписанием перерисовки).
    static func at(_ mood: CapriMood, _ t: Double, still: Bool, blinkCycle: Double? = nil) -> FaceParams {
        var p = FaceParams()
        let tt = still ? 0 : t
        // Моргание раз в ~4.3 с (у «думает» и «отвечает» реже).
        func blink(_ ownCycle: Double) -> Double {
            guard !still else { return 1 }
            let cycle = blinkCycle ?? ownCycle
            let phase = tt.truncatingRemainder(dividingBy: cycle)
            return phase < 0.16 ? 1 - sin(.pi * phase / 0.16) : 1
        }
        switch mood {
        case .idle:
            p.open = blink(4.3)
            p.lookX = sin(tt * 0.45) * 0.6 + sin(tt * 0.17) * 0.4
            p.lookY = sin(tt * 0.3) * 0.15
        case .listening:
            p.open = 1.18 * blink(5.1)
            p.lookX = 0.55; p.lookY = 0.45
            p.mouth = 0.25
        case .thinking:
            p.open = 0.5
            p.lookX = sin(tt * 4.2); p.lookY = -0.35
            p.r = 0.68; p.g = 0.6; p.b = 1.0
        case .speaking:
            p.happy = 1
            p.mouth = 0.25 + abs(sin(tt * 9)) * 0.75
        case .alert:
            p.open = 1.25 * blink(3.1)
            p.lookY = -1
            p.r = 0.24; p.g = 0.96; p.b = 0.54
            let phase = tt.truncatingRemainder(dividingBy: 2.2)
            p.bounce = phase < 0.45 ? sin(.pi * phase / 0.45) : 0
            p.alertMark = 1
        case .error:
            p.cross = 1
            p.r = 0.91; p.g = 0.09; p.b = 0.25
            let phase = tt.truncatingRemainder(dividingBy: 1.7)
            p.jitter = still ? 0 : (phase < 0.12 ? (phase < 0.06 ? -1 : 1) : 0)
        }
        return p
    }
}

/// Лицо Capri. `active` — анимировать (виден и нужен); иначе статичный кадр, без нагрузки на CPU.
struct CapriFace: View {
    enum Style { case head, eyes }
    var mood: CapriMood
    var style: Style = .head
    var active = true

    @State private var fromMood: CapriMood = .idle
    @State private var shownMood: CapriMood = .idle
    @State private var changedAt = Date.distantPast

    private static let transition = 0.32
    private var still: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    var body: some View {
        Group {
            if style == .eyes {
                // В свёрнутом notch: перерисовка только в кадры моргания и после смены настроения.
                TimelineView(EyesSchedule(changedAt: changedAt, transition: Self.transition, paused: !active || still)) { ctx in
                    canvas(ctx.date)
                }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active || still)) { ctx in canvas(ctx.date) }
            }
        }
        .onAppear { shownMood = mood; fromMood = mood }
        .onChange(of: mood) { m in
            fromMood = shownMood
            shownMood = m
            changedAt = Date()
        }
        .accessibilityLabel(Text("Capri"))
    }

    private func params(_ date: Date) -> FaceParams {
        let t = date.timeIntervalSinceReferenceDate
        let cycle = style == .eyes ? EyesSchedule.blinkCycle : nil
        let target = FaceParams.at(shownMood, t, still: still, blinkCycle: cycle)
        let k = min(1, max(0, date.timeIntervalSince(changedAt) / Self.transition))
        guard k < 1, !still else { return target }
        let eased = k * k * (3 - 2 * k)
        return FaceParams.lerp(FaceParams.at(fromMood, t, still: still, blinkCycle: cycle), target, eased)
    }

    private func canvas(_ date: Date) -> some View {
        let p = params(date)
        return Canvas { ctx, size in
            if style == .eyes { Self.drawEyes(&ctx, in: CGRect(origin: .zero, size: size), p) }
            else { Self.drawHead(&ctx, size: size, p) }
        }
    }

    // MARK: рисование

    private static func color(_ p: FaceParams) -> Color { Color(red: p.r, green: p.g, blue: p.b) }

    private static func drawHead(_ ctx: inout GraphicsContext, size: CGSize, _ p: FaceParams) {
        let w = size.width, h = size.height
        let dy = -p.bounce * h * 0.05
        func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * w + p.jitter * w * 0.02, y: y * h + dy) }

        // ▲ «кто-то ждёт» над головой.
        if p.alertMark > 0.01 {
            var tri = Path()
            tri.addLines([pt(0.5, 0.0), pt(0.56, 0.1), pt(0.44, 0.1)])
            tri.closeSubpath()
            ctx.fill(tri, with: .color(Palette.acid.opacity(p.alertMark)))
        }
        // Осколки сверху.
        var shards = Path()
        shards.addLines([pt(0.1, 0.36), pt(0.16, 0.12), pt(0.27, 0.27), pt(0.38, 0.08), pt(0.5, 0.24),
                         pt(0.63, 0.06), pt(0.7, 0.25), pt(0.84, 0.13), pt(0.9, 0.36)])
        shards.closeSubpath()
        ctx.fill(shards, with: .color(Palette.crimson))
        ctx.stroke(shards, with: .color(Palette.violet), lineWidth: 1.2)

        // Визор со срезанными углами.
        let visor = CGRect(x: 0.05 * w + p.jitter * w * 0.02, y: 0.28 * h + dy, width: 0.9 * w, height: 0.66 * h)
        let cut = min(visor.width, visor.height) * 0.16
        var v = Path()
        v.move(to: CGPoint(x: visor.minX, y: visor.minY))
        v.addLine(to: CGPoint(x: visor.maxX - cut, y: visor.minY))
        v.addLine(to: CGPoint(x: visor.maxX, y: visor.minY + cut))
        v.addLine(to: CGPoint(x: visor.maxX, y: visor.maxY))
        v.addLine(to: CGPoint(x: visor.minX + cut, y: visor.maxY))
        v.addLine(to: CGPoint(x: visor.minX, y: visor.maxY - cut))
        v.closeSubpath()
        ctx.fill(v, with: .color(Color(red: 0.05, green: 0.04, blue: 0.06)))
        // Строки развёртки внутри визора.
        var scan = Path()
        var y = visor.minY + 3
        while y < visor.maxY - 2 { scan.addRect(CGRect(x: visor.minX + 2, y: y, width: visor.width - 4, height: 0.6)); y += 3 }
        ctx.fill(scan, with: .color(Color.white.opacity(0.035)))
        ctx.stroke(v, with: .color(Palette.crimson.opacity(0.85)), lineWidth: 1.5)

        let eyes = CGRect(x: visor.minX + visor.width * 0.12, y: visor.minY + visor.height * 0.2,
                          width: visor.width * 0.76, height: visor.height * 0.44)
        drawEyes(&ctx, in: eyes, p)

        // «Рот» — короткая черта, шевелится, пока Capri говорит.
        if p.mouth > 0.01 {
            let mw = visor.width * (0.06 + 0.12 * p.mouth)
            let mh = max(1.5, visor.height * 0.035 * (0.6 + p.mouth))
            let mouth = CGRect(x: visor.midX - mw / 2, y: visor.minY + visor.height * 0.76, width: mw, height: mh)
            ctx.fill(Path(mouth), with: .color(color(p).opacity(0.8)))
        }
    }

    /// Два скошенных глаза в прямоугольнике `r` (у мини-версии в notch это весь холст).
    private static func drawEyes(_ ctx: inout GraphicsContext, in r: CGRect, _ p: FaceParams) {
        let c = color(p)
        let ew = r.width * 0.36
        let eh = r.height * 0.62
        let shiftX = p.lookX * r.width * 0.06 + p.jitter * r.width * 0.04
        let shiftY = p.lookY * r.height * 0.12
        var glow = ctx
        glow.addFilter(.shadow(color: c.opacity(0.75), radius: max(1.5, r.height * 0.12)))
        for side in [-1.0, 1.0] {
            let cx = r.midX + side * r.width * 0.25 + shiftX
            let cy = r.midY + shiftY
            if p.cross > 0.5 {
                var x = Path()
                let s = min(ew, eh) * 0.42
                x.move(to: CGPoint(x: cx - s, y: cy - s)); x.addLine(to: CGPoint(x: cx + s, y: cy + s))
                x.move(to: CGPoint(x: cx + s, y: cy - s)); x.addLine(to: CGPoint(x: cx - s, y: cy + s))
                glow.stroke(x, with: .color(c), style: StrokeStyle(lineWidth: max(1.5, eh * 0.2), lineCap: .square))
                continue
            }
            if p.happy > 0.5 {
                // Глаза-дуги «^ ^».
                var arc = Path()
                arc.move(to: CGPoint(x: cx - ew / 2, y: cy + eh * 0.2))
                arc.addLine(to: CGPoint(x: cx, y: cy - eh * 0.3))
                arc.addLine(to: CGPoint(x: cx + ew / 2, y: cy + eh * 0.2))
                glow.stroke(arc, with: .color(c), style: StrokeStyle(lineWidth: max(1.5, eh * 0.24), lineCap: .square, lineJoin: .miter))
                continue
            }
            // Скошенный четырёхугольник: внутренний верхний угол ниже внешнего — прищур, низ срезан к внешнему краю.
            let hh = max(0.6, eh * min(1.4, p.open)) / 2
            let lift = min(hh, eh * 0.16)
            let outer = cx + side * ew / 2, inner = cx - side * ew / 2
            var eye = Path()
            eye.addLines([
                CGPoint(x: inner, y: cy - hh + lift),
                CGPoint(x: outer, y: cy - hh - lift),
                CGPoint(x: outer - side * ew * 0.14, y: cy + hh - lift * 0.4),
                CGPoint(x: inner, y: cy + hh + lift * 0.4)
            ])
            eye.closeSubpath()
            glow.fill(eye, with: .color(c))
            // Блик.
            if p.open > 0.4 {
                let hl = CGRect(x: cx - ew * 0.18, y: cy - hh * 0.55, width: ew * 0.14, height: max(1, hh * 0.45))
                ctx.fill(Path(hl), with: .color(Color.white.opacity(0.85)))
            }
        }
    }
}

/// Расписание перерисовки мини-глаз: кадры перехода после смены настроения и кадры моргания (раз в
/// `blinkCycle` с). Между ними Canvas не перерисовывается — свёрнутый notch не тратит CPU. Даты строго растут.
struct EyesSchedule: TimelineSchedule {
    static let blinkCycle = 4.3
    static let frame = 1.0 / 30
    var changedAt: Date
    var transition: Double
    var paused: Bool

    func entries(from start: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var queue: [Date] = [start]
        if !paused {
            // Кадры перехода настроения, которые ещё впереди.
            var t = changedAt
            while t.timeIntervalSince(changedAt) <= transition + Self.frame {
                if t > start { queue.append(t) }
                t += Self.frame
            }
        }
        var last = start
        var cycle = (start.timeIntervalSinceReferenceDate / Self.blinkCycle).rounded(.up)
        var k = 0
        return AnyIterator {
            if !queue.isEmpty {
                last = queue.removeFirst()
                return last
            }
            guard !paused else { return nil }
            // Моргание: 7 кадров по 1/30 с и кадр «открыто» через 0.25 с, затем следующий цикл.
            while true {
                let date = Date(timeIntervalSinceReferenceDate: cycle * Self.blinkCycle + (k < 7 ? Double(k) * Self.frame : 0.25))
                k += 1
                if k > 7 { k = 0; cycle += 1 }
                if date > last { last = date; return date }
            }
        }
    }
}
