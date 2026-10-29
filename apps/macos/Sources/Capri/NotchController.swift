import AppKit
import SwiftUI
import QuartzCore
import Combine
import CapriKit

// Notch-капля над строкой меню: свёрнутый → (наведение или новое «ждёт меня») → peek → (клик) → expanded.
// Панель фиксированного размера и прозрачная; капля — CAShapeLayer, её путь анимируется пружиной в
// render server. Отработано в NotchSpike (Этап 0), здесь — на живых сессиях.
// Проверка без мыши: SIGUSR1 — peek, SIGUSR2 — клик, SIGINFO — снимок окна в ~/.capri/tmp/notch-<state>.png.

/// Пружина как SwiftUI `.spring(response: 0.45, dampingFraction: 0.8)`.
private let springResponse: CGFloat = 0.45
private let springDamping: CGFloat = 0.8

/// Не 0: при alpha 0 AppKit не рисует слой, и первый показ тратил кадр 20–40 мс на рендер.
private let hiddenContentAlpha: CGFloat = 0.01

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

private func springAnimation(_ keyPath: String, from: Any?, to: Any?) -> CASpringAnimation {
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

final class NotchPanel: NSPanel {
    var allowKey = false
    override var canBecomeKey: Bool { allowKey }
    override var canBecomeMain: Bool { false }
    // Не даём AppKit сдвинуть окно под строку меню.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Слой содержимого: показывается fade + сдвиг сверху вниз, прячется наоборот.
final class FadingHost<Content: View>: NSHostingView<Content> {
    var restingOrigin: CGPoint = .zero
    var shownState = false

    func set(shown: Bool, delay: TimeInterval, duration: TimeInterval, lift: CGFloat) {
        guard shown != shownState else { return }
        shownState = shown
        let work = { [weak self] in
            guard let self, self.shownState == shown else { return }
            if shown { self.isHidden = false }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = duration
                ctx.timingFunction = CAMediaTimingFunction(name: shown ? .easeOut : .easeIn)
                ctx.allowsImplicitAnimation = true
                self.animator().alphaValue = shown ? 1 : hiddenContentAlpha
                self.animator().setFrameOrigin(shown ? self.restingOrigin
                                               : CGPoint(x: self.restingOrigin.x, y: self.restingOrigin.y + lift))
            }, completionHandler: { [weak self] in
                // Погасший слой убираем совсем: первый рендер уже сделан, а под другим содержимым
                // он не должен просвечивать и ловить клики.
                guard let self, !self.shownState else { return }
                self.isHidden = true
            })
        }
        if delay > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) } else { work() }
    }

    func reset(shown: Bool, lift: CGFloat) {
        shownState = shown
        alphaValue = shown ? 1 : hiddenContentAlpha
        setFrameOrigin(shown ? restingOrigin : CGPoint(x: restingOrigin.x, y: restingOrigin.y + lift))
    }
}

final class NotchController: NSObject {
    let store: SessionStore
    let ui = NotchUI()
    /// Меню по правому клику (с «Выйти») — его даёт AppDelegate.
    var makeMenu: (() -> NSMenu)?
    var soundEnabled: () -> Bool = { true }
    /// «Подробнее» в карточке — открыть основное окно.
    var onDetails: ((SessionKey, String) -> Void)?
    /// Отладочные команды, которые обрабатывает не notch (окно и т.п.).
    var onDebug: ((String, String) -> Void)?

    private var panel: NotchPanel!
    private var container: NSView!
    private let dropLayer = CAShapeLayer()
    private let maskLayer = CAShapeLayer()
    private let strokeLayer = CAShapeLayer()
    private let glitchSlice = CALayer()
    private var contentView: NSView!
    private var topRow: FadingHost<TopRowView>!
    private var peekLine: FadingHost<PeekLineView>!
    private var expandedHost: FadingHost<ExpandedView>!
    private var screen: NSScreen!
    private var notch = NotchScreen(frame: .zero, visibleFrame: .zero, safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil)
    private var host: CGRect = .zero
    private(set) var state: NotchState = .collapsed
    /// Нет ни ждущих, ни работающих: свёрнутая капля совпадает с вырезом.
    private var quiet = true
    private var collapseWork: DispatchWorkItem?
    private var alertWork: DispatchWorkItem?
    private var monitors: [Any] = []
    private var signalSources: [DispatchSourceSignal] = []
    private var cancellables: Set<AnyCancellable> = []
    private var hovering = false
    private var lastSound: Date = .distantPast

    init(store: SessionStore) {
        self.store = store
        super.init()
    }

