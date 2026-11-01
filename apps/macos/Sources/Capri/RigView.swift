import AppKit
import SwiftUI
import CapriKit

/// Риг мини-маски: рисунок из `~/.capri/art/capri-rig.json` (локальный, «по мотивам»), иначе простой фолбэк из кода.
enum RigArt {
    static let url = CapriPaths.dir.appendingPathComponent("art/capri-rig.json")

    /// Загружается при первом обращении; `reload()` — после замены файла (`rig reload` в `--debug-control`).
    private(set) static var rig: CapriRig = load()

    static func load() -> CapriRig { CapriRig.load(url) ?? .fallback }

    @discardableResult
    static func reload() -> String {
        rig = load()
        return rig.name
    }

    static func color(_ ink: RigInk) -> Color {
        switch ink {
        case .mask: BiblePalette.mask
        case .ink: Color(red: 0x07 / 255, green: 0x03 / 255, blue: 0x16 / 255)
        case .white: Color(red: 0xF4 / 255, green: 0xF4 / 255, blue: 0xF5 / 255)
        case .pupil: Color(red: 0, green: 0x64 / 255, blue: 0xEB / 255)
        case .ring: BiblePalette.mask
        case .hair: BiblePalette.hair
        case .rim: BiblePalette.rim
        case .sparkle: BiblePalette.sparkle
        case .glint: Color(red: 0xF9 / 255, green: 0xF9 / 255, blue: 0xFA / 255)
        case .ghostLight: Color(white: 0.62)
        case .ghostDark: Color(white: 0.16)
        case .ghostRed: Color(red: 0.86, green: 0.25, blue: 0.22)
        case .stripe: .white
        }
    }

    /// Поза в прямоугольник `box` (коробка рига вписана по ширине, по центру), сплющивание к середине, глитч:
    /// фиолетовая копия со сдвигом и горизонтальные срезы со смещением.
    static func draw(_ pose: RigPose, in box: CGRect, squash: CGFloat = 1, glitch: Int = 0, _ ctx: GraphicsContext) {
        let rig = rig
        let shapes = rig.compose(pose)
        let s = box.width / rig.size.width
        let oy = box.midY - rig.size.height * s / 2
        func path(_ sh: RigShape, dx: CGFloat = 0) -> Path {
            var p = Path()
            guard let f = sh.points.first else { return p }
            func map(_ q: CGPoint) -> CGPoint {
                let y = oy + q.y * s
                return CGPoint(x: box.minX + q.x * s + dx, y: box.midY + (y - box.midY) * squash)
            }
            p.move(to: map(f))
            for q in sh.points.dropFirst() { p.addLine(to: map(q)) }
            p.closeSubpath()
            return p
        }
        func fill(_ c: GraphicsContext, dx: CGFloat = 0, tint: Color? = nil) {
            for sh in shapes {
                c.fill(path(sh, dx: dx), with: .color((tint ?? color(sh.ink)).opacity(sh.opacity)))
            }
        }
        guard glitch > 0 else {
            fill(ctx)
            return
        }
        // RGB-разнос: фиолетовая тень вбок, потом срезы основного рисунка со сдвигом.
        let tick = pose.tick
        fill(ctx, dx: CGFloat(1 + glitch) * s * 0.9, tint: BiblePalette.rim.opacity(0.7))
        let bands = 3 + glitch
        let all = CGRect(x: box.minX - box.width * 0.5, y: box.minY - box.height, width: box.width * 2, height: box.height * 3)
        for k in 0..<bands {
            let y0 = all.minY + all.height * CGFloat(k) / CGFloat(bands)
            var c = ctx
            c.clip(to: Path(CGRect(x: all.minX, y: y0, width: all.width, height: all.height / CGFloat(bands) + 0.5)))
            let shift = (CGFloat(TickNoise.unit(k &+ tick &* 17, 4800)) - 0.5) * CGFloat(glitch) * 5 * s
            fill(c, dx: shift)
        }
    }
}

/// Мини-маска в своём Canvas: `pad` — запас вокруг коробки (руки, волосы, «z» выходят за полосу глаз).
struct RigCanvas: View {
    var pose: RigPose
    var squash: CGFloat = 1
    var glitch = 0
    var pad: CGSize = .zero

    /// Запас вокруг полосы глаз размера `r` под руки (вверх) и волосы.
    static func margin(_ r: CGSize) -> CGSize { PerchLayout.rigMargin(r) }

    var body: some View {
        Canvas { ctx, size in
            let box = CGRect(x: pad.width, y: pad.height, width: size.width - 2 * pad.width, height: size.height - 2 * pad.height)
            RigArt.draw(pose, in: box, squash: squash, glitch: glitch, ctx)
        }
    }
}

