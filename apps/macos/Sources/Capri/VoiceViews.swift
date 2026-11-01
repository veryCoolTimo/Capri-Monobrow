import SwiftUI
import AppKit
import CapriKit

/// Строка голоса в peek: что слышу (хвост фразы — начало уходит влево), итог или ошибка.
struct VoiceLineView: View {
    var line: VoiceLine

    var body: some View {
        // Слушает — спокойный фиолетовый; малиновый — только тревога («не слышу») и ошибка.
        let phaseColor: Color = switch line.phase {
        case .listening: Palette.codex
        case .working: Palette.codex
        case .done: Palette.acid
        case .failed: Palette.crimson
        }
        let color = line.alarm ? Palette.crimson : phaseColor
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold)).foregroundColor(color)
            let isNote = line.text.isEmpty && !line.note.isEmpty
            Text(shown)
                .font(.system(size: isNote ? 11 : 12, weight: isNote && line.alarm ? .semibold : .medium))
                .minimumScaleFactor(isNote ? 0.8 : 1)
                .layoutPriority(1)
                .foregroundColor(!line.text.isEmpty ? Palette.text : line.alarm ? Palette.crimson
                                 : line.note.isEmpty ? Palette.text.opacity(0.85) : Palette.codex)
                .lineLimit(1).truncationMode(!isNote && (line.phase == .listening || line.phase == .working) ? .head : .tail)
            Spacer(minLength: 0)
            if !line.hint.isEmpty { Caps(line.hint, size: 8, color: Palette.dim).fixedSize() }
        }
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch line.phase {
        case .listening: line.alarm ? "mic.slash.fill" : "mic.fill"
        case .working: "ellipsis"
        case .done: "checkmark"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var shown: String {
        if !line.text.isEmpty { return line.text }
        if !line.note.isEmpty { return line.note }
        return line.phase == .listening ? "слушаю…" : "…"
    }
}

/// Рот Capri рядом с глазами, пока она слушает: розовый зигзаг с фиолетовой тенью, колени — по громкости
/// (`VoiceMouth`). Громкость читает сам по кадрам 12 fps (`level` — не публикуется); `tick`/`fixed` — для листа.
struct VoiceMouthView: View {
    var level: () -> Double
    var fixedTick: Int? = nil

    var body: some View {
        if let t = fixedTick {
            mouth(tick: t)
        } else {
            TimelineView(.periodic(from: .now, by: 1 / CapriFace.fps)) { ctx in
                mouth(tick: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : Int(ctx.date.timeIntervalSinceReferenceDate * CapriFace.fps))
            }
        }
    }

    private func mouth(tick: Int) -> some View {
        Canvas { g, size in
            let r = CGRect(x: 1, y: 1, width: size.width - 2, height: size.height - 2)
            let lv = level()
            let pts = VoiceMouth.points(in: r, tick: tick, level: lv)
            var p = Path()
            p.addLines(pts)
            // Тишина — ровная тусклая черта: голоса нет.
            guard VoiceLevel.speaking(lv) else {
                g.stroke(p, with: .color(Palette.codex.opacity(0.45)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                return
            }
            g.stroke(p.offsetBy(dx: 0.8, dy: 1), with: .color(Palette.violet), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .miter))
            g.stroke(p, with: .color(Palette.crimson), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .miter))
        }
        .accessibilityHidden(true)
    }
}

