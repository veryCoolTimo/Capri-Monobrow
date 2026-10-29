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
func dropPath(_ r: CGRect, top t: CGFloat, bottom b0: CGFloat) -> CGPath {
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
    p.closeSubpath()
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
            Image(systemName: "sparkle").font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
            Spacer(minLength: model.hasNotch ? notchWidth : 8)
            HStack(spacing: 6) {
                Text("● 2").foregroundColor(.orange)
                Text("○ 3").foregroundColor(.gray)
            }.font(.system(size: 11, weight: .semibold, design: .rounded))
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PeekLineView: View {
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.orange).frame(width: 6, height: 6)
            Text("capri").font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
            Text("Run date > stamp.txt?").font(.system(size: 12)).foregroundColor(.white.opacity(0.75)).lineLimit(1)
            Spacer(minLength: 0)
            Text("+1").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(.gray)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ExpandedView: View {
    @ObservedObject var model: NotchModel
    var onAction: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ждут меня · 2").font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 6) {
                rowHeader("capri", "timoserver · claude", "2 мин")
                Text("Bash: date > stamp.txt && echo done").font(.system(size: 11, design: .monospaced)).lineLimit(1)
                HStack(spacing: 6) {
                    button("1 Yes"); button("2 Yes, don't ask"); button("3 No")
                    Spacer(); button("Открыть")
                }
            }
            .padding(10).background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08)))
            VStack(alignment: .leading, spacing: 4) {
                rowHeader("archestor", "quiz · codex", "40 с")
                Text("Allow creating stamp-codex.txt?").font(.system(size: 11)).lineLimit(1)
            }
            .padding(10).background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08)))
            HStack(spacing: 6) {
                TextField("Ответить в capri…", text: $model.reply)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.1)))
                button("Отправить")
            }
            Spacer(minLength: 0)
        }
        .foregroundColor(.white)
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, 18).padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func rowHeader(_ project: String, _ meta: String, _ age: String) -> some View {
        HStack(spacing: 6) {
            Text(project).font(.system(size: 12, weight: .semibold))
            Text(meta).font(.system(size: 10)).foregroundColor(.gray)
            Spacer()
            Text(age).font(.system(size: 11)).foregroundColor(.orange)
        }
    }

    private func button(_ title: String) -> some View {
        Button(action: { onAction(title) }) {
            Text(title).font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.14)))
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
                self.animator().alphaValue = shown ? 1 : 0
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
        alphaValue = shown ? 1 : 0
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
        if target == .expanded { panel.makeKey() }
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
    }

    func clickNotch() {
        go(state == .expanded ? (hovering ? .peek : .collapsed) : .expanded, reason: "click")
    }

    func simulateAlert() {
        guard state == .collapsed else { return }
        go(.peek, reason: "alert")
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
