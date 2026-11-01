import SwiftUI
import CapriKit

/// Глаза в notch на смене пространства (`SpaceSweep` из CapriKit): уезжают вместе со столом полосами со сдвигом и
/// RGB-разносом (`TransitionArt`), с цветными копиями позади, и входят с другой стороны. Рисует только кадр — время
/// ведёт `SpaceSweepLive` (пока идёт эффект) или лист.
struct SpaceSweepCanvas: View {
    var frame: SpaceSweepFrame
    /// Глаза в покое и где их видно (левое крыло капли) — в координатах верхней строки notch.
    var eyes: CGRect
    var lane: CGRect
    var alert: Bool

    static let tints: [Color] = [BiblePalette.hair, BiblePalette.rim, BiblePalette.bolt]

    /// Где глаза в верхней строке notch (как `TopRowView`: отступ 13, 32×16 по центру высоты) и где их видно.
    static func layout(rowHeight h: CGFloat, hasNotch: Bool) -> (eyes: CGRect, lane: CGRect) {
        let eyes = CGRect(x: 13, y: (h - 16) / 2, width: 32, height: 16)
        return (eyes, CGRect(x: 0, y: -h, width: hasNotch ? NotchGeometry.sideWidth : 60, height: h * 3))
    }

    /// Рисунок глаз: «тебя ждут» — много глаз; прищур — щёлки.
    static func image(alert: Bool, squint: Bool) -> NSImage? {
        if let show = ShowArt.shared { return squint ? show.vibing(beat: true) : alert ? show.all : show.open }
        return CapriArt.images[squint ? .squint : alert ? .many : .open]
    }

    var body: some View {
        Canvas { ctx, _ in
            guard frame.visible, let symbol = ctx.resolveSymbol(id: frame.squint > 0.5 ? 1 : 0) else { return }
            var c = ctx
            c.clip(to: Path(lane))
            c.opacity = Double(frame.alpha)
            let r = eyes.offsetBy(dx: frame.dx, dy: 0)
            func scaled(_ g: inout GraphicsContext, around p: CGPoint) {
                g.translateBy(x: p.x, y: p.y)
                g.scaleBy(x: frame.scaleX, y: frame.scaleY)
                g.translateBy(x: -p.x, y: -p.y)
            }
            for ghost in frame.ghosts {
                var g = c
                g.blendMode = .screen
                g.opacity *= Double(ghost.alpha)
                g.addFilter(.colorMultiply(Self.tints[ghost.tint % Self.tints.count]))
                let gr = r.offsetBy(dx: ghost.dx, dy: 0)
                scaled(&g, around: CGPoint(x: gr.midX, y: gr.midY))
                g.draw(symbol, in: gr)
            }
            var m = c
            scaled(&m, around: CGPoint(x: r.midX, y: r.midY))
            let fx = TransitionFrame(kind: .glitchBars, role: .enter, progress: 0.5, rect: r, bars: frame.bars)
            TransitionArt.drawContent(fx, symbol: symbol, in: r, squash: 1, m)
        } symbols: {
            CapriArtImage(image: Self.image(alert: alert, squint: false)).frame(width: eyes.width, height: eyes.height).tag(0)
            CapriArtImage(image: Self.image(alert: false, squint: true)).frame(width: eyes.width, height: eyes.height).tag(1)
        }
        .allowsHitTesting(false)
    }
}

/// Живой показ: перерисовка ~60 fps только пока идёт эффект (его снимает `NotchController` по окончании).
struct SpaceSweepLive: View {
    var run: SpaceSweepRun
    var rowHeight: CGFloat
    var hasNotch: Bool
    var alert: Bool

    var body: some View {
        let l = SpaceSweepCanvas.layout(rowHeight: rowHeight, hasNotch: hasNotch)
        TimelineView(.animation(minimumInterval: 1 / 60)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate - run.start
            SpaceSweepCanvas(frame: SpaceSweep.frame(t: t, style: run.style, eyes: l.eyes, lane: l.lane.minX...l.lane.maxX),
                             eyes: l.eyes, lane: l.lane, alert: alert)
        }
    }
}

// MARK: лист кадров (отладка)

enum SpaceSweepSheet {
    /// Строки листа: вид → стиль.
    static let variants: [(String, SpaceSweepStyle)] = [
        ("forward →", SpaceSweepStyle(move: .forward, seed: 11)),
        ("backward ←", SpaceSweepStyle(move: .backward, seed: 12)),
        ("unknown", SpaceSweepStyle(move: .unknown, seed: 13)),
        ("fullscreen (soft)", SpaceSweepStyle(move: .forward, soft: true, seed: 14)),
        ("reduce motion", SpaceSweepStyle(move: .forward, reduceMotion: true, seed: 15)),
    ]
    static let times: [Double] = stride(from: 0.0, through: 0.45, by: 0.03).map { ($0 * 100).rounded() / 100 }

