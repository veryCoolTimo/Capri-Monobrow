import Foundation
import CoreGraphics

// Проход 2: окна с содержимым (`sessions`, `thinking`, `answer`), телепорт к терминалу (`reply`), горячие точки
// для кликов и перетаскивания и часы сцены с удержанием (`SceneClock`). Всё — чистые функции, как `SceneTimeline`.

// MARK: раскладка окон

extension SceneTimeline {
    /// Ширина строки ответа в окне `answer` (моно 11 pt, окно 340).
    public static let answerColumns = 40
    public static let answerMaxLines = 6
    public static let sessionsMaxRows = 4
    static let titleHeight: CGFloat = 22

    /// Размер окна сцены (для не-окон — глаза). Проход 3: лицо Capri — ≥ 55 % окна (таблица 3.2).
    public static func windowSize(_ kind: SceneKind, _ o: SceneOptions = SceneOptions()) -> CGSize {
        switch kind {
        case .window: windowSize
        case .sessions: CGSize(width: 340, height: titleHeight + faceHeight(kind) + 8 + 22 * CGFloat(max(1, min(sessionsMaxRows, o.rows))) + 6)
        case .thinking: CGSize(width: 260, height: titleHeight + faceHeight(kind))
        case .answer: CGSize(width: 340, height: titleHeight + faceHeight(kind) + 8 + 14 * CGFloat(max(1, min(answerMaxLines, o.answerLines))) + 36)
        case .music: CGSize(width: 340, height: 270)
        default: eyesSize
        }
    }

    /// Высота лица окна.
    static func faceHeight(_ kind: SceneKind) -> CGFloat {
        switch kind {
        case .sessions: 170
        case .thinking: 162
        case .answer: 190
        case .music: 212
        case .window: 188
        default: 0
        }
    }

    /// Лицо Capri в окне `kind`: во всю ширину (внутри рамки) сразу под заголовком.
    public static func faceIn(_ kind: SceneKind, window w: CGRect) -> CGRect {
        let top = w.maxY - titleHeight
        let minY = max(w.minY + 1, top - faceHeight(kind))
        return CGRect(x: w.minX + 1, y: minY, width: max(0, w.width - 2), height: max(0, top - minY))
    }

    /// Высота тёмной полосы-градиента внизу лица под подписью (0 — подписи на лице нет).
    public static func faceBand(_ kind: SceneKind) -> CGFloat {
        switch kind {
        case .music: 34
        case .thinking, .window: 30
        default: 0
        }
    }

    /// Градиент под подписью выше самой полосы (тёмный низ → прозрачно): во столько раз.
    public static let bandFade: CGFloat = 1.6

    /// Полоса подписи внизу лица (глобально); nil — нет.
    public static func bandRect(_ kind: SceneKind, window w: CGRect) -> CGRect? {
        let b = faceBand(kind)
        guard b > 0 else { return nil }
        let f = faceIn(kind, window: w)
        return CGRect(x: f.minX, y: f.minY, width: f.width, height: min(b, f.height))
    }

    /// Полоса глаз 2:1 по центру лица: в неё прилетает молния и из её линии раскрывается окно.
    static func strip(_ face: CGRect) -> CGRect {
        let h = face.height * 0.42, wd = min(face.width, h * 2)
        return CGRect(x: face.midX - wd / 2, y: face.midY - h / 2, width: wd, height: h)
    }

    /// Строка `i` окна сессий (под лицом, 22 pt).
    public static func rowRect(_ w: CGRect, _ i: Int) -> CGRect {
        let face = faceIn(.sessions, window: w)
        return CGRect(x: w.minX + 6, y: face.minY - 8 - 22 * CGFloat(i + 1), width: w.width - 12, height: 22)
    }

    /// Середина строки `i` текста ответа (под лицом, слева — отступ 12).
    public static func answerLine(_ w: CGRect, _ i: Int) -> CGPoint {
        let face = faceIn(.answer, window: w)
        return CGPoint(x: w.minX + 12, y: face.minY - 8 - 14 * CGFloat(i) - 7)
    }

    /// Кнопки окна ответа: с предложением — «отправить», «отмена»; всегда — «весь разговор».
    public static func answerButtons(_ w: CGRect, proposal: Bool) -> [(id: String, rect: CGRect)] {
        var out: [(String, CGRect)] = []
        var x = w.minX + 10
        let specs: [(String, CGFloat)] = (proposal ? [("send", 84), ("cancel", 64)] : []) + [("conversation", 110)]
        for (id, width) in specs {
            out.append((id, CGRect(x: x, y: w.minY + 8, width: width, height: 20)))
            x += width + 8
        }
        return out
    }

    /// Строка статуса окна `window` — полоса подписи внизу лица; кликабельна (основное окно).
    public static func statusRect(_ w: CGRect) -> CGRect {
        bandRect(.window, window: w) ?? CGRect(x: w.minX + 6, y: w.minY + 6, width: w.width - 12, height: 24)
    }

    /// «📌» — слева от «×».
    public static func pinRect(_ w: CGRect) -> CGRect {
        CGRect(x: w.maxX - 44, y: w.maxY - 20, width: 18, height: 18)
    }

