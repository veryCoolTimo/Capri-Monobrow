import XCTest
import CoreGraphics
@testable import CapriKit

/// Проход 2: свои клипы у каждого окна, горячие точки, перетаскивание, удержание, ответ терминалу.
final class SceneWindowsTests: XCTestCase {
    let visible = CGRect(x: 0, y: 0, width: 1512, height: 944)
    let home = CGRect(x: 600, y: 950, width: 32, height: 16)
    let all = Set(SceneClip.all)

    func geometry(_ kind: SceneKind, _ o: SceneOptions = SceneOptions()) -> SceneGeometry {
        switch kind {
        case .window:
            let w = SceneLayout.windowForm(visible)
            return SceneGeometry(home: home, target: SceneTimeline.eyesInWindow(w), area: w, visible: visible)
        case .sessions, .thinking, .answer:
            let w = SceneLayout.windowForm(visible, kind: kind, options: o)
            return SceneGeometry(home: home, target: SceneTimeline.eyesIn(kind, window: w), area: w, visible: visible)
        default:
            return SceneGeometry(home: home, target: SceneLayout.corner(visible, size: SceneTimeline.eyesSize), visible: visible)
        }
    }

    func frame(_ kind: SceneKind, _ t: Double, _ o: SceneOptions = SceneOptions(), clips: Set<String>? = nil) -> SceneFrame {
        SceneTimeline.frame(kind, t: t, geometry: geometry(kind, o), clips: clips ?? all, options: o)
    }

    /// Клипы спокойной фазы окна (по кадрам 24 fps).
    func calmClips(_ kind: SceneKind, _ o: SceneOptions = SceneOptions()) -> Set<String> {
        let c = SceneTimeline.calm(kind, o)!
        return Set(stride(from: c.lowerBound, to: min(c.upperBound, c.lowerBound + 8), by: 1.0 / 24).map { frame(kind, $0, o).clip })
    }

    // MARK: у каждого окна свои клипы (таблица 2.1)

    func testEachWindowHasItsOwnAnimation() {
        // Открытие: сессии — много глаз, думает — щёлки, ответ — появление.
        XCTAssertEqual(frame(.sessions, 0.8, SceneOptions(rows: 2)).clip, "many")
        XCTAssertEqual(frame(.thinking, 0.8).clip, "slits")
        XCTAssertEqual(frame(.answer, 0.8, SceneOptions(answerLines: 2, answerChars: 60)).clip, "appear")
        // Покой.
        XCTAssertEqual(calmClips(.sessions, SceneOptions(rows: 2)), ["many", "look"])
        XCTAssertTrue(calmClips(.sessions, SceneOptions(rows: 4, waiting: 3)).contains("crazy"), "≥ 3 ждут — crazy")
        XCTAssertEqual(calmClips(.thinking), ["slits", "shut"])
        XCTAssertEqual(calmClips(.answer, SceneOptions(answerLines: 3, answerChars: 90)), ["talk", "shut"])
        XCTAssertEqual(calmClips(.window, SceneOptions(text: 20)), ["talk", "look"])
        XCTAssertEqual(calmClips(.teleport), ["look", "close"], "моргает вместо глитча")
        XCTAssertEqual(Set([frame(.reply, 1.0).clip, frame(.reply, 2.0).clip]), ["burst", "slits"])
        // Уход окон — свёртывание с закрытыми глазами; у статуса — `melt`.
        let o = SceneOptions(rows: 2)
        XCTAssertEqual(frame(.sessions, SceneTimeline.duration(.sessions, o) - 0.7, o).phase, "fold")
        XCTAssertEqual(frame(.sessions, SceneTimeline.duration(.sessions, o) - 0.7, o).clip, "close")
        XCTAssertEqual(frame(.window, 7.3).clip, "melt")
    }

