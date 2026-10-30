import AppKit
import SwiftUI
import QuartzCore
import Combine
import CapriKit

// Notch-капля над строкой меню: свёрнутый → (наведение или новое «ждёт меня») → peek → (клик) → expanded.
// Помощник (assistant) — по ⌃⌥Space, клику по глазам Capri слева от выреза или кнопке «✦ capri».
// Высота expanded и assistant — по содержимому (SwiftUI сообщает её в NotchUI), капля подстраивается пружиной.
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
        isHidden = !shown
        alphaValue = shown ? 1 : hiddenContentAlpha
        setFrameOrigin(shown ? restingOrigin : CGPoint(x: restingOrigin.x, y: restingOrigin.y + lift))
    }
}

final class NotchController: NSObject {
    let store: SessionStore
    let codex: CodexService
    let ui = NotchUI()
    /// Меню по правому клику (с «Выйти») — его даёт AppDelegate.
    var makeMenu: (() -> NSMenu)?
    /// «Подробнее» в карточке — открыть основное окно (nil — без выбора сессии; второе — черновик ответа).
    var onDetails: ((SessionKey?, String) -> Void)?
    /// «Весь разговор» в помощнике — основное окно на чате.
    var onConversation: (() -> Void)?
    /// Отладочные команды, которые обрабатывает не notch (окно и т.п.).
    var onDebug: ((String, String) -> Void)?

    private var panel: NotchPanel!
    private(set) var container: NSView!
    private let dropLayer = CAShapeLayer()
    private let maskLayer = CAShapeLayer()
    private let strokeLayer = CAShapeLayer()
    private let glitchSlice = CALayer()
    private var contentView: NSView!
    private var topRow: FadingHost<TopRowView>!
    private var peekLine: FadingHost<PeekLineView>!
    private var expandedHost: FadingHost<ExpandedView>!
    private var assistantHost: FadingHost<AssistantView>!
    private(set) var screen: NSScreen!
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
    /// Переходы notch в лог — только с `--debug-control`.
    var debugLog = false
    private var lastSound: Date = .distantPast
    /// Экран, на котором живёт notch.
    var notchScreen: NSScreen? { screen }
    /// Полноэкранное приложение на экране notch: свёрнутый notch спрятан, всплывает только на «ждёт меня».
    private(set) var suppressed = false