    /// Заголовок окна (за него тянут) — без «📌» и «×».
    public static func titleRect(_ w: CGRect) -> CGRect {
        CGRect(x: w.minX, y: w.maxY - titleHeight, width: max(0, w.width - 48), height: titleHeight)
    }

    /// Лицо можно тянуть: всё, кроме полосы подписи с её градиентом.
    static func faceGrab(_ kind: SceneKind, window w: CGRect) -> CGRect {
        let f = faceIn(kind, window: w)
        let b = min(faceBand(kind) * bandFade, f.height)
        return CGRect(x: f.minX, y: f.minY + b, width: f.width, height: f.height - b)
    }

    /// Тело окна — всё под заголовком.
    static func bodyRect(_ w: CGRect) -> CGRect {
        CGRect(x: w.minX, y: w.minY, width: w.width, height: max(0, w.height - titleHeight))
    }

    /// Где подпись `reply`: правый край — слева от глаз.
    static func captionAnchor(_ eyes: CGRect) -> CGPoint { CGPoint(x: eyes.minX - 8, y: eyes.midY - 4) }
}

// MARK: таймлайны окон и ответа

extension SceneTimeline {
    /// Первый клип из списка, который есть (последний — без проверки: `look`/`close` есть всегда).
    static func pick(_ wants: [String], _ c: Set<String>) -> String {
        wants.dropLast().first { c.contains($0) } ?? wants.last ?? SceneClip.look
    }

    /// Клип, с которым окно раскрывается из линии глаз: у каждого окна свой.
    static func openingClip(_ kind: SceneKind, _ c: Set<String>) -> String {
        switch kind {
        case .sessions: pick([SceneClip.many, SceneClip.look], c)
        case .thinking: pick([SceneClip.slits, SceneClip.look], c)
        case .answer: pick([SceneClip.appear, SceneClip.look], c)
        case .music: pick([SceneClip.hairBob, SceneClip.slits, SceneClip.look], c)
        default: SceneClip.look
        }
    }

