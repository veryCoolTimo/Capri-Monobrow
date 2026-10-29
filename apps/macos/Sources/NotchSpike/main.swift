// Спайк Этапа 0: notch-капля над строкой меню, три состояния.
//   свёрнутый → (наведение или новое «ждёт меня») → peek → (клик) → expanded.
// NSPanel фиксированного размера и прозрачная. Капля — CAShapeLayer, её путь и маска содержимого
// анимируются пружиной в render server (Core Animation), поэтому главный поток не участвует в кадрах.
// Содержимое — SwiftUI-слои фиксированного размера, появляются fade + сдвиг после начала раскрытия.
// Аргументы: --expanded, --no-notch, --screen N, --diag PATH (по умолчанию /tmp/capri-notch.json).
// Управление для проверки без мыши: SIGUSR1 — «новое ждёт меня» (peek на 3 с), SIGUSR2 — клик (expanded/свернуть),
// SIGHUP — холостой замер кадров без анимации (фон), SIGINFO — снимок своего окна в /tmp/capri-notch-<state>.png.
// Выход: значок в строке меню → «Выйти» (⌘Q), правый клик по капле → «Выйти», scripts/stop-macos.sh.
import AppKit
import SwiftUI
import QuartzCore
import CapriKit

let args = CommandLine.arguments
func argValue(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
let forceNoNotch = args.contains("--no-notch")
let diagPath = argValue("--diag") ?? "/tmp/capri-notch.json"

/// Пружина как SwiftUI `.spring(response: 0.45, dampingFraction: 0.8)`.
let springResponse: CGFloat = 0.45
let springDamping: CGFloat = 0.8

func notchScreen(_ screen: NSScreen) -> NotchScreen {
    if forceNoNotch {
        return NotchScreen(frame: screen.frame, visibleFrame: screen.visibleFrame, safeAreaTop: 0,
                           auxiliaryTopLeft: nil, auxiliaryTopRight: nil)
    }
    return NotchScreen(frame: screen.frame, visibleFrame: screen.visibleFrame,
                       safeAreaTop: screen.safeAreaInsets.top,
                       auxiliaryTopLeft: screen.auxiliaryTopLeftArea, auxiliaryTopRight: screen.auxiliaryTopRightArea)
}

// MARK: - Форма

/// Путь капли в координатах слоя (начало внизу слева). `r` — тело капли; верхние «ушки» радиуса `t`
/// выходят за него в стороны, нижние углы скруглены радиусом `b`. Число и порядок сегментов
/// одинаковы для всех состояний — Core Animation интерполирует путь поточечно.
func dropPath(_ r: CGRect, top t: CGFloat, bottom b0: CGFloat, closed: Bool = true) -> CGPath {
    let b = min(b0, r.width / 2, r.height)
    let p = CGMutablePath()
    p.move(to: CGPoint(x: r.minX - t, y: r.maxY))
    p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - t), control: CGPoint(x: r.minX, y: r.maxY))
    p.addLine(to: CGPoint(x: r.minX, y: r.minY + b))
    p.addQuadCurve(to: CGPoint(x: r.minX + b, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
    p.addLine(to: CGPoint(x: r.maxX - b, y: r.minY))
    p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + b), control: CGPoint(x: r.maxX, y: r.minY))
    p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - t))
    p.addQuadCurve(to: CGPoint(x: r.maxX + t, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
    if closed { p.closeSubpath() }
    return p
}

func springAnimation(_ keyPath: String, from: Any?, to: Any?) -> CASpringAnimation {
    let a = CASpringAnimation(keyPath: keyPath)
    a.mass = 1
    a.stiffness = pow(2 * .pi / springResponse, 2)
    a.damping = 4 * .pi * springDamping / springResponse
    a.initialVelocity = 0
    a.duration = a.settlingDuration
    a.fromValue = from
    a.toValue = to
    return a
}

// MARK: - Стиль

/// Палитра по референсам Тимофея (refs/ui-capri-2026-10-29, в репозиторий не входят): малиновый
/// акцент, кислотно-зелёный — «ждёт меня», тонкая фиолетовая обводка, чёрная капля.
enum Palette {
    static let crimson = Color(red: 0.91, green: 0.09, blue: 0.25)
    static let crimsonNS = NSColor(srgbRed: 0.91, green: 0.09, blue: 0.25, alpha: 1)
    static let acid = Color(red: 0.24, green: 0.96, blue: 0.54)
    static let acidNS = NSColor(srgbRed: 0.24, green: 0.96, blue: 0.54, alpha: 1)
    static let violet = Color(red: 0.42, green: 0.29, blue: 1.0)
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

// MARK: - Содержимое (SwiftUI)

final class NotchModel: ObservableObject {
    @Published var reply = ""
    @Published var hasNotch = true
}

struct TopRowView: View {
    @ObservedObject var model: NotchModel
    var notchWidth: CGFloat
    var body: some View {
        HStack(spacing: 0) {
            CapriGlyph(alert: true)
            Spacer(minLength: model.hasNotch ? notchWidth : 8)
            HStack(spacing: 7) {
                HStack(spacing: 3) {
                    Image(systemName: "triangle.fill").font(.system(size: 7, weight: .bold))
                    Text("2")
                }.foregroundColor(Palette.acid)
                HStack(spacing: 3) {
                    Rectangle().frame(width: 5, height: 5).rotationEffect(.degrees(45))
                    Text("3")
                }.foregroundColor(Palette.crimson)
            }.font(.mono(11, .bold))
        }
        .padding(.horizontal, 15)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PeekLineView: View {
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "triangle.fill").font(.system(size: 7, weight: .bold)).foregroundColor(Palette.acid)
            Caps("capri", size: 10, color: Palette.acid, weight: .bold)
            Rectangle().fill(Palette.line).frame(width: 1, height: 11)
            Text("Run date > stamp.txt?").font(.system(size: 12, weight: .medium)).foregroundColor(Palette.text).lineLimit(1)
            Spacer(minLength: 0)
            Caps("+1", size: 9, color: Palette.dim)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ExpandedView: View {
    @ObservedObject var model: NotchModel
    var onAction: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            attentionCard
            codexCard
            replyRow
            footer
        }
        .foregroundColor(Palette.text)
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Caps("ждут меня", size: 11, color: Palette.text, weight: .bold)
                Caps("// 02", size: 11, color: Palette.acid, weight: .bold)
                Spacer()
                Text("応答待機").font(.system(size: 9, weight: .medium)).foregroundColor(Palette.crimson.opacity(0.7))
                Caps("capri.sys", size: 8)
            }
            HStack(spacing: 0) {
                Rectangle().fill(Palette.crimson).frame(width: 26, height: 2)
                Rectangle().fill(Palette.line).frame(height: 1)
            }
        }
    }

    /// Запрос разрешения оформлен как ATTENTION-блок.
    private var attentionCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                ZStack {
                    Image(systemName: "triangle").font(.system(size: 17, weight: .regular))
                    Text("!").font(.mono(9, .heavy)).offset(y: 1.5)
                }.foregroundColor(Palette.acid)
                VStack(alignment: .leading, spacing: 1) {
                    Caps("attention · запрос разрешения", size: 9, color: Palette.acid, weight: .bold)
                    HStack(spacing: 6) {
                        Text("capri").font(.system(size: 12, weight: .semibold))
                        Caps("timoserver · claude", size: 8)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Caps("02:14", size: 10, color: Palette.acid, weight: .bold)
                    SegmentBar(fraction: 0.22, color: Palette.acid)
                }
            }
            Text("$ date > stamp.txt && echo done").font(.mono(11)).foregroundColor(Palette.text)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.55))
            HStack(spacing: 6) {
                hudButton("1 yes", accent: Palette.acid)
                hudButton("2 don't ask")
                hudButton("3 no")
                Spacer()
                hudButton("открыть ↗")
            }
        }
        .padding(10)
        .hud(stroke: Palette.acid.opacity(0.6), fill: Palette.acid.opacity(0.05), cut: 9)
    }

    private var codexCard: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Palette.crimson).frame(width: 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("archestor").font(.system(size: 12, weight: .semibold))
                    Caps("quiz · codex", size: 8)
                    Spacer()
                    Caps("00:40", size: 10, color: Palette.crimson, weight: .bold)
                }
                Text("Allow creating stamp-codex.txt?").font(.system(size: 11)).foregroundColor(Palette.text.opacity(0.85)).lineLimit(1)
            }
        }
        .padding(.vertical, 7).padding(.trailing, 10).padding(.leading, 6)
        .hud()
    }

    private var replyRow: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Text(">").font(.mono(12, .bold)).foregroundColor(Palette.crimson)
                TextField("ответ в capri", text: $model.reply)
                    .textFieldStyle(.plain).font(.mono(12))
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .hud(fill: Color.black.opacity(0.5), cut: 6)
            hudButton("отправить ⏎", accent: Palette.crimson)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Barcode(seed: "capri-notch").frame(width: 70, height: 9)
            Caps("root@capri :: notch v0.1", size: 7)
            Spacer()
            Caps("警告 · 待機中", size: 7, color: Palette.crimson.opacity(0.7))
        }
    }

    private func hudButton(_ title: String, accent: Color = Palette.crimson) -> some View {
        Button(action: { onAction(title) }) {
            Caps(title, size: 9, color: accent == Palette.crimson ? Palette.text : accent, weight: .bold)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .hud(stroke: accent.opacity(0.7), fill: accent.opacity(0.1), cut: 5)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Окно

final class NotchPanel: NSPanel {
    var allowKey = false
    override var canBecomeKey: Bool { allowKey }
    override var canBecomeMain: Bool { false }
    // Не даём AppKit сдвинуть окно под строку меню.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Не 0: при alpha 0 AppKit не рисует слой, и первый показ тратил кадр 20–40 мс на рендер
/// (шрифты, Canvas). 0.01 на чёрной капле не видно, а слой отрисован заранее.
let hiddenContentAlpha: CGFloat = 0.01

/// Слой содержимого: показывается fade + сдвиг сверху вниз, прячется наоборот.
/// Невидимый слой не должен ловить клики — за это отвечает монитор мыши контроллера.
final class FadingHost<Content: View>: NSHostingView<Content> {
    var restingOrigin: CGPoint = .zero
    var shownState = false

    func set(shown: Bool, delay: TimeInterval, duration: TimeInterval, lift: CGFloat) {
        guard shown != shownState else { return }
        shownState = shown
        let work = { [weak self] in
            guard let self, self.shownState == shown else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = duration
                ctx.timingFunction = CAMediaTimingFunction(name: shown ? .easeOut : .easeIn)
                ctx.allowsImplicitAnimation = true
                self.animator().alphaValue = shown ? 1 : hiddenContentAlpha
                self.animator().setFrameOrigin(shown ? self.restingOrigin
                                               : CGPoint(x: self.restingOrigin.x, y: self.restingOrigin.y + lift))
            })
        }
        if delay > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) } else { work() }
    }

    func reset(shown: Bool, lift: CGFloat) {
        shownState = shown
        // Не прячем через isHidden: слой остаётся отрисованным (alpha 0), и первое раскрытие не тратит
        // кадр на первый рендер SwiftUI.
        alphaValue = shown ? 1 : hiddenContentAlpha
        setFrameOrigin(shown ? restingOrigin : CGPoint(x: restingOrigin.x, y: restingOrigin.y + lift))
    }
}

