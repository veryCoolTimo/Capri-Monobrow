import SwiftUI
import AppKit
import CapriKit

/// Арт Capri: её глаза крупным планом, как в сериале (зелёная полоса маски, глаза-миндалины с шипами).
/// Кадры сгенерированы Codex по кадрам сериала (промпт и сырые кадры — локально в `work/art/v5/`, в репозитории
/// только финальные кадры). Все кадры одного кадрирования, отличаются только глазами/ртом.
enum CapriArt {
    enum Frame: String, CaseIterable {
        case open, blink, squint, lookLeft = "look-left", lookRight = "look-right", slits, many, speakA, speakB
    }

    static let images: [Frame: NSImage] = {
        var out: [Frame: NSImage] = [:]
        for f in Frame.allCases { if let url = url(f.rawValue), let im = NSImage(contentsOf: url) { out[f] = im } }
        if out.count != Frame.allCases.count {
            NSLog("[Capri] кадры персонажа: найдено %d из %d", out.count, Frame.allCases.count)
        }
        return out
    }()

    /// Пропорции кадра (ширина / высота).
    static let aspect: CGFloat = 2

    /// В `.app` — `Contents/Resources/Capri/` (кладёт build-macos.sh); при `swift run` — бандл ресурсов SwiftPM
    /// рядом с исполняемым файлом (`Bundle.module` не используем: без бандла он падает).
    static func url(_ name: String) -> URL? {
        if let u = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Capri") { return u }
        guard let dir = Bundle.main.executableURL?.deletingLastPathComponent(),
              let dev = Bundle(url: dir.appendingPathComponent("Capri_Capri.bundle")) else { return nil }
        return dev.url(forResource: name, withExtension: "png", subdirectory: "Capri")
            ?? dev.url(forResource: name, withExtension: "png")
    }

    /// Кадр настроения в момент `t` (секунды), `since` — секунды с начала настроения. Позы сменяются резко,
    /// как в аниме, без наплыва. `still` — «Уменьшить движение» или пауза: один кадр.
    static func frame(_ mood: CapriMood, t: Double, since: Double, still: Bool) -> Frame {
        func blinking(_ cycle: Double) -> Bool { !still && t.truncatingRemainder(dividingBy: cycle) < 0.16 }
        switch mood {
        case .idle:
            guard !still else { return .open }
            // Раз в ~11 с она «рассматривает»: прищур, взгляд влево, вправо; иначе — открытые глаза и моргание.
            let p = t.truncatingRemainder(dividingBy: 11)
            if p >= 7.5 && p < 8.1 { return .squint }
            if p >= 8.1 && p < 9.1 { return .lookLeft }
            if p >= 9.1 && p < 10.1 { return .lookRight }
            return blinking(4.3) ? .blink : .open
        case .listening:
            return blinking(5.2) ? .blink : .lookRight
        case .thinking:
            guard !still else { return .slits }
            return t.truncatingRemainder(dividingBy: 1.6) < 0.8 ? .slits : .squint
        case .speaking:
            guard !still else { return .speakA }
            // Слоги: ~5 в секунду.
            return Int(t * 5) % 2 == 0 ? .speakA : .speakB
        case .alert:
            // Как в сериале: глаза закрываются, по маске расползается много глаз, потом снова открытые.
            guard !still else { return .many }
            let p = since.truncatingRemainder(dividingBy: 3.2)
            if p < 0.35 { return .blink }
            if p < 2.4 { return .many }
            return .open
        case .error:
            return .slits
        }
    }
}

/// Клипы сериала с её глазами крупным планом — только локально, в `~/.capri/art/eyes/` (кадры сериала не входят
/// в публичный репозиторий; кладёт `scripts/push-capri-art.sh`). `clips.json` (12 fps): `{"clips": {"look":
/// [["000.png", 35], …], "close": …, "many": …, "slits": …}}`. Нет папки — Capri показывает кадры `CapriArt`.
struct ShowArt {
    let images: [NSImage]
    let look, close, many, slits: FrameClip
    /// «Тебя ждут»: глаза закрываются → много глаз, по кругу.
    let alert: FrameClip

