import Foundation
import CoreGraphics

// MARK: пространства (Spaces) — список и направление переключения

/// Пространство на дисплее: id (`ManagedSpaceID`) и полноэкранное ли (приложение на весь экран).
public struct SpaceInfo: Equatable {
    public var id: UInt64
    public var fullscreen: Bool
    public init(id: UInt64, fullscreen: Bool) { self.id = id; self.fullscreen = fullscreen }
}

/// Пространства одного дисплея в порядке Mission Control и текущее.
public struct DisplaySpaces: Equatable {
    /// UUID дисплея или `Main` (когда «у дисплеев общие пространства»).
    public var display: String
    public var spaces: [SpaceInfo]
    public var current: UInt64?
    public init(display: String, spaces: [SpaceInfo], current: UInt64?) {
        self.display = display; self.spaces = spaces; self.current = current
    }
    public func index(of id: UInt64?) -> Int? { id.flatMap { id in spaces.firstIndex { $0.id == id } } }
    public var currentSpace: SpaceInfo? { index(of: current).map { spaces[$0] } }
}

/// Снимок `CGSCopyManagedDisplaySpaces`: все дисплеи.
public struct SpaceSnapshot: Equatable {
    public var displays: [DisplaySpaces]
    public init(displays: [DisplaySpaces]) { self.displays = displays }

    /// Тип полноэкранного пространства в списке WindowServer (0 — обычный стол).
    public static let fullscreenType = 4

    /// Разбор ответа WindowServer: `Display Identifier`, `Spaces` (`ManagedSpaceID`/`id64`, `type`,
    /// `TileLayoutManager` у полноэкранных), `Current Space`. Непонятные записи пропускаются.
    public static func parse(_ raw: [[String: Any]]) -> SpaceSnapshot {
        func id(_ d: [String: Any]?) -> UInt64? {
            guard let d else { return nil }
            for key in ["ManagedSpaceID", "id64"] {
                if let n = d[key] as? NSNumber { return n.uint64Value }
                if let n = d[key] as? Int, n >= 0 { return UInt64(n) }
            }
            return nil
        }
        func fullscreen(_ d: [String: Any]) -> Bool {
            let type = (d["type"] as? NSNumber)?.intValue ?? (d["type"] as? Int) ?? 0
            return type == fullscreenType || d["TileLayoutManager"] != nil
        }
        let displays = raw.compactMap { d -> DisplaySpaces? in
            guard let name = d["Display Identifier"] as? String else { return nil }
            let spaces = (d["Spaces"] as? [[String: Any]] ?? []).compactMap { s in id(s).map { SpaceInfo(id: $0, fullscreen: fullscreen(s)) } }
            return DisplaySpaces(display: name, spaces: spaces, current: id(d["Current Space"] as? [String: Any]))
        }
        return SpaceSnapshot(displays: displays)
    }

    /// Дисплей notch: по UUID; иначе единственный; иначе `Main` (общие пространства на всех дисплеях).
    public func display(_ uuid: String?) -> DisplaySpaces? {
        if let uuid, let d = displays.first(where: { $0.display.caseInsensitiveCompare(uuid) == .orderedSame }) { return d }
        if displays.count == 1 { return displays[0] }
        return displays.first { $0.display == "Main" }
    }
}

/// Куда переключились: `forward` — на пространство правее в Mission Control (всё уезжает влево),
/// `backward` — левее, `unknown` — не понять (нет приватных функций, нет снимка до).
public enum SpaceMove: String, Equatable, Codable, CaseIterable {
    case forward, backward, unknown

    /// Куда едут глаза вместе со столом: −1 — влево, +1 — вправо, 0 — на месте.
    public var eyesDirection: CGFloat {
        switch self {
        case .forward: -1
        case .backward: 1
        case .unknown: 0
        }
    }
}

/// Что случилось с пространством дисплея notch.
public enum SpaceChange: Equatable {
    /// Стол notch переключился; `fullscreen` — новое пространство полноэкранное (nil — не знаем).
    case moved(SpaceMove, fullscreen: Bool?)
    /// Переключился другой дисплей — на экране notch ничего не ехало.
    case elsewhere
}