/// Замер ритма кадров главного потока (display link с частотой экрана). Анимации капли идут в
/// render server и от главного потока не зависят; замер показывает, что он свободен во время перехода.
final class FrameMeter: NSObject {
    private var link: AnyObject?   // CADisplayLink, macOS 14+
    private var stamps: [CFTimeInterval] = []
    private var expected: CFTimeInterval = 1.0 / 120
    private var label = ""
    private var stopWork: DispatchWorkItem?
    var onReport: (([String: Any]) -> Void)?

    func measure(_ label: String, in view: NSView, duration: TimeInterval = 0.8) {
        if !stamps.isEmpty { finish() }
        guard #available(macOS 14.0, *) else { return }
        self.label = label
        stamps = []
        let l = (link as? CADisplayLink) ?? view.displayLink(target: self, selector: #selector(tick(_:)))
        if link == nil { l.add(to: .main, forMode: .common); link = l }
        l.isPaused = false
        stopWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.finish() }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    @objc private func tick(_ sender: AnyObject) {
        guard #available(macOS 14.0, *), let l = sender as? CADisplayLink else { return }
        stamps.append(l.timestamp)
        expected = l.targetTimestamp - l.timestamp
    }

    private func finish() {
        if #available(macOS 14.0, *) { (link as? CADisplayLink)?.isPaused = true }
        guard stamps.count > 2 else { stamps = []; return }
        let intervals = zip(stamps.dropFirst(), stamps).map { $0 - $1 }
        let hitches = intervals.filter { $0 > expected * 1.5 }
        let report: [String: Any] = [
            "transition": label,
            "frames": stamps.count,
            "expectedFrameMs": (expected * 1000 * 100).rounded() / 100,
            "avgFps": Double(intervals.count) / intervals.reduce(0, +),
            "maxFrameMs": ((intervals.max() ?? 0) * 1000 * 100).rounded() / 100,
            "hitches": hitches.count,
        ]
        stamps = []
        onReport?(report)
    }
}

// MARK: - Контроллер

final class Controller: NSObject, NSApplicationDelegate {
    let model = NotchModel()
    let meter = FrameMeter()
    var panel: NotchPanel!
    var container: NSView!
    let dropLayer = CAShapeLayer()
    let maskLayer = CAShapeLayer()
    /// Тонкая малиновая обводка капли (без верхней кромки вдоль края экрана).
    let strokeLayer = CAShapeLayer()
    /// Зелёная «полоса сбоя» для glitch-акцента.
    let glitchSlice = CALayer()
    var contentView: NSView!
    var topRow: FadingHost<TopRowView>!
    var peekLine: FadingHost<PeekLineView>!
    var expandedHost: FadingHost<ExpandedView>!
    var screen: NSScreen!
    var notch = NotchScreen(frame: .zero, visibleFrame: .zero, safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil)
    var host: CGRect = .zero
    var state: NotchState = .collapsed
    var collapseWork: DispatchWorkItem?
    var alertWork: DispatchWorkItem?
    var monitors: [Any] = []
    var signalSources: [DispatchSourceSignal] = []
    var transitions: [[String: Any]] = []
    var hovering = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenus()
        let index = Int(argValue("--screen") ?? "") ?? 0
        screen = NSScreen.screens.indices.contains(index) ? NSScreen.screens[index] : NSScreen.main!
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Выше строки меню (mainMenu = 24).
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = true