    /// Окна `sessions`, `thinking`, `answer`, `music`: прилёт (молния, раскрытие из линии) → своё «тело» с крупной
    /// Capri (лицо во всю ширину) → свёртывание в линию. Клипы и движение покоя — по стене (`o.lag`).
    static func boxed(_ kind: SceneKind, _ t: Double, _ g: SceneGeometry, _ c: Set<String>, _ o: SceneOptions) -> SceneFrame {
        let w = g.area ?? g.target
        let face = faceIn(kind, window: w)
        let arrive = arrival(kind, o)
        let exit = duration(kind, o) - foldDuration
        func has(_ clip: String) -> Bool { c.contains(clip) }
        if t < arrive {
            if kind == .answer && o.continued {
                // Ответ в том же окне, что «думает»: глитч-переход 0,3 с, сразу говорит маской.
                var f = SceneFrame(phase: "swap", eyes: face, clip: pick([SceneClip.faceTalk, SceneClip.appear, SceneClip.look], c),
                                   clipT: t, loop: false)
                f.face = SceneFace()
                f.glitch = t < 0.15 ? 3 : 2
                f.window = SceneWindow(rect: w, open: 1, chrome: true, melt: 0, typed: 0, caret: true)
                return f
            }
            return arriveWindow(t, g, w, face, c, clip: openingClip(kind, c))
        }
        if t >= exit { return fold(t - exit, g, w, face, c) }
        let k = t - arrive
        // Секунды стены от конца прилёта (с удержанием таймлайн стоит, Capri — нет).
        let kw = k + o.lag
        let H = max(1, face.height)
        var f = SceneFrame(phase: kind.rawValue, eyes: face)
        f.face = SceneFace()
        f.wallClock = true
        var win = SceneWindow(rect: w, open: 1, chrome: true, melt: 0, typed: 0, caret: Int(t * 2.5) % 2 == 0)
        switch kind {
        case .sessions:
            // Много глаз доигрывают открытие; курсор на строке — наезд в глаз, глаза к строке; ≥ 3 ждут — оскал и
            // взрыв глаз; иначе камера ведёт по глазам туда-обратно, взгляд плывёт вниз по строкам.
            let since = kw + arrive - o.hoverAt
            if kw < 0.6, has(SceneClip.many) {
                f.clip = SceneClip.many; f.clipT = 0.4 + kw; f.loop = false
            } else if let i = o.hoverRow, since >= 0 {
                f.clip = pick([SceneClip.eyeZoom, SceneClip.look], c)
                f.clipT = f.clip == SceneClip.eyeZoom ? since * 2.8 : kw
                f.loop = f.clip != SceneClip.eyeZoom
                f.face?.shift.dy = -0.04 * CGFloat(i + 1)
                f.face?.zoom = 1.04
                f.glitch = since < 2.0 / 24 ? 1 : 0
            } else if o.waiting >= 3, has(SceneClip.faceGrin) {
                f.clip = SceneClip.faceGrin; f.loop = false
                f.clipT = 2.17 + max(0, kw - 0.6).truncatingRemainder(dividingBy: 1.0)
                f.face?.zoom = 1 + 0.03 * CGFloat(abs(sin(kw * 3)))
            } else if o.waiting >= 3, has(SceneClip.crazy) {
                f.clip = SceneClip.crazy; f.clipT = kw
            } else {
                f.clip = pick([SceneClip.faceScan, SceneClip.look], c)
                let scan = f.clip == SceneClip.faceScan
                f.clipMode = scan ? .bounce : .loop
                f.clipT = scan ? kw * 0.5 : kw
                // Камера плывёт вбок и вниз, к строкам (у окна статуса — зеркало и вверх-вниз).
                f.face?.shift = CGVector(dx: 0.02 * sin(kw * 0.9), dy: -0.02 * (1 - cos(kw * 0.7)))
                f.glitch = o.hoverAt > 0 && since >= 0 && since < 2.0 / 24 ? 1 : idleGlitch(t)
            }
            // Строки появляются по одной, 0,08 с.
            win.typed = min(max(1, min(sessionsMaxRows, o.rows)), Int(kw / 0.08) + 1)
        case .thinking:
            // Голова набок, взгляд в сторону и обратно (×0,5), наклон −2°, медленно плывёт; сканлайн по кругу.
            if has(SceneClip.sideLook) {
                f.clip = SceneClip.sideLook; f.clipT = kw * 0.5; f.clipMode = .bounce
                f.face?.tilt = -2
                f.face?.shift.dy = CGFloat(sin(2 * .pi * 0.25 * kw)) * 3 / H
                f.face?.zoom = 1.02
            } else {
                // Щёлки (держит последний кадр), каждые 1,5 с — закрыла и снова щёлки.
                let cyc = kw.truncatingRemainder(dividingBy: 1.5)
                let shut = has(SceneClip.shut) ? SceneClip.shut : SceneClip.close
                let slits = has(SceneClip.slits) ? SceneClip.slits : SceneClip.close
                if cyc < 0.35 { f.clip = shut; f.clipT = cyc } else { f.clip = slits; f.clipT = cyc - 0.35 }
                f.loop = false
            }
            win.scan = CGFloat(kw.truncatingRemainder(dividingBy: 1.6) / 1.6)
            win.typed = Int(kw * 3) % 4
        case .answer:
            // Говорит маской, пока печатается ответ (18 букв/с), с лёгким кивком по слогам; напечатано — рот закрыт.
            // Печать — по стене: с курсором на лице текст не встаёт.
            let typed = min(o.answerChars, Int(kw * 18))
            win.typed = typed
            let typingEnd = Double(o.answerChars) / 18
            if typed < o.answerChars {
                f.clip = pick([SceneClip.faceTalk, SceneClip.talk, SceneClip.look], c); f.clipT = kw
                if f.clip == SceneClip.faceTalk { f.face?.shift.dy = syllableNod(kw, height: H) }
            } else if has(SceneClip.faceTalk) {
                f.clip = SceneClip.faceTalk; f.clipT = 0; f.loop = false
            } else {
                f.clip = has(SceneClip.shut) ? SceneClip.shut : SceneClip.look
                f.clipT = kw - typingEnd; f.loop = f.clip == SceneClip.look
            }
            if let b = o.burstAt, t >= b {
                // «Отправлено»: кивок и довольные ^^ (3 с) с кольцом от лица; без клипа — взрыв глаз 1 с.
                let s = t - b
                if has(SceneClip.faceNod), s < 3.0 {
                    f.clip = SceneClip.faceNod; f.clipT = s; f.loop = false
                    f.glitch = s < 0.15 ? 1 : 0
                    if s < 0.6 { f.rings = [SceneRing(center: center(face), progress: CGFloat(s / 0.6))] }
                } else if !has(SceneClip.faceNod), s < 1.0 {
                    f.clip = has(SceneClip.burst) ? SceneClip.burst : SceneClip.look
                    f.clipT = s; f.loop = false
                    f.glitch = s < 0.3 ? 2 : 0
                }
            }
        case .music:
            music(&f, &win, t, face, c, o)
        default:
            break
        }
        f.window = win
        return f
    }

    /// Прилёт в окно: уход из notch, молния к полосе глаз посреди лица, появление, рамка растёт из линии, лицо
    /// раскрывается вместе с ней.
    static func arriveWindow(_ t: Double, _ g: SceneGeometry, _ w: CGRect, _ face: CGRect, _ c: Set<String>, clip: String) -> SceneFrame {
        let eyes = strip(face)
        let line = CGRect(x: eyes.minX, y: eyes.midY - 1, width: eyes.width, height: 2)
        switch t {
        case ..<0.25: return out("out", at: g.home, t, len: 0.25, c)
        case ..<0.4: return jump("jump", from: g.home, to: eyes, t - 0.25, len: 0.15)
        case ..<0.6: return into("in", at: eyes, t - 0.4, len: 0.2, c)
        default:
            let p = CGFloat(min(1, (t - 0.6) / 0.4))
            return unfoldFrame(p, w, face, line, clip: clip, clipT: t - 0.6, loop: clip == SceneClip.look)
        }
    }