    func testFallbacksWithoutShowClips() {
        // Встроенные кадры: всё — look/close, без падений.
        for k in SceneKind.allCases {
            let o = SceneOptions(text: 10, lines: [5], rows: 3, waiting: 3, answerLines: 2, answerChars: 40, caption: 8)
            var t = 0.0
            while t < min(10, SceneTimeline.duration(k, o)) {
                let f = frame(k, t, o, clips: [])
                XCTAssertTrue(["look", "close", "melt"].contains(f.clip) || f.eyes == nil, "\(k) \(t) \(f.clip)")
                t += 0.05
            }
        }
    }

    func testThinkingBlinksAndScans() {
        let f = frame(.thinking, 2.0)
        XCTAssertNotNil(f.window?.scan)
        XCTAssertNil(f.bolt)
        let scans = Set(stride(from: 1.0, to: 4, by: 0.1).compactMap { frame(.thinking, $0).window?.scan.map { Int($0 * 10) } })
        XCTAssertGreaterThan(scans.count, 5, "сканлайн идёт по кругу")
    }

    func testAnswerTypesThenShutsAndBursts() {
        let o = SceneOptions(answerLines: 2, answerChars: 36, proposal: true)
        XCTAssertLessThan(frame(.answer, 1.5, o).window!.typed, 36)
        XCTAssertEqual(frame(.answer, 4.0, o).window!.typed, 36)
        XCTAssertEqual(frame(.answer, 4.0, o).clip, "shut")
        XCTAssertFalse(frame(.answer, 4.0, o).loop, "держит последний кадр")
        var sent = o
        sent.burstAt = 5
        XCTAssertEqual(frame(.answer, 5.3, sent).clip, "burst")
        XCTAssertEqual(frame(.answer, 6.5, sent).clip, "shut")
        // С кнопками читать дольше.
        XCTAssertGreaterThan(SceneTimeline.duration(.answer, o), SceneTimeline.duration(.answer, SceneOptions(answerLines: 2, answerChars: 36)))
        // Продолжение «думает»: без прилёта, глитч-переход в том же окне.
        let cont = SceneOptions(answerLines: 2, answerChars: 36, continued: true)
        let swap = frame(.answer, 0.1, cont)
        XCTAssertEqual(swap.phase, "swap")
        XCTAssertNil(swap.bolt)
        XCTAssertEqual(swap.window?.rect, geometry(.answer, cont).area)
        XCTAssertEqual(SceneTimeline.calm(.answer, cont)?.lowerBound, 0.3)
    }

    func testReplyTeleportsToTerminalAndCaptions() {
        let g = geometry(.reply)
        func at(_ t: Double, _ o: SceneOptions = SceneOptions(caption: 10)) -> SceneFrame {
            SceneTimeline.frame(.reply, t: t, geometry: g, clips: all, options: o)
        }
        XCTAssertEqual(at(0.1).clip, "tele_out")
        XCTAssertEqual(at(0.1).eyes, g.home)
        XCTAssertEqual(at(0.4).bolt?.to, CGPoint(x: g.target.midX, y: g.target.midY))
        XCTAssertEqual(at(0.7).clip, "tele_in")
        XCTAssertEqual(at(1.0).rings.count, 1)
        XCTAssertEqual(at(2.0).phase, "watch")
        XCTAssertLessThan(at(2.0).eyes!.minY, g.target.minY, "смотрит вниз, в окно")
        XCTAssertEqual(at(3.0).caption?.typed, 10)
        XCTAssertFalse(at(3.0).caption!.failed)
        XCTAssertLessThan(at(1.6).caption!.typed, 10)
        let failed = at(2.5, SceneOptions(caption: 10, failedAt: 2.2))
        XCTAssertEqual(failed.clip, "crazy")
        XCTAssertEqual(failed.glitch, 3)
        XCTAssertTrue(failed.caption!.failed)
        XCTAssertEqual(at(3.9).phase, "home")
        XCTAssertTrue(at(4.0).done)
    }

    // MARK: раскладка

