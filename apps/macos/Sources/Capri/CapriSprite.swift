import SwiftUI
import AppKit

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

/// Анимированные глаза Capri. `active` — анимировать (виден и нужен); иначе статичный кадр.
struct CapriSprite: View {
    var mood: CapriMood
    var active = true

    @State private var changedAt = Date()
    private var still: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / CapriFace.fps, paused: !active || still)) { ctx in
            let animating = active && !still
            let t = ctx.date.timeIntervalSinceReferenceDate
            let f = CapriArt.frame(mood, t: t, since: max(0, ctx.date.timeIntervalSince(changedAt)), still: !animating)
            // Ошибка: короткий глитч-сдвиг раз в 1.7 с.
            let jitter: CGFloat = mood == .error && animating && t.truncatingRemainder(dividingBy: 1.7) < 0.12 ? 3 : 0
            CapriArtImage(frame: f).offset(x: jitter)
        }
        .onChange(of: mood) { _ in changedAt = Date() }
        .accessibilityLabel(Text("Capri"))
    }
}

/// Один кадр, вписанный с сохранением пропорций.
struct CapriArtImage: View {
    var frame: CapriArt.Frame
    var body: some View {
        if let im = CapriArt.images[frame] {
            Image(nsImage: im).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
        }
    }
}