        container = NSView()
        container.wantsLayer = true
        dropLayer.fillColor = NSColor.black.cgColor
        container.layer?.addSublayer(dropLayer)
        contentView = NSView()
        contentView.wantsLayer = true
        contentView.layer?.mask = maskLayer
        maskLayer.fillColor = NSColor.black.cgColor
        container.addSubview(contentView)
        strokeLayer.fillColor = nil
        strokeLayer.strokeColor = Palette.crimsonNS.cgColor
        strokeLayer.lineWidth = 1
        strokeLayer.opacity = 0
        strokeLayer.zPosition = 10
        container.layer?.addSublayer(strokeLayer)
        glitchSlice.backgroundColor = Palette.acidNS.withAlphaComponent(0.85).cgColor
        glitchSlice.opacity = 0
        glitchSlice.zPosition = 11
        container.layer?.addSublayer(glitchSlice)
        panel.contentView = container

        topRow = FadingHost(rootView: TopRowView(model: model, notchWidth: 0))
        peekLine = FadingHost(rootView: PeekLineView())
        expandedHost = FadingHost(rootView: ExpandedView(model: model, onAction: { [weak self] in self?.action($0) }))
        for v in [topRow!, peekLine!, expandedHost!] as [NSView] {
            if let h = v as? NSHostingView<TopRowView> { h.sizingOptions = [] }
            if let h = v as? NSHostingView<PeekLineView> { h.sizingOptions = [] }
            if let h = v as? NSHostingView<ExpandedView> { h.sizingOptions = [] }
            v.wantsLayer = true
            contentView.addSubview(v)
        }