public enum Spaces {
    /// Сравнение снимков до и после уведомления о смене пространства. Без снимков — `unknown`.
    public static func change(from old: SpaceSnapshot?, to new: SpaceSnapshot?, display uuid: String?) -> SpaceChange {
        guard let new, let d = new.display(uuid) else { return .moved(.unknown, fullscreen: nil) }
        let fullscreen = d.currentSpace?.fullscreen
        guard let old, let o = old.display(d.display) ?? old.display(uuid) else { return .moved(.unknown, fullscreen: fullscreen) }
        if o.current == d.current {
            // Наш стол не менялся, а другой — да: ехало не у нас.
            let others = new.displays.contains { n in
                n.display != d.display && old.displays.first { $0.display == n.display }.map { $0.current != n.current } == true
            }
            return others ? .elsewhere : .moved(.unknown, fullscreen: fullscreen)
        }
        // Индексы — по новому списку (пространство могли переставить); прежнего уже нет — по старому.
        guard let ni = d.index(of: d.current), let oi = d.index(of: o.current) ?? o.index(of: o.current) else {
            return .moved(.unknown, fullscreen: fullscreen)
        }
        return .moved(ni > oi ? .forward : ni < oi ? .backward : .unknown, fullscreen: fullscreen)
    }
}

// MARK: глаза в notch «сметает» вместе со столом

/// Как играть смену пространства.
public struct SpaceSweepStyle: Equatable {
    public var move: SpaceMove
    /// Пришли в полноэкранное приложение: тише — прищур, без глитча на входе и без перелёта.
    public var soft: Bool
    /// «Уменьшить движение»: просто гаснут и проявляются.
    public var reduceMotion: Bool
    public var seed: Int
    public init(move: SpaceMove, soft: Bool = false, reduceMotion: Bool = false, seed: Int = 0) {
        self.move = move; self.soft = soft; self.reduceMotion = reduceMotion; self.seed = seed
    }
}

/// Копия глаз позади (размаз движения): сдвиг от глаз (pt), прозрачность, цвет (0 — волосы, 1 — кромка, 2 — розовый).
public struct SweepGhost: Equatable {
    public var dx: CGFloat
    public var alpha: CGFloat
    public var tint: Int
}

/// Кадр эффекта: глаза сдвинуты на `dx` (pt), растянуты `scaleX`/`scaleY` вокруг своего центра, полосами `bars`
/// (пусто — целиком), с копиями `ghosts` позади; `squint` 0…1 — прищур (рисунок щёлок).
public struct SpaceSweepFrame: Equatable {
    public var dx: CGFloat = 0
    public var scaleX: CGFloat = 1
    public var scaleY: CGFloat = 1
    public var alpha: CGFloat = 1
    public var bars: [TransitionBar] = []
    public var ghosts: [SweepGhost] = []
    public var squint: CGFloat = 0
    public init() {}

    public var visible: Bool { alpha > 0.001 && scaleX > 0.001 }
    /// Глаза просто на месте — как без эффекта.
    public var plain: Bool { self == SpaceSweepFrame() }
}

/// Запущенный эффект: начало (секунды) и как играть.
public struct SpaceSweepRun: Equatable {
    public var start: Double
    public var style: SpaceSweepStyle
    public init(start: Double, style: SpaceSweepStyle) { self.start = start; self.style = style }
    public var end: Double { start + SpaceSweep.duration(style) }
}

/// Смена пространства: глаза в notch не стоят на месте, пока весь стол уезжает. 0,42 с (как слайд macOS):
/// разгон в сторону переключения с растяжкой, полосами со сдвигом и RGB-разносом и копиями позади → за край
/// капли (влево) или в вырез (вправо) → пауза → входят с другой стороны и садятся с маленьким перелётом.
/// Направление неизвестно — симметрично: сжимаются в щель к центру и раскрываются обратно.
public enum SpaceSweep {
    public static let length: Double = 0.42
    /// До `outEnd` уходят, до `inStart` их нет, дальше входят.
    public static let outEnd: Double = 0.16
    public static let inStart: Double = 0.2
    /// Reduce Motion: гаснут (до 0,14), нет (до 0,18), проявляются.
    public static let reduceLength: Double = 0.32
    public static let reduceOutEnd: Double = 0.14
    public static let reduceInStart: Double = 0.18
    /// Перелёт на входе (pt, не больше).
    public static let overshootMax: CGFloat = 3

