// Рисует значок Capri (1024×1024 PNG): своя геометрическая стилизация — малиновый фон с искрами,
// чёрные рваные осколки с фиолетовой кромкой, кислотно-зелёный визор с одним глазом.
// Запуск: swift scripts/make-icon.swift out.png  (делает scripts/build-macos.sh, если значка нет)
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "capri-icon.png"

let crimson = CGColor(srgbRed: 0.91, green: 0.09, blue: 0.25, alpha: 1)
let crimsonDeep = CGColor(srgbRed: 0.55, green: 0.03, blue: 0.15, alpha: 1)
let acid = CGColor(srgbRed: 0.24, green: 0.96, blue: 0.54, alpha: 1)
let violet = CGColor(srgbRed: 0.45, green: 0.30, blue: 1.0, alpha: 1)
let ink = CGColor(srgbRed: 0.04, green: 0.02, blue: 0.06, alpha: 1)
let white = CGColor(srgbRed: 1, green: 0.97, blue: 0.97, alpha: 1)

guard let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("no context") }
// Координаты ниже — от верхнего левого угла, как в редакторе.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

func poly(_ pts: [(CGFloat, CGFloat)]) -> CGPath {
    let p = CGMutablePath()
    p.addLines(between: pts.map { CGPoint(x: $0.0, y: $0.1) })
    p.closeSubpath()
    return p
}

// Тело значка по сетке macOS: 824×824 со скруглением.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Тень под телом.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 30, color: CGColor(gray: 0, alpha: 0.45))
ctx.addPath(squircle); ctx.setFillColor(crimson); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(squircle); ctx.clip()

// Фон: малиновый градиент сверху вниз.
let bg = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [crimson, crimsonDeep] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])

// Искры: детерминированный «шум».
var seed: UInt64 = 0xC0FFEE
func rnd() -> CGFloat {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return CGFloat(seed >> 40) / CGFloat(1 << 24)
}
for _ in 0..<420 {
    let x = 100 + rnd() * 824, y = 100 + rnd() * 560, r = 1.5 + rnd() * 3.5
    ctx.setFillColor(CGColor(srgbRed: 1, green: 0.8, blue: 0.9, alpha: 0.25 + rnd() * 0.55))
    ctx.fillEllipse(in: CGRect(x: x, y: y, width: r, height: r))
}

// Осколки: рваный силуэт снизу, с фиолетовой кромкой (та же форма, сдвинутая).
let shards = poly([(60, 980), (150, 560), (250, 640), (330, 300), (450, 500), (560, 150), (585, 430),
                   (800, 250), (720, 520), (980, 470), (870, 640), (980, 760), (980, 980)])
ctx.saveGState(); ctx.translateBy(x: -14, y: -12)
ctx.addPath(shards); ctx.setFillColor(violet); ctx.fillPath()
ctx.restoreGState()
ctx.addPath(shards); ctx.setFillColor(ink); ctx.fillPath()

// Визор: угловатая зелёная пластина наискось.
let visor = poly([(250, 610), (520, 515), (820, 560), (735, 735), (330, 760)])
ctx.addPath(visor); ctx.setFillColor(acid); ctx.fillPath()
// Тёмный клин, рассекающий визор.
ctx.addPath(poly([(560, 505), (600, 520), (520, 760), (490, 760)])); ctx.setFillColor(ink); ctx.fillPath()

// Глаз: чёрное кольцо, зелёный ободок, фиолетовая радужка, белый блик.
let eye = CGPoint(x: 400, y: 640)
func disk(_ c: CGPoint, _ r: CGFloat, _ color: CGColor) {
    ctx.setFillColor(color); ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
}
disk(eye, 92, ink); disk(eye, 74, acid); disk(eye, 60, ink); disk(eye, 48, violet)
disk(CGPoint(x: eye.x + 8, y: eye.y + 4), 22, white)

// Крестик-шрам на правой половине визора.
ctx.setStrokeColor(ink); ctx.setLineWidth(16); ctx.setLineCap(.square)
ctx.move(to: CGPoint(x: 625, y: 590)); ctx.addLine(to: CGPoint(x: 735, y: 665))
ctx.move(to: CGPoint(x: 700, y: 570)); ctx.addLine(to: CGPoint(x: 655, y: 700))
ctx.strokePath()

// Ухмылка: белые зубцы под визором.
ctx.addPath(poly([(400, 800), (700, 770), (655, 845), (610, 805), (560, 870), (515, 815), (470, 850)]))
ctx.setFillColor(white); ctx.fillPath()

ctx.restoreGState()

// Тонкая фиолетовая обводка тела.
ctx.addPath(squircle); ctx.setStrokeColor(violet.copy(alpha: 0.6)!); ctx.setLineWidth(4); ctx.strokePath()

guard let image = ctx.makeImage(),
      let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { fatalError("render") }
try! data.write(to: URL(fileURLWithPath: out))
print(out)