    /// Кадр раскрытия/свёртывания (`p` 0…1): рамка из `unfoldRect`; лицо — полоска по линии, пока растёт линия
    /// (не шире её), потом раскрывается по высоте вместе с окном.
    static func unfoldFrame(_ p: CGFloat, _ w: CGRect, _ face: CGRect, _ line: CGRect, phase: String = "unfold",
                            clip: String, clipT: Double, loop: Bool) -> SceneFrame {
        let rect = unfoldRect(w, line: line, p)
        let eyes = p < 0.5 ? CGRect(x: rect.minX, y: face.minY, width: rect.width, height: face.height) : face
        var f = SceneFrame(phase: phase, eyes: eyes, clip: clip, clipT: clipT, loop: loop)
        f.face = SceneFace()
        f.squash = p < 0.5 ? 0.06 : 0.06 + 0.94 * (p - 0.5) * 2
        f.glitch = 1
        f.window = SceneWindow(rect: rect, open: p, chrome: false, melt: 0, typed: 0, caret: false)
        return f
    }

    /// Рамка при раскрытии (`p` 0…1): сначала линия растёт в ширину, потом окно — в высоту.
    static func unfoldRect(_ w: CGRect, line: CGRect, _ p: CGFloat) -> CGRect {
        if p < 0.5 {
            let k = p * 2, wd = line.width + (w.width - line.width) * k
            return CGRect(x: w.midX - wd / 2, y: line.midY - 1, width: wd, height: 2)
        }
        let k = (p - 0.5) * 2, h = 2 + (w.height - 2) * k
        return CGRect(x: w.minX, y: line.midY - (line.midY - w.minY) * k - 1, width: w.width, height: h).intersection(w)
    }

    /// Уход окна (0,9 с): сворачивается в линию глаз (раскрытие наоборот), глаза закрываются, молния домой.
    static func fold(_ k: Double, _ g: SceneGeometry, _ w: CGRect, _ face: CGRect, _ c: Set<String>) -> SceneFrame {
        let eyes = strip(face)
        let line = CGRect(x: eyes.minX, y: eyes.midY - 1, width: eyes.width, height: 2)
        switch k {
        case ..<0.5:
            let p = CGFloat(1 - k / 0.5)
            var f = unfoldFrame(p, w, face, line, phase: "fold", clip: pick([SceneClip.close, SceneClip.look], c), clipT: k, loop: false)
            f.glitch = k < 0.25 ? 1 : 3
            return f
        case ..<0.65: return jump("back", from: line, to: g.home, k - 0.5, len: 0.15)
        default:
            var f = into("home", at: g.home, k - 0.65, len: 0.25, c)
            f.glitch = 2
            return f
        }
    }

    /// Ответ сессии через Capri: телепорт на окно терминала (лицо 200×125), решительно смотрит в терминал
    /// (наезд в глаз) с кольцом «отправила», оскал → зажмурилась → взрыв глаз, печатает «→ имя ✓», домой.
    /// Не дошло — `crazy` и глитч 3.
    static func reply(_ t: Double, _ g: SceneGeometry, _ c: Set<String>, _ o: SceneOptions) -> SceneFrame {
        var f: SceneFrame
        switch t {
        case ..<0.3: return out("out", at: g.home, t, len: 0.3, c)
        case ..<0.5: return jump("jump", from: g.home, to: g.target, t - 0.3, len: 0.2)
        case ..<0.9: f = into("in", at: g.target, t - 0.5, len: 0.4, c)
        case ..<1.5:
            let k = t - 0.9
            f = SceneFrame(phase: "sent", eyes: g.target, clip: pick([SceneClip.eyeZoom, SceneClip.burst, SceneClip.look], c),
                           clipT: k, loop: false)
            if f.clip == SceneClip.eyeZoom { f.clipT = k * 2.2 }
            f.glitch = k < 0.1 ? 1 : 0
            f.rings = [SceneRing(center: center(g.target), progress: CGFloat(min(1, k / 0.6)))]
        case ..<3.4:
            // Покой по стене (`o.lag`): с курсором на лице таймлайн стоит, клип, наезд и подпись — нет.
            let k = t - 1.5 + o.lag
            let failed = o.failedAt.map { t >= $0 } ?? false
            // Взгляд вниз, в окно терминала.
            f = SceneFrame(phase: "watch", eyes: g.target.offsetBy(dx: 0, dy: -3))
            f.wallClock = true
            if failed, let at = o.failedAt {
                f.clip = pick([SceneClip.crazy, SceneClip.look], c); f.clipT = t - at + o.lag
                f.glitch = f.clipT < 0.5 ? 3 : idleGlitch(k)
            } else if c.contains(SceneClip.faceGrin) {
                // Оскал с 0,9 с клипа: зажмурилась к ~2,6 с сцены, взрыв глаз к ~2,8.
                f.clip = SceneClip.faceGrin; f.clipT = 0.9 + k; f.loop = false
                f.glitch = abs(f.clipT - 2.1) < 0.05 ? 2 : 0
                f.face = SceneFace(zoom: 1 + 0.04 * CGFloat(min(1, k / 1.9)))
            } else {
                f.clip = pick([SceneClip.slits, SceneClip.look], c); f.clipT = k
                f.loop = f.clip == SceneClip.look
            }
            f.caption = SceneCaption(anchor: captionAnchor(g.target), typed: min(o.caption, Int(k * 22)), failed: failed)
        case ..<3.7: f = out("leave", at: g.target, t - 3.4, len: 0.3, c)
        case ..<3.85: return jump("back", from: g.target, to: g.home, t - 3.7, len: 0.15)
        default:
            var h = into("home", at: g.home, t - 3.85, len: 0.15, c)
            h.glitch = 2
            return h
        }
        if f.face == nil { f.face = SceneFace() }
        return f
    }
}

