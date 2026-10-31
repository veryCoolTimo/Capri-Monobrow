import SwiftUI
import CapriKit

/// Содержимое окон сцен (`sessions`, `thinking`, `answer`) и подпись `reply` — рисунок в Canvas сцены, по
/// прямоугольникам `SceneTimeline` (те же, что у горячих точек: куда нарисовано, туда и кликают).
/// Кликов здесь нет — их ловит `StageHitView` по `SceneLayout.hotspots`.
struct StageWindows {
    var run: SceneRun
    var window: SceneWindow
    /// Глобальные координаты AppKit → координаты панели.
    var local: (CGRect) -> CGRect
    var localPoint: (CGPoint) -> CGPoint
    /// Стена (для мигания).
    var t: Double

    static func title(_ kind: SceneKind) -> String {
        switch kind {
        case .sessions: "CAPRI//SESSIONS"
        case .thinking: "CAPRI//THINK"
        case .answer: "CAPRI//ANSWER"
        case .music: "CAPRI//MUSIC"
        default: "CAPRI//SYS"
        }
    }

    private var pink: Color { CapriFX.hackPink }

    func draw(_ c: GraphicsContext) {
        switch run.kind {
        case .sessions: drawSessions(c)
        case .thinking: drawThinking(c)
        case .answer: drawAnswer(c)
        case .music: drawMusic(c)
        case .window: drawStatus(c)
        default: break
        }
    }

    // MARK: лицо: полоса подписи и сканлайн

    /// Лицо окна (координаты панели).
    private var face: CGRect { local(SceneTimeline.faceIn(run.kind, window: window.rect)) }

    /// Тёмный градиент внизу лица высотой `h` (прозрачный → чёрный 0,85) — под подпись.
    static func drawBand(_ face: CGRect, height h: CGFloat, _ c: GraphicsContext) {
        let fade = h * SceneTimeline.bandFade
        let band = CGRect(x: face.minX, y: face.maxY - fade, width: face.width, height: fade)
        c.fill(Path(band), with: .linearGradient(Gradient(stops: [.init(color: .black.opacity(0), location: 0),
                                                                  .init(color: .black.opacity(0.6), location: 0.4),
                                                                  .init(color: .black.opacity(0.88), location: 1)]),
                                                 startPoint: CGPoint(x: band.midX, y: band.minY), endPoint: CGPoint(x: band.midX, y: band.maxY)))
    }

    /// Текст цвета `color` с тенью 1 pt (читается на лице).
    static func shadowed(_ text: Text, _ color: Color, at p: CGPoint, anchor: UnitPoint, _ c: GraphicsContext) {
        c.draw(text.foregroundColor(.black), at: CGPoint(x: p.x + 1, y: p.y + 1), anchor: anchor)
        c.draw(text.foregroundColor(color), at: p, anchor: anchor)
    }

    /// Сканлайн-вайп по лицу сверху вниз со шлейфом.
    private func drawScan(_ scan: CGFloat, _ c: GraphicsContext) {
        let body = face
        let y = body.minY + body.height * scan
        for k in 0..<6 {
            c.fill(Path(CGRect(x: body.minX, y: y - CGFloat(k) * 3, width: body.width, height: 1)),
                   with: .color(pink.opacity(0.6 - Double(k) * 0.09)))
        }
    }

    // MARK: статус

    private func drawStatus(_ c: GraphicsContext) {
        Self.drawBand(face, height: SceneTimeline.faceBand(.window), c)
        let sr = local(SceneTimeline.statusRect(window.rect))
        if run.hover == .button("status") {
            c.fill(Path(sr), with: .color(pink.opacity(0.18)))
            c.fill(Path(CGRect(x: sr.minX, y: sr.minY, width: 2, height: sr.height)), with: .color(Palette.acid))
        }
        let text = String(run.content.status.prefix(window.typed))
        let caret = window.typed < run.content.status.count || window.caret ? "▮" : " "
        let line = Text("> " + Self.clip(text, 38) + caret).font(.mono(11, .semibold))
        let at = CGPoint(x: sr.minX + 11, y: sr.midY)
        Self.shadowed(line, Palette.text, at: at, anchor: .leading, c)
    }

