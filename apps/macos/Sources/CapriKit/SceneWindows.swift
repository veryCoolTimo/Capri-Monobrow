import Foundation
import CoreGraphics

// Проход 2: окна с содержимым (`sessions`, `thinking`, `answer`), телепорт к терминалу (`reply`), горячие точки
// для кликов и перетаскивания и часы сцены с удержанием (`SceneClock`). Всё — чистые функции, как `SceneTimeline`.

// MARK: раскладка окон

extension SceneTimeline {
    /// Ширина строки ответа в окне `answer` (моно 11 pt, окно 300).
    public static let answerColumns = 40
    public static let answerMaxLines = 6
    public static let sessionsMaxRows = 4
    static let titleHeight: CGFloat = 22

    /// Размер окна сцены (для не-окон — глаза).
    public static func windowSize(_ kind: SceneKind, _ o: SceneOptions = SceneOptions()) -> CGSize {
        switch kind {
        case .window: windowSize
        case .sessions: CGSize(width: 300, height: 98 + 22 * CGFloat(max(1, min(sessionsMaxRows, o.rows))))
        case .thinking: CGSize(width: 220, height: 110)
        case .answer: CGSize(width: 300, height: 116 + 14 * CGFloat(max(1, min(answerMaxLines, o.answerLines))))
        case .music: CGSize(width: 280, height: 124)
        default: eyesSize
        }
    }

    /// Глаза внутри окна сцены `kind`: под заголовком, по центру; размер у каждого окна свой.
    public static func eyesIn(_ kind: SceneKind, window w: CGRect) -> CGRect {
        let h: CGFloat
        switch kind {
        case .sessions: h = 56
        case .thinking: h = 48
        case .answer, .music: h = 40
        default: return eyesInWindow(w)
        }
        return CGRect(x: w.midX - h, y: w.maxY - titleHeight - 6 - h, width: h * 2, height: h)
    }

    /// Строка `i` окна сессий (под глазами, 22 pt).
    public static func rowRect(_ w: CGRect, _ i: Int) -> CGRect {
        let eyes = eyesIn(.sessions, window: w)
        return CGRect(x: w.minX + 6, y: eyes.minY - 6 - 22 * CGFloat(i + 1), width: w.width - 12, height: 22)
    }

    /// Середина строки `i` текста ответа (слева — отступ 12).
    public static func answerLine(_ w: CGRect, _ i: Int) -> CGPoint {
        let eyes = eyesIn(.answer, window: w)
        return CGPoint(x: w.minX + 12, y: eyes.minY - 6 - 14 * CGFloat(i) - 7)
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

    /// Строка статуса окна `window` — кликабельна (основное окно).
    public static func statusRect(_ w: CGRect) -> CGRect {
        CGRect(x: w.minX + 6, y: w.minY + 6, width: w.width - 12, height: 24)
    }

    /// «📌» — слева от «×».
    public static func pinRect(_ w: CGRect) -> CGRect {
        CGRect(x: w.maxX - 44, y: w.maxY - 20, width: 18, height: 18)
    }

    /// Заголовок окна (за него тянут) — без «📌» и «×».
    public static func titleRect(_ w: CGRect) -> CGRect {
        CGRect(x: w.minX, y: w.maxY - titleHeight, width: max(0, w.width - 48), height: titleHeight)
    }

    /// Где подпись `reply`: правый край — слева от глаз.
    static func captionAnchor(_ eyes: CGRect) -> CGPoint { CGPoint(x: eyes.minX - 8, y: eyes.midY - 4) }
}

// MARK: таймлайны окон и ответа

extension SceneTimeline {
    /// Клип, с которым окно раскрывается из линии глаз: у каждого окна свой.
    static func openingClip(_ kind: SceneKind, _ c: Set<String>) -> String {
        let want: String
        switch kind {
        case .sessions: want = SceneClip.many
        case .thinking: want = SceneClip.slits
        case .answer: want = SceneClip.appear
        case .music: want = SceneClip.slits
        default: want = SceneClip.look
        }
        return c.contains(want) ? want : SceneClip.look
    }

