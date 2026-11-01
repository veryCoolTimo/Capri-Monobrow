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
            // Слушает — смотрит прямо на того, кто говорит (не по сторонам), изредка моргает.
            return blinking(5.2) ? .blink : .open
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
        case .vibing:
            guard !still else { return .open }
            return vibing(beat: SceneTimeline.onBeat(since))
        }
    }

    /// Кивает под музыку: на сильную долю — щёлки (одно правило с `ShowArt.vibing` и `VibingMask`).
    static func vibing(beat: Bool) -> Frame { beat ? .slits : .open }

    /// Кадр встроенного арта для клипа сцены (когда клипов сериала нет).
    static func frame(clip: String, t: Double) -> Frame {
        switch clip {
        case SceneClip.close, SceneClip.teleOut, SceneClip.shut: return t < 0.1 ? .squint : .blink
        case SceneClip.many, SceneClip.burst, SceneClip.melt: return .many
        case SceneClip.slits: return .slits
        case SceneClip.talk: return Int(t * 5) % 2 == 0 ? .speakA : .speakB
        case SceneClip.appear, SceneClip.teleIn: return t < 0.12 ? .blink : .open
        default:
            let p = t.truncatingRemainder(dividingBy: 3.4)
            return p < 1.2 ? .open : p < 2.0 ? .lookLeft : p < 2.8 ? .lookRight : .open
        }
    }
}

/// Клипы сериала с Capri крупным планом — только локально, в `~/.capri/art/eyes/` (кадры сериала не входят
/// в публичный репозиторий; кладёт `scripts/push-capri-art.sh`). `clips.json`: `{"fps": 24, "clips": {"look":
/// [["000.png", 14], …], …}}` — держания в кадрах `fps`. Обязателен `look` (рассматривает); по желанию `close`,
/// `many` (закрыла глаза → много глаз), `slits` (щёлки), `appear`, `talk`, `shut`, `burst` (маска появляется,
/// говорит, закрывает глаза, взрыв глаз), `crazy` (безумный глитч); для сцен на столе — `tele_out`, `tele_in` (телепорт),
/// `melt` (окно рассыпается), `tex_mosh`, `tex_graffiti` (текстуры «захвата»); для окон (проход 3, 16:10) —
/// `face_talk`, `face_nod`, `face_scan`, `face_grin`, `hair_bob`, `side_look`, `eye_zoom`. Нет папки — Capri показывает кадры `CapriArt`.
struct ShowArt {
    let images: [NSImage]
    let fps: Double
    let clips: [String: FrameClip]
    /// «Тебя ждут»: маска появляется → закрывает глаза → взрыв глаз (или глаза закрываются → много глаз), по кругу.
    let alert: FrameClip

