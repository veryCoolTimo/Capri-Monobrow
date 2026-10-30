import SwiftUI
import AppKit

/// Арт Capri: кадры состояний, сгенерированные Codex по рефам (промпт и сырые кадры — локально в `work/art/v3/`,
/// в репозитории только финальные кадры).
/// Кадры одного кадрирования, отличаются только лицом — поэтому плавность даёт наложение: нижний кадр целиком,
/// верхний поверх с прозрачностью. Поверх — лёгкие преобразования (дыхание, наклон, подскок, glitch).
enum CapriArt {
    enum Frame: String, CaseIterable {
        case idle, blink, listen, think, speakA, speakB, alert
        case mask, maskBlink = "mask-blink", maskAlert = "mask-alert"
    }

    static let images: [Frame: NSImage] = {
        var out: [Frame: NSImage] = [:]
        for f in Frame.allCases { if let url = url(f.rawValue), let im = NSImage(contentsOf: url) { out[f] = im } }
        if out.count != Frame.allCases.count {
            NSLog("[Capri] кадры персонажа: найдено %d из %d", out.count, Frame.allCases.count)
        }
        return out
    }()

    /// В `.app` — `Contents/Resources/Capri/` (кладёт build-macos.sh); при `swift run` — бандл ресурсов SwiftPM
    /// рядом с исполняемым файлом (`Bundle.module` не используем: без бандла он падает).
    static func url(_ name: String) -> URL? {
        if let u = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Capri") { return u }
        guard let dir = Bundle.main.executableURL?.deletingLastPathComponent(),
              let dev = Bundle(url: dir.appendingPathComponent("Capri_Capri.bundle")) else { return nil }
        return dev.url(forResource: name, withExtension: "png", subdirectory: "Capri")
            ?? dev.url(forResource: name, withExtension: "png")
    }
}

/// Кадр в момент времени: нижний `a`, верхний `b` с прозрачностью `mix`, преобразования.
private struct SpritePose {
    var a: CapriArt.Frame
    var b: CapriArt.Frame
    var mix: Double = 0
    var scale: Double = 1
    var angle: Double = 0
    var dy: Double = 0
    var jitter: Double = 0
    var glow: Double = 0

    static let blinkCycle = 4.3

    /// Преобразования между позами (кадры смешиваются слоями отдельно); `e` — доля `self`.
    func mixed(with from: SpritePose, _ e: Double) -> SpritePose {
        func m(_ x: Double, _ y: Double) -> Double { x + (y - x) * e }
        var o = self
        o.scale = m(from.scale, scale); o.angle = m(from.angle, angle); o.dy = m(from.dy, dy)
        o.jitter = m(from.jitter, jitter); o.glow = m(from.glow, glow)
        return o
    }

    /// `still` — «Уменьшить движение»: один кадр без движения.
    static func at(_ mood: CapriMood, _ t: Double, still: Bool) -> SpritePose {
        let tt = still ? 0 : t
        // Моргание: 0.06 с наплыв, 0.08 с закрыто, 0.06 с обратно.
        func blinkMix(_ cycle: Double) -> Double {
            guard !still else { return 0 }
            let p = tt.truncatingRemainder(dividingBy: cycle)
            if p < 0.06 { return p / 0.06 }
            if p < 0.14 { return 1 }
            if p < 0.2 { return 1 - (p - 0.14) / 0.06 }
            return 0
        }
        switch mood {
        case .idle:
            var s = SpritePose(a: .idle, b: .blink, mix: blinkMix(blinkCycle))
            s.scale = 1 + 0.012 * sin(tt * 1.6)        // дыхание
            s.angle = 1.2 * sin(tt * 0.5)
            return s
        case .listening:
            var s = SpritePose(a: .listen, b: .blink, mix: blinkMix(5.2))
            s.scale = 1.02
            s.angle = -2
            return s
        case .thinking:
            var s = SpritePose(a: .think, b: .think)
            s.angle = 3 * sin(tt * 1.3)
            s.scale = 1 + 0.008 * sin(tt * 2.2)
            return s
        case .speaking:
            // Рот: speakA ↔ speakB с наплывом, ~3.5 слога в секунду.
            let m = still ? 0 : 0.5 + 0.5 * sin(tt * 22)
            var s = SpritePose(a: .speakA, b: .speakB, mix: m)
            s.dy = still ? 0 : -1.2 * abs(sin(tt * 11))
            return s
        case .alert:
            var s = SpritePose(a: .alert, b: .alert)
            let p = tt.truncatingRemainder(dividingBy: 2.2)
            s.dy = still ? 0 : (p < 0.45 ? -6 * sin(.pi * p / 0.45) : 0)
            s.glow = 0.6 + (still ? 0 : 0.4 * sin(tt * 3))
            return s
        case .error:
            var s = SpritePose(a: .think, b: .think)
            let p = tt.truncatingRemainder(dividingBy: 1.7)
            s.jitter = still ? 0 : (p < 0.12 ? (p < 0.06 ? -3 : 3) : 0)
            return s
        }
    }
}

/// Анимированный арт Capri. Смена настроения — наплыв 0.3 с от прежнего кадра к новому.
struct CapriSprite: View {
    var mood: CapriMood
    var active = true

    @State private var fromMood: CapriMood = .idle
    @State private var shownMood: CapriMood = .idle
    @State private var changedAt = Date.distantPast

    private static let transition = 0.3
    private var still: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active || still)) { ctx in
            // На паузе время не идёт — показываем кадр текущего настроения без перехода.
            let animating = active && !still
            let (from, target, e) = animating ? blend(ctx.date) : (nil, SpritePose.at(shownMood, 0, still: true), 1.0)
            let p = from.map { target.mixed(with: $0, e) } ?? target
            ZStack {
                layers(target)
                if let from, e < 1 { layers(from).opacity(1 - e) }
            }
            .drawingGroup()
            .shadow(color: p.glow > 0.01 ? Palette.acid.opacity(0.55 * p.glow) : .clear, radius: p.glow > 0.01 ? 8 * p.glow : 0)
            .scaleEffect(p.scale, anchor: .bottom)
            .rotationEffect(.degrees(p.angle), anchor: .bottom)
            .offset(x: p.jitter, y: p.dy)
        }
        .onAppear { shownMood = mood; fromMood = mood }
        .onChange(of: mood) { m in
            fromMood = shownMood
            shownMood = m
            changedAt = Date()
        }
        .accessibilityLabel(Text("Capri"))
    }

    /// Кадры позы: нижний целиком, верхний с прозрачностью.
    private func layers(_ p: SpritePose) -> some View {
        ZStack {
            image(p.a)
            if p.mix > 0.001 { image(p.b).opacity(p.mix) }
        }
    }

    private func image(_ f: CapriArt.Frame) -> some View {
        Group {
            if let im = CapriArt.images[f] { Image(nsImage: im).resizable().interpolation(.high).aspectRatio(contentMode: .fit) }
        }
    }

    /// Переход настроений: прежняя поза целиком (со своим морганием/речью) гаснет поверх новой, `e` — 0…1.
    private func blend(_ date: Date) -> (SpritePose?, SpritePose, Double) {
        let t = date.timeIntervalSinceReferenceDate
        let target = SpritePose.at(shownMood, t, still: false)
        let k = min(1, max(0, date.timeIntervalSince(changedAt) / Self.transition))
        guard k < 1 else { return (nil, target, 1) }
        return (SpritePose.at(fromMood, t, still: false), target, k * k * (3 - 2 * k))
    }
}