    func testWindowLayoutsFit() {
        for rows in 1...6 {
            let o = SceneOptions(rows: rows)
            let w = SceneLayout.windowForm(visible, kind: .sessions, options: o)
            XCTAssertTrue(visible.contains(w))
            let eyes = SceneTimeline.eyesIn(.sessions, window: w)
            XCTAssertTrue(w.contains(eyes))
            for i in 0..<min(rows, SceneTimeline.sessionsMaxRows) {
                let r = SceneTimeline.rowRect(w, i)
                XCTAssertTrue(w.contains(r), "строка \(i) из \(rows) в окне")
                XCTAssertLessThanOrEqual(r.maxY, eyes.minY)
            }
        }
        for lines in 1...6 {
            let o = SceneOptions(answerLines: lines)
            let w = SceneLayout.windowForm(visible, kind: .answer, options: o)
            XCTAssertLessThanOrEqual(w.height, 202)
            let buttons = SceneTimeline.answerButtons(w, proposal: true)
            XCTAssertEqual(buttons.map(\.id), ["send", "cancel", "conversation"])
            let lastLine = SceneTimeline.answerLine(w, lines - 1)
            for b in buttons {
                XCTAssertTrue(w.contains(b.rect))
                XCTAssertLessThan(b.rect.maxY, lastLine.y - 6, "кнопки под текстом")
            }
        }
        let think = SceneLayout.windowForm(visible, kind: .thinking)
        XCTAssertEqual(think.size, CGSize(width: 220, height: 110))
        XCTAssertTrue(think.contains(SceneTimeline.eyesIn(.thinking, window: think)))
        // Ответ на месте окна «думает»: тот же правый верхний угол.
        let moved = think.offsetBy(dx: -400, dy: 300)
        let r = SceneLayout.resized(moved, to: SceneTimeline.windowSize(.answer, SceneOptions(answerLines: 3)), visible: visible)
        XCTAssertEqual(r.maxX, moved.maxX)
        XCTAssertEqual(r.maxY, moved.maxY)
    }

    func testAtTerminal() {
        let w = CGRect(x: 100, y: 100, width: 800, height: 500)
        XCTAssertEqual(SceneLayout.atTerminal(w, visible: visible), SceneLayout.onWindow(w, visible: visible))
        // Окно под самой строкой меню — внутрь, у правого верхнего угла.
        let tall = CGRect(x: 100, y: 0, width: 800, height: 944)
        let r = SceneLayout.atTerminal(tall, visible: visible)
        XCTAssertTrue(tall.contains(r))
        XCTAssertGreaterThan(r.midX, tall.midX)
        XCTAssertGreaterThan(r.midY, tall.midY)
    }

    func testWrap() {
        XCTAssertEqual(SceneText.wrap("коротко"), ["коротко"])
        XCTAssertEqual(SceneText.wrap("**votek2** ждёт `y/n`\n\n# итог", columns: 40), ["votek2 ждёт y/n", " итог".trimmingCharacters(in: .whitespaces)])
        let long = Array(repeating: "слово", count: 80).joined(separator: " ")
        let w = SceneText.wrap(long, columns: 20, maxLines: 3)
        XCTAssertEqual(w.count, 3)
        XCTAssertTrue(w.allSatisfy { $0.count <= 20 })
        XCTAssertTrue(w[2].hasSuffix("…"))
        XCTAssertEqual(SceneText.wrap(String(repeating: "x", count: 45), columns: 20).map(\.count), [20, 20, 5])
        XCTAssertEqual(SceneText.wrap(""), [])
    }

    // MARK: горячие точки

    func testHotspotsOnlyInCalmPhase() {
        for k in SceneKind.allCases {
            let o = SceneOptions(text: 12, rows: 3, answerLines: 2, answerChars: 30, proposal: true, caption: 6)
            let g = geometry(k, o)
            let d = SceneTimeline.duration(k, o)
            let calm = SceneTimeline.calm(k, o)
            var t = 0.0
            while t < min(d, 12) {
                let spots = SceneLayout.hotspots(k, t: t, geometry: g, clips: all, options: o)
                let f = SceneTimeline.frame(k, t: t, geometry: g, clips: all, options: o)
                if calm?.contains(t) != true || k == .takeover {
                    XCTAssertTrue(spots.isEmpty, "\(k) t=\(t)")
                } else {
                    XCTAssertFalse(spots.isEmpty, "\(k) t=\(t)")
                    XCTAssertNil(f.bolt)
                    XCTAssertTrue(spots.contains { $0.kind == .drag }, "\(k): тянуть можно")
                    // После обрыва — ничего.
                    XCTAssertTrue(SceneLayout.hotspots(k, t: t, geometry: g, clips: all, options: o, abortedAt: t - 0.01).isEmpty)
                }
                t += 0.25
            }
        }
    }