    static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".capri/art/eyes")
    static let shared: ShowArt? = load(dir)
    static let names = SceneClip.all

    /// Потолок папки: рисунков и байт PNG (сейчас ≈ 290 рисунков, 43 МБ).
    static let maxImages = 640
    static let maxBytes = 160 << 20

    static func load(_ dir: URL) -> ShowArt? {
        func skip(_ why: String) -> ShowArt? {
            NSLog("[Capri] ~/.capri/art/eyes: %@ — показываю встроенные кадры", why)
            return nil
        }
        let json = dir.appendingPathComponent("clips.json")
        guard FileManager.default.fileExists(atPath: json.path) else { return nil }
        guard let data = try? Data(contentsOf: json),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["clips"] as? [String: Any] else { return skip("clips.json не читается") }
        let fps = (root["fps"] as? Double).map { min(max($0, 6), 30) } ?? 12
        var images: [NSImage] = [], index: [String: Int] = [:], bytes = 0
        func clip(_ name: String) -> FrameClip? {
            guard let list = raw[name] as? [[Any]], !list.isEmpty else { return nil }
            var frames: [Int] = [], holds: [Int] = []
            for item in list {
                // Только PNG прямо в папке, рисунок до 4 МБ, всего до `maxImages` рисунков и `maxBytes`.
                guard item.count == 2, let file = item[0] as? String, let hold = item[1] as? Int,
                      file.hasSuffix(".png"), !file.hasPrefix("."), !file.contains("/") else { return nil }
                if index[file] == nil {
                    let url = dir.appendingPathComponent(file)
                    guard images.count < maxImages,
                          let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4 << 20,
                          bytes + size <= maxBytes,
                          let im = NSImage(contentsOf: url) else { return nil }
                    index[file] = images.count
                    images.append(im)
                    bytes += size
                }
                frames.append(index[file]!)
                holds.append(hold)
            }
            return FrameClip(frames: frames, holds: holds)
        }
        var clips: [String: FrameClip] = [:]
        // `look` — первым: без него показа нет. Остальные клипы не прошли — пропускаем только их (сцена возьмёт
        // фолбэк), а не весь показ.
        for name in [SceneClip.look] + names.filter({ $0 != SceneClip.look }) where raw[name] != nil {
            guard let c = clip(name) else {
                if name == SceneClip.look { return skip("клип look: нужны PNG до 4 МБ прямо в папке") }
                NSLog("[Capri] ~/.capri/art/eyes: клип %@ пропущен (PNG до 4 МБ прямо в папке, всего до %d рисунков)", name, maxImages)
                continue
            }
            clips[name] = c
        }
        guard let look = clips["look"] else { return skip("нет клипа look") }
        let second = Int(fps)
        let none = FrameClip(frames: [], holds: [])
        let alert: FrameClip = if let burst = clips["burst"] {
            (clips["appear"] ?? none)
                + (clips["talk"].map { FrameClip(frames: [$0.frames[0]], holds: [second / 2]) } ?? none)
                + (clips["shut"] ?? none)
                + burst.holdingLast(second)
        } else if let close = clips["close"], let many = clips["many"] {
            close.capped(second / 2) + many.holdingLast(2 * second)
        } else {
            look
        }
        return ShowArt(images: images, fps: fps, clips: clips, alert: alert)
    }

    private func clip(_ name: String) -> FrameClip { clips[name] ?? clips["look"]! }

    /// Клип без подмены на `look`: сцене нужно знать, есть ли он.
    func clip(named name: String) -> FrameClip? { clips[name] }

    /// Рисунок клипа `name` через `t` секунд от его начала (нет клипа — `look`).
    func image(clip name: String, t: Double, loop: Bool) -> NSImage? {
        image(clip: name, t: t, mode: loop ? .loop : .once)
    }

    func image(clip name: String, t: Double, mode: FrameClip.Mode) -> NSImage? {
        clip(name).frame(at: Int(max(0, t) * fps), mode: mode).map { images[$0] }
    }

    /// Рисунок настроения: `tick` — общий счётчик кадров `fps`, `since` — кадры с начала настроения.
    func image(_ mood: CapriMood, tick: Int, since: Int) -> NSImage? {
        // Покой: рассматривает три круга, потом — сцена «тебя ждут» (маска, закрыла глаза, взрыв глаз), и снова.
        if mood == .vibing { return vibing(beat: SceneTimeline.onBeat(Double(since) / fps)) }
        let calm = clip("look").total * 3, k = tick % (calm + alert.total)
        let i: Int? = switch mood {
        case .idle: k < calm ? clip("look").frame(at: k, loop: true) : alert.frame(at: k - calm, loop: false)
        // Слушает — открытые глаза прямо на человека, моргание раз в ~5 с (не «рассматривает» по сторонам).
        case .listening: nil
        case .speaking: clip("talk").frame(at: tick, loop: true)
        case .thinking: clip("slits").frame(at: since, loop: false)
        case .alert: alert.frame(at: since, loop: true)
        case .error: clip(clips["crazy"] != nil ? "crazy" : "slits").frame(at: since, loop: clips["crazy"] != nil)
        case .vibing: nil
        }
        if mood == .listening { return (Double(tick) / fps).truncatingRemainder(dividingBy: 5.2) < 0.16 ? shut : open }
        return i.map { images[$0] }
    }

    /// Кивает под музыку: на сильную долю — щёлки (нет клипа — закрытые глаза), иначе открытые.
    func vibing(beat: Bool) -> NSImage? {
        guard beat else { return open }
        return clips[SceneClip.slits] != nil ? last(SceneClip.slits) : shut
    }

    /// Один рисунок без движения («Уменьшить движение», пауза).
    func still(_ mood: CapriMood) -> NSImage? {
        switch mood {
        case .idle, .listening, .vibing: open
        case .speaking: first("talk")
        case .thinking, .error: last("slits")
        case .alert: all
        }
    }

    /// Конец сцены «тебя ждут» (последние 0,7 с: взрыв глаз держится) — розовый «взлом», как в сериале.
    func hacking(_ mood: CapriMood, tick: Int, since: Int) -> Bool {
        let tail = Int(fps * 0.7), calm = clip("look").total * 3
        switch mood {
        case .alert: return since % alert.total >= alert.total - tail
        case .idle: return tick % (calm + alert.total) >= calm + alert.total - tail
        default: return false
        }
    }

    private func first(_ name: String) -> NSImage? { clip(name).frames.first.map { images[$0] } }
    private func last(_ name: String) -> NSImage? { clip(name).frames.last.map { images[$0] } }

    /// Мини-глаза: открытые, закрытые (моргание) и много глаз.
    var open: NSImage? { first("look") }
    var shut: NSImage? { clips["close"] != nil ? last("close") : open }
    var all: NSImage? { clips["many"] != nil ? last("many") : last("burst") }
}

/// Анимированные глаза Capri. `active` — анимировать (виден и нужен); иначе статичный кадр.
struct CapriSprite: View {
    var mood: CapriMood
    var active = true

    /// Настроение и когда оно началось: пока `onChange` не сработал, новое настроение считается только что начавшимся.
    @State private var started: (mood: CapriMood, at: Date)?
    private var still: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / (ShowArt.shared?.fps ?? CapriFace.fps), paused: !active || still)) { ctx in
            let animating = active && !still
            let t = ctx.date.timeIntervalSinceReferenceDate
            let since = started?.mood == mood ? max(0, ctx.date.timeIntervalSince(started!.at)) : 0
            // Эффекты — «на двойках» (12 fps), клипы — в своём темпе.
            let tick = Int(t * CapriFace.fps), sinceTick = Int(since * CapriFace.fps)
            let image: NSImage? = if let show = ShowArt.shared {
                animating ? show.image(mood, tick: Int(t * show.fps), since: Int(since * show.fps)) : show.still(mood)
            } else {
                CapriArt.images[CapriArt.frame(mood, t: t, since: since, still: !animating)]
            }
            let hacking = animating && ShowArt.shared?.hacking(mood, tick: Int(t * (ShowArt.shared?.fps ?? 12)),
                                                                since: Int(since * (ShowArt.shared?.fps ?? 12))) == true
            CapriShotView(image: image,
                          glitch: hacking ? CapriFX.make(level: 4, tick: tick, strength: 1)
                              : animating ? CapriFX.glitch(mood, tick: tick, since: sinceTick) : nil,
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