// MARK: горячие точки

/// Кликабельный прямоугольник сцены (глобальные координаты). Всё вне них — сквозь панель.
public struct SceneHotspot: Equatable {
    public enum Kind: Equatable {
        /// Тянуть: глаза и заголовок.
        case drag
        case close
        case pin
        /// Строка окна сессий.
        case row(Int)
        /// Кнопка: `status`, `assistant`, `send`, `cancel`, `conversation`.
        case button(String)
    }

    public var kind: Kind
    public var rect: CGRect

    public init(_ kind: Kind, _ rect: CGRect) { self.kind = kind; self.rect = rect }
}

extension SceneLayout {
    /// Горячие точки кадра — только в спокойной фазе и не после обрыва (в перелёте кликать не во что).
    /// Порядок — приоритет попадания: «×», «📌», кнопки/строки, потом перетаскивание.
    public static func hotspots(_ kind: SceneKind, t: Double, geometry g: SceneGeometry, clips: Set<String> = [],
                                options o: SceneOptions = SceneOptions(), abortedAt: Double? = nil) -> [SceneHotspot] {
        guard abortedAt == nil, let calm = SceneTimeline.calm(kind, o), calm.contains(t) else { return [] }
        let f = SceneTimeline.frame(kind, t: t, geometry: g, clips: clips, options: o)
        guard let eyes = f.eyes else { return [] }
        let grab = SceneHotspot(.drag, eyes.insetBy(dx: -4, dy: -4))
        guard kind.boxed else {
            guard kind != .takeover else { return [] }
            // Под глазами — ⏮ ⏯ ⏭, пока на глаза навели (и музыка известна).
            let controls = o.musicKnown && o.controls ? SceneTimeline.eyeControls(g.target).map { SceneHotspot(.button($0.id), $0.rect) } : []
            return controls + [grab]
        }
        guard let w = f.window?.rect, f.window?.chrome == true else { return [grab] }
        var out = [SceneHotspot(.close, SceneTimeline.closeRect(w).insetBy(dx: -3, dy: -2)),
                   SceneHotspot(.pin, SceneTimeline.pinRect(w).insetBy(dx: -3, dy: -2))]
        switch kind {
        case .window:
            out.append(SceneHotspot(.button("status"), SceneTimeline.statusRect(w)))
        case .sessions:
            for i in 0..<min(SceneTimeline.sessionsMaxRows, o.rows) {
                out.append(SceneHotspot(.row(i), SceneTimeline.rowRect(w, i)))
            }
        case .thinking:
            // Всё окно под заголовком — помощник; тянуть — только за заголовок.
            out.append(SceneHotspot(.button("assistant"), SceneTimeline.bodyRect(w)))
        case .answer:
            for b in SceneTimeline.answerButtons(w, proposal: o.proposal) { out.append(SceneHotspot(.button(b.id), b.rect)) }
        case .music:
            for b in SceneTimeline.musicButtons(w) { out.append(SceneHotspot(.button(b.id), b.rect)) }
        default:
            break
        }
        out.append(SceneHotspot(.drag, SceneTimeline.titleRect(w)))
        // Лицо тоже тянется — кроме полосы подписи (там текст/статус).
        if kind != .thinking { out.append(SceneHotspot(.drag, SceneTimeline.faceGrab(kind, window: w))) }
        return out
    }

    /// Что под точкой `p` (первое по порядку).
    public static func hit(_ spots: [SceneHotspot], _ p: CGPoint) -> SceneHotspot? {
        spots.first { $0.rect.contains(p) }
    }

    /// Окно сцены `kind` в правом нижнем углу.
    public static func windowForm(_ visible: CGRect, kind: SceneKind, options o: SceneOptions = SceneOptions()) -> CGRect {
        corner(visible, size: SceneTimeline.windowSize(kind, o))
    }

    /// То же окно другого размера, с тем же правым верхним углом (ответ на месте окна «думает», куда бы его ни отнесли).
    public static func resized(_ w: CGRect, to size: CGSize, visible: CGRect) -> CGRect {
        clamp(CGRect(x: w.maxX - size.width, y: w.maxY - size.height, width: size.width, height: size.height), to: visible)
    }

    /// Куда сесть у окна терминала: на верхний край (`onWindow`) размером `size`, не помещается — полосой глаз
    /// `eyesSize` на край; и та не помещается — полосой глаз внутрь, у правого верхнего угла (крупное лицо
    /// закрыло бы терминал).
    public static func atTerminal(_ window: CGRect, visible: CGRect, size: CGSize = SceneTimeline.eyesSize) -> CGRect {
        if let on = onWindow(window, visible: visible, size: size) { return on }
        let small = SceneTimeline.eyesSize
        if size != small, let on = onWindow(window, visible: visible, size: small) { return on }
        let inside = CGRect(x: window.maxX - 24 - small.width, y: window.maxY - 34 - small.height, width: small.width, height: small.height)
        return clamp(inside, to: visible)
    }
}

// MARK: перенос текста ответа