    /// Лист: строка на вид, столбец на момент; кадр — свёрнутый notch (капля, вырез пунктиром, столбики сессий)
    /// на тёмном столе, ×3. Пишет `~/.capri/tmp/space-sweep.png`.
    @MainActor
    static func render(notchWidth: CGFloat, rowHeight: CGFloat, hasNotch: Bool, alert: Bool = false) -> URL? {
        let scale: CGFloat = 3
        let side = NotchGeometry.sideWidth
        let width = hasNotch ? notchWidth + 2 * side : NotchGeometry.pillSize.width
        // Всё происходит в левом крыле и у края выреза — остальную каплю на листе не показываем.
        let cell = CGSize(width: min(width, side + 70) + 10, height: rowHeight + 8)
        let l = SpaceSweepCanvas.layout(rowHeight: rowHeight, hasNotch: hasNotch)
        var rows: [[CGImage]] = []
        for (_, style) in variants {
            rows.append(times.compactMap { t in
                let f = SpaceSweep.frame(t: t, style: style, eyes: l.eyes, lane: l.lane.minX...l.lane.maxX)
                // Капля — в координатах AppKit (y вверх), здесь — сверху вниз.
                let drop = Path(dropPath(CGRect(x: 0, y: 0, width: width, height: rowHeight), top: hasNotch ? 6 : 0, bottom: hasNotch ? 10 : 13))
                    .applying(CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -rowHeight))
                let view = ZStack(alignment: .topLeading) {
                    Color(red: 0.16, green: 0.19, blue: 0.25)
                    ZStack(alignment: .topLeading) {
                        drop.fill(Color.black)
                        if hasNotch {
                            Path(CGRect(x: side, y: 0, width: notchWidth, height: rowHeight - 1))
                                .stroke(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                        }
                        HStack(spacing: 2.5) {
                            ForEach(0..<3, id: \.self) { i in SessionBar(status: i == 0 ? .running : .idle) }
                        }
                        .frame(width: side - 13, height: rowHeight, alignment: .trailing)
                        .offset(x: width - side)
                        SpaceSweepCanvas(frame: f, eyes: l.eyes, lane: l.lane, alert: alert)
                            .frame(width: width, height: rowHeight)
                    }
                    .frame(width: width, height: rowHeight)
                    .clipShape(drop)
                    .offset(x: 10, y: 0)
                }
                .frame(width: cell.width, height: cell.height, alignment: .topLeading)
                .clipped()
                let r = ImageRenderer(content: view)
                r.scale = scale
                return r.cgImage
            })
        }
        guard let first = rows.first?.first else { return nil }
        let w = CGFloat(first.width), h = CGFloat(first.height)
        let label: CGFloat = 22, gutter: CGFloat = 150
        let cols = 8
        // Длинная строка кадров не влезет — переносим каждые `cols` кадров; вид подписан слева.
        let lines = (times.count + cols - 1) / cols
        let W = Int(gutter + CGFloat(cols) * (w + 6)), H = Int(CGFloat(rows.count * lines) * (h + label + 6) + CGFloat(rows.count) * 10)
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(NSColor(white: 0.06, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        var y = CGFloat(H)
        let font = NSFont.monospacedSystemFont(ofSize: 15, weight: .bold)
        for (k, frames) in rows.enumerated() {
            y -= 10
            NSString(string: variants[k].0).draw(at: CGPoint(x: 8, y: y - 30), withAttributes: [.font: font, .foregroundColor: NSColor.white])
            for (i, im) in frames.enumerated() {
                let c = i % cols, line = i / cols
                let x = gutter + CGFloat(c) * (w + 6)
                let top = y - CGFloat(line) * (h + label + 6)
                ctx.draw(im, in: CGRect(x: x, y: top - label - h, width: w, height: h))
                NSString(string: String(format: "t=%.2f", times[i])).draw(at: CGPoint(x: x + 3, y: top - label + 3),
                                                                          withAttributes: [.font: font, .foregroundColor: NSColor.yellow])
            }
            y -= CGFloat(lines) * (h + label + 6)
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let image = ctx.makeImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return nil }
        CapriPaths.ensureDir()
        let url = CapriPaths.tmp.appendingPathComponent("space-sweep.png")
        return (try? data.write(to: url)) != nil ? url : nil
    }
}