    static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".capri/art/eyes")
    static let shared: ShowArt? = load(dir)

    static func load(_ dir: URL) -> ShowArt? {
        func skip(_ why: String) -> ShowArt? {
            NSLog("[Capri] ~/.capri/art/eyes: %@ — показываю встроенные кадры", why)
            return nil
        }
        let json = dir.appendingPathComponent("clips.json")
        guard FileManager.default.fileExists(atPath: json.path) else { return nil }
        guard let data = try? Data(contentsOf: json),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clips = root["clips"] as? [String: Any] else { return skip("clips.json не читается") }
        var images: [NSImage] = [], index: [String: Int] = [:]
        func clip(_ name: String) -> FrameClip? {
            guard let list = clips[name] as? [[Any]], !list.isEmpty else { return nil }
            var frames: [Int] = [], holds: [Int] = []
            for item in list {
                // Только PNG прямо в папке, не больше 64 рисунков по 4 МБ.
                guard item.count == 2, let file = item[0] as? String, let hold = item[1] as? Int,
                      file.hasSuffix(".png"), !file.hasPrefix("."), !file.contains("/") else { return nil }
                if index[file] == nil {
                    let url = dir.appendingPathComponent(file)
                    guard images.count < 64,
                          let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4 << 20,
                          let im = NSImage(contentsOf: url) else { return nil }
                    index[file] = images.count
                    images.append(im)
                }
                frames.append(index[file]!)
                holds.append(hold)
            }
            return FrameClip(frames: frames, holds: holds)
        }
        guard let look = clip("look"), let close = clip("close"), let many = clip("many"), let slits = clip("slits") else {
            return skip("нужны клипы look, close, many, slits из PNG до 4 МБ")
        }
        return ShowArt(images: images, look: look, close: close, many: many, slits: slits,
                       alert: close.capped(6) + many.holdingLast(26))
    }

    /// Рисунок настроения: `tick` — общий счётчик 12 fps, `since` — тики с начала настроения.
    func image(_ mood: CapriMood, tick: Int, since: Int) -> NSImage? {
        let i: Int?
        switch mood {
        case .idle, .listening, .speaking: i = look.frame(at: tick, loop: true)
        case .thinking, .error: i = slits.frame(at: since, loop: false)
        case .alert: i = alert.frame(at: since, loop: true)
        }
        return i.map { images[$0] }
    }

    /// Один рисунок без движения («Уменьшить движение», пауза).
    func still(_ mood: CapriMood) -> NSImage? {
        switch mood {
        case .idle, .listening, .speaking: open
        case .thinking, .error: slits.frames.last.map { images[$0] }
        case .alert: all
        }
    }

    /// Мини-глаза: открытые, закрытые (моргание) и много глаз.
    var open: NSImage? { look.frames.first.map { images[$0] } }
    var shut: NSImage? { close.frames.last.map { images[$0] } }
    var all: NSImage? { many.frames.last.map { images[$0] } }
}

/// Анимированные глаза Capri. `active` — анимировать (виден и нужен); иначе статичный кадр.
struct CapriSprite: View {
    var mood: CapriMood
    var active = true

    /// Настроение и когда оно началось: пока `onChange` не сработал, новое настроение считается только что начавшимся.
    @State private var started: (mood: CapriMood, at: Date)?
    private var still: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / CapriFace.fps, paused: !active || still)) { ctx in
            let animating = active && !still
            let t = ctx.date.timeIntervalSinceReferenceDate
            let since = started?.mood == mood ? max(0, ctx.date.timeIntervalSince(started!.at)) : 0
            let tick = Int(t * CapriFace.fps), sinceTick = Int(since * CapriFace.fps)
            let image: NSImage? = if let show = ShowArt.shared {
                animating ? show.image(mood, tick: tick, since: sinceTick) : show.still(mood)
            } else {
                CapriArt.images[CapriArt.frame(mood, t: t, since: since, still: !animating)]
            }
            CapriShotView(image: image,
                          glitch: animating ? CapriFX.glitch(mood, tick: tick, since: sinceTick) : nil,
                          bolt: animating ? CapriFX.bolt(mood, tick: tick, since: sinceTick) : nil)
        }
        .onAppear { started = (mood, Date()) }
        .onChange(of: mood) { m in started = (m, Date()) }
        .accessibilityLabel(Text("Capri"))
    }
}

/// Один кадр, вписанный с сохранением пропорций.
struct CapriArtImage: View {
    var image: NSImage?
    init(image: NSImage?) { self.image = image }
    init(frame: CapriArt.Frame) { image = CapriArt.images[frame] }

    var body: some View {
        if let image {
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
        }
    }
}
