import AppKit
import WebKit
import Combine
import CapriKit

final class CharacterController: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    @Published var size: String { didSet { defaults.set(size, forKey: "size"); resize() } }
    @Published var paused: Bool { didSet { defaults.set(paused, forKey: "paused"); configureRenderer() } }
    @Published var pinned: Bool { didSet { defaults.set(pinned, forKey: "pinned") } }
    @Published private(set) var isHidden = false
    @Published private(set) var rendererStatus = "Загрузка персонажа…"
    @Published private(set) var currentState = "idle"
    var onClick: (() -> Void)?
    var onContextMenu: ((NSEvent, NSView) -> Void)?
    var dragging = false
    private let defaults = UserDefaults(suiteName: "local.capri.prototype.preferences") ?? .standard
    private(set) var panel: CharacterPanel!
    private var inputPanel: CharacterPanel!
    private var webView: WKWebView!
    private var timer: Timer?
    private var ready = false
    private var systemPaused = false
    private var hiddenUntil: Date?
    private var nextRoam = Date().addingTimeInterval(45)
    private var teleportGeneration = 0
    var scale: Double { size == "small" ? 0.38 : size == "large" ? 0.68 : 0.52 }
    var reducedMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    override init() {
        size = defaults.string(forKey: "size") ?? "medium"
        paused = defaults.bool(forKey: "paused")
        pinned = defaults.object(forKey: "pinned") as? Bool ?? true
        super.init()
        hiddenUntil = defaults.object(forKey: "hiddenUntil") as? Date
        makePanel()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(motionChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        if OverlayPreferences.isHidden(until: hiddenUntil, now: Date()) {
            isHidden = true; inputPanel.orderOut(nil); panel.orderOut(nil)
        } else { panel.orderFrontRegardless(); inputPanel.orderFrontRegardless() }
        let timer = Timer(timeInterval: 1, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func makePanel() {
        let canvasSize = NSSize(width: (352 * scale).rounded(), height: (532 * scale).rounded())
        panel = CharacterPanel(contentRect: NSRect(origin: .zero, size: canvasSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Capri Character"
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let root = NSView(frame: NSRect(origin: .zero, size: canvasSize))
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(self, name: "capri")
        if let data = try? Data(contentsOf: CharacterAssets.directory.appendingPathComponent("capri-full.png")) {
            // A data texture stays origin-clean; file:// textures are blocked by WebGL in WKWebView.
            let script = "window.CAPRI_TEXTURE='data:image/png;base64,\(data.base64EncodedString())';"
            configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        webView = WKWebView(frame: root.bounds, configuration: configuration)
        webView.autoresizingMask = [.width, .height]
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self
        root.addSubview(webView)
        let input = CharacterInputView(frame: root.bounds)
        input.autoresizingMask = [.width, .height]; input.controller = self
        input.setAccessibilityElement(true)
        input.setAccessibilityLabel("Capri. Нажми, чтобы открыть сессии. Можно перетащить.")
        input.setAccessibilityRole(.button)
        panel.contentView = root
        let saved = CGPoint(x: defaults.double(forKey: "x"), y: defaults.double(forKey: "y"))
        let savedRect = CGRect(origin: saved, size: canvasSize)
        if let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(savedRect) }) ?? NSScreen.main {
            let origin = defaults.object(forKey: "x") == nil
                ? CGPoint(x: screen.visibleFrame.maxX - canvasSize.width - 54, y: screen.visibleFrame.minY + 30) : saved
            panel.setFrameOrigin(OverlayGeometry.clampedOrigin(origin, panelSize: canvasSize, visibleFrame: screen.visibleFrame))
        }
        inputPanel = CharacterPanel(contentRect: panel.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        inputPanel.title = "Capri Input"
        inputPanel.isOpaque = false; inputPanel.backgroundColor = .clear; inputPanel.hasShadow = false
        inputPanel.level = .floating; inputPanel.hidesOnDeactivate = false; inputPanel.isReleasedWhenClosed = false
        inputPanel.collectionBehavior = panel.collectionBehavior
        // Do not assign ignoresMouseEvents on the native input panel: its default
        // alpha hit-testing passes transparent pixels through before event delivery.
        inputPanel.contentView = input
        panel.addChildWindow(inputPanel, ordered: .above)
        webView.loadFileURL(CharacterAssets.directory.appendingPathComponent("index.html"), allowingReadAccessTo: CharacterAssets.directory)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let data = message.body as? [String: Any], let kind = data["kind"] as? String else { return }
        if kind == "ready" {
            ready = true; rendererStatus = "WebGL работает · 12 fps"; configureRenderer(); setState(currentState)
            NSLog("[Capri] renderer ready: %@", String(describing: data))
        } else if kind == "error" {
            rendererStatus = "Статичный спрайт: \(data["message"] ?? "ошибка WebGL")"
            NSLog("[Capri] renderer error: %@", String(describing: data))
        } else if kind == "restored" { rendererStatus = "WebGL восстановлен"; configureRenderer() }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        rendererStatus = "Не удалось загрузить персонажа: \(error.localizedDescription)"
    }
    private func configureRenderer() {
        guard ready else { return }
        webView.evaluateJavaScript("window.capri.configure({paused:\(paused || systemPaused || isHidden),reducedMotion:\(reducedMotion)})", completionHandler: nil)
    }
    func setState(_ state: String) {
        guard ["idle", "teleport", "thinking", "working", "approval", "success", "error", "sleep"].contains(state) else { return }
        if state != "teleport" { teleportGeneration += 1 }
        currentState = state
        if ready { webView.evaluateJavaScript("window.capri.setState('\(state)')", completionHandler: nil) }
    }
    private func resize() {
        guard panel != nil else { return }
        panel.setContentSize(NSSize(width: (352 * scale).rounded(), height: (532 * scale).rounded()))
        inputPanel.setFrame(panel.frame, display: true)
        screensChanged(); configureRenderer()
    }
    func show() {
        hiddenUntil = nil; defaults.removeObject(forKey: "hiddenUntil"); isHidden = false
        panel.orderFrontRegardless(); inputPanel.orderFrontRegardless(); screensChanged(); configureRenderer()
    }
    func hideForOneHour() {
        teleportGeneration += 1
        if currentState == "teleport" { setState("idle") }
        hiddenUntil = OverlayPreferences.hiddenDeadline(from: Date())
        defaults.set(hiddenUntil, forKey: "hiddenUntil"); isHidden = true
        inputPanel.orderOut(nil); panel.orderOut(nil); configureRenderer()
    }
    func returnToNotch() {
        show()
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let desired = CGPoint(x: screen.frame.midX + 90, y: screen.frame.maxY - panel.frame.height - screen.safeAreaInsets.top)
        teleport(to: OverlayGeometry.clampedOrigin(desired, panelSize: panel.frame.size, visibleFrame: screen.visibleFrame))
    }
    func teleport(to origin: CGPoint? = nil) {
        guard !isHidden, !dragging else { return }
        let destination: CGPoint?
        if let origin { destination = origin }
        else if let screen = panel.screen ?? NSScreen.main {
            let space = screen.visibleFrame
            destination = OverlayGeometry.clampedOrigin(
                CGPoint(x: panel.frame.midX < space.midX ? space.maxX - panel.frame.width - 30 : space.minX + 30, y: space.minY + 24),
                panelSize: panel.frame.size, visibleFrame: space)
        } else { destination = nil }
        teleportGeneration += 1
        let generation = teleportGeneration
        setState("teleport")
        DispatchQueue.main.asyncAfter(deadline: .now() + (reducedMotion ? 0 : 0.3)) { [weak self] in
            guard let self, self.teleportGeneration == generation, !self.isHidden else { return }
            if let destination { self.panel.setFrameOrigin(destination); self.savePosition() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, self.teleportGeneration == generation else { return }; self.setState("idle")
        }
    }
    func savePosition() {
        defaults.set(panel.frame.origin.x, forKey: "x"); defaults.set(panel.frame.origin.y, forKey: "y")
        nextRoam = Date().addingTimeInterval(45)
    }
    func move(to origin: CGPoint) { panel.setFrameOrigin(origin) }
    @objc private func tick() {
        let now = Date()
        if isHidden { if !OverlayPreferences.isHidden(until: hiddenUntil, now: now) { show() }; return }
        guard !systemPaused else { return }
        if !pinned && !paused && !reducedMotion && !dragging && currentState == "idle" && now > nextRoam {
            nextRoam = now.addingTimeInterval(45)
            if let screen = panel.screen ?? NSScreen.main {
                let space = screen.visibleFrame
                let origin = CGPoint(x: Double.random(in: space.minX...max(space.minX, space.maxX - panel.frame.width)), y: space.minY + 24)
                teleport(to: OverlayGeometry.clampedOrigin(origin, panelSize: panel.frame.size, visibleFrame: space))
            }
        }
    }
    @objc private func screensChanged() {
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(panel.frame) }) ?? NSScreen.main else { return }
        panel.setFrameOrigin(OverlayGeometry.clampedOrigin(panel.frame.origin, panelSize: panel.frame.size, visibleFrame: screen.visibleFrame))
    }
    @objc private func willSleep() { systemPaused = true; configureRenderer() }
    @objc private func didWake() { systemPaused = false; screensChanged(); configureRenderer(); NSLog("[Capri] wake restored") }
    @objc private func motionChanged() { configureRenderer() }

    func exportDiagnostics(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let transparentPoint = CGPoint(x: panel.frame.minX + 2, y: panel.frame.minY + 2)
        let bodyPoint = CGPoint(x: panel.frame.minX + 176 * scale, y: panel.frame.maxY - 246 * scale)
        let native: [String: Any] = [
            "panelWindow": inputPanel.windowNumber, "rendererWindow": panel.windowNumber,
            "transparentHitWindow": NSWindow.windowNumber(at: transparentPoint, belowWindowWithWindowNumber: 0),
            "opaqueHitWindow": NSWindow.windowNumber(at: bodyPoint, belowWindowWithWindowNumber: 0),
            "panelFrame": NSStringFromRect(panel.frame), "panelCanBecomeKey": panel.canBecomeKey,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: native, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("native.json"))
        }
        webView.takeSnapshot(with: nil) { image, error in
            if let tiff = image?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
               let png = bitmap.representation(using: .png, properties: [:]) { try? png.write(to: directory.appendingPathComponent("character.png")) }
            if let error { NSLog("[Capri] snapshot: %@", error.localizedDescription) }
        }
        webView.evaluateJavaScript("JSON.stringify(window.capri.diagnostics())") { value, _ in
            if let text = value as? String { try? text.write(to: directory.appendingPathComponent("renderer.json"), atomically: true, encoding: .utf8) }
        }
    }
}