    func testHotspotRects() {
        let o = SceneOptions(rows: 3)
        let g = geometry(.sessions, o)
        let w = g.area!
        let spots = SceneLayout.hotspots(.sessions, t: 3, geometry: g, clips: all, options: o)
        XCTAssertEqual(spots.first?.kind, .close)
        XCTAssertTrue(spots[0].rect.contains(CGPoint(x: SceneTimeline.closeRect(w).midX, y: SceneTimeline.closeRect(w).midY)))
        XCTAssertEqual(spots.filter { if case .row = $0.kind { return true }; return false }.count, 3)
        for s in spots where s.kind != .close && s.kind != .pin { XCTAssertTrue(w.insetBy(dx: -5, dy: -5).contains(s.rect), "\(s.kind)") }
        // Попадание: строка 1, заголовок — тянуть, «×».
        XCTAssertEqual(SceneLayout.hit(spots, CGPoint(x: SceneTimeline.rowRect(w, 1).midX, y: SceneTimeline.rowRect(w, 1).midY))?.kind, .row(1))
        XCTAssertEqual(SceneLayout.hit(spots, CGPoint(x: w.minX + 30, y: w.maxY - 8))?.kind, .drag)
        XCTAssertEqual(SceneLayout.hit(spots, CGPoint(x: SceneTimeline.pinRect(w).midX, y: SceneTimeline.pinRect(w).midY))?.kind, .pin)
        XCTAssertNil(SceneLayout.hit(spots, CGPoint(x: w.minX - 30, y: w.midY)), "мимо окна — сквозь панель")
        // Ответ: кнопки; думает: всё тело — помощник; статус — строка.
        let ao = SceneOptions(answerLines: 2, answerChars: 20, proposal: true)
        let ids = SceneLayout.hotspots(.answer, t: 3, geometry: geometry(.answer, ao), clips: all, options: ao).compactMap { s -> String? in
            if case .button(let id) = s.kind { return id }; return nil
        }
        XCTAssertEqual(ids, ["send", "cancel", "conversation"])
        let tg = geometry(.thinking)
        let think = SceneLayout.hotspots(.thinking, t: 3, geometry: tg, clips: all)
        XCTAssertEqual(SceneLayout.hit(think, CGPoint(x: tg.area!.minX + 10, y: tg.area!.minY + 10))?.kind, .button("assistant"))
        XCTAssertEqual(SceneLayout.hit(think, CGPoint(x: tg.target.midX, y: tg.target.midY))?.kind, .drag)
        let wg = geometry(.window)
        let st = SceneLayout.hotspots(.window, t: 3, geometry: wg, clips: all)
        XCTAssertEqual(SceneLayout.hit(st, CGPoint(x: wg.area!.midX, y: wg.area!.minY + 12))?.kind, .button("status"))
        // Телепорт и ответ терминалу — только глаза.
        let rg = geometry(.reply)
        XCTAssertEqual(SceneLayout.hotspots(.reply, t: 2, geometry: rg, clips: all).map(\.kind), [.drag])
    }

    // MARK: перетаскивание

