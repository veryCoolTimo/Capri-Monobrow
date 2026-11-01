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
            return SceneGeometry(home: home, target: SceneTimeline.faceIn(.window, window: w), area: w, visible: visible)
        case .sessions, .thinking, .answer, .music:
            let w = SceneLayout.windowForm(visible, kind: kind, options: o)
            return SceneGeometry(home: home, target: SceneTimeline.faceIn(kind, window: w), area: w, visible: visible)
        case .reply:
            return SceneGeometry(home: home, target: SceneLayout.corner(visible, size: SceneTimeline.replySize), visible: visible)
        default:
            return SceneGeometry(home: home, target: SceneLayout.corner(visible, size: SceneTimeline.eyesSize), visible: visible)
        }
    }

    /// Старые клипы глаз (проход 2) — фолбэк, когда новых клипов нет.
    let old = Set(SceneClip.all).subtracting([SceneClip.faceTalk, SceneClip.faceNod, SceneClip.faceScan, SceneClip.faceGrin,
                                              SceneClip.hairBob, SceneClip.sideLook, SceneClip.eyeZoom])

    func frame(_ kind: SceneKind, _ t: Double, _ o: SceneOptions = SceneOptions(), clips: Set<String>? = nil) -> SceneFrame {
        SceneTimeline.frame(kind, t: t, geometry: geometry(kind, o), clips: clips ?? all, options: o)
    }

    /// Клипы спокойной фазы окна (по кадрам 24 fps).
    func calmClips(_ kind: SceneKind, _ o: SceneOptions = SceneOptions(), clips: Set<String>? = nil) -> Set<String> {
        let c = SceneTimeline.calm(kind, o)!
        return Set(stride(from: c.lowerBound, to: min(c.upperBound, c.lowerBound + 8), by: 1.0 / 24).map { frame(kind, $0, o, clips: clips).clip })
    }

    // MARK: у каждого окна свои клипы (таблица 3.2) и фолбэки (проход 2)

    func testEachWindowHasItsOwnAnimation() {
        // Открытие: сессии — много глаз, думает — щёлки, ответ — появление, музыка — взгляд в сторону.
        XCTAssertEqual(frame(.sessions, 0.8, SceneOptions(rows: 2)).clip, "many")
        XCTAssertEqual(frame(.thinking, 0.8).clip, "slits")
        XCTAssertEqual(frame(.answer, 0.8, SceneOptions(answerLines: 2, answerChars: 60)).clip, "appear")
        // Покой: у каждого окна свой клип.
        XCTAssertEqual(calmClips(.sessions, SceneOptions(rows: 2)), ["many", "face_scan"])
        XCTAssertTrue(calmClips(.sessions, SceneOptions(rows: 4, waiting: 3)).contains("face_grin"), "≥ 3 ждут — оскал и много глаз")
        XCTAssertEqual(calmClips(.thinking), ["side_look"])
        XCTAssertEqual(calmClips(.answer, SceneOptions(answerLines: 3, answerChars: 90)), ["face_talk"])
        XCTAssertEqual(calmClips(.window, SceneOptions(text: 20)), ["face_talk", "face_scan"])
        XCTAssertEqual(calmClips(.teleport), ["look", "close"], "телепорт — без изменений")
        XCTAssertEqual(Set([frame(.reply, 1.0).clip, frame(.reply, 2.0).clip]), ["eye_zoom", "face_grin"])
        // Лицо в окнах заполняет прямоугольник (fill), у сцен на столе — нет.
        XCTAssertNotNil(frame(.sessions, 3, SceneOptions(rows: 2)).face)
        XCTAssertNotNil(frame(.reply, 2.0).face, "лицо у терминала")
        XCTAssertNil(frame(.teleport, 2.0).face)
        XCTAssertNil(frame(.vibe, 2.0).face)
        XCTAssertTrue(frame(.sessions, 3, SceneOptions(rows: 2)).clipMode == .bounce, "камера туда-обратно")
        XCTAssertTrue(frame(.thinking, 3).clipMode == .bounce)
        // Уход окон — свёртывание с закрытыми глазами; у статуса — `melt`.
        let o = SceneOptions(rows: 2)
        XCTAssertEqual(frame(.sessions, SceneTimeline.duration(.sessions, o) - 0.7, o).phase, "fold")
        XCTAssertEqual(frame(.sessions, SceneTimeline.duration(.sessions, o) - 0.7, o).clip, "close")
        XCTAssertEqual(frame(.window, 7.3).clip, "melt")
    }

    func testOldClipsFallback() {
        // Без новых клипов — раскладка прохода 2 по клипам (окна всё равно крупные).
        XCTAssertEqual(calmClips(.sessions, SceneOptions(rows: 2), clips: old), ["many", "look"])
        XCTAssertTrue(calmClips(.sessions, SceneOptions(rows: 4, waiting: 3), clips: old).contains("crazy"))
        XCTAssertEqual(calmClips(.thinking, clips: old), ["slits", "shut"])
        XCTAssertEqual(calmClips(.answer, SceneOptions(answerLines: 3, answerChars: 90), clips: old), ["talk", "shut"])
        XCTAssertEqual(calmClips(.window, SceneOptions(text: 20), clips: old), ["talk", "look"])
        XCTAssertEqual(Set([frame(.reply, 1.0, clips: old).clip, frame(.reply, 2.0, clips: old).clip]), ["burst", "slits"])
    }

    func testSessionsHoverZoomsIntoEye() {
        var o = SceneOptions(rows: 3)
        o.hoverRow = 2
        o.hoverAt = 3.0
        let f = frame(.sessions, 3.3, o)
        XCTAssertEqual(f.clip, "eye_zoom")
        XCTAssertFalse(f.loop, "держит последний кадр")
        XCTAssertEqual(f.face!.shift.dy, -0.12, accuracy: 1e-9, "глаза к строке")
        // Ушёл со строки — снова сканирует, с глитчем на 2 кадра.
        var back = SceneOptions(rows: 3)
        back.hoverAt = 4.0
        XCTAssertEqual(frame(.sessions, 4.02, back).clip, "face_scan")
        XCTAssertEqual(frame(.sessions, 4.02, back).glitch, 1)
    }

    func testAnswerSentNods() {
        var o = SceneOptions(answerLines: 2, answerChars: 36, proposal: true)
        o.burstAt = 5
        XCTAssertEqual(frame(.answer, 5.3, o).clip, "face_nod")
        XCTAssertEqual(frame(.answer, 5.3, o).rings.count, 1)
        XCTAssertEqual(frame(.answer, 7.5, o).clip, "face_nod", "кивок и ^^ — 3 с")
        XCTAssertEqual(frame(.answer, 8.2, o).clip, "face_talk")
        XCTAssertEqual(frame(.answer, 8.2, o).clipT, 0, "рот закрыт")
        // Печатает — кивает слогами.
        let ys = Set(stride(from: 1.2, to: 2.0, by: 1.0 / 24).map { Int((frame(.answer, $0, o).face!.shift.dy * 1000).rounded()) })
        XCTAssertGreaterThan(ys.count, 3)
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
        XCTAssertEqual(frame(.answer, 4.0, o, clips: old).clip, "shut")
        XCTAssertFalse(frame(.answer, 4.0, o).loop, "держит кадр")
        var sent = o
        sent.burstAt = 5
        XCTAssertEqual(frame(.answer, 5.3, sent, clips: old).clip, "burst")
        XCTAssertEqual(frame(.answer, 6.5, sent, clips: old).clip, "shut")
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
        XCTAssertEqual(at(1.0).clip, "eye_zoom", "решительно смотрит в терминал")
        XCTAssertEqual(at(2.0).clip, "face_grin")
        XCTAssertEqual(g.target.size, SceneTimeline.replySize)
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
            let face = SceneTimeline.faceIn(.sessions, window: w)
            XCTAssertTrue(w.contains(face))
            for i in 0..<min(rows, SceneTimeline.sessionsMaxRows) {
                let r = SceneTimeline.rowRect(w, i)
                XCTAssertTrue(w.contains(r), "строка \(i) из \(rows) в окне")
                XCTAssertLessThanOrEqual(r.maxY, face.minY, "строки под лицом")
            }
        }
        for lines in 1...6 {
            let o = SceneOptions(answerLines: lines)
            let w = SceneLayout.windowForm(visible, kind: .answer, options: o)
            XCTAssertLessThanOrEqual(w.height, 340)
            let buttons = SceneTimeline.answerButtons(w, proposal: true)
            XCTAssertEqual(buttons.map(\.id), ["send", "cancel", "conversation"])
            let face = SceneTimeline.faceIn(.answer, window: w)
            XCTAssertLessThan(SceneTimeline.answerLine(w, 0).y + 7, face.minY, "текст под лицом")
            let lastLine = SceneTimeline.answerLine(w, lines - 1)
            for b in buttons {
                XCTAssertTrue(w.contains(b.rect))
                XCTAssertLessThan(b.rect.maxY, lastLine.y - 6, "кнопки под текстом")
            }
        }
        let think = SceneLayout.windowForm(visible, kind: .thinking)
        XCTAssertEqual(think.size, CGSize(width: 260, height: 184))
        XCTAssertTrue(think.contains(SceneTimeline.faceIn(.thinking, window: think)))
        XCTAssertEqual(SceneLayout.windowForm(visible, kind: .music).size, CGSize(width: 340, height: 270))
        // Ответ на месте окна «думает»: тот же правый верхний угол.
        let moved = think.offsetBy(dx: -400, dy: 300)
        let r = SceneLayout.resized(moved, to: SceneTimeline.windowSize(.answer, SceneOptions(answerLines: 3)), visible: visible)
        XCTAssertEqual(r.maxX, moved.maxX)
        XCTAssertEqual(r.maxY, moved.maxY)
    }

    /// Проход 3: Capri — главное в окне: лицо ≥ 55 % площади при любом числе строк.
    func testFaceFillsMostOfEveryWindow() {
        func share(_ kind: SceneKind, _ o: SceneOptions) -> CGFloat {
            let w = kind == .window ? SceneLayout.windowForm(visible) : SceneLayout.windowForm(visible, kind: kind, options: o)
            let f = SceneTimeline.faceIn(kind, window: w)
            XCTAssertTrue(w.contains(f))
            XCTAssertEqual(f.maxY, w.maxY - 22, "сразу под заголовком")
            return f.width * f.height / (w.width * w.height)
        }
        for n in 1...4 { XCTAssertGreaterThanOrEqual(share(.sessions, SceneOptions(rows: n)), 0.55, "сессии, \(n) строк") }
        for l in 1...6 { XCTAssertGreaterThanOrEqual(share(.answer, SceneOptions(answerLines: l)), 0.55, "ответ, \(l) строк") }
        XCTAssertGreaterThanOrEqual(share(.music, SceneOptions()), 0.75)
        XCTAssertGreaterThanOrEqual(share(.thinking, SceneOptions()), 0.85)
        XCTAssertGreaterThanOrEqual(share(.window, SceneOptions()), 0.85)
        // Подписи на полосе лица; кнопки музыки — под лицом.
        let mw = SceneLayout.windowForm(visible, kind: .music)
        let mf = SceneTimeline.faceIn(.music, window: mw)
        XCTAssertTrue(SceneTimeline.bandRect(.music, window: mw)!.contains(SceneTimeline.musicLine(mw)))
        for b in SceneTimeline.musicButtons(mw) {
            XCTAssertEqual(b.rect.size, CGSize(width: 44, height: 24))
            XCTAssertLessThanOrEqual(b.rect.maxY, mf.minY)
            XCTAssertGreaterThanOrEqual(b.rect.minY, mw.minY)
        }
        let sw = SceneLayout.windowForm(visible)
        XCTAssertEqual(SceneTimeline.statusRect(sw), SceneTimeline.bandRect(.window, window: sw))
    }

    /// Горячие точки внутри окна, кнопки/строки/«×»/«📌» не пересекаются; лицо тянется, кроме полосы подписи.
    func testHotspotsDoNotOverlap() {
        let opts: [(SceneKind, SceneOptions)] = [(.sessions, SceneOptions(rows: 4)), (.answer, SceneOptions(answerLines: 6, answerChars: 40, proposal: true)),
                                                 (.music, SceneOptions()), (.thinking, SceneOptions()), (.window, SceneOptions(text: 10))]
        for (k, o) in opts {
            let g = geometry(k, o)
            let w = g.area!
            let spots = SceneLayout.hotspots(k, t: 3, geometry: g, clips: all, options: o)
            let solid = spots.filter { $0.kind != .drag && $0.kind != .pin }  // «📌» и «×» — как в проходе 2
            for s in spots { XCTAssertTrue(w.insetBy(dx: -3, dy: -3).contains(s.rect), "\(k) \(s.kind)") }
            for (i, a) in solid.enumerated() {
                for b in solid[(i + 1)...] { XCTAssertFalse(a.rect.intersects(b.rect), "\(k): \(a.kind) × \(b.kind)") }
            }
            if let band = SceneTimeline.bandRect(k, window: w), k != .thinking {
                let face = SceneTimeline.faceIn(k, window: w)
                XCTAssertNotEqual(SceneLayout.hit(spots, CGPoint(x: face.midX, y: band.midY))?.kind, .drag, "\(k): полоса подписи — не тянуть")
                XCTAssertEqual(SceneLayout.hit(spots, CGPoint(x: face.midX, y: face.maxY - 30))?.kind, .drag, "\(k): лицо тянется")
            }
        }
    }

    func testAtTerminal() {
        let w = CGRect(x: 100, y: 100, width: 800, height: 500)
        XCTAssertEqual(SceneLayout.atTerminal(w, visible: visible), SceneLayout.onWindow(w, visible: visible))
        XCTAssertEqual(SceneLayout.atTerminal(w, visible: visible, size: SceneTimeline.replySize).size, SceneTimeline.replySize)
        // Над окном мало места под лицо 200×125 — полоса глаз на край; совсем нет места — полоса глаз внутрь.
        let high = CGRect(x: 100, y: 100, width: 800, height: 944 - 100 - 60)
        XCTAssertEqual(SceneLayout.atTerminal(high, visible: visible, size: SceneTimeline.replySize).size, SceneTimeline.eyesSize)
        let full = CGRect(x: 0, y: 0, width: 1512, height: 944)
        XCTAssertEqual(SceneLayout.atTerminal(full, visible: visible, size: SceneTimeline.replySize).size, SceneTimeline.eyesSize)
        // Окно под самой строкой меню — внутрь, у правого верхнего угла.
        let tall = CGRect(x: 100, y: 0, width: 800, height: 944)
        let r = SceneLayout.atTerminal(tall, visible: visible)
        XCTAssertTrue(tall.contains(r))
        XCTAssertGreaterThan(r.midX, tall.midX)
        XCTAssertGreaterThan(r.midY, tall.midY)
    }

    /// Удержание (курсор на лице): таймлайн стоит, а Capri, печать и движение идут по стене.
    func testWindowsRunOnWallClockWhileHeld() {
        var o = SceneOptions(answerLines: 3, answerChars: 90)
        let a0 = frame(.answer, 2.0, o)
        o.lag = 2
        let a1 = frame(.answer, 2.0, o)
        XCTAssertTrue(a1.wallClock)
        XCTAssertGreaterThan(a1.window!.typed, a0.window!.typed, "ответ печатается и при удержании")
        var w = SceneOptions(text: 40)
        let s0 = frame(.window, 1.5, w)
        w.lag = 4
        let s1 = frame(.window, 1.5, w)
        XCTAssertTrue(s1.wallClock, "окно статуса — по стене")
        XCTAssertGreaterThan(s1.window!.typed, s0.window!.typed)
        let quiet = SceneOptions(text: 5)
        var quietHeld = quiet
        quietHeld.lag = 4
        XCTAssertEqual(frame(.window, 3, quietHeld).clipT, frame(.window, 3, quiet).clipT + 4 * 0.4, accuracy: 1e-9,
                       "face_scan не ускоряется вдвое")
        var r = SceneOptions(caption: 10)
        let r0 = frame(.reply, 2.0, r)
        r.lag = 0.7
        let r1 = frame(.reply, 2.0, r)
        XCTAssertTrue(r1.wallClock)
        XCTAssertEqual(r1.clipT, r0.clipT + 0.7, accuracy: 1e-9)
        XCTAssertEqual(r1.glitch, 2, "глитч оскала — по итоговому времени клипа")
        XCTAssertGreaterThan(r1.face!.zoom, r0.face!.zoom)
    }

    /// Окно статуса и окно сессий: разные кадрирование и движение в покое; музыка ищет не как «думает».
    func testRestingWindowsDiffer() {
        let status = frame(.window, 6.0, SceneOptions(text: 10))
        let sessions = frame(.sessions, 3.0, SceneOptions(rows: 2))
        XCTAssertEqual(status.clip, sessions.clip)
        XCTAssertNotEqual(status.face?.mirror, sessions.face?.mirror)
        XCTAssertNotEqual(status.face?.zoom, sessions.face?.zoom)
        let talkingStatus = frame(.window, 1.5, SceneOptions(text: 40))
        XCTAssertEqual(talkingStatus.clip, "face_talk")
        XCTAssertGreaterThan(talkingStatus.face!.zoom, 1.05, "маска крупнее, чем в ответе")
    }

    /// Пока растёт линия глаз, лицо не шире её; потом — во всю ширину.
    func testUnfoldFaceInsideLine() {
        for kind in [SceneKind.sessions, .thinking, .answer, .music, .window] {
            let o = SceneOptions(text: 5, rows: 2, answerLines: 2, answerChars: 20)
            for t in stride(from: 0.6, to: 1.0, by: 0.04) {
                let f = frame(kind, t, o)
                guard f.phase == "unfold", let win = f.window, let e = f.eyes else { continue }
                if win.open < 0.5 { XCTAssertEqual(e.width, win.rect.width, accuracy: 0.01, "\(kind) t=\(t)") }
            }
        }
    }

    func testNoRowHotspotsWithoutSessions() {
        let o = SceneOptions(rows: 0)
        let spots = SceneLayout.hotspots(.sessions, t: 3, geometry: geometry(.sessions, o), clips: all, options: o)
        XCTAssertFalse(spots.contains { if case .row = $0.kind { return true } else { return false } })
    }

    func testUsesFace() {
        XCTAssertTrue(SceneTimeline.usesFace(.sessions))
        XCTAssertTrue(SceneTimeline.usesFace(.window))
        XCTAssertTrue(SceneTimeline.usesFace(.reply))
        XCTAssertFalse(SceneTimeline.usesFace(.teleport))
        XCTAssertFalse(SceneTimeline.usesFace(.takeover))
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
                    if k == .perch {
                        XCTAssertTrue(spots.contains { $0.kind == .button("shoo") }, "на окне: глаза — «кыш»")
                    } else {
                        XCTAssertTrue(spots.contains { $0.kind == .drag }, "\(k): тянуть можно")
                    }
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
        XCTAssertEqual(SceneLayout.hit(think, CGPoint(x: tg.target.midX, y: tg.target.midY))?.kind, .button("assistant"), "лицо — тоже помощник")
        XCTAssertEqual(SceneLayout.hit(think, CGPoint(x: tg.area!.minX + 30, y: tg.area!.maxY - 8))?.kind, .drag, "тянуть — за заголовок")
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