    public static func duration(_ s: SpaceSweepStyle) -> Double { s.reduceMotion ? reduceLength : length }
    static func outEnd(_ s: SpaceSweepStyle) -> Double { s.reduceMotion ? reduceOutEnd : outEnd }
    static func inStart(_ s: SpaceSweepStyle) -> Double { s.reduceMotion ? reduceInStart : inStart }
    /// Середина «их нет» — отсюда начинается вход заново.
    public static func hidden(_ s: SpaceSweepStyle) -> Double { (outEnd(s) + inStart(s)) / 2 }

    /// Новое уведомление о смене пространства (быстрые свайпы подряд) — один эффект, а не очередь:
    /// - ничего не идёт или кончилось — новый;
    /// - ещё уходят или их нет — тот же, только тон входа (тихий/обычный) — по последнему пространству;
    /// - уже входят — снова «их нет» и вход заново, в сторону последнего переключения.
    public static func coalesce(_ run: SpaceSweepRun?, now: Double, style: SpaceSweepStyle) -> SpaceSweepRun {
        guard let run, now < run.end, now >= run.start else { return SpaceSweepRun(start: now, style: style) }
        var s = run.style
        s.soft = style.soft
        if now - run.start < inStart(run.style) { return SpaceSweepRun(start: run.start, style: s) }
        s.move = style.move == .unknown ? s.move : style.move
        s.seed = run.style.seed &+ 1
        return SpaceSweepRun(start: now - hidden(s), style: s)
    }

    /// Только вход (notch был спрятан полноэкранным приложением и проявляется): начало — «их нет».
    public static func arriving(now: Double, style: SpaceSweepStyle) -> SpaceSweepRun {
        SpaceSweepRun(start: now - hidden(style), style: style)
    }

    /// Кадр в момент `t`. `eyes` — глаза (локально), `lane` — по x, где их видно (левое крыло капли до выреза):
    /// уходят ровно за её края.
    public static func frame(t: Double, style s: SpaceSweepStyle, eyes: CGRect, lane: ClosedRange<CGFloat>) -> SpaceSweepFrame {
        var f = SpaceSweepFrame()
        let d = duration(s)
        guard t > 0, t < d else { return f }
        let tick = Int(t * 24)
        if s.reduceMotion {
            if t < reduceOutEnd { f.alpha = CGFloat(1 - t / reduceOutEnd) }
            else if t < reduceInStart { f.alpha = 0 }
            else { f.alpha = CGFloat(smooth((t - reduceInStart) / (reduceLength - reduceInStart))) }
            return f.alpha >= 0.999 ? SpaceSweepFrame() : f
        }
        let dir = s.move.eyesDirection
        // Сколько ехать до края: влево — правый край глаз за левый край крыла; вправо — левый край за правый.
        // Запас — на растяжку и копии позади.
        let pad = eyes.width * 0.9
        let toLeft = eyes.maxX - lane.lowerBound + pad, toRight = lane.upperBound - eyes.minX + pad
        let exit = dir < 0 ? toLeft : toRight, entry = dir < 0 ? toRight : toLeft
        if t < outEnd {
            // Уход: крошечный замах против хода (первые 0,03 с), потом разгон.
            let u = CGFloat(max(0, (t - 0.03) / (outEnd - 0.03)))
            let windup = t < 0.03 ? CGFloat(sin(t / 0.03 * .pi)) : 0
            if dir == 0 {
                f.scaleX = max(0.04, 1 - 0.96 * u * u)
                f.scaleY = 1 + 0.18 * u
                f.bars = bars(eyes, q: 0.25 + 0.55 * u, tick: tick, seed: s.seed, dir: 0, keepAll: true)
                f.ghosts = u > 0.05 ? [SweepGhost(dx: -7 * u, alpha: 0.45 * u, tint: 0), SweepGhost(dx: 7 * u, alpha: 0.45 * u, tint: 1)] : []
                f.scaleX -= windup * 0.06
                return f
            }
            f.dx = dir * (exit * u * u * u - 1.5 * windup)
            f.scaleX = 1 + 0.9 * u
            f.scaleY = 1 - 0.28 * u
            f.bars = bars(eyes, q: 0.2 + 0.6 * u, tick: tick, seed: s.seed, dir: dir, keepAll: false)
            f.ghosts = ghosts(dir: dir, k: u, width: eyes.width)
            return f
        }
        if t < inStart(s) {
            f.alpha = 0
            return f
        }
        let v = CGFloat((t - inStart) / (length - inStart))
        if dir == 0 {
            // Раскрываются из щели с лёгким перелётом по ширине.
            f.scaleX = max(0.04, 0.04 + 0.96 * backOut(v, 1.4))
            f.scaleY = 1 + 0.18 * (1 - v) * (1 - v)
            if !s.soft {
                f.bars = v < 0.8 ? bars(eyes, q: 0.6 * pow(1 - v / 0.8, 1.5), tick: tick, seed: s.seed &+ 7, dir: 0, keepAll: true) : []
                if v < 0.5 { f.ghosts = [SweepGhost(dx: -6 * (1 - 2 * v), alpha: 0.35 * (1 - 2 * v), tint: 0),
                                         SweepGhost(dx: 6 * (1 - 2 * v), alpha: 0.35 * (1 - 2 * v), tint: 1)] }
            }
            if s.soft { f.squint = squint(v); f.scaleY = 1 - 0.25 * f.squint }
            return settle(f)
        }
        // Вход с другой стороны, всё ещё в сторону `dir`: от −dir·entry к 0.
        let from = -dir * entry
        if s.soft {
            // Тихо: без полос и копий, без перелёта, прищурившись.
            f.dx = from * pow(1 - v, 3)
            f.squint = squint(v)
            f.scaleY = 1 - 0.25 * f.squint
            return settle(f)
        }
        // Перелёт ≈ 3,7 % пути, но не больше `overshootMax`.
        let c = min(1.0, Double(overshootMax / max(1, abs(from))) / 0.037)
        f.dx = from * (1 - backOut(v, CGFloat(c)))
        let w = (1 - v) * (1 - v)
        f.scaleX = 1 + 0.7 * w
        f.scaleY = 1 - 0.2 * w
        f.bars = v < 0.75 ? bars(eyes, q: 0.6 * pow(1 - v / 0.75, 1.5), tick: tick, seed: s.seed &+ 7, dir: dir, keepAll: false) : []
        f.ghosts = v < 0.6 ? ghosts(dir: dir, k: 1 - v / 0.6, width: eyes.width) : []
        return settle(f)
    }