    // MARK: музыка

    private func drawMusic(_ c: GraphicsContext) {
        let wall = run.clock.time(t)
        let state = SceneTimeline.musicState(at: wall, run.marks).state
        if let scan = window.scan, state == .searching { drawScan(scan, c) }
        Self.drawBand(face, height: SceneTimeline.faceBand(.music), c)
        let q = run.content.query.map { "«\(Self.clip($0, 26))»" } ?? ""
        let track = run.content.track.map { Self.clip($0, 42) }
        var text: String
        var color = Palette.text
        switch state {
        case .searching:
            text = "ищу \(q)" + String(repeating: ".", count: max(0, window.typed - 200))
        case .playing:
            text = "♪ " + (track ?? "играет")
        case .paused:
            text = "❚❚ " + (track ?? "пауза"); color = Palette.dim
        case .failed:
            text = run.content.note ?? "не нашла \(q)"; color = Palette.crimson
        case .info:
            text = run.content.note ?? ""; color = Palette.dim
        }
        if state != .searching { text = String(text.prefix(max(1, window.typed))) }
        let line = Text(text).font(.mono(11, .bold))
        let at = localPoint(SceneTimeline.musicLine(window.rect))
        Self.shadowed(line, color, at: at, anchor: .leading, c)
        let buttons = SceneTimeline.musicButtons(window.rect)
        for b in buttons {
            Self.drawMusicButton(b.id, local(b.rect), playing: run.content.trackPlaying, hover: run.hover == .button(b.id), c)
        }
        if state == .playing, let last = buttons.last.map({ local($0.rect) }) {
            // Мини-эквалайзер справа в полосе кнопок: столбики в такт.
            let r = local(window.rect)
            let x0 = last.maxX + 22, beat = t * SceneTimeline.bpm / 60
            for i in 0..<5 {
                let x = x0 + CGFloat(i) * 6
                guard x + 4 < r.maxX - 10 else { break }
                let ph = beat * (1 + Double(i) * 0.37) + Double(i) * 0.7
                let h = 4 + 12 * CGFloat(abs(sin(ph * .pi)))
                c.fill(Path(CGRect(x: x, y: last.maxY - h, width: 4, height: h)), with: .color((i % 2 == 0 ? pink : Palette.acid).opacity(0.85)))
            }
        }
    }

    /// Кнопка ⏮ ⏯ ⏭: рамка HUD, значок рисуется путями (одинаково в живом показе и на листе).
    static func drawMusicButton(_ id: String, _ r: CGRect, playing: Bool, hover: Bool, _ c: GraphicsContext) {
        let pink = CapriFX.hackPink
        c.fill(Path(r), with: .color((id == "toggle" ? pink : Color.white).opacity(hover ? 0.32 : id == "toggle" ? 0.14 : 0.05)))
        c.stroke(Path(r.insetBy(dx: 0.5, dy: 0.5)), with: .color(pink.opacity(hover ? 0.95 : 0.5)), lineWidth: 1)
        let m = CGPoint(x: r.midX, y: r.midY)
        let s = min(r.height * 0.32, 6)
        var p = Path()
        func tri(_ x: CGFloat, right: Bool) {
            let d: CGFloat = right ? 1 : -1
            p.move(to: CGPoint(x: x - d * s * 0.8, y: m.y - s)); p.addLine(to: CGPoint(x: x + d * s * 0.8, y: m.y))
            p.addLine(to: CGPoint(x: x - d * s * 0.8, y: m.y + s)); p.closeSubpath()
        }
        switch id {
        case "prev":
            p.addRect(CGRect(x: m.x - s * 1.3, y: m.y - s, width: 1.6, height: s * 2)); tri(m.x + s * 0.2, right: false)
        case "next":
            p.addRect(CGRect(x: m.x + s * 1.3 - 1.6, y: m.y - s, width: 1.6, height: s * 2)); tri(m.x - s * 0.2, right: true)
        default:
            if playing {
                p.addRect(CGRect(x: m.x - s * 0.8, y: m.y - s, width: s * 0.55, height: s * 2))
                p.addRect(CGRect(x: m.x + s * 0.25, y: m.y - s, width: s * 0.55, height: s * 2))
            } else {
                tri(m.x + s * 0.15, right: true)
            }
        }
        c.fill(p, with: .color(hover ? Palette.acid : Palette.text))
    }