public enum SceneText {
    /// Перенос по словам в `columns` знаков, не больше `maxLines` строк (последняя — с «…», если не влезло).
    /// Пустые строки схлопываются, markdown-разметка (`**`, `` ` ``, `#`) убирается.
    public static func wrap(_ text: String, columns: Int = SceneTimeline.answerColumns,
                            maxLines: Int = SceneTimeline.answerMaxLines) -> [String] {
        let clean = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        var out: [String] = []
        for para in clean.split(whereSeparator: \.isNewline) {
            var p = para.trimmingCharacters(in: .whitespaces)
            while p.hasPrefix("#") { p.removeFirst() }
            var line = ""
            for word in p.split(separator: " ") {
                var w = String(word)
                // Слово длиннее строки — режем.
                while w.count > columns {
                    if !line.isEmpty { out.append(line); line = "" }
                    out.append(String(w.prefix(columns)))
                    w = String(w.dropFirst(columns))
                }
                if line.isEmpty { line = w } else if line.count + 1 + w.count <= columns { line += " " + w } else {
                    out.append(line)
                    line = w
                }
            }
            if !line.isEmpty { out.append(line) }
            if out.count > maxLines { break }
        }
        guard out.count > maxLines else { return out }
        out = Array(out.prefix(maxLines))
        out[maxLines - 1] = String(out[maxLines - 1].prefix(columns - 1)) + "…"
        return out
    }
}

// MARK: часы сцены

/// Время сцены с удержанием: пока мышь над горячей точкой, сцену тянут, ≤ 3 с после последнего касания или
/// закреплено «📌» (до 10 мин), время таймлайна стоит внутри спокойной фазы; клип глаз при этом идёт по стене.
/// `wall` — секунды от начала сцены.
public struct SceneClock: Equatable {
    public static let grace = 3.0
    public static let pinCap = 600.0
    /// Потолок удержания наведением: курсор, забытый на глазах или окне, не держит сцену (и её кадры) вечно.
    public static let holdCap = 60.0

    /// Сколько всего простояли (таймлайн отстаёт от стены).
    public private(set) var held = 0.0
    /// Стена, когда таймлайн встал (nil — идёт).
    public private(set) var frozenAt: Double?
    /// Мышь над горячей точкой или идёт перетаскивание.
    public private(set) var holding = false
    /// Стена, когда началось нынешнее наведение.
    public private(set) var holdingSince: Double?
    public private(set) var releasedAt: Double?
    public private(set) var pinnedAt: Double?

    public init() {}

    public var frozen: Bool { frozenAt != nil }
    public var pinned: Bool { pinnedAt != nil }

    /// Время таймлайна.
    public func time(_ wall: Double) -> Double { (frozenAt ?? wall) - held }

    /// Насколько таймлайн отстаёт от стены (сдвиг клипа в спокойной фазе — глаза не замирают).
    public func lag(_ wall: Double) -> Double { wall - time(wall) }

    /// Наведение/перетаскивание началось или кончилось. `calm` — таймлайн сейчас в спокойной фазе (вне её не встаём).
    public mutating func hold(_ on: Bool, wall: Double, calm: Bool) {
        if on {
            if !holding { holdingSince = wall }
            holding = true
            if frozenAt == nil, calm { frozenAt = wall }
        } else if holding {
            holding = false
            holdingSince = nil
            releasedAt = wall
        }
    }

    /// «📌»: держать до «×» (или 10 мин); снятие — как отпустили мышь.
    public mutating func pin(_ on: Bool, wall: Double, calm: Bool) {
        if on {
            pinnedAt = wall
            if frozenAt == nil, calm { frozenAt = wall }
        } else if pinnedAt != nil {
            pinnedAt = nil
            releasedAt = wall
        }
    }

    /// Пересчёт: истёк потолок «📌» или 3 с после касания — таймлайн снова идёт. true — что-то изменилось.
    @discardableResult
    public mutating func update(_ wall: Double) -> Bool {
        var changed = false
        if holding, pinnedAt == nil, let h = holdingSince, wall - h >= Self.holdCap {
            // Минута наведения без движения — как будто мышь ушла (новое движение над точкой снова держит).
            holding = false
            holdingSince = nil
            releasedAt = h + Self.holdCap - Self.grace
            changed = true
        }
        if let p = pinnedAt, wall - p >= Self.pinCap {
            pinnedAt = nil
            releasedAt = p + Self.pinCap - Self.grace
            changed = true
        }
        if let f = frozenAt, !holding, pinnedAt == nil, wall - (releasedAt ?? f) >= Self.grace {
            held += wall - f
            frozenAt = nil
            changed = true
        }
        return changed
    }

    /// Обрыв или «×»: таймлайн сразу идёт дальше, без удержания и «📌».
    public mutating func release(_ wall: Double) {
        if let f = frozenAt { held += wall - f }
        frozenAt = nil
        holding = false
        holdingSince = nil
        pinnedAt = nil
        releasedAt = nil
    }

    /// Когда снова звать `update` (стена); nil — не нужно (идёт). Держат мышью — потолок `holdCap`.
    public func nextCheck() -> Double? {
        guard let f = frozenAt else { return nil }
        if let p = pinnedAt { return p + Self.pinCap }
        if holding { return (holdingSince ?? f) + Self.holdCap }
        return (releasedAt ?? f) + Self.grace
    }

