import SwiftUI
import AppKit
import CapriKit

/// Строка голоса в peek: что слышу (хвост фразы — начало уходит влево), итог или ошибка.
struct VoiceLineView: View {
    var line: VoiceLine

    var body: some View {
        let color: Color = switch line.phase {
        case .listening: Palette.crimson
        case .working: Palette.codex
        case .done: Palette.acid
        case .failed: Palette.crimson
        }
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold)).foregroundColor(color)
            Text(shown)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(line.text.isEmpty ? Palette.dim : Palette.text)
                .lineLimit(1).truncationMode(line.phase == .listening || line.phase == .working ? .head : .tail)
            Spacer(minLength: 0)
            if !line.hint.isEmpty { Caps(line.hint, size: 8, color: Palette.dim).fixedSize() }
        }
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch line.phase {
        case .listening: "mic.fill"
        case .working: "ellipsis"
        case .done: "checkmark"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var shown: String {
        if !line.text.isEmpty { return line.text }
        return line.phase == .listening ? "слушаю…" : "…"
    }
}

/// Молния вдоль нижнего края notch, пока держат клавишу: прежняя розовая игольчатая (иглы `CapriFX.needles`) с
/// фиолетовой тенью. Не бахрома по всему краю, а разряд, который бежит по кромке: короткий зигзаг с неровными
/// коленями ползёт слева направо (~1.5 с на проход), громче — длиннее, шире и с веткой вниз. Каждый тик (12 fps)
/// колени «кипят». `bottom` — y нижнего края, `down` — куда «вниз» (−1 в слоях AppKit, +1 в SwiftUI).
enum VoiceBolt {
    static func points(left: CGFloat, right: CGFloat, bottom: CGFloat, down: CGFloat, tick: Int, level: Double) -> [CGPoint] {
        let lv = CGFloat(max(0, min(1, level)))
        let span = right - left
        let len = span * (0.28 + 0.3 * lv)
        // Голова бежит по кромке; за краем — заходит с другой стороны.
        let head = CGFloat((tick % 18)) / 18
        let x0 = left - len + (span + len) * head
        let seed = 31 + tick / 18
        let n = 6 + Int(TickNoise.hash(seed, 3) % 3)
        let amp = 1.5 + 6 * lv
        var pts: [CGPoint] = []
        for k in 0..<n {
            let f = CGFloat(k) / CGFloat(n - 1)
            let jitterX = k == 0 || k == n - 1 ? 0 : (CGFloat(TickNoise.unit(seed, 10 + k)) - 0.5) * len / CGFloat(n) * 0.8
            let x = min(right, max(left, x0 + len * f + jitterX))
            // Колени: в основном поочерёдно, но разной высоты; «кипение» — каждый тик.
            let side: CGFloat = k % 2 == 0 ? 1 : -0.35
            let mag = 0.35 + 0.65 * CGFloat(TickNoise.unit(seed, 20 + k)) + 0.25 * (CGFloat(TickNoise.unit(tick, 40 + k)) - 0.5)
            let off = k == 0 || k == n - 1 ? 0.5 : side * mag * amp + 1
            pts.append(CGPoint(x: x, y: bottom + down * off))
        }
        // Обрезанные краем колени слипаются — без нулевых игл.
        var out: [CGPoint] = []
        for p in pts where out.last.map({ abs($0.x - p.x) > 1.5 }) ?? true { out.append(p) }
        return out
    }

    static func paths(left: CGFloat, right: CGFloat, bottom: CGFloat, down: CGFloat, tick: Int, level: Double) -> (main: Path, fork: Path?) {
        let lv = CGFloat(max(0, min(1, level)))
        let pts = points(left: left, right: right, bottom: bottom, down: down, tick: tick, level: level)
        guard pts.count > 1 else { return (Path(), nil) }
        let main = CapriFX.needles(pts, width: 1.6 + 1.8 * lv, taper: 0.35, tip: 0.14)
        guard lv > 0.4, pts.count > 3 else { return (main, nil) }
        // Громко — ветка вниз из самого низкого колена.
        let from = pts.dropFirst().dropLast().max { ($0.y - bottom) * down < ($1.y - bottom) * down } ?? pts[1]
        let seed = 31 + tick / 6
        let to = CGPoint(x: from.x + (CGFloat(TickNoise.unit(seed, 8)) - 0.5) * 16, y: from.y + down * (6 + 10 * lv))
        let fork = CapriFX.boltPath(from: from, to: to, seed: seed + 5, boil: tick, width: 1.3 + lv)
        return (main, fork)
    }
}

/// Контактный лист голоса в notch (`scene sheet voice` в `--debug-control`): форма peek, глаза, строка и молния —
/// те же виды и пути, что в живом notch, по кадрам 12 fps.
enum VoiceSheet {
    struct Frame { var line: VoiceLine; var tick: Int; var level: Double; var label: String }