    /// ⏮ ⏯ ⏭ под глазами на столе: чёрная плашка под кнопками.
    static func drawEyeControls(_ rects: [(id: String, rect: CGRect)], playing: Bool, hover: SceneHotspot.Kind?, _ c: GraphicsContext) {
        guard let first = rects.first?.rect, let last = rects.last?.rect else { return }
        let plate = first.union(last).insetBy(dx: -4, dy: -3)
        c.fill(Path(plate), with: .color(.black.opacity(0.78)))
        for b in rects { drawMusicButton(b.id, b.rect, playing: playing, hover: hover == .button(b.id), c) }
    }

    // MARK: сессии

    private func drawSessions(_ c: GraphicsContext) {
        let rows = run.content.rows
        let shown = min(window.typed, rows.count, run.rowsCap)
        if rows.isEmpty {
            let r = local(SceneTimeline.rowRect(window.rect, 0))
            c.draw(Text("> никого — всё тихо").font(.mono(11, .semibold)).foregroundColor(Palette.dim),
                   at: CGPoint(x: r.minX + 8, y: r.midY), anchor: .leading)
            return
        }
        for i in 0..<shown {
            let row = rows[i]
            let r = local(SceneTimeline.rowRect(window.rect, i))
            let hover = run.hover == .row(i)
            if hover {
                c.fill(Path(r), with: .color(pink.opacity(0.14)))
                c.fill(Path(CGRect(x: r.minX, y: r.minY + 2, width: 3, height: r.height - 4)), with: .color(Palette.acid))
            } else if i % 2 == 1 {
                c.fill(Path(r), with: .color(.white.opacity(0.025)))
            }
            let color = Session.color(row.status)
            c.fill(Path(ellipseIn: CGRect(x: r.minX + 8, y: r.midY - 3, width: 6, height: 6)), with: .color(color))
            c.draw(Text(Self.clip(row.name, 13)).font(.mono(11, .bold)).foregroundColor(Palette.text),
                   at: CGPoint(x: r.minX + 20, y: r.midY), anchor: .leading)
            // Вторичные колонки — светлее `dim`: на тёмном `#1a1218` он почти не читается.
            c.draw(Text(Self.clip(row.detail, 18)).font(.mono(10)).foregroundColor(row.status == .needsInput ? Palette.acid : Palette.text.opacity(0.68)),
                   at: CGPoint(x: r.minX + 122, y: r.midY), anchor: .leading)
            c.draw(Text(row.since).font(.mono(10, .semibold)).foregroundColor(Palette.text.opacity(0.6)),
                   at: CGPoint(x: r.maxX - 6, y: r.midY), anchor: .trailing)
        }
        if rows.count > shown, shown == run.rowsCap {
            // Остальные — только числом, в правом нижнем углу лица на тёмной плашке.
            let f = face
            let label = Text("+\(rows.count - shown)").font(.mono(10, .bold))
            let chip = CGRect(x: f.maxX - 40, y: f.maxY - 20, width: 36, height: 16)
            c.fill(Path(chip), with: .color(.black.opacity(0.8)))
            c.fill(Path(CGRect(x: chip.minX, y: chip.minY, width: 2, height: chip.height)), with: .color(pink))
            c.draw(label.foregroundColor(Palette.text), at: CGPoint(x: chip.maxX - 5, y: chip.midY), anchor: .trailing)
        }
    }

    // MARK: думает

    private func drawThinking(_ c: GraphicsContext) {
        if let scan = window.scan { drawScan(scan, c) }
        let f = face
        let band = SceneTimeline.faceBand(.thinking)
        Self.drawBand(f, height: band, c)
        let dots = String(repeating: ".", count: window.typed) + String(repeating: " ", count: 3 - window.typed)
        let hover = run.hover == .button("assistant")
        let y = f.maxY - band / 2
        let think = Text("думаю" + dots).font(.mono(12, .bold))
        let at = CGPoint(x: f.minX + 12, y: y)
        Self.shadowed(think, hover ? Palette.acid : Palette.text, at: at, anchor: .leading, c)
        let open = Text("помощник ↗").font(.mono(10, .bold))
        let right = CGPoint(x: f.maxX - 10, y: y)
        Self.shadowed(open, hover ? Palette.acid : Palette.text.opacity(0.8), at: right, anchor: .trailing, c)
    }

