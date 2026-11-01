import AppKit
import SwiftUI
import CapriKit

/// Capri в полный рост: рисунок из `~/.capri/art/capri-body.json` (локальный, «по мотивам»), иначе простой фолбэк
/// из кода. Лицо — маска мини-рига (`RigArt.rig`). В живые сцены пока не встроено — только лист одобрения.
enum BodyArt {
    static let url = CapriPaths.dir.appendingPathComponent("art/capri-body.json")

    private(set) static var rig: BodyRig = load()

    static func load() -> BodyRig { BodyRig.load(url) ?? .fallback }

    @discardableResult
    static func reload() -> String {
        rig = load()
        return rig.name
    }

    /// Поза: ноль сцены — в точке `origin`, `scale` пунктов на единицу рига. Подряд идущие фигуры одного цвета —
    /// одной заливкой (порядок слоёв сохраняется), блёстки — по цвету одной заливкой поверх. Плотность блёсток —
    /// по масштабу (на 1× мелкие уходят под пиксель). Та же поза и масштаб — фигуры из кэша.
    static func draw(_ pose: BodyPose, at origin: CGPoint, scale: CGFloat, face: CapriRig? = nil, _ ctx: GraphicsContext) {
        let shapes = shapes(pose, scale: scale, face: face ?? RigArt.rig)
        func map(_ q: CGPoint) -> CGPoint { CGPoint(x: origin.x + q.x * scale, y: origin.y + q.y * scale) }
        var run = Path()
        var runKey: (RigInk, Double)?
        func flush() {
            if let k = runKey, !run.isEmpty { ctx.fill(run, with: .color(RigArt.color(k.0).opacity(k.1))) }
            run = Path()
        }
        var sparkles: [RigInk: Path] = [:]
        var sparkleOpacity: [RigInk: Double] = [:]
        for sh in shapes where sh.opacity > 0.01 {
            guard let f = sh.points.first else { continue }
            var p = Path()
            p.move(to: map(f))
            for q in sh.points.dropFirst() { p.addLine(to: map(q)) }
            p.closeSubpath()
            if sh.layer == "sparkle" {
                sparkles[sh.ink, default: Path()].addPath(p)
                sparkleOpacity[sh.ink] = sh.opacity
                continue
            }
            if let k = runKey, k.0 == sh.ink, abs(k.1 - sh.opacity) < 0.001 {
                run.addPath(p)
            } else {
                flush()
                runKey = (sh.ink, sh.opacity)
                run = p
            }
        }
        flush()
        for (ink, p) in sparkles { ctx.fill(p, with: .color(RigArt.color(ink).opacity(sparkleOpacity[ink] ?? 1))) }
    }

    private static var cache: (pose: BodyPose, scale: CGFloat, face: String, shapes: [RigShape])?

    static func shapes(_ pose: BodyPose, scale: CGFloat, face: CapriRig) -> [RigShape] {
        if let c = cache, c.pose == pose, c.scale == scale, c.face == face.name { return c.shapes }
        let out = rig.compose(pose, face: face, sparkle: Double(max(0.35, min(1, scale / 2))))
        cache = (pose, scale, face.name, out)
        return out
    }
}

/// Лист одобрения тела (`body sheet` в `--debug-control`): все позы в 2× и в натуральную величину, полосы танца и
/// качания ног сидя в 2× и 1×. Пишет `~/.capri/tmp/body-sheet.png`.
enum BodySheet {
    /// Клетка в натуральную величину (пункты).
    static let cell = CGSize(width: 200, height: 250)