    /// Сколько стены до конца сцены длиной `end` (таймлайн); nil — стоит.
    public func remaining(_ wall: Double, end: Double) -> Double? {
        frozen ? nil : max(0, end - time(wall))
    }
}

// MARK: окно музыки

/// Состояние окна музыки.
public enum SceneMusicState: String, Equatable {
    /// «ищу «X»…» — ждём плеер.
    case searching
    case playing
    case paused
    /// Не нашла / не включилось / нет доступа.
    case failed
    /// Просто сообщение (нужен ключ Spotify).
    case info
}

/// Смена состояния окна музыки: `t` — время таймлайна, `wall` — стена (секунды от начала сцены; с удержанием
/// таймлайн отстаёт — клип нового состояния начинается с момента клика, а не «с середины»).
public struct SceneMusicMark: Equatable {
    public var t: Double
    public var wall: Double
    public var state: SceneMusicState

    public init(t: Double, wall: Double? = nil, state: SceneMusicState) {
        self.t = t; self.wall = wall ?? t; self.state = state
    }
}

extension SceneTimeline {
    /// Кнопки окна музыки ⏮ ⏯ ⏭ — по центру полосы под лицом.
    public static func musicButtons(_ w: CGRect) -> [(id: String, rect: CGRect)] {
        let bw: CGFloat = 44, gap: CGFloat = 12, bh: CGFloat = 24
        let face = faceIn(.music, window: w)
        let x0 = w.midX - (bw * 3 + gap * 2) / 2
        let y = w.minY + max(2, (face.minY - w.minY - bh) / 2)
        return MusicCommand.buttons.enumerated().map { i, id in
            (id, CGRect(x: x0 + CGFloat(i) * (bw + gap), y: y, width: bw, height: bh))
        }
    }

    /// Строка «♪ Artist — Track» окна музыки: на полосе внизу лица (середина строки — 13 pt от низа лица).
    public static func musicLine(_ w: CGRect) -> CGPoint {
        let face = faceIn(.music, window: w)
        return CGPoint(x: face.minX + 12, y: face.minY + 13)
    }

    /// ⏮ ⏯ ⏭ под глазами на столе (телепорт, вайб, у терминала) — вплотную к глазам, чтобы курсор с глаз
    /// переходил на кнопки, не теряя наведения.
    public static func eyeControls(_ eyes: CGRect) -> [(id: String, rect: CGRect)] {
        let bw: CGFloat = 28, gap: CGFloat = 6
        let x0 = eyes.midX - (bw * 3 + gap * 2) / 2
        return MusicCommand.buttons.enumerated().map { i, id in
            (id, CGRect(x: x0 + CGFloat(i) * (bw + gap), y: eyes.minY - 4 - 20, width: bw, height: 20))
        }
    }

    /// Состояние окна музыки в момент `t` (последняя смена ≤ t; без смен — играет) и смена, с которой оно началось.
    public static func musicState(at t: Double, _ marks: [SceneMusicMark]) -> (state: SceneMusicState, mark: SceneMusicMark?, previous: SceneMusicState?) {
        let past = marks.filter { $0.t <= t }
        guard let last = past.last else { return (.playing, nil, nil) }
        return (last.state, last, past.dropLast().last?.state)
    }