    /// Почти на месте — ровно на месте (никаких 0,0001 pt в последнем кадре).
    static func settle(_ f: SpaceSweepFrame) -> SpaceSweepFrame {
        var f = f
        if abs(f.dx) < 0.01 { f.dx = 0 }
        if abs(f.scaleX - 1) < 0.001 { f.scaleX = 1 }
        if abs(f.scaleY - 1) < 0.001 { f.scaleY = 1 }
        if f.squint < 0.001 { f.squint = 0 }
        return f
    }

    /// Прищур на тихом входе: держится, к концу раскрывается.
    static func squint(_ v: CGFloat) -> CGFloat { v < 0.7 ? 1 : max(0, 1 - (v - 0.7) / 0.3) }

    /// Полосы общей библиотеки; при движении все уезжают назад (против хода) — размаз, а не распад.
    static func bars(_ r: CGRect, q: CGFloat, tick: Int, seed: Int, dir: CGFloat, keepAll: Bool) -> [TransitionBar] {
        Transitions.bars(r, q: q, tick: tick, seed: seed).enumerated().map { i, b in
            var b = b
            if dir != 0 {
                // Каждая третья — чуть вперёд, остальные тянутся назад.
                let back = i % 3 != 1
                b.dx = (back ? -dir : dir * 0.4) * abs(b.dx) * 1.3
            }
            if keepAll { b.shown = true } else { b.shown = b.shown || i % 2 == 0 }
            return b
        }
    }

    /// Три копии позади (против хода), чем быстрее — тем дальше и ярче.
    static func ghosts(dir: CGFloat, k: CGFloat, width: CGFloat) -> [SweepGhost] {
        guard k > 0.05 else { return [] }
        return [(0.35, 0.5, 0), (0.7, 0.32, 1), (1.05, 0.18, 2)].map { (gap: CGFloat, a: CGFloat, tint: Int) in
            SweepGhost(dx: -dir * width * gap * k, alpha: a * k, tint: tint)
        }
    }

    static func smooth(_ x: Double) -> Double { let x = max(0, min(1, x)); return x * x * (3 - 2 * x) }

    /// easeOutBack: 0 → 1 с перелётом (c = 1 — около 3,7 %).
    static func backOut(_ x: CGFloat, _ c: CGFloat) -> CGFloat {
        let y = max(0, min(1, x)) - 1
        return 1 + (c + 1) * y * y * y + c * y * y
    }
}
