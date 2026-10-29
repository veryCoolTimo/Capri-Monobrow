// Спайк Этапа 0: notch-панель над строкой меню.
// Аргументы: --expanded (сразу раскрыть), --no-notch (вести себя как экран без выреза),
// --screen N (индекс NSScreen.screens), --diag PATH (куда писать диагностику, по умолчанию /tmp/capri-notch.json).
import AppKit
import SwiftUI
import CapriKit

let args = CommandLine.arguments
func argValue(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
let forceNoNotch = args.contains("--no-notch")
let startExpanded = args.contains("--expanded")
let diagPath = argValue("--diag") ?? "/tmp/capri-notch.json"

func notchScreen(_ screen: NSScreen) -> NotchScreen {
    if forceNoNotch {
        return NotchScreen(frame: screen.frame, visibleFrame: screen.visibleFrame, safeAreaTop: 0,
                           auxiliaryTopLeft: nil, auxiliaryTopRight: nil)
    }
    return NotchScreen(frame: screen.frame, visibleFrame: screen.visibleFrame,
                       safeAreaTop: screen.safeAreaInsets.top,
                       auxiliaryTopLeft: screen.auxiliaryTopLeftArea, auxiliaryTopRight: screen.auxiliaryTopRightArea)
}

final class NotchModel: ObservableObject {
    @Published var expanded = false
    @Published var hasNotch = true
    @Published var notchWidth: CGFloat = 0
}

struct NotchShape: Shape {
    var radius: CGFloat
    var animatableData: CGFloat { get { radius } set { radius = newValue } }
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - radius))
        p.addQuadCurve(to: CGPoint(x: r.maxX - radius, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + radius, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - radius), control: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

struct NotchView: View {
    @ObservedObject var model: NotchModel
    var body: some View {
        ZStack(alignment: .top) {
            NotchShape(radius: model.expanded ? 18 : (model.hasNotch ? 10 : 13))
                .fill(Color.black)
            if model.expanded {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Ждут меня · 2").font(.system(size: 13, weight: .semibold))
                    row("capri", "timoserver · claude", "Run date > stamp.txt?", "2 мин")
                    row("archestor", "quiz · codex", "Allow creating stamp-codex.txt?", "40 с")
                    Spacer()
                    Text("Спайк Этапа 0 — данные ненастоящие").font(.system(size: 10)).foregroundColor(.gray)
                }
                .foregroundColor(.white)
                .padding(.top, model.hasNotch ? 44 : 14).padding(.horizontal, 18).padding(.bottom, 14)
            } else {
                HStack(spacing: 0) {
                    Image(systemName: "sparkle").foregroundColor(.white).frame(width: 30)
                    Spacer(minLength: model.notchWidth)
                    HStack(spacing: 6) {
                        Text("● 2").foregroundColor(.orange)
                        Text("○ 3").foregroundColor(.gray)
                    }.font(.system(size: 11, weight: .semibold, design: .rounded))
                }
                .padding(.horizontal, 14)
                .frame(maxHeight: .infinity)
            }
        }
    }
    func row(_ project: String, _ meta: String, _ question: String, _ age: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(project).font(.system(size: 12, weight: .medium)); Spacer(); Text(age).font(.system(size: 11)).foregroundColor(.orange) }
            Text(meta).font(.system(size: 10)).foregroundColor(.gray)
            Text(question).font(.system(size: 11)).lineLimit(1)
        }
        .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))
    }
}

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // Не даём AppKit сдвинуть окно под строку меню.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class HoverView: NSView {
    var onHover: ((Bool) -> Void)?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class Controller: NSObject, NSApplicationDelegate {
    let model = NotchModel()
    var panel: NotchPanel!
    var screen: NSScreen!
    var collapseWork: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let index = Int(argValue("--screen") ?? "") ?? 0
        screen = NSScreen.screens.indices.contains(index) ? NSScreen.screens[index] : NSScreen.main!
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Выше строки меню (mainMenu = 24) и её меню-экстр.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let hover = HoverView()
        let host = NSHostingView(rootView: NotchView(model: model))
        if #available(macOS 13.0, *) { host.sizingOptions = [] }
        host.autoresizingMask = [.width, .height]
        hover.addSubview(host)
        hover.onHover = { [weak self] inside in self?.hover(inside) }
        panel.contentView = hover
        layout(animated: false)
        if startExpanded { model.expanded = true; layout(animated: false) }
        panel.orderFrontRegardless()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.layout(animated: false); self?.writeDiagnostics(reason: "screenParametersChanged")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.writeDiagnostics(reason: "launch") }
    }

    func hover(_ inside: Bool) {
        collapseWork?.cancel()
        if inside {
            guard !model.expanded else { return }
            model.expanded = true; layout(animated: true)
            writeDiagnostics(reason: "hoverExpand")
        } else {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.model.expanded, !startExpanded else { return }
                self.model.expanded = false; self.layout(animated: true)
                self.writeDiagnostics(reason: "hoverCollapse")
            }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }

    func layout(animated: Bool) {
        let s = notchScreen(screen)
        model.hasNotch = NotchGeometry.notchRect(s) != nil
        model.notchWidth = NotchGeometry.notchRect(s)?.width ?? 0
        let frame = model.expanded ? NotchGeometry.expandedFrame(s) : NotchGeometry.collapsedFrame(s)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    func rect(_ r: CGRect?) -> Any { r.map { ["x": $0.minX, "y": $0.minY, "w": $0.width, "h": $0.height] } ?? NSNull() }

    func writeDiagnostics(reason: String) {
        var screens: [[String: Any]] = []
        for (i, sc) in NSScreen.screens.enumerated() {
            let s = notchScreen(sc)
            screens.append([
                "index": i, "name": sc.localizedName, "isMain": sc == NSScreen.main,
                "frame": rect(sc.frame), "visibleFrame": rect(sc.visibleFrame), "backingScale": sc.backingScaleFactor,
                "safeAreaInsets": ["top": sc.safeAreaInsets.top, "left": sc.safeAreaInsets.left,
                                   "bottom": sc.safeAreaInsets.bottom, "right": sc.safeAreaInsets.right],
                "auxiliaryTopLeftArea": rect(sc.auxiliaryTopLeftArea), "auxiliaryTopRightArea": rect(sc.auxiliaryTopRightArea),
                "menuBarHeight": NotchGeometry.menuBarHeight(s),
                "notchRect": rect(NotchGeometry.notchRect(s)),
                "collapsedFrame": rect(NotchGeometry.collapsedFrame(s)), "expandedFrame": rect(NotchGeometry.expandedFrame(s)),
            ])
        }
        // Как окно видит WindowServer: слой и границы (CG-координаты, начало сверху слева).
        var windowInfo: Any = NSNull()
        if let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(panel.windowNumber)) as? [[String: Any]], let w = list.first {
            windowInfo = ["layer": w[kCGWindowLayer as String] ?? NSNull(), "bounds": w[kCGWindowBounds as String] ?? NSNull(),
                          "alpha": w[kCGWindowAlpha as String] ?? NSNull(), "onscreen": w[kCGWindowIsOnscreen as String] ?? NSNull()]
        }
        // Чьи окна лежат прямо под панелью и что выше неё: строка меню должна быть ниже.
        var menuBarLayer: Any = NSNull()
        if let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] {
            menuBarLayer = all.filter { ($0[kCGWindowOwnerName as String] as? String) == "Window Server" || ($0[kCGWindowName as String] as? String) == "Menubar" }
                .map { ["owner": $0[kCGWindowOwnerName as String] ?? "", "name": $0[kCGWindowName as String] ?? "", "layer": $0[kCGWindowLayer as String] ?? 0] }
        }
        let diag: [String: Any] = [
            "reason": reason, "time": Date().timeIntervalSince1970,
            "args": Array(args.dropFirst()), "expanded": model.expanded,
            "panel": ["frame": rect(panel.frame), "level": panel.level.rawValue,
                      "mainMenuLevel": NSWindow.Level.mainMenu.rawValue, "statusBarLevel": NSWindow.Level.statusBar.rawValue,
                      "isVisible": panel.isVisible, "canBecomeKey": panel.canBecomeKey, "ignoresMouseEvents": panel.ignoresMouseEvents,
                      "window": windowInfo],
            "menuBarWindows": menuBarLayer,
            "screens": screens,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: diag, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: diagPath))
            if reason != "launch" { try? data.write(to: URL(fileURLWithPath: diagPath + "." + reason)) }
        }
    }
}

let app = NSApplication.shared
let controller = Controller()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