    /// Окна `sessions`, `thinking`, `answer`: прилёт (молния, раскрытие из линии) → своё «тело» → свёртывание в линию.
    static func boxed(_ kind: SceneKind, _ t: Double, _ g: SceneGeometry, _ c: Set<String>, _ o: SceneOptions) -> SceneFrame {
        let w = g.area ?? g.target
        let eyes = eyesIn(kind, window: w)
        let arrive = arrival(kind, o)
        let exit = duration(kind, o) - foldDuration
        if t < arrive {
            if kind == .answer && o.continued {
                // Ответ в том же окне, что «думает»: глитч-переход 0,3 с, глаза открываются (`appear`).
                var f = SceneFrame(phase: "swap", eyes: eyes, clip: c.contains(SceneClip.appear) ? SceneClip.appear : SceneClip.look,
                                   clipT: t, loop: false)
                f.glitch = t < 0.15 ? 3 : 2
                f.window = SceneWindow(rect: w, open: 1, chrome: true, melt: 0, typed: 0, caret: true)
                return f
            }
            return arriveWindow(t, g, w, eyes, c, clip: openingClip(kind, c))
        }
        if t >= exit { return fold(t - exit, g, w, eyes, c) }
        let k = t - arrive
        var f = SceneFrame(phase: kind.rawValue, eyes: eyes)
        var win = SceneWindow(rect: w, open: 1, chrome: true, melt: 0, typed: 0, caret: Int(t * 2.5) % 2 == 0)
        switch kind {
        case .sessions:
            // Много глаз доигрывают открытие; ≥ 3 ждут — «сходит с ума», иначе смотрит (с наклоном к курсору).
            f.eyes = lean(eyes, g)
            if k < 0.6, c.contains(SceneClip.many) {
                f.clip = SceneClip.many; f.clipT = 0.4 + k; f.loop = false
            } else if o.waiting >= 3, c.contains(SceneClip.crazy) {
                f.clip = SceneClip.crazy; f.clipT = k
            } else {
                f.clip = SceneClip.look; f.clipT = k
                f.glitch = idleGlitch(t)
            }
            // Строки появляются по одной, 0,08 с.
            win.typed = min(max(1, min(sessionsMaxRows, o.rows)), Int(k / 0.08) + 1)
        case .thinking:
            // Щёлки (держит последний кадр), каждые 1,5 с — закрыла и снова щёлки; сканлайн по кругу.
            let cyc = k.truncatingRemainder(dividingBy: 1.5)
            let shut = c.contains(SceneClip.shut) ? SceneClip.shut : SceneClip.close
            let slits = c.contains(SceneClip.slits) ? SceneClip.slits : SceneClip.close
            if cyc < 0.35 { f.clip = shut; f.clipT = cyc } else { f.clip = slits; f.clipT = cyc - 0.35 }
            f.loop = false
            win.scan = CGFloat(k.truncatingRemainder(dividingBy: 1.6) / 1.6)
            win.typed = Int(k * 3) % 4
        case .answer:
            // Говорит, пока печатается ответ (18 букв/с), потом закрыла рот (`shut`, держит последний кадр).
            let typed = min(o.answerChars, Int(k * 18))
            win.typed = typed
            let typingEnd = Double(o.answerChars) / 18
            if typed < o.answerChars {
                f.clip = c.contains(SceneClip.talk) ? SceneClip.talk : SceneClip.look; f.clipT = k
            } else {
                f.clip = c.contains(SceneClip.shut) ? SceneClip.shut : SceneClip.look
                f.clipT = k - typingEnd; f.loop = f.clip == SceneClip.look
            }
            if let b = o.burstAt, t >= b, t < b + 1.0 {
                // «Отправлено» — взрыв глаз один раз.
                f.clip = c.contains(SceneClip.burst) ? SceneClip.burst : SceneClip.look
                f.clipT = t - b; f.loop = false
                f.glitch = t < b + 0.3 ? 2 : 0
            }
        case .music:
            music(&f, &win, t, eyes, c, o)
        default:
            break
        }
        f.window = win
        return f
    }

