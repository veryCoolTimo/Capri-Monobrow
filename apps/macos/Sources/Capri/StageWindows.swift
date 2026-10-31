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
        default: break
        }
    }

    // MARK: музыка

    private func drawMusic(_ c: GraphicsContext) {
        let r = local(window.rect)
        let state = SceneTimeline.musicState(at: run.clock.time(t), run.marks).state
        if let scan = window.scan, state == .searching {
            let body = CGRect(x: r.minX, y: r.minY + 22, width: r.width, height: r.height - 22)
            let y = body.minY + body.height * scan
            for k in 0..<5 {
                c.fill(Path(CGRect(x: body.minX + 1, y: y - CGFloat(k) * 3, width: body.width - 2, height: 1)),
                       with: .color(pink.opacity(0.45 - Double(k) * 0.08)))
            }
        }
        let q = run.content.query.map { "«\(Self.clip($0, 26))»" } ?? ""
        let track = run.content.track.map { Self.clip($0, 38) }
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
        c.draw(Text(text).font(.mono(10.5, .semibold)).foregroundColor(color),
               at: localPoint(SceneTimeline.musicLine(window.rect)), anchor: .leading)
        for b in SceneTimeline.musicButtons(window.rect) {
            Self.drawMusicButton(b.id, local(b.rect), playing: run.content.trackPlaying, hover: run.hover == .button(b.id), c)
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
            c.draw(Text(Self.clip(row.detail, 18)).font(.mono(10)).foregroundColor(row.status == .needsInput ? Palette.acid : Palette.dim),
                   at: CGPoint(x: r.minX + 122, y: r.midY), anchor: .leading)
            c.draw(Text(row.since).font(.mono(9, .semibold)).foregroundColor(Palette.dim),
                   at: CGPoint(x: r.maxX - 6, y: r.midY), anchor: .trailing)
        }
        if rows.count > shown, shown == run.rowsCap {
            // Остальные — только числом, в заголовке.
            let bar = local(SceneTimeline.titleRect(window.rect))
            c.draw(Text("+\(rows.count - shown)").font(.mono(9, .bold)).foregroundColor(Palette.dim),
                   at: CGPoint(x: bar.maxX - 4, y: bar.midY), anchor: .trailing)
        }
    }

    // MARK: думает

    private func drawThinking(_ c: GraphicsContext) {
        let r = local(window.rect)
        let body = CGRect(x: r.minX, y: r.minY + 22, width: r.width, height: r.height - 22)
        if let scan = window.scan {
            // Сканлайн-вайп сверху вниз со шлейфом.
            let y = body.minY + body.height * scan
            for k in 0..<6 {
                c.fill(Path(CGRect(x: body.minX + 1, y: y - CGFloat(k) * 3, width: body.width - 2, height: 1)),
                       with: .color(pink.opacity(0.5 - Double(k) * 0.08)))
            }
        }
        let dots = String(repeating: ".", count: window.typed) + String(repeating: " ", count: 3 - window.typed)
        let hover = run.hover == .button("assistant")
        c.draw(Text("думаю" + dots).font(.mono(11, .semibold)).foregroundColor(hover ? Palette.acid : Palette.text),
               at: CGPoint(x: r.midX, y: r.maxY - 14), anchor: .center)
        if hover {
            c.draw(Text("открыть помощника").font(.mono(8, .bold)).foregroundColor(Palette.dim),
                   at: CGPoint(x: r.midX, y: r.maxY - 4), anchor: .center)
        }
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
            c.draw(Text(label).font(.mono(9, .bold)).foregroundColor(p?.state == "sent" && b.id == "send" ? Palette.acid : Palette.text),
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
