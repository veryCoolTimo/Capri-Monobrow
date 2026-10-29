import SwiftUI

// Стиль notch: HUD по референсам Тимофея. Перенесено из NotchSpike (Этап 0).

/// Палитра по референсам Тимофея (refs/ui-capri-2026-10-29, в репозиторий не входят): малиновый
/// акцент, кислотно-зелёный — «ждёт меня», тонкая фиолетовая обводка, чёрная капля.
enum Palette {
    static let crimson = Color(red: 0.91, green: 0.09, blue: 0.25)
    static let crimsonNS = NSColor(srgbRed: 0.91, green: 0.09, blue: 0.25, alpha: 1)
    static let acid = Color(red: 0.24, green: 0.96, blue: 0.54)
    static let acidNS = NSColor(srgbRed: 0.24, green: 0.96, blue: 0.54, alpha: 1)
    static let violet = Color(red: 0.42, green: 0.29, blue: 1.0)
    /// Всё, что сказал Codex: светлый фиолетовый, читается на чёрном.
    static let codex = Color(red: 0.68, green: 0.6, blue: 1.0)
    static let text = Color(red: 0.95, green: 0.91, blue: 0.92)
    static let dim = Color(red: 0.61, green: 0.54, blue: 0.55)
    static let line = crimson.opacity(0.55)
    static let fill = crimson.opacity(0.07)
}

extension Font {
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// HUD-подпись: моноширинный КАПС с разрядкой.
struct Caps: View {
    var text: String
    var size: CGFloat = 9
    var color: Color = Palette.dim
    var weight: Font.Weight = .semibold
    init(_ text: String, size: CGFloat = 9, color: Color = Palette.dim, weight: Font.Weight = .semibold) {
        self.text = text; self.size = size; self.color = color; self.weight = weight
    }
    var body: some View {
        Text(text.uppercased()).font(.mono(size, weight)).tracking(size * 0.12).foregroundColor(color).lineLimit(1)
    }
}

/// Прямоугольник со срезанными углами (верхний правый и нижний левый).
struct Chamfer: Shape {
    var cut: CGFloat = 7
    func path(in r: CGRect) -> Path {
        let c = min(cut, r.width / 4, r.height / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - c, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + c))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + c, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - c))
        p.closeSubpath()
        return p
    }
}

struct HUDFrame: ViewModifier {
    var stroke: Color = Palette.line
    var fill: Color = Palette.fill
    var cut: CGFloat = 7
    func body(content: Content) -> some View {
        content
            .background(Chamfer(cut: cut).fill(fill))
            .overlay(Chamfer(cut: cut).stroke(stroke, lineWidth: 1))
    }
}

extension View {
    func hud(stroke: Color = Palette.line, fill: Color = Palette.fill, cut: CGFloat = 7) -> some View {
        modifier(HUDFrame(stroke: stroke, fill: fill, cut: cut))
    }
}

/// Значок Capri: рваные малиновые осколки, зелёный угловатый глаз, фиолетовая обводка.
/// Свой рисунок по мотивам, не копия арта.
struct CapriGlyph: View {
    var alert: Bool
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * w, y: y * h) }
            var shards = Path()
            shards.addLines([pt(0.02, 0.95), pt(0.18, 0.30), pt(0.30, 0.55), pt(0.42, 0.02), pt(0.55, 0.42),
                             pt(0.78, 0.08), pt(0.70, 0.50), pt(0.98, 0.35), pt(0.80, 0.95)])
            shards.closeSubpath()
            ctx.stroke(shards, with: .color(Palette.violet), lineWidth: 1.6)
            ctx.fill(shards, with: .color(Palette.crimson))
            var eye = Path()
            eye.addLines([pt(0.22, 0.66), pt(0.52, 0.44), pt(0.86, 0.58), pt(0.56, 0.86)])
            eye.closeSubpath()
            ctx.fill(eye, with: .color(alert ? Palette.acid : Color(white: 0.12)))
            let pupil = CGRect(x: 0.47 * w, y: 0.56 * h, width: 0.17 * w, height: 0.17 * w)
            ctx.fill(Path(ellipseIn: pupil.insetBy(dx: -1, dy: -1)), with: .color(Palette.violet))
            ctx.fill(Path(ellipseIn: pupil), with: .color(.white))
        }
        .frame(width: 20, height: 17)
    }
}

/// Сегментная полоска (как «LOADING 64%»): сколько ждёт сессия, полная — 10 минут.
struct SegmentBar: View {
    var fraction: Double
    var color: Color
    var segments = 10
    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<segments, id: \.self) { i in
                Rectangle().fill(Double(i) < fraction * Double(segments) ? color : color.opacity(0.18))
                    .frame(width: 3, height: 7)
            }
        }
    }
}

/// Декоративный штрихкод: детерминированный из строки.
struct Barcode: View {
    var seed: String
    var body: some View {
        Canvas { ctx, size in
            var x: CGFloat = 0
            var h = UInt64(1469598103934665603)
            for b in seed.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
            while x < size.width {
                h = h &* 6364136223846793005 &+ 1442695040888963407
                let w = CGFloat(1 + (h >> 60) % 3)
                if (h >> 33) % 3 != 0 { ctx.fill(Path(CGRect(x: x, y: 0, width: w, height: size.height)), with: .color(Palette.crimson.opacity(0.5))) }
                x += w + 1
            }
        }
    }
}