    init(store: SessionStore, codex: CodexService) {
        self.store = store
        self.codex = codex
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
            },
            assistant: { [weak self] in self?.go(.assistant, reason: "button") },
            window: { [weak self] in
                self?.go(.collapsed, reason: "window")
                self?.onDetails?(nil, "")
            },
            conversation: { [weak self] in
                self?.go(.collapsed, reason: "conversation")
                self?.onConversation?()
            })
        topRow = FadingHost(rootView: TopRowView(store: store, ui: ui, codex: codex, notchWidth: 0))
        peekLine = FadingHost(rootView: PeekLineView(store: store, ui: ui))
        expandedHost = FadingHost(rootView: ExpandedView(store: store, ui: ui, actions: actions))
        assistantHost = FadingHost(rootView: AssistantView(codex: codex, store: store, ui: ui, actions: actions))
        topRow.sizingOptions = []
        peekLine.sizingOptions = []
        expandedHost.sizingOptions = []
        assistantHost.sizingOptions = []
        for v in [topRow!, peekLine!, expandedHost!, assistantHost!] as [NSView] {
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
            if self?.state == .expanded || self?.state == .assistant { self?.go(.collapsed, reason: "resignKey") }
        }
        // Содержимое поменяло высоту — капля подстраивается.
        // @Published шлёт значение до записи в свойство — берём высоту из потока, не из ui.
        ui.$expandedHeight.removeDuplicates()
            .sink { [weak self] h in self?.contentResized(.expanded, h) }.store(in: &cancellables)
        ui.$assistantHeight.removeDuplicates()
            .sink { [weak self] h in self?.contentResized(.assistant, h) }.store(in: &cancellables)
        // Изменения сессий: свёрнутая капля растёт/сжимается вокруг выреза.
        store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.storeChanged() }
            .store(in: &cancellables)
        store.onDelivered = { [weak self] key in self?.delivered(key) }
    }

    // MARK: раскладка

    /// Экран со встроенным вырезом, иначе главный.
    private func pickScreen() {
        screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 && $0.auxiliaryTopLeftArea != nil } ?? NSScreen.main ?? NSScreen.screens[0]
        applyScreen()
    }

    /// Высота содержимого под верхней строкой (её мерит SwiftUI).
    private var measured: [NotchState: CGFloat] = [:]

    /// Высота формы с учётом содержимого.
    private func contentHeight(_ s: NotchState) -> CGFloat? {
        let row = NotchGeometry.notchRect(notch)?.height ?? NotchGeometry.pillSize.height
        return measured[s].map { $0 + row }
    }

    private func global(_ s: NotchState) -> CGRect {
        NotchGeometry.shapeRect(s, notch, quiet: quiet, contentHeight: contentHeight(s))
    }

    private func local(_ s: NotchState) -> CGRect {
        global(s).offsetBy(dx: -host.minX, dy: -host.minY)
    }

    private func contentResized(_ s: NotchState, _ h: CGFloat?) {
        measured[s] = h
        guard state == s, panel != nil else { return }
        animateShape(to: s)
        updateMouseThrough()
    }

    private func radii(_ s: NotchState) -> (top: CGFloat, bottom: CGFloat) {
        let hasNotch = NotchGeometry.notchRect(notch) != nil
        switch s {
        case .collapsed: return (hasNotch ? 6 : 0, hasNotch ? 10 : 13)
        case .peek: return (hasNotch ? 8 : 0, 16)
        case .expanded, .assistant: return (hasNotch ? 14 : 0, 24)
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
        case .assistant: return 0.9
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
        topRow.rootView = TopRowView(store: store, ui: ui, codex: codex, notchWidth: notchRect?.width ?? 0)
        topRow.frame = CGRect(x: collapsed.minX, y: bounds.height - rowHeight, width: collapsed.width, height: rowHeight)
        topRow.restingOrigin = topRow.frame.origin
        peekLine.frame = CGRect(x: peek.minX, y: peek.minY + 3, width: peek.width, height: peek.height - rowHeight - 3)
        peekLine.restingOrigin = peekLine.frame.origin
        // Содержимое expanded/assistant — во всю наибольшую высоту под верхней строкой, прижато к верху;
        // лишнее срезает маска капли.
        for (hostView, s) in [(expandedHost as NSView, NotchState.expanded), (assistantHost as NSView, NotchState.assistant)] {
            let maxRect = NotchGeometry.shapeRect(s, notch, contentHeight: .greatestFiniteMagnitude).offsetBy(dx: -host.minX, dy: -host.minY)
            hostView.frame = CGRect(x: maxRect.minX, y: maxRect.minY, width: maxRect.width, height: maxRect.height - rowHeight)
        }
        expandedHost.restingOrigin = expandedHost.frame.origin
        assistantHost.restingOrigin = assistantHost.frame.origin
        topRow.reset(shown: !(quiet && state == .collapsed), lift: 0)
        peekLine.reset(shown: state == .peek, lift: 6)
        expandedHost.reset(shown: state == .expanded, lift: 8)
        assistantHost.reset(shown: state == .assistant, lift: 8)
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
        if debugLog { Self.debugWrite("notch \(from.rawValue) → \(target.rawValue) (\(reason))") }
        let growing = NotchState.allCases.firstIndex(of: target)! > NotchState.allCases.firstIndex(of: from)!
        state = target
        if suppressed {
            if target != .collapsed { setPanelVisible(true) }   // кликабельность — updateMouseThrough() в конце go()
            else {
                // Дать капле свернуться, потом спрятать.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                    guard let self, self.suppressed, self.state == .collapsed else { return }
                    self.hovering = false
                    self.setPanelVisible(false)
                }
            }
        }
        collapseWork?.cancel()
        let interactive: Set<NotchState> = [.expanded, .assistant]
        panel.allowKey = interactive.contains(target)
        if target != .peek { ui.alertKey = nil }
        ui.assistantShown = target == .assistant
        if target == .assistant { ui.assistantFocusTick += 1 }
        // Карточка не должна переключаться сама при пересортировке списка — закрепляем выбор.
        if target == .expanded, ui.selected.flatMap(store.resolve) == nil {
            ui.selected = store.waiting.first?.key ?? store.sessions.first?.key
        }

        if from == .peek { peekLine.set(shown: false, delay: 0, duration: 0.1, lift: 6) }
        if from == .expanded { expandedHost.set(shown: false, delay: 0, duration: 0.12, lift: 8) }
        if from == .assistant { assistantHost.set(shown: false, delay: 0, duration: 0.12, lift: 8) }
        if target == .peek { peekLine.set(shown: true, delay: growing ? 0.1 : 0.2, duration: 0.22, lift: 6) }
        if target == .expanded { expandedHost.set(shown: true, delay: 0.12, duration: 0.24, lift: 8) }
        if target == .assistant { assistantHost.set(shown: true, delay: 0.14, duration: 0.26, lift: 10) }
        if quiet { topRow.set(shown: target != .collapsed, delay: target == .collapsed ? 0 : 0.1, duration: 0.2, lift: 0) }

        let shapeDelay: TimeInterval = growing ? 0 : 0.06
        DispatchQueue.main.asyncAfter(deadline: .now() + shapeDelay) { [weak self] in
            guard let self, self.state == target else { return }
            self.animateShape(to: target)
        }
        // Ключевым окно делаем после пружины: смена key-статуса перерисовывает SwiftUI-панель.
        if interactive.contains(target) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.state == target else { return }
                self.panel.makeKey()
                if target == .assistant { self.ui.assistantFocusTick += 1 }
            }
        } else if interactive.contains(from) {
            panel.resignKey()
            if from == .expanded { ui.reply = "" }
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

    /// ⌃⌥Space и пункт меню: открыть экранчик Capri или убрать его.
    func toggleAssistant() {
        if suppressed && state == .collapsed { setPanelVisible(true) }
        go(state == .assistant ? .collapsed : .assistant, reason: "assistant")
    }

    /// Клик по левому крылу верхней строки (там глаза Capri), а не по строке peek под ней.
    private func onCapriEyes(_ p: NSPoint) -> Bool {
        let top = NotchGeometry.anchorTop(notch)
        let row = NotchGeometry.notchRect(notch)?.height ?? NotchGeometry.pillSize.height
        guard p.y >= top - row else { return false }
        if let n = NotchGeometry.notchRect(notch) { return p.x < n.minX }
        return p.x < global(state).minX + 40
    }

    /// Спрятать свёрнутый notch (полноэкранное приложение) или вернуть. Раскрытый и peek не трогаем —
    /// они спрячутся, когда свернутся.
    func setSuppressed(_ value: Bool) {
        guard value != suppressed else { return }
        suppressed = value
        if !value { setPanelVisible(true); updateMouseThrough() }
        else if state == .collapsed { hovering = false; collapseWork?.cancel(); setPanelVisible(false) }
    }

    private func setPanelVisible(_ visible: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = visible ? 0.12 : 0.25
            panel.animator().alphaValue = visible ? 1 : 0
        }
        if !visible { panel.ignoresMouseEvents = true }
    }

    /// Новое «ждёт меня»: peek на 3 с с этой сессией, звук, glitch. Что из этого играть — решает AttentionPolicy.
    func alert(_ s: Session, sound: Bool) {
        // Несколько «ждёт меня» разом (например, при запуске) — один звук.
        if sound, Date().timeIntervalSince(lastSound) > 2 {
            lastSound = Date()
            NSSound(named: "Tink")?.play()
        }
        if state == .expanded || state == .assistant {
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

    func select(_ key: SessionKey) {
        if ui.selected != key { ui.reply = "" }
        ui.selected = key
        store.clearDelivery(key)
    }

    func send(_ key: SessionKey, _ action: ReplyAction) {
        let key = store.resolve(key) ?? key
        ui.selected = key
        store.send(key, action) { [weak self] ok in
            if ok, case .text = action { self?.ui.reply = "" }
        }
    }

    /// Ответ дошёл: если больше никто не ждёт — свернуть через секунду. Выбор сам не переключаем:
    /// следующую сессию выбирает человек.
    private func delivered(_ key: SessionKey) {
        guard state == .expanded, ui.selected.flatMap(store.resolve) == key else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.state == .expanded, self.ui.selected.flatMap(self.store.resolve) == key,
                  self.store.waiting.isEmpty, !self.hovering else { return }
            self.go(.collapsed, reason: "delivered")
        }
    }

    func open(_ key: SessionKey) {
        if store.openTerminal(key) { go(.collapsed, reason: "open") }
    }

    // MARK: мышь

    /// Попадание считаем по целевой форме, а не по кадру анимации — так нет дрожания на границе.
    private func shapeContains(_ p: NSPoint) -> Bool {
        global(state).insetBy(dx: -2, dy: -2).contains(p)
    }

    private func updateMouseThrough() {
        if suppressed && state == .collapsed { panel.ignoresMouseEvents = true; return }
        panel.ignoresMouseEvents = !shapeContains(NSEvent.mouseLocation)
    }

    private func mouseMoved() {
        // Спрятанный notch не раскрывается наведением: в полноэкранном режиме там всплывает строка меню.
        if suppressed && state == .collapsed {
            hovering = false
            collapseWork?.cancel()
            return
        }
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
            guard let self, self.state == .expanded || self.state == .assistant, !self.shapeContains(NSEvent.mouseLocation) else { return }
            self.go(.collapsed, reason: "clickOutside")
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
            guard let self, e.window === self.panel else { return e }
            guard self.shapeContains(NSEvent.mouseLocation) else {
                if self.state == .expanded || self.state == .assistant { self.go(.collapsed, reason: "clickOutside") }
                return e
            }
            if e.type == .rightMouseDown, let menu = self.makeMenu?() {
                NSMenu.popUpContextMenu(menu, with: e, for: self.container)
                return nil
            }
            // В раскрытой панели и помощнике клик идёт в кнопки и поле ввода; в свёрнутой/peek — раскрывает
            // (по глазам Capri слева от выреза — помощник).
            if self.state == .collapsed || self.state == .peek {
                if self.onCapriEyes(NSEvent.mouseLocation) { self.go(.assistant, reason: "eyes") } else { self.clickNotch() }
                return nil
            }
            return e
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            if e.keyCode == 53, self.state == .expanded || self.state == .assistant { self.go(.collapsed, reason: "esc"); return nil }
            if e.modifierFlags.contains(.command), e.charactersIgnoringModifiers == "q" { NSApp.terminate(nil); return nil }
            return e
        } as Any)
    }

    private func installSignals() {
        let handlers: [(Int32, () -> Void)] = [
            (SIGUSR1, { [weak self] in
                guard let self else { return }
                if let s = self.store.waiting.first { self.alert(s, sound: false) } else if self.state == .collapsed { self.go(.peek, reason: "signal") }
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
}