/// Лист рига (`rig sheet` в `--debug-control`): все выражения и позы из `RigPose.library` и кадры моментов.
enum RigSheet {
    static let cell = CGSize(width: 230, height: 200)

    @MainActor
    static func render() -> [URL] {
        CapriPaths.ensureDir()
        var urls: [URL] = []
        let lib = RigPose.library
        let moments = momentFrames()
        for (name, items, cols) in [("rig-sheet.png", lib, 6), ("rig-moments.png", moments, 6)] {
            let rows = (items.count + cols - 1) / cols
            let grid = VStack(spacing: 6) {
                ForEach(0..<rows, id: \.self) { r in
                    HStack(spacing: 6) {
                        ForEach(0..<cols, id: \.self) { c in
                            let i = r * cols + c
                            if i < items.count { cellView(items[i].0, items[i].1) } else { Color.clear.frame(width: cell.width, height: cell.height) }
                        }
                    }
                }
            }
            .padding(8)
            .background(Color.black)
            let rr = ImageRenderer(content: grid)
            rr.scale = 1
            guard let cg = rr.cgImage else { continue }
            let url = CapriPaths.tmp.appendingPathComponent(name)
            if let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]), (try? data.write(to: url)) != nil {
                urls.append(url)
            }
        }
        // Крупно и мелко (как на окне 120×60 и в «значке» 32×16) — читается ли.
        let scales = HStack(alignment: .bottom, spacing: 18) {
            ForEach([360.0, 120.0, 60.0, 32.0], id: \.self) { w in
                RigCanvas(pose: lib[0].1, pad: CGSize(width: w * 0.3, height: w * 0.3))
                    .frame(width: w * 1.6, height: w * 1.1)
                    .background(Color(white: 0.13))
            }
        }
        .padding(10).background(Color(white: 0.3))
        let rr = ImageRenderer(content: scales)
        rr.scale = 1
        if let cg = rr.cgImage, let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
            let url = CapriPaths.tmp.appendingPathComponent("rig-scales.png")
            if (try? data.write(to: url)) != nil { urls.append(url) }
        }
        return urls
    }

    static func cellView(_ label: String, _ pose: RigPose) -> some View {
        ZStack(alignment: .bottomLeading) {
            Color(red: 0.11, green: 0.12, blue: 0.15)
            RigCanvas(pose: pose, pad: CGSize(width: 55, height: 70))
            Text(label).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(.yellow).padding(4)
        }
        .frame(width: cell.width, height: cell.height)
    }

    /// Кадры моментов из настоящих таймлайнов (посадка, терминал, перегрузка).
    static func momentFrames() -> [(String, RigPose)] {
        let eyes = CGRect(x: 500, y: 500, width: 120, height: 60)
        var g = SceneGeometry(home: CGRect(x: 600, y: 900, width: 32, height: 16), target: eyes, visible: CGRect(x: 0, y: 0, width: 1400, height: 1000),
                              cursor: CGPoint(x: 300, y: 450), bubble: CGRect(x: 450, y: 566, width: 170, height: 24))
        var o = SceneOptions()
        o.seed = 5
        o.perchChars = 30
        var out: [(String, RigPose)] = []
        for t in [0.95, 1.2, 1.5, 1.75, 2.2, PerchTimeline.speakEnd(o) + 0.5, RigMoments.yawnAt(o) + 0.4] {
            if let p = PerchTimeline.frame(t, g, [], o).rig { out.append((String(format: "окно t=%.2f", t), p)) }
        }
        var w = SceneWatch(window: CGRect(x: 300, y: 100, width: 700, height: 420), says: [SceneSay(at: WatchTimeline.firstSay, chars: 24)])
        g.bubble = CGRect(x: 380, y: 520, width: 170, height: 24)
        o.watch = w
        for t in [1.8, 2.4, 46, 48, 52] {
            if let p = WatchTimeline.frame(t, g, [], o, w).rig { out.append((String(format: "терм t=%.1f", t), p)) }
        }
        w.says.append(SceneSay(at: 20, chars: 20))
        w.gloatAt = 20
        o.watch = w
        for t in [20.3, 20.7, 21.6, 22.2] {
            if let p = WatchTimeline.frame(t, g, [], o, w).rig { out.append((String(format: "злорадство t=%.1f", t), p)) }
        }
        var gw = SceneWatch(window: w.window, says: w.says.prefix(1).map { $0 }, ghostAt: 10)
        o.watch = gw
        for t in [10.1, 10.5, 10.9, 11.3] {
            if let p = WatchTimeline.frame(t, g, [], o, gw).rig { out.append((String(format: "призрак t=%.1f", t), p)) }
        }
        gw.ghostAt = nil
        o.watch = nil
        o.overload = true
        for k in [0.05, 0.2, 0.4] { out.append((String(format: "перегрузка %.2f", k), RigMoments.overload(k, o))) }
        return out
    }
}