    /// Покой окна музыки (лицо во всю ширину): ищет — голова набок туда-обратно + сканлайн; пошёл трек — наезд в
    /// глаз, потом по плечи в волосах кивает в такт (сдвиг, наклон ±1,5° на 2 доли, «удар» масштабом на долю, на
    /// сильную — глитч и вспышка) с нотами у краёв; пауза — прикрыла глаза (`face_nod`); снова играет — открыла
    /// глаза; не вышло — `crazy` + глитч 3. Фолбэки — старые клипы глаз.
    static func music(_ f: inout SceneFrame, _ win: inout SceneWindow, _ t: Double, _ face: CGRect, _ c: Set<String>, _ o: SceneOptions) {
        let wall = t + o.lag
        let (state, mark, previous) = musicState(at: t, o.musicMarks)
        // Секунды стены от смены состояния (без смен — от конца прилёта).
        let since = max(0, wall - (mark?.wall ?? arrival(.music, o)))
        func has(_ clip: String) -> Bool { c.contains(clip) }
        let H = max(1, face.height)
        f.loop = false
        f.clipT = since
        win.typed = Int(since * 30)
        switch state {
        case .searching:
            // Тот же взгляд в сторону, что у «думает», но зеркально, крупнее (глаза) и без наклона набок — плывёт.
            if has(SceneClip.sideLook) {
                f.clip = SceneClip.sideLook; f.clipT = since * 0.6; f.clipMode = .bounce
                f.face?.mirror = true
                f.face?.zoom = 1.18
                f.face?.shift = CGVector(dx: 0.03 * sin(since * 1.1), dy: 0.06)
            } else {
                f.clip = has(SceneClip.slits) ? SceneClip.slits : SceneClip.close
            }
            win.scan = CGFloat(since.truncatingRemainder(dividingBy: 1.6) / 1.6)
            win.typed = 200 + Int(since * 3) % 4
        case .playing:
            let resumed = previous == .paused
            let intro: Double
            if resumed {
                // Снова играет: открывает глаза (конец `face_nod`) или появление.
                intro = has(SceneClip.faceNod) ? 0.5 : 0.6
                if since < intro {
                    f.clip = pick([SceneClip.faceNod, SceneClip.appear, SceneClip.look], c)
                    f.clipT = f.clip == SceneClip.faceNod ? 2.5 + since : since
                    f.loop = f.clip == SceneClip.look
                    return
                }
            } else {
                // Трек пошёл: наезд в глаз (или взрыв глаз) с глитчем в начале.
                intro = has(SceneClip.eyeZoom) ? 0.8 : 1.0
                if since < intro {
                    f.clip = pick([SceneClip.eyeZoom, SceneClip.burst, SceneClip.look], c)
                    f.clipT = f.clip == SceneClip.eyeZoom ? since * 1.7 : since
                    f.loop = f.clip == SceneClip.look
                    // Глитч только на входе — наезд должен быть виден.
                    f.glitch = since < 0.12 ? 2 : 0
                    return
                }
            }
            let k = since - intro
            f.notes = musicNotes(k, face)
            if has(SceneClip.hairBob) {
                f.clip = SceneClip.hairBob; f.clipT = k; f.loop = true
                f.face = groove(k, height: H)
                if strongBeat(k) { f.glitch = 1 }
            } else {
                // Старые глаза: кивает, на долю — щёлки.
                f.face?.shift.dy = -nod(k, amplitude: 4) / H
                f.clip = onBeat(k) && has(SceneClip.slits) ? SceneClip.slits : SceneClip.look
                f.clipT = onBeat(k) ? 0.4 : k
                f.loop = true
            }
        case .paused:
            // Прикрыла глаза: кивок из `face_nod` до довольных закрытых глаз и держит.
            if has(SceneClip.faceNod) {
                f.clip = SceneClip.faceNod; f.clipT = min(1.3 + since, 1.9)
                f.face?.shift.dy = -CGFloat(min(1, since / 0.4)) * 4 / H
            } else {
                f.clip = has(SceneClip.close) ? SceneClip.close : SceneClip.look
            }
        case .failed:
            f.clip = has(SceneClip.crazy) ? SceneClip.crazy : SceneClip.look
            f.loop = true
            f.glitch = since < 0.5 ? 3 : idleGlitch(t)
        case .info:
            f.clip = pick([SceneClip.hairBob, SceneClip.look], c)
            f.clipT = since
            f.loop = true
            f.glitch = idleGlitch(t)
        }
    }

    /// Доля в момент `k`: номер (дробный) и секунды от начала доли.
    static func beatPhase(_ k: Double) -> (beat: Double, inBeat: Double) {
        let beatLen = 60 / bpm
        let beat = k / beatLen
        return (beat, (beat - floor(beat)) * beatLen)
    }

    /// Кивок по слогам, пока маска говорит (окно ответа): 5 Гц, ±1,5 pt (доля высоты лица `height`).
    static func syllableNod(_ k: Double, height: CGFloat) -> CGFloat {
        CGFloat(sin(2 * .pi * 5 * k)) * 1.5 / max(1, height)
    }

    /// Кивок в такт (`bpm`): вниз на долю (6 pt), наклон ±1,5° с периодом 2 доли, «удар» масштабом 1,00 → 1,04
    /// на каждую долю (спад 0,15 с), на сильную долю (каждая 4-я) — вспышка яркости.
    public static func groove(_ k: Double, height: CGFloat) -> SceneFace {
        let (beat, inBeat) = beatPhase(k)
        let hit = CGFloat(max(0, 1 - inBeat / 0.15))
        var s = SceneFace()
        s.shift.dy = -nod(k, amplitude: 6) / max(1, height)
        s.shift.dx = CGFloat(sin(.pi * beat)) * 0.012
        s.tilt = 1.5 * sin(.pi * beat)
        s.zoom = 1 + 0.04 * hit
        s.pulse = Int(floor(beat)) % 4 == 0 ? hit : 0
        return s
    }

    /// Сильная доля (каждая 4-я), первые 0,1 с — больше шага 12 fps, кадр в неё всегда попадёт.
    static func strongBeat(_ k: Double) -> Bool {
        let (beat, inBeat) = beatPhase(k)
        return Int(floor(beat)) % 4 == 0 && inBeat < 0.1
    }

    /// Ноты у краёв лица окна музыки (не у глаз): раз в долю, живут 1,2 с, поднимаются на 40 pt.
    static func musicNotes(_ k: Double, _ face: CGRect) -> [SceneNote] {
        let beatLen = 60 / bpm
        var out: [SceneNote] = []
        let first = max(0, Int((k - 1.2) / beatLen) + 1)
        for i in first...max(first, Int(k / beatLen)) where Double(i) * beatLen <= k {
            let age = (k - Double(i) * beatLen) / 1.2
            guard age < 1 else { continue }
            let inset = 18 + CGFloat(TickNoise.unit(i, 52)) * 16
            let x = i % 2 == 0 ? face.minX + inset : face.maxX - inset
            out.append(SceneNote(center: CGPoint(x: x + CGFloat(sin(age * 6)) * 3, y: face.minY + 46 + CGFloat(age) * 40),
                                 alpha: CGFloat(age < 0.2 ? age / 0.2 : 1 - (age - 0.2) / 0.8), glyph: i % 3))
        }
        return out
    }
}