    // MARK: ответ

    private func drawAnswer(_ c: GraphicsContext) {
        // Печатается построчно: `typed` букв всего.
        var left = window.typed
        for (i, line) in run.content.answer.enumerated() where left > 0 {
            let n = min(line.count, left)
            left -= n
            let caret = n < line.count || (left == 0 && window.caret) ? "▮" : ""
            let isProposal = run.content.proposal != nil && i == run.content.answer.count - 1
            c.draw(Text(String(line.prefix(n)) + caret).font(.mono(11, isProposal ? .bold : .medium))
                    .foregroundColor(isProposal ? Palette.acid : Palette.text),
                   at: localPoint(SceneTimeline.answerLine(window.rect, i)), anchor: .leading)
        }
        let p = run.content.proposal
        for b in SceneTimeline.answerButtons(window.rect, proposal: p != nil) {
            let r = local(b.rect)
            let hover = run.hover == .button(b.id)
            var label: String
            switch b.id {
            case "send":
                switch p?.state {
                case "sending": label = "отправляю…"
                case "sent": label = "отправлено ✓"
                case "failed": label = "не вышло"
                case "cancelled": label = "отменено"
                default: label = p?.clipped == true ? "прочитать ↗" : "отправить ⏎"
                }
            case "cancel": label = "отмена"
            default: label = "весь разговор ↗"
            }
            let primary = b.id == "send" && p?.state == "pending"
            c.fill(Path(r), with: .color((primary ? pink : Color.white).opacity(hover ? 0.32 : primary ? 0.16 : 0.05)))
            c.stroke(Path(r.insetBy(dx: 0.5, dy: 0.5)), with: .color(pink.opacity(hover || primary ? 0.95 : 0.45)), lineWidth: 1)
            c.draw(Text(label).font(.mono(10, .bold)).foregroundColor(p?.state == "sent" && b.id == "send" ? Palette.acid : Palette.text),
                   at: CGPoint(x: r.midX, y: r.midY), anchor: .center)
        }
    }

    // MARK: общие

    /// «📌» в заголовке: закреплено — розовая рамка и полная яркость.
    static func drawPin(_ r: CGRect, pinned: Bool, hover: Bool, _ c: GraphicsContext) {
        var g = c
        if pinned || hover {
            g.fill(Path(r), with: .color(CapriFX.hackPink.opacity(pinned ? 0.3 : 0.15)))
            g.stroke(Path(r.insetBy(dx: 0.5, dy: 0.5)), with: .color(CapriFX.hackPink.opacity(0.8)), lineWidth: 1)
        }
        g.opacity = pinned ? 1 : hover ? 0.9 : 0.5
        g.draw(Text("📌").font(.system(size: 10)), at: CGPoint(x: r.midX, y: r.midY), anchor: .center)
    }

    /// Подпись `reply` слева от глаз: чёрная плашка, моно; «не дошло» — красным.
    static func drawCaption(_ text: String, full: Bool, at p: CGPoint, failed: Bool, _ c: GraphicsContext) {
        let width = CGFloat(text.count + 1) * 7.4 + 12
        let box = CGRect(x: p.x - width, y: p.y - 10, width: width, height: 20)
        c.fill(Path(box), with: .color(.black.opacity(0.82)))
        c.fill(Path(CGRect(x: box.maxX - 2, y: box.minY, width: 2, height: box.height)), with: .color(failed ? Palette.crimson : Palette.acid))
        c.draw(Text(text + (full ? "" : "▮")).font(.mono(12, .bold)).foregroundColor(failed ? Palette.crimson : Palette.text),
               at: CGPoint(x: box.minX + 6, y: box.midY), anchor: .leading)
    }

    /// Обрезка по числу знаков (моно).
    static func clip(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n - 1)) + "…"
    }
}