    /// Прилёт в окно: уход из notch, молния к линии глаз, появление, рамка растёт из линии.
    static func arriveWindow(_ t: Double, _ g: SceneGeometry, _ w: CGRect, _ eyes: CGRect, _ c: Set<String>, clip: String) -> SceneFrame {
        let line = CGRect(x: eyes.minX, y: eyes.midY - 1, width: eyes.width, height: 2)
        switch t {
        case ..<0.25: return out("out", at: g.home, t, len: 0.25, c)
        case ..<0.4: return jump("jump", from: g.home, to: eyes, t - 0.25, len: 0.15)
        case ..<0.6: return into("in", at: eyes, t - 0.4, len: 0.2, c)
        default:
            let p = CGFloat(min(1, (t - 0.6) / 0.4))
            var f = SceneFrame(phase: "unfold", eyes: eyes, clip: clip, clipT: t - 0.6, loop: clip == SceneClip.look)
            f.squash = p < 0.5 ? 0.06 : 0.06 + 0.94 * (p - 0.5) * 2
            f.glitch = 1
            f.window = SceneWindow(rect: unfoldRect(w, line: line, p), open: p, chrome: false, melt: 0, typed: 0, caret: false)
            return f
        }
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
    static func fold(_ k: Double, _ g: SceneGeometry, _ w: CGRect, _ eyes: CGRect, _ c: Set<String>) -> SceneFrame {
        let line = CGRect(x: eyes.minX, y: eyes.midY - 1, width: eyes.width, height: 2)
        switch k {
        case ..<0.5:
            let p = CGFloat(1 - k / 0.5)
            var f = SceneFrame(phase: "fold", eyes: eyes, clip: c.contains(SceneClip.close) ? SceneClip.close : SceneClip.look,
                               clipT: k, loop: false)
            f.squash = p < 0.5 ? 0.06 : 0.06 + 0.94 * (p - 0.5) * 2
            f.glitch = k < 0.25 ? 1 : 3
            f.window = SceneWindow(rect: unfoldRect(w, line: line, p), open: p, chrome: false, melt: 0, typed: 0, caret: false)
            return f
        case ..<0.65: return jump("back", from: line, to: g.home, k - 0.5, len: 0.15)
        default:
            var f = into("home", at: g.home, k - 0.65, len: 0.25, c)
            f.glitch = 2
            return f
        }
    }

    /// Ответ сессии через Capri: телепорт на окно терминала, «отправила» (`burst` + кольцо), смотрит в терминал
    /// щёлками и печатает «→ имя ✓», домой. Не дошло — `crazy` и глитч 3.
    static func reply(_ t: Double, _ g: SceneGeometry, _ c: Set<String>, _ o: SceneOptions) -> SceneFrame {
        switch t {
        case ..<0.3: return out("out", at: g.home, t, len: 0.3, c)
        case ..<0.5: return jump("jump", from: g.home, to: g.target, t - 0.3, len: 0.2)
        case ..<0.9: return into("in", at: g.target, t - 0.5, len: 0.4, c)
        case ..<1.5:
            let k = t - 0.9
            var f = SceneFrame(phase: "sent", eyes: g.target, clip: c.contains(SceneClip.burst) ? SceneClip.burst : SceneClip.look,
                               clipT: k, loop: false)
            f.glitch = k < 0.1 ? 1 : 0
            f.rings = [SceneRing(center: center(g.target), progress: CGFloat(min(1, k / 0.6)))]
            return f
        case ..<3.4:
            let k = t - 1.5
            let failed = o.failedAt.map { t >= $0 } ?? false
            // Взгляд вниз, в окно терминала.
            var f = SceneFrame(phase: "watch", eyes: g.target.offsetBy(dx: 0, dy: -3))
            if failed, let at = o.failedAt {
                f.clip = c.contains(SceneClip.crazy) ? SceneClip.crazy : SceneClip.look; f.clipT = t - at
                f.glitch = t - at < 0.5 ? 3 : idleGlitch(t)
            } else {
                f.clip = c.contains(SceneClip.slits) ? SceneClip.slits : SceneClip.look; f.clipT = k
                f.loop = f.clip == SceneClip.look
            }
            f.caption = SceneCaption(anchor: captionAnchor(g.target), typed: min(o.caption, Int(k * 22)), failed: failed)
            return f
        case ..<3.7: return out("leave", at: g.target, t - 3.4, len: 0.3, c)
        case ..<3.85: return jump("back", from: g.target, to: g.home, t - 3.7, len: 0.15)
        default:
            var f = into("home", at: g.home, t - 3.85, len: 0.15, c)
            f.glitch = 2
            return f
        }
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
        var out = [SceneHotspot(.close, SceneTimeline.closeRect(w).insetBy(dx: -3, dy: -3)),
                   SceneHotspot(.pin, SceneTimeline.pinRect(w).insetBy(dx: -3, dy: -3))]
        switch kind {
        case .window:
            out.append(SceneHotspot(.button("status"), SceneTimeline.statusRect(w)))
        case .sessions:
            for i in 0..<min(SceneTimeline.sessionsMaxRows, o.rows) {
                out.append(SceneHotspot(.row(i), SceneTimeline.rowRect(w, i)))
            }
        case .thinking:
            out.append(grab)
            out.append(SceneHotspot(.button("assistant"), CGRect(x: w.minX, y: w.minY, width: w.width, height: w.height - SceneTimeline.titleHeight)))
        case .answer:
            for b in SceneTimeline.answerButtons(w, proposal: o.proposal) { out.append(SceneHotspot(.button(b.id), b.rect)) }
        case .music:
            for b in SceneTimeline.musicButtons(w) { out.append(SceneHotspot(.button(b.id), b.rect)) }
        default:
            break
        }
        out.append(SceneHotspot(.drag, SceneTimeline.titleRect(w)))
        if kind != .thinking { out.append(grab) }
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

    /// Куда сесть у окна терминала: на верхний край (`onWindow`); не помещается — внутрь, у правого верхнего угла.
    public static func atTerminal(_ window: CGRect, visible: CGRect, size: CGSize = SceneTimeline.eyesSize) -> CGRect {
        if let on = onWindow(window, visible: visible, size: size) { return on }
        let inside = CGRect(x: window.maxX - 24 - size.width, y: window.maxY - 34 - size.height, width: size.width, height: size.height)
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
    /// Кнопки окна музыки ⏮ ⏯ ⏭ — по центру внизу.
    public static func musicButtons(_ w: CGRect) -> [(id: String, rect: CGRect)] {
        let bw: CGFloat = 40, gap: CGFloat = 10
        let x0 = w.midX - (bw * 3 + gap * 2) / 2
        return MusicCommand.buttons.enumerated().map { i, id in
            (id, CGRect(x: x0 + CGFloat(i) * (bw + gap), y: w.minY + 8, width: bw, height: 20))
        }
    }

    /// Строка «♪ Artist — Track» окна музыки (середина, слева — отступ 12).
    public static func musicLine(_ w: CGRect) -> CGPoint {
        CGPoint(x: w.minX + 12, y: w.minY + 42)
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

    /// Покой окна музыки: ищет — щёлки + сканлайн; пошёл трек — `burst`, потом кивает (`look`/`slits` на долю) с
    /// нотами; пауза — держит последний кадр `close`; снова играет — `appear`; не вышло — `crazy` + глитч 3.
    static func music(_ f: inout SceneFrame, _ win: inout SceneWindow, _ t: Double, _ eyes: CGRect, _ c: Set<String>, _ o: SceneOptions) {
        let wall = t + o.lag
        let (state, mark, previous) = musicState(at: t, o.musicMarks)
        // Секунды стены от смены состояния (без смен — от конца прилёта).
        let since = max(0, wall - (mark?.wall ?? arrival(.music, o)))
        func has(_ clip: String) -> Bool { c.contains(clip) }
        f.loop = false
        f.clipT = since
        win.typed = Int(since * 30)
        switch state {
        case .searching:
            f.clip = has(SceneClip.slits) ? SceneClip.slits : SceneClip.close
            win.scan = CGFloat(since.truncatingRemainder(dividingBy: 1.6) / 1.6)
            win.typed = 200 + Int(since * 3) % 4
        case .playing:
            let resumed = previous == .paused
            let opening = resumed ? (has(SceneClip.appear) ? SceneClip.appear : nil) : (has(SceneClip.burst) ? SceneClip.burst : nil)
            if since < (resumed ? 0.6 : 1.0) {
                f.clip = opening ?? SceneClip.look
                f.loop = opening == nil
                f.glitch = !resumed && since < 0.3 ? 2 : 0
            } else {
                // Кивает под музыку: вниз на долю, на сильную — щёлки; ноты по бокам глаз.
                let k = since - (resumed ? 0.6 : 1.0)
                f.eyes = eyes.offsetBy(dx: 0, dy: -nod(k, amplitude: 3))
                f.clip = onBeat(k) && has(SceneClip.slits) ? SceneClip.slits : SceneClip.look
                f.clipT = onBeat(k) ? 0.4 : k
                f.loop = true
                f.notes = musicNotes(k, eyes)
            }
        case .paused:
            f.clip = has(SceneClip.close) ? SceneClip.close : SceneClip.look
        case .failed:
            f.clip = has(SceneClip.crazy) ? SceneClip.crazy : SceneClip.look
            f.loop = true
            f.glitch = since < 0.5 ? 3 : idleGlitch(t)
        case .info:
            f.clip = SceneClip.look
            f.loop = true
            f.glitch = idleGlitch(t)
        }
    }

    /// Ноты по бокам глаз окна музыки: раз в долю, живут 1,2 с, поднимаются на 24 pt.
    static func musicNotes(_ k: Double, _ eyes: CGRect) -> [SceneNote] {
        let beatLen = 60 / bpm
        var out: [SceneNote] = []
        let first = max(0, Int((k - 1.2) / beatLen) + 1)
        for i in first...max(first, Int(k / beatLen)) where Double(i) * beatLen <= k {
            let age = (k - Double(i) * beatLen) / 1.2
            guard age < 1 else { continue }
            let side: CGFloat = i % 2 == 0 ? -1 : 1
            let x = eyes.midX + side * (eyes.width * 0.5 + 14 + CGFloat(TickNoise.unit(i, 52)) * 16)
            out.append(SceneNote(center: CGPoint(x: x + CGFloat(sin(age * 6)) * 3, y: eyes.minY + 6 + CGFloat(age) * 24),
                                 alpha: CGFloat(age < 0.2 ? age / 0.2 : 1 - (age - 0.2) / 0.8), glyph: i % 3))
        }
        return out
    }
}