/// Молния вдоль нижнего края notch, пока она слышит голос (выше порога `VoiceLevel.heard`; в тишине её нет):
/// розовая игольчатая (иглы `CapriFX.needles`) с фиолетовой тенью. Растёт из-под её лица (слева) вправо:
/// громче — длиннее, шире и с веткой вниз. Каждый тик (12 fps) колени «кипят», форма меняется раз в 3 кадра. `bottom` — y нижнего края, `down` — куда «вниз» (−1 в слоях AppKit, +1 в SwiftUI).
enum VoiceBolt {
    static func points(left: CGFloat, right: CGFloat, bottom: CGFloat, down: CGFloat, tick: Int, level: Double) -> [CGPoint] {
        let lv = CGFloat(max(0, min(1, level)))
        let span = right - left
        // Разряд привязан к ней: начинается под глазами/ртом (слева) и тянется вправо — громче, длиннее.
        let len = span * (0.3 + 0.45 * lv)
        let x0 = left + span * 0.02
        let seed = 31 + tick / 3
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
    struct Frame { var line: VoiceLine; var tick: Int; var level: Double; var label: String; var heard: HearingWatch.Status? = nil }

    static let frames: [Frame] = [
        Frame(line: VoiceLine(phase: .listening, text: ""), tick: 2, level: 0.05, label: "держат, тишина"),
        Frame(line: VoiceLine(phase: .listening, text: "Капри, напомни"), tick: 7, level: 0.45, label: "говорит", heard: .heard),
        Frame(line: VoiceLine(phase: .listening, text: "Капри, напомни через 20 минут"), tick: 11, level: 0.9, label: "громко", heard: .heard),
        Frame(line: VoiceLine(phase: .listening, text: "Капри, напомни через двадцать минут проверить, собрался ли деплой на quiz"),
              tick: 15, level: 0.12, label: "длинная фраза, пауза", heard: .heard),
        Frame(line: VoiceLine(phase: .listening, text: "", note: "«USB Mic» не подключён — слушаю встроенный"), tick: 4, level: 0.12,
              label: "выбранного нет"),
        Frame(line: VoiceLine(phase: .listening, text: "", note: HearingWatch.quietText, alarm: true), tick: 9, level: 0.1,
              label: "звук есть, тихо 1.5 с", heard: .quiet),
        Frame(line: VoiceLine(phase: .listening, text: "", note: HearingWatch.deadText, alarm: true), tick: 9, level: 0,
              label: "кусков нет 2.5 с", heard: .dead),
        Frame(line: VoiceLine(phase: .working, text: "Капри, напомни через 20 минут проверить деплой"), tick: 12, level: 0, label: "отпустили"),
        Frame(line: VoiceLine(phase: .done, text: "Напомню в 15:20: «проверить деплой»"), tick: 13, level: 0, label: "итог"),
        Frame(line: VoiceLine(phase: .done, text: "▶ ищу «Daft Punk»…"), tick: 14, level: 0, label: "музыка"),
        Frame(line: VoiceLine(phase: .failed, text: "Не расслышала — держи ⌃⌥Пробел"), tick: 15, level: 0,
              label: "пусто"),
        Frame(line: VoiceLine(phase: .failed, text: "Микрофон отключился — Настройки → Голос"), tick: 15, level: 0,
              label: "вход пропал"),
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
        let assistant = VStack(spacing: 8) {
            assistantCell(voice: nil, hint: true, text: "", level: 0, label: "помощник по тапу: подсказка")
            assistantCell(voice: frames[1].line, hint: true, text: "Капри, напомни", level: 0.6, label: "держат при открытом помощнике")
            assistantCell(voice: frames[5].line, hint: true, text: "", level: 0.02, label: "помощник: не слышу")
            assistantCell(voice: nil, hint: false, text: "", level: 0, label: "после 3 раз — без подсказки")
        }
        .padding(10).background(Color(white: 0.55))
        let answers = VStack(spacing: 8) {
            answerCell(PeekAnswer(text: "Да, квота **Codex** почти кончилась — осталось 12% до 18:00.",
                                  hint: PeekAnswerTiming.hint(confirm: false, links: false)))
            answerCell(PeekAnswer(text: "Votek ждёт ответа: спрашивает, можно ли удалить старую миграцию и пересобрать базу на тестовом стенде. Остальные три сессии работают, quiz скрыт настройками. Если хочешь, могу предложить ответ.",
                                  hint: PeekAnswerTiming.hint(confirm: false, links: true)))
            answerCell(PeekAnswer(text: "Отправить в votek: «да, удаляй и пересобирай»?",
                                  hint: PeekAnswerTiming.hint(confirm: true, links: false)))
            answerCell(PeekAnswer(text: "Codex не ответил: нет сети", hint: PeekAnswerTiming.hint(confirm: false, links: false), failed: true))
        }
        .padding(10).background(Color(white: 0.55))
        for (name, view, scale) in [("scene-voice.png", AnyView(grid), 2.0),
                                    ("scene-voice-detail.png", AnyView(VStack(spacing: 8) { cell(frames[0]); cell(frames[2]); cell(frames[5]); cell(frames[7]) }
                                        .padding(10).background(Color(white: 0.55))), 3.0),
                                    ("scene-voice-assistant.png", AnyView(assistant), 2.0),
                                    ("scene-voice-answer.png", AnyView(answers), 2.0)] {
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
            // Вырез камеры — чёрный, как настоящий (на экране его не видно).
            CapriFace(mood: VoiceLine.mood(f.line), style: .mask, active: false)
                .frame(width: 32, height: 16).offset(x: left + 13, y: (top - 16) / 2)
            VoiceLineView(line: f.line).padding(.horizontal, 18)
                .frame(width: w, height: h - top - 3).offset(x: left, y: top)
            if f.line.phase == .listening, VoiceLevel.speaking(f.level) {
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

    /// Peek с ответом: та же капля, глаза моноброви и `PeekAnswerView`, высота — по тексту (как в живом notch).
    @MainActor
    static func answerCell(_ a: PeekAnswer) -> some View {
        let w: CGFloat = 377, top: CGFloat = 32
        return VStack(spacing: 0) {
            HStack {
                CapriFace(mood: .idle, style: .mask, active: false).frame(width: 32, height: 16)
                Spacer()
            }
            .padding(.horizontal, 13).frame(height: top)
            PeekAnswerView(answer: a).fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: w)
        .background(GeometryReader { g in
            ZStack {
                Path(dropPath(CGRect(x: 0, y: 0, width: w, height: g.size.height), top: 8, bottom: 16, flipped: true)).fill(Color.black)
                Path(dropPath(CGRect(x: 0, y: 0, width: w, height: g.size.height), top: 8, bottom: 16, flipped: true))
                    .stroke(Palette.crimson.opacity(0.55), lineWidth: 1)
            }
        })
        .padding(.horizontal, 20).padding(.bottom, 8)
        .background(Color(red: 0.16, green: 0.17, blue: 0.2))
        .environment(\.colorScheme, .dark)
    }

    /// Нижняя часть помощника (поле, строка голоса, подсказки) — те же виды, что в `AssistantView`.
    @MainActor
    static func assistantCell(voice: VoiceLine?, hint: Bool, text: String, level: Double, label: String) -> some View {
        let w: CGFloat = 460, h: CGFloat = 104
        return ZStack(alignment: .topLeading) {
            Color(red: 0.16, green: 0.17, blue: 0.2)
            Path(dropPath(CGRect(x: 0, y: 0, width: w, height: h - 8), top: 8, bottom: 16, flipped: true)).fill(Color.black)
            HStack(alignment: .bottom, spacing: 10) {
                CapriSprite(mood: voice != nil ? .listening : .idle, active: false).frame(width: 112, height: 56)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(">").font(.mono(13, .bold)).foregroundColor(Palette.codex)
                        Text(text.isEmpty ? "спроси Capri: что ждёт? ответь… включи …" : text).font(.system(size: 12.5))
                            .foregroundColor(text.isEmpty ? Palette.dim : Palette.text).lineLimit(1)
                        Spacer(minLength: 0)
                        if voice != nil {
                            VoiceMouthView(level: { level }, fixedTick: 7).frame(width: 20, height: 12)
                        }
                    }
                    .padding(.horizontal, 9).padding(.vertical, 7)
                    .hud(stroke: Palette.codex.opacity(0.85), fill: Color.black.opacity(0.55), cut: 7)
                    AssistantVoiceRow(voice: voice, hint: hint)
                    HStack(spacing: 8) { Caps("⏎ спросить", size: 7.5); Caps("esc закрыть", size: 7.5); Spacer() }
                }
            }
            .padding(.horizontal, 14).padding(.bottom, 8).frame(width: w, height: h - 8, alignment: .bottom)
            if voice != nil, VoiceLevel.speaking(level) {
                let p = VoiceBolt.paths(left: 14, right: w - 14, bottom: h - 8, down: 1, tick: voice?.alarm == true ? 3 : 9, level: level)
                p.main.offsetBy(dx: 1.2, dy: 1.5).fill(Palette.violet)
                p.main.fill(Palette.crimson)
            }
            Text(label).font(.mono(8)).foregroundColor(.white.opacity(0.6)).offset(x: w - 230, y: 6)
        }
        .frame(width: w, height: h + 10)
        .environment(\.colorScheme, .dark)
    }

    /// Капля для SwiftUI (y вниз): `dropPath` notch рисует в слоях AppKit (y вверх) — переворачиваем.
    static func dropPath(_ r: CGRect, top: CGFloat, bottom: CGFloat, flipped: Bool) -> CGPath {
        let p = Capri.dropPath(CGRect(x: r.minX, y: 0, width: r.width, height: r.height), top: top, bottom: bottom)
        var t = CGAffineTransform(translationX: 0, y: r.height).scaledBy(x: 1, y: -1)
        return p.copy(using: &t) ?? p
    }
}