    func start() {
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

        let actions = NotchActions(
            send: { [weak self] key, action in self?.send(key, action) },
            open: { [weak self] key in self?.open(key) },
            select: { [weak self] key in self?.select(key) },
            details: { [weak self] key in
                guard let self else { return }
                let draft = self.ui.selected.flatMap(self.store.resolve) == self.store.resolve(key) ? self.ui.reply : ""
                self.go(.collapsed, reason: "details")
                self.onDetails?(key, draft)
            })
        topRow = FadingHost(rootView: TopRowView(store: store, ui: ui, notchWidth: 0))
        peekLine = FadingHost(rootView: PeekLineView(store: store, ui: ui))
        expandedHost = FadingHost(rootView: ExpandedView(store: store, ui: ui, actions: actions))
        topRow.sizingOptions = []
        peekLine.sizingOptions = []
        expandedHost.sizingOptions = []
        for v in [topRow!, peekLine!, expandedHost!] as [NSView] {
            v.wantsLayer = true
            contentView.addSubview(v)
        }

        quiet = !store.active
        CapriPaths.ensureDir()
        CapriPaths.cleanTmp()
        pickScreen()
        panel.orderFrontRegardless()
        installMonitors()
        installSignals()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.pickScreen()
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            if self?.state == .expanded { self?.go(.collapsed, reason: "resignKey") }
        }
        // Изменения сессий: свёрнутая капля растёт/сжимается вокруг выреза.
        store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.storeChanged() }
            .store(in: &cancellables)
        store.onNeedsInput = { [weak self] s in self?.alert(s) }
        store.onDelivered = { [weak self] key in self?.delivered(key) }
    }

    // MARK: раскладка

    /// Экран со встроенным вырезом, иначе главный.
    private func pickScreen() {
        screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 && $0.auxiliaryTopLeftArea != nil } ?? NSScreen.main ?? NSScreen.screens[0]
        applyScreen()
    }

    private func local(_ s: NotchState) -> CGRect {
        NotchGeometry.shapeRect(s, notch, quiet: quiet).offsetBy(dx: -host.minX, dy: -host.minY)
    }

    private func radii(_ s: NotchState) -> (top: CGFloat, bottom: CGFloat) {
        let hasNotch = NotchGeometry.notchRect(notch) != nil
        switch s {
        case .collapsed: return (hasNotch ? 6 : 0, hasNotch ? 10 : 13)
        case .peek: return (hasNotch ? 8 : 0, 16)
        case .expanded: return (hasNotch ? 14 : 0, 24)
        }
    }

    private func path(_ s: NotchState) -> CGPath {
        let r = radii(s)
        return dropPath(local(s), top: r.top, bottom: r.bottom)
    }

    private func strokePath(_ s: NotchState) -> CGPath {
        let r = radii(s)
        return dropPath(local(s), top: r.top, bottom: r.bottom, closed: false)
    }

    private func strokeOpacity(_ s: NotchState) -> Float {
        switch s {
        case .collapsed: return 0
        case .peek: return 0.55
        case .expanded: return 0.8
        }
    }

    private func applyScreen() {
        notch = NotchScreen(frame: screen.frame, visibleFrame: screen.visibleFrame, safeAreaTop: screen.safeAreaInsets.top,
                            auxiliaryTopLeft: screen.auxiliaryTopLeftArea, auxiliaryTopRight: screen.auxiliaryTopRightArea)
        host = NotchGeometry.hostFrame(notch)
        let notchRect = NotchGeometry.notchRect(notch)
        ui.hasNotch = notchRect != nil
        panel.setFrame(host, display: true)
        let bounds = CGRect(origin: .zero, size: host.size)
        container.frame = bounds
        contentView.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [dropLayer, maskLayer, strokeLayer] as [CALayer] { l.frame = bounds }
        dropLayer.path = path(state)
        maskLayer.path = path(state)
        strokeLayer.path = strokePath(state)
        strokeLayer.opacity = strokeOpacity(state)
        CATransaction.commit()

        let rowHeight = notchRect?.height ?? NotchGeometry.pillSize.height
        let collapsed = NotchGeometry.shapeRect(.collapsed, notch).offsetBy(dx: -host.minX, dy: -host.minY)
        let peek = local(.peek)
        let expanded = local(.expanded)
        topRow.rootView = TopRowView(store: store, ui: ui, notchWidth: notchRect?.width ?? 0)
        topRow.frame = CGRect(x: collapsed.minX, y: bounds.height - rowHeight, width: collapsed.width, height: rowHeight)
        topRow.restingOrigin = topRow.frame.origin
        peekLine.frame = CGRect(x: peek.minX, y: peek.minY + 3, width: peek.width, height: peek.height - rowHeight - 3)
        peekLine.restingOrigin = peekLine.frame.origin
        expandedHost.frame = CGRect(x: expanded.minX, y: expanded.minY, width: expanded.width, height: expanded.height - rowHeight)
        expandedHost.restingOrigin = expandedHost.frame.origin
        topRow.reset(shown: !(quiet && state == .collapsed), lift: 0)
        peekLine.reset(shown: state == .peek, lift: 6)
        expandedHost.reset(shown: state == .expanded, lift: 8)
    }

    // MARK: состояния

    private func storeChanged() {
        // objectWillChange приходит до изменения — смотрим после.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Выбранная сессия закрылась — черновик ответа не должен достаться другой.
            if let k = self.ui.selected, self.store.resolve(k) == nil, !self.ui.reply.isEmpty { self.ui.reply = "" }
            let q = !self.store.active
            guard q != self.quiet else { return }
            self.quiet = q
            if self.state == .collapsed {
                self.topRow.set(shown: !q, delay: q ? 0 : 0.12, duration: 0.2, lift: 0)
                self.animateShape(to: .collapsed)
            }
        }
    }

    /// Переход: при росте сначала форма, содержимое — когда капля уже растёт; при сворачивании наоборот.
    func go(_ target: NotchState, reason: String) {
        guard target != state else { return }
        let from = state
        let growing = NotchState.allCases.firstIndex(of: target)! > NotchState.allCases.firstIndex(of: from)!
        state = target
        collapseWork?.cancel()
        panel.allowKey = target == .expanded
        if target != .peek { ui.alertKey = nil }
        // Карточка не должна переключаться сама при пересортировке списка — закрепляем выбор.
        if target == .expanded, ui.selected.flatMap(store.resolve) == nil {
            ui.selected = store.waiting.first?.key ?? store.sessions.first?.key
        }

        if from == .peek { peekLine.set(shown: false, delay: 0, duration: 0.1, lift: 6) }
        if from == .expanded { expandedHost.set(shown: false, delay: 0, duration: 0.12, lift: 8) }
        if target == .peek { peekLine.set(shown: true, delay: growing ? 0.1 : 0.2, duration: 0.22, lift: 6) }
        if target == .expanded { expandedHost.set(shown: true, delay: 0.12, duration: 0.24, lift: 8) }
        if quiet { topRow.set(shown: target != .collapsed, delay: target == .collapsed ? 0 : 0.1, duration: 0.2, lift: 0) }

        let shapeDelay: TimeInterval = growing ? 0 : 0.06
        DispatchQueue.main.asyncAfter(deadline: .now() + shapeDelay) { [weak self] in
            guard let self, self.state == target else { return }
            self.animateShape(to: target)
        }
        // Ключевым окно делаем после пружины: смена key-статуса перерисовывает SwiftUI-панель.
        if target == .expanded {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.state == .expanded else { return }
                self.panel.makeKey()
            }
        } else if from == .expanded {
            panel.resignKey()
            ui.reply = ""
        }
        updateMouseThrough()
    }

    private func animateShape(to target: NotchState) {
        let newPath = path(target)
        for layer in [dropLayer, maskLayer] {
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

    /// Короткий (≤120 мс) glitch-акцент; при «Уменьшить движение» не играется.
    private func glitch() {
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

    /// Новое «ждёт меня»: peek на 3 с с этой сессией, звук, glitch.
    func alert(_ s: Session) {
        // Несколько «ждёт меня» разом (например, при запуске) — один звук.
        if soundEnabled(), Date().timeIntervalSince(lastSound) > 2 {
            lastSound = Date()
            NSSound(named: "Tink")?.play()
        }
        if state == .expanded {
            glitch()
            return
        }
        ui.alertKey = s.key
        if state == .collapsed { go(.peek, reason: "alert") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in self?.glitch() }
        alertWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .peek, !self.hovering else { return }
            self.go(.collapsed, reason: "alertTimeout")
        }
        alertWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    // MARK: действия

    private func select(_ key: SessionKey) {
        if ui.selected != key { ui.reply = "" }
        ui.selected = key
        store.clearDelivery(key)
    }

    private func send(_ key: SessionKey, _ action: ReplyAction) {
        let key = store.resolve(key) ?? key
        ui.selected = key
        store.send(key, action) { [weak self] ok in
            if ok, case .text = action { self?.ui.reply = "" }
        }
    }

    /// Ответ дошёл: если больше никто не ждёт — свернуть через секунду, иначе перейти к следующему.
    private func delivered(_ key: SessionKey) {
        guard state == .expanded, ui.selected.flatMap(store.resolve) == key else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.state == .expanded, self.ui.selected.flatMap(self.store.resolve) == key else { return }
            if let next = self.store.waiting.first(where: { $0.key != key }) {
                self.ui.selected = next.key
            } else if !self.hovering {
                self.go(.collapsed, reason: "delivered")
            }
        }
    }

    private func open(_ key: SessionKey) {
        if store.openTerminal(key) { go(.collapsed, reason: "open") }
    }

    // MARK: отладочное управление

    /// Только с `--debug-control`: команды из `~/.capri/tmp/control` идут по тем же путям, что клики, —
    /// для сквозной проверки без мыши. Файл в каталоге 0700, читается и удаляется раз в 0.3 с.
    func startDebugControl() {
        let file = CapriPaths.tmp.appendingPathComponent("control")
        CapriPaths.ensureDir()
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            // Только обычный файл владельца, не ссылка.
            var st = stat()
            guard lstat(file.path, &st) == 0 else { return }
            defer { try? FileManager.default.removeItem(at: file) }
            guard (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid(),
                  let data = FileManager.default.contents(atPath: file.path) else { return }
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") { self?.debugCommand(String(line)) }
        }
        NSLog("[Capri] отладочное управление: %@", file.path)
    }

    private func debugCommand(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        NSLog("[Capri] control: %@", parts.first ?? "")
        switch parts.first {
        case "expand": go(.expanded, reason: "control")
        case "collapse": go(.collapsed, reason: "control")
        case "peek": go(.peek, reason: "control")
        case "select":
            // select <tmux-сессия>: первая сессия Capri в этой tmux-сессии
            if let s = store.sessions.first(where: { $0.tmux?.session == arg }) { select(s.key) }
        case "choose": if let k = ui.selected, let n = Int(arg) { send(k, .choose(n)) }
        case "text": if let k = ui.selected { ui.reply = arg; send(k, .text(arg)) }
        case "open": if let k = ui.selected { open(k) }
        case "snapshot": snapshot()
        case "dump": dumpState()
        default: if let cmd = parts.first { onDebug?(cmd, arg) }
        }
    }

    private func dumpState() {
        let rows = store.sessions.map { s -> [String: Any] in
            var r: [String: Any] = ["key": s.key.description, "status": s.status.rawValue, "project": s.project,
                                    "tmux": s.tmux?.session ?? "", "headline": s.headline]
            if let c = s.request?.choices { r["choices"] = c.map { "\($0.index) \($0.label)" } }
            if let d = store.deliveries[s.key] { r["delivery"] = "\(d)" }
            return r
        }
        let out: [String: Any] = ["state": state.rawValue, "selected": ui.selected?.description ?? "", "sessions": rows,
                                  "hosts": store.hosts.map { "\($0.name)=\($0.connected)" }]
        if let d = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: CapriPaths.tmp.appendingPathComponent("state.json"))
        }
    }

    // MARK: мышь

    /// Попадание считаем по целевой форме, а не по кадру анимации — так нет дрожания на границе.
    private func shapeContains(_ p: NSPoint) -> Bool {
        NotchGeometry.shapeRect(state, notch, quiet: quiet).insetBy(dx: -2, dy: -2).contains(p)
    }

    private func updateMouseThrough() {
        panel.ignoresMouseEvents = !shapeContains(NSEvent.mouseLocation)
    }

    private func mouseMoved() {
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

    private func installMonitors() {
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
            if e.type == .rightMouseDown, let menu = self.makeMenu?() {
                NSMenu.popUpContextMenu(menu, with: e, for: self.container)
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

    private func installSignals() {
        let handlers: [(Int32, () -> Void)] = [
            (SIGUSR1, { [weak self] in
                guard let self else { return }
                if let s = self.store.waiting.first { self.alert(s) } else if self.state == .collapsed { self.go(.peek, reason: "signal") }
            }),
            (SIGUSR2, { [weak self] in self?.clickNotch() }),
            (SIGINFO, { [weak self] in self?.snapshot() }),
        ]
        for (sig, handler) in handlers {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler(handler: handler)
            src.resume()
            signalSources.append(src)
        }
    }

    /// Снимок собственного окна без записи экрана (маска слоя не учитывается).
    private func snapshot() {
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
        CapriPaths.ensureDir()
        try? rep.representation(using: .png, properties: [:])?.write(to: CapriPaths.tmp.appendingPathComponent("notch-\(state.rawValue).png"))
    }
}