    static let frames: [Frame] = [
        Frame(line: VoiceLine(phase: .listening, text: ""), tick: 2, level: 0.05, label: "нажали, тишина"),
        Frame(line: VoiceLine(phase: .listening, text: "Капри, напомни"), tick: 7, level: 0.45, label: "говорит"),
        Frame(line: VoiceLine(phase: .listening, text: "Капри, напомни через 20 минут"), tick: 11, level: 0.9, label: "громко"),
        Frame(line: VoiceLine(phase: .listening, text: "Капри, напомни через двадцать минут проверить, собрался ли деплой на quiz"),
              tick: 15, level: 0.3, label: "длинная фраза"),
        Frame(line: VoiceLine(phase: .working, text: "Капри, напомни через 20 минут проверить деплой"), tick: 12, level: 0, label: "отпустили"),
        Frame(line: VoiceLine(phase: .done, text: "Напомню в 15:20: «проверить деплой»"), tick: 13, level: 0, label: "итог"),
        Frame(line: VoiceLine(phase: .done, text: "▶ ищу «Daft Punk»…"), tick: 14, level: 0, label: "музыка"),
        Frame(line: VoiceLine(phase: .failed, text: "Нет модели речи — Настройки → Голос"), tick: 15, level: 0, label: "ошибка"),
    ]

    static let size = CGSize(width: 360, height: 92)

    /// Лист в `~/.capri/tmp/scene-voice.png` (сетка) и `scene-voice-detail.png` (два кадра крупно).
    @MainActor
    static func render() -> [URL] {
        CapriPaths.ensureDir()
        var urls: [URL] = []
        let grid = VStack(spacing: 8) {
            ForEach(0..<(frames.count + 1) / 2, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(0..<2, id: \.self) { col in
                        let i = row * 2 + col
                        if i < frames.count { cell(frames[i]) }
                    }
                }
            }
        }
        .padding(10)
        .background(Color(white: 0.55))
        for (name, view, scale) in [("scene-voice.png", AnyView(grid), 2.0),
                                    ("scene-voice-detail.png", AnyView(VStack(spacing: 8) { cell(frames[2]); cell(frames[3]) }
                                        .padding(10).background(Color(white: 0.55))), 3.0)] {
            let r = ImageRenderer(content: view)
            r.scale = scale
            guard let cg = r.cgImage else { continue }
            let rep = NSBitmapImageRep(cgImage: cg)
            let url = CapriPaths.tmp.appendingPathComponent(name)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            urls.append(url)
        }
        return urls
    }

    @MainActor
    static func cell(_ f: Frame) -> some View {
        // Peek: ширина свёрнутой капли + 40, высота строки выреза 32 + 34.
        let w: CGFloat = 300, top: CGFloat = 32, h: CGFloat = 66
        let left = (size.width - w) / 2
        return ZStack(alignment: .topLeading) {
            Color(red: 0.16, green: 0.17, blue: 0.2)
            Path(dropPath(CGRect(x: left, y: 0, width: w, height: h), top: 8, bottom: 16, flipped: true))
                .fill(Color.black)
            Path(dropPath(CGRect(x: left, y: 0, width: w, height: h), top: 8, bottom: 16, flipped: true))
                .stroke(Palette.crimson.opacity(0.55), lineWidth: 1)
            // Вырез камеры.
            RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.02)).frame(width: 180, height: top - 2)
                .offset(x: (size.width - 180) / 2, y: 0)
            CapriMaskSprite(mood: f.line.phase == .listening ? .listening : .idle, active: false)
                .frame(width: 32, height: 16).offset(x: left + 13, y: (top - 16) / 2)
            VoiceLineView(line: f.line).padding(.horizontal, 18)
                .frame(width: w, height: h - top - 3).offset(x: left, y: top)
            if f.line.phase == .listening {
                let p = VoiceBolt.paths(left: left + 14, right: left + w - 14, bottom: h, down: 1, tick: f.tick, level: f.level)
                p.main.offsetBy(dx: 1.2, dy: 1.5).fill(Palette.violet)
                p.main.fill(Palette.crimson)
                if let fork = p.fork {
                    fork.offsetBy(dx: 1.2, dy: 1.5).fill(Palette.violet)
                    fork.fill(Palette.crimson)
                }
            }
            Text(f.label).font(.mono(8)).foregroundColor(.white.opacity(0.6)).offset(x: 6, y: size.height - 14)
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, .dark)
    }

    /// Капля для SwiftUI (y вниз): `dropPath` notch рисует в слоях AppKit (y вверх) — переворачиваем.
    static func dropPath(_ r: CGRect, top: CGFloat, bottom: CGFloat, flipped: Bool) -> CGPath {
        let p = Capri.dropPath(CGRect(x: r.minX, y: 0, width: r.width, height: r.height), top: top, bottom: bottom)
        var t = CGAffineTransform(translationX: 0, y: r.height).scaledBy(x: 1, y: -1)
        return p.copy(using: &t) ?? p
    }
}