    func testMovedClampsToScreenAndKeepsHome() {
        let g = geometry(.sessions, SceneOptions(rows: 2))
        let m = g.moved(by: CGVector(dx: -300, dy: 200))
        XCTAssertEqual(m.home, g.home)
        XCTAssertEqual(m.area!.minX, g.area!.minX - 300)
        XCTAssertEqual(m.area!.minY, g.area!.minY + 200)
        XCTAssertEqual(m.target.minX - m.area!.minX, g.target.minX - g.area!.minX, "глаза едут с окном")
        let far = g.moved(by: CGVector(dx: 5000, dy: -5000))
        XCTAssertTrue(visible.contains(far.area!))
        XCTAssertEqual(far.area!.maxX, visible.maxX)
        XCTAssertEqual(far.area!.minY, visible.minY)
        // Без окна — тянется цель.
        let t = geometry(.teleport).moved(by: CGVector(dx: -100, dy: 50))
        XCTAssertEqual(t.target.minX, geometry(.teleport).target.minX - 100)
        XCTAssertNil(t.area)
        // Кадр идёт от нового места.
        let f = SceneTimeline.frame(.sessions, t: 3, geometry: m, clips: all, options: SceneOptions(rows: 2))
        XCTAssertEqual(f.window?.rect, m.area)
    }

    // MARK: часы

    func testClockHoldsAndReleases() {
        var c = SceneClock()
        XCTAssertEqual(c.time(2), 2)
        c.hold(true, wall: 2, calm: true)
        XCTAssertEqual(c.time(10), 2, "стоит, пока мышь на месте")
        XCTAssertEqual(c.nextCheck(), 2 + SceneClock.holdCap, "держат мышью — проверка на потолке")
        XCTAssertNil(c.remaining(10, end: 5))
        XCTAssertEqual(c.lag(10), 8)
        c.hold(false, wall: 10, calm: true)
        XCTAssertEqual(c.nextCheck(), 13)
        XCTAssertFalse(c.update(12))
        XCTAssertEqual(c.time(12), 2, "3 с после касания — ещё стоит")
        XCTAssertTrue(c.update(13))
        XCTAssertEqual(c.time(13), 2)
        XCTAssertEqual(c.time(14), 3, "пошло дальше с того же места")
        XCTAssertEqual(c.remaining(14, end: 5), 2)
        // Вне спокойной фазы не встаём.
        var d = SceneClock()
        d.hold(true, wall: 0.2, calm: false)
        XCTAssertEqual(d.time(1), 1)
    }

    func testClockHoverCap() {
        var c = SceneClock()
        c.hold(true, wall: 2, calm: true)
        XCTAssertFalse(c.update(30))
        XCTAssertTrue(c.frozen)
        XCTAssertTrue(c.update(2 + SceneClock.holdCap), "минута наведения без движения — отпустили")
        XCTAssertFalse(c.holding)
        XCTAssertFalse(c.frozen)
        XCTAssertEqual(c.time(2 + SceneClock.holdCap), 2, "пошло дальше с того же места")
        // «📌» сильнее потолка наведения.
        var d = SceneClock()
        d.pin(true, wall: 2, calm: true)
        d.hold(true, wall: 3, calm: true)
        XCTAssertFalse(d.update(3 + SceneClock.holdCap))
        XCTAssertTrue(d.frozen)
    }

    func testClockPinAndCap() {
        var c = SceneClock()
        c.pin(true, wall: 2, calm: true)
        c.hold(true, wall: 3, calm: true)
        c.hold(false, wall: 4, calm: true)
        c.update(100)
        XCTAssertEqual(c.time(100), 2, "закреплено — стоит и без мыши")
        XCTAssertEqual(c.nextCheck(), 2 + SceneClock.pinCap)
        XCTAssertTrue(c.update(2 + SceneClock.pinCap))
        XCTAssertFalse(c.pinned)
        XCTAssertFalse(c.frozen, "10 мин — потолок")
        // Снять «📌» — как отпустить мышь: ещё 3 с.
        var d = SceneClock()
        d.pin(true, wall: 2, calm: true)
        d.pin(false, wall: 50, calm: true)
        d.update(52)
        XCTAssertTrue(d.frozen)
        d.update(53)
        XCTAssertFalse(d.frozen)
        XCTAssertEqual(d.time(54), 3)
        // Обрыв: сразу идёт, держание и «📌» сняты.
        var e = SceneClock()
        e.pin(true, wall: 2, calm: true)
        e.hold(true, wall: 3, calm: true)
        e.release(9)
        XCTAssertFalse(e.frozen || e.pinned || e.holding)
        XCTAssertEqual(e.time(9), 2)
        XCTAssertEqual(e.time(10), 3)
    }
}