    @MainActor
    static func render() -> URL? {
        CapriPaths.ensureDir()
        // Лицо — свежая копия рига с диска, не трогая живой notch (`RigArt.reload` перезагрузил бы и его).
        let face = RigArt.load()
        let b = BodyArt.rig.bones
        let poses = BodyMoves.catalog(b)
        let dance = BodyMoves.danceStrip(b)
        let swing = BodyMoves.swingStrip(b)
        let sheet = VStack(alignment: .leading, spacing: 10) {
            title("Capri — full body (\(BodyArt.rig.name)) · poses 2×")
            grid(poses, cols: 8, k: 2, face: face)
            title("poses 1× (real size)")
            row(poses, k: 1, face: face)
            title("dance strip 2× (¼ beat per frame; bar 1 wave+hip, bar 2 V-arms)")
            row(dance, k: 2, face: face)
            title("sit on window edge, legs swing 2× (one period \(String(format: "%.1f", BodyMoves.swingPeriod)) s)")
            row(swing, k: 2, face: face)
            title("dance + swing 1×")
            row(dance + swing, k: 1, face: face)
        }
        .padding(16)
        .background(Color(white: 0.03))
        let rr = ImageRenderer(content: sheet)
        rr.scale = 1
        guard let cg = rr.cgImage, let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return nil }
        let url = CapriPaths.tmp.appendingPathComponent("body-sheet.png")
        return (try? data.write(to: url)) != nil ? url : nil
    }

    static func title(_ s: String) -> some View {
        Text(s).font(.system(size: 18, weight: .bold, design: .monospaced)).foregroundColor(.yellow)
    }

    static func grid(_ frames: [BodyFrame], cols: Int, k: CGFloat, face: CapriRig) -> some View {
        let rows = (frames.count + cols - 1) / cols
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<rows, id: \.self) { r in
                HStack(spacing: 4) {
                    ForEach(0..<cols, id: \.self) { c in
                        let i = r * cols + c
                        if i < frames.count { cellView(frames[i], k: k, face: face) }
                    }
                }
            }
        }
    }

    static func row(_ frames: [BodyFrame], k: CGFloat, face: CapriRig) -> some View {
        HStack(spacing: 4) { ForEach(0..<frames.count, id: \.self) { cellView(frames[$0], k: k, face: face) } }
    }

    static func cellView(_ f: BodyFrame, k: CGFloat, face: CapriRig) -> some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.085, green: 0.09, blue: 0.12)))
                let o = origin(f, size, k)
                stage(f.stage, at: o, k: k, size: size, ctx)
                BodyArt.draw(f.pose, at: o, scale: k, face: face, ctx)
            }
            Text(f.name).font(.system(size: 9 * max(1, k * 0.7), weight: .bold, design: .monospaced))
                .foregroundColor(.yellow).padding(4)
        }
        .frame(width: cell.width * k, height: cell.height * k)
        .clipped()
    }

    /// Ноль сцены в клетке: пол — внизу, край окна — посередине (висит — сверху), уход лужи — левее. По `spot`
    /// кадра, не по имени.
    static func origin(_ f: BodyFrame, _ size: CGSize, _ k: CGFloat) -> CGPoint {
        var x = size.width / 2, y = size.height - 22 * k
        switch f.stage {
        case .edge, .terminal: y = 135 * k
        case .sill: x = size.width * 0.4
        default: break
        }
        switch f.spot {
        case .floor: break
        case .seat: x = size.width * 0.42
        case .hang: y = 32 * k
        case .walk: y = size.height - 22 * k; x = size.width * 0.32
        case .leave: x = size.width * 0.3
        }
        return CGPoint(x: x, y: y)
    }

    /// Окружение: пол, окно под краем, рама с подоконником, светлый дверной проём, терминал со строками.
    static func stage(_ s: BodyStage, at o: CGPoint, k: CGFloat, size: CGSize, _ ctx: GraphicsContext) {
        func rect(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat, _ c: Color) {
            ctx.fill(Path(CGRect(x: o.x + x0 * k, y: o.y + y0 * k, width: (x1 - x0) * k, height: (y1 - y0) * k)), with: .color(c))
        }
        let floor = Color(red: 0.13, green: 0.14, blue: 0.18)
        switch s {
        case .ground:
            rect(-300, 0, 300, 300, floor)
        case .edge:
            rect(-70, 0, 70, 300, Color(red: 0.16, green: 0.17, blue: 0.22))
            rect(-70, 0, 70, 7, Color(red: 0.23, green: 0.24, blue: 0.3))
        case .terminal:
            rect(-70, 0, 70, 300, Color(red: 0.05, green: 0.06, blue: 0.08))
            rect(-70, 0, 70, 7, Color(red: 0.15, green: 0.15, blue: 0.18))
            for i in 0..<7 {
                let w = CGFloat(18 + (i * 37) % 70)
                rect(-62, CGFloat(15 + i * 9), -62 + w, CGFloat(18.5 + Double(i) * 9), Color(red: 0.25, green: 0.8, blue: 0.47))
            }
        case .sill:
            let sx = BodyMoves.sill.x, sy = BodyMoves.sill.y
            rect(-300, 0, 300, 300, floor)
            rect(sx + 2, -200, 300, sy, Color(red: 0.84, green: 0.87, blue: 0.93))
            rect(sx + 2, sy, 300, 0, Color(red: 0.2, green: 0.22, blue: 0.28))
            rect(sx - 3, -200, sx + 2, 0, Color(red: 0.28, green: 0.29, blue: 0.36))
        case .door:
            rect(-300, 0, 300, 300, Color(red: 0.11, green: 0.12, blue: 0.15))
            rect(-300, -300, 300, 0, Color(red: 0.1, green: 0.1, blue: 0.13))
            rect(-46, -230, 46, 0, Color(red: 0.93, green: 0.9, blue: 0.86))
        }
    }
}