        meter.onReport = { [weak self] in self?.recordTransition($0) }
        applyScreen()
        panel.orderFrontRegardless()
        installMonitors()
        installSignals()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.applyScreen(); self?.writeDiagnostics(reason: "screenParametersChanged")
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            if self?.state == .expanded { self?.go(.collapsed, reason: "resignKey") }
        }
        if args.contains("--expanded") { go(.expanded, reason: "arg") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.writeDiagnostics(reason: "launch") }
    }

    // MARK: выход

    func installMenus() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Выйти из NotchSpike", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = main

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "NotchSpike")
        statusItem.menu = makeMenu()
    }
    var statusItem: NSStatusItem!

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Показать peek", action: #selector(menuPeek), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Раскрыть / свернуть", action: #selector(menuToggle), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.command]
        menu.addItem(quit)
        return menu
    }

    @objc func menuPeek() { simulateAlert() }
    @objc func menuToggle() { clickNotch() }

    // MARK: раскладка

    /// Прямоугольник состояния в координатах контейнера (начало внизу слева).
    func local(_ s: NotchState) -> CGRect {
        NotchGeometry.shapeRect(s, notch).offsetBy(dx: -host.minX, dy: -host.minY)
    }

    func radii(_ s: NotchState) -> (top: CGFloat, bottom: CGFloat) {
        let hasNotch = NotchGeometry.notchRect(notch) != nil
        switch s {
        case .collapsed: return (hasNotch ? 6 : 0, hasNotch ? 10 : 13)
        case .peek: return (hasNotch ? 8 : 0, 16)
        case .expanded: return (hasNotch ? 14 : 0, 24)
        }
    }

    func path(_ s: NotchState) -> CGPath {
        let r = radii(s)
        return dropPath(local(s), top: r.top, bottom: r.bottom)
    }

    func strokePath(_ s: NotchState) -> CGPath {
        let r = radii(s)
        return dropPath(local(s), top: r.top, bottom: r.bottom, closed: false)
    }

    func strokeOpacity(_ s: NotchState) -> Float {
        switch s {
        case .collapsed: return 0
        case .peek: return 0.55
        case .expanded: return 0.8
        }
    }

    func applyScreen() {
        notch = notchScreen(screen)
        host = NotchGeometry.hostFrame(notch)
        let notchRect = NotchGeometry.notchRect(notch)
        model.hasNotch = notchRect != nil
        panel.setFrame(host, display: true)
        let bounds = CGRect(origin: .zero, size: host.size)
        container.frame = bounds
        contentView.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dropLayer.frame = bounds
        maskLayer.frame = bounds
        dropLayer.path = path(state)
        maskLayer.path = path(state)
        strokeLayer.frame = bounds
        strokeLayer.path = strokePath(state)
        strokeLayer.opacity = strokeOpacity(state)
        CATransaction.commit()

        let rowHeight = notchRect?.height ?? NotchGeometry.pillSize.height
        let collapsed = local(.collapsed)
        let peek = local(.peek)
        let expanded = local(.expanded)
        topRow.rootView = TopRowView(model: model, notchWidth: notchRect?.width ?? 0)
        topRow.frame = CGRect(x: collapsed.minX, y: bounds.height - rowHeight, width: collapsed.width, height: rowHeight)
        topRow.restingOrigin = topRow.frame.origin
        peekLine.frame = CGRect(x: peek.minX, y: peek.minY + 3, width: peek.width, height: peek.height - rowHeight - 3)
        peekLine.restingOrigin = peekLine.frame.origin
        expandedHost.frame = CGRect(x: expanded.minX, y: expanded.minY, width: expanded.width, height: expanded.height - rowHeight)
        expandedHost.restingOrigin = expandedHost.frame.origin
        peekLine.reset(shown: state == .peek, lift: 6)
        expandedHost.reset(shown: state == .expanded, lift: 8)
    }

    // MARK: состояния

    /// Переход: при росте сначала форма, содержимое — когда капля уже растёт; при сворачивании наоборот.
    func go(_ target: NotchState, reason: String) {
        guard target != state else { return }
        let from = state
        let growing = NotchState.allCases.firstIndex(of: target)! > NotchState.allCases.firstIndex(of: from)!
        state = target
        collapseWork?.cancel()
        panel.allowKey = target == .expanded
        meter.measure("\(from.rawValue)→\(target.rawValue) (\(reason))", in: container)

        // Содержимое: исчезает быстро и сразу, появляется после начала роста.
        if from == .peek { peekLine.set(shown: false, delay: 0, duration: 0.1, lift: 6) }
        if from == .expanded { expandedHost.set(shown: false, delay: 0, duration: 0.12, lift: 8) }
        if target == .peek { peekLine.set(shown: true, delay: growing ? 0.1 : 0.2, duration: 0.22, lift: 6) }
        if target == .expanded { expandedHost.set(shown: true, delay: 0.12, duration: 0.24, lift: 8) }

        // Форма: при сворачивании ждём, пока содержимое начнёт гаснуть.
        let shapeDelay: TimeInterval = growing ? 0 : 0.06
        DispatchQueue.main.asyncAfter(deadline: .now() + shapeDelay) { [weak self] in
            guard let self, self.state == target else { return }
            self.animateShape(to: target)
        }
        // Ключевым окно делаем после пружины: смена key-статуса перерисовывает всю SwiftUI-панель
        // (активность контролов), и в начале раскрытия это давало 1–7 пропущенных кадров.
        if target == .expanded {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.state == .expanded else { return }
                self.panel.makeKey()
            }
        }
        updateMouseThrough()
    }

    func animateShape(to target: NotchState) {
        let newPath = path(target)
        for layer in [dropLayer, maskLayer] {
            // Перехват на середине анимации: продолжаем с того места, где капля сейчас на экране.
            let current = layer.presentation()?.path ?? layer.path
            layer.removeAnimation(forKey: "drop")
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.path = newPath
            CATransaction.commit()
            layer.add(springAnimation("path", from: current, to: newPath), forKey: "drop")
        }
        let newStroke = strokePath(target)
        let currentStroke = strokeLayer.presentation()?.path ?? strokeLayer.path
        let currentOpacity = strokeLayer.presentation()?.opacity ?? strokeLayer.opacity
        strokeLayer.removeAnimation(forKey: "drop")
        strokeLayer.removeAnimation(forKey: "fade")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strokeLayer.path = newStroke
        strokeLayer.opacity = strokeOpacity(target)
        CATransaction.commit()
        strokeLayer.add(springAnimation("path", from: currentStroke, to: newStroke), forKey: "drop")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = currentOpacity
        fade.toValue = strokeOpacity(target)
        fade.duration = 0.25
        strokeLayer.add(fade, forKey: "fade")
    }

    /// Короткий (≤120 мс) glitch-акцент на смене статуса: сдвиг содержимого, вспышка обводки и
    /// зелёная полоса сбоя. При «Уменьшить движение» не играется.
    func glitch() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let duration: CFTimeInterval = 0.11
        let jitter = CAKeyframeAnimation(keyPath: "transform.translation.x")
        jitter.values = [0, -3, 2.5, -1.5, 0]
        jitter.keyTimes = [0, 0.25, 0.5, 0.75, 1]
        jitter.calculationMode = .discrete
        jitter.duration = duration
        contentView.layer?.add(jitter, forKey: "glitch")

        let flash = CAKeyframeAnimation(keyPath: "strokeColor")
        flash.values = [Palette.acidNS.cgColor, Palette.crimsonNS.cgColor, Palette.acidNS.cgColor, Palette.crimsonNS.cgColor]
        flash.keyTimes = [0, 0.3, 0.6, 1]
        flash.calculationMode = .discrete
        flash.duration = duration
        strokeLayer.add(flash, forKey: "glitch")

        let r = local(state)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glitchSlice.frame = CGRect(x: r.minX + 6, y: r.minY + r.height * 0.35, width: r.width - 12, height: 2)
        CATransaction.commit()
        let slice = CAKeyframeAnimation(keyPath: "opacity")
        slice.values = [0.9, 0, 0.7, 0]
        slice.keyTimes = [0, 0.3, 0.55, 1]
        slice.calculationMode = .discrete
        slice.duration = duration
        let move = CAKeyframeAnimation(keyPath: "position.y")
        move.values = [r.minY + r.height * 0.35, r.minY + r.height * 0.7, r.minY + r.height * 0.2]
        move.keyTimes = [0, 0.4, 1]
        move.calculationMode = .discrete
        move.duration = duration
        let group = CAAnimationGroup()
        group.animations = [slice, move]
        group.duration = duration
        glitchSlice.add(group, forKey: "glitch")
    }

    func clickNotch() {
        go(state == .expanded ? (hovering ? .peek : .collapsed) : .expanded, reason: "click")
    }

    func simulateAlert() {
        guard state == .collapsed else { return }
        go(.peek, reason: "alert")
        // Акцент — когда капля уже выехала и показалась строка.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in self?.glitch() }
        alertWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .peek, !self.hovering else { return }
            self.go(.collapsed, reason: "alertTimeout")
        }
        alertWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    func action(_ title: String) {
        model.reply = ""
        go(.collapsed, reason: "action:\(title)")
    }

    // MARK: мышь

    /// Попадание считаем по целевой форме, а не по кадру анимации — так нет дрожания на границе.
    func shapeContains(_ p: NSPoint) -> Bool {
        NotchGeometry.shapeRect(state, notch).insetBy(dx: -2, dy: -2).contains(p)
    }

    /// Прозрачная часть панели не должна ловить клики: пропускаем события, если мышь вне капли.
    func updateMouseThrough() {
        panel.ignoresMouseEvents = !shapeContains(NSEvent.mouseLocation)
    }

    func mouseMoved() {
        let inside = shapeContains(NSEvent.mouseLocation)
        panel.ignoresMouseEvents = !inside
        guard inside != hovering else { return }
        hovering = inside
        if inside {
            collapseWork?.cancel()
            if state == .collapsed { go(.peek, reason: "hover") }
        } else if state == .peek {
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.hovering, self.state == .peek else { return }
                self.go(.collapsed, reason: "hoverOut")
            }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    func installMonitors() {
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: moves) { [weak self] _ in self?.mouseMoved() } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: moves) { [weak self] e in self?.mouseMoved(); return e } as Any)
        // Клик мимо раскрытой панели — свернуть.
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.state == .expanded, !self.shapeContains(NSEvent.mouseLocation) else { return }
            self.go(.collapsed, reason: "clickOutside")
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
            guard let self, e.window === self.panel else { return e }
            guard self.shapeContains(NSEvent.mouseLocation) else {
                if self.state == .expanded { self.go(.collapsed, reason: "clickOutside") }
                return e
            }
            if e.type == .rightMouseDown {
                NSMenu.popUpContextMenu(self.makeMenu(), with: e, for: self.container)
                return nil
            }
            // В раскрытой панели клик идёт в кнопки и поле ввода; в свёрнутой/peek — раскрывает.
            if self.state != .expanded { self.clickNotch(); return nil }
            return e
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            if e.keyCode == 53, self.state == .expanded { self.go(.collapsed, reason: "esc"); return nil }
            if e.modifierFlags.contains(.command), e.charactersIgnoringModifiers == "q" { NSApp.terminate(nil); return nil }
            return e
        } as Any)
    }

    func installSignals() {
        let idle: () -> Void = { [weak self] in
            guard let self else { return }
            self.meter.measure("idle", in: self.container)
        }
        for (sig, handler) in [(SIGUSR1, { [weak self] in self?.simulateAlert() }), (SIGUSR2, { [weak self] in self?.clickNotch() }), (SIGHUP, idle), (SIGINFO, { [weak self] in self?.snapshot() })] as [(Int32, () -> Void)] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler(handler: handler)
            src.resume()
            signalSources.append(src)
        }
    }

    // MARK: диагностика

    /// Снимок собственного окна без записи экрана: /tmp/capri-notch-<state>.png (маска слоя не учитывается).
    func snapshot() {
        let scale = screen.backingScaleFactor
        let size = container.bounds.size
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setFillColor(NSColor(calibratedWhite: 0.55, alpha: 1).cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        container.layer?.render(in: ctx)
        guard let image = ctx.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/capri-notch-\(state.rawValue).png"))
    }

    func recordTransition(_ report: [String: Any]) {
        transitions.append(report)
        if transitions.count > 30 { transitions.removeFirst() }
        writeDiagnostics(reason: "transition")
    }

    func rect(_ r: CGRect?) -> Any { r.map { ["x": $0.minX, "y": $0.minY, "w": $0.width, "h": $0.height] } ?? NSNull() }

    func writeDiagnostics(reason: String) {
        var shapes: [String: Any] = [:]
        for s in NotchState.allCases { shapes[s.rawValue] = rect(NotchGeometry.shapeRect(s, notch)) }
        var windowInfo: Any = NSNull()
        if let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(panel.windowNumber)) as? [[String: Any]], let w = list.first {
            windowInfo = ["layer": w[kCGWindowLayer as String] ?? NSNull(), "bounds": w[kCGWindowBounds as String] ?? NSNull()]
        }
        let diag: [String: Any] = [
            "reason": reason, "time": Date().timeIntervalSince1970, "args": Array(args.dropFirst()),
            "state": state.rawValue,
            "screen": ["name": screen.localizedName, "maximumFramesPerSecond": screen.maximumFramesPerSecond,
                       "frame": rect(screen.frame), "safeAreaTop": screen.safeAreaInsets.top,
                       "notchRect": rect(NotchGeometry.notchRect(notch)), "menuBarHeight": NotchGeometry.menuBarHeight(notch)],
            "panel": ["frame": rect(panel.frame), "level": panel.level.rawValue, "ignoresMouseEvents": panel.ignoresMouseEvents,
                      "window": windowInfo],
            "shapes": shapes,
            "transitions": transitions,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: diag, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: diagPath))
        }
    }
}

let app = NSApplication.shared
let controller = Controller()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
