import AppKit
import SwiftUI
import Combine
import CapriKit

/// Capri: notch над вырезом + значок в строке меню. Окно сессий (`DashboardView`) пока на демо-данных
/// (Этап 3), персонаж по умолчанию выключен.
///
/// Аргументы: `--hosts timoserver,quiz` — ssh-хосты (по умолчанию из настроек `capri.hosts`);
/// `--no-local`; `--only-sessions PREFIX` — только tmux-сессии с префиксом (проверки);
/// `--debug-control` — команды из `~/.capri/tmp/control` (сквозные проверки без мыши);
/// `--export-diagnostics DIR` — диагностика персонажа (прототип).
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var store: SessionStore!
    private var notch: NotchController!
    private var window: NSWindow?
    private var character: CharacterController?
    private let demo = DemoStore()
    private var cancellables: Set<AnyCancellable> = []
    private let defaults = UserDefaults.standard

    private var soundEnabled: Bool {
        get { defaults.object(forKey: "capri.sound") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "capri.sound") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        store = SessionStore(sources: Self.sources())
        notch = NotchController(store: store)
        notch.makeMenu = { [weak self] in self?.makeMenu() ?? NSMenu() }
        notch.soundEnabled = { [weak self] in self?.soundEnabled ?? false }
        notch.start()
        store.start()
        if CommandLine.arguments.contains("--debug-control") { notch.startDebugControl() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Capri")
        statusItem.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        store.$sessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                let waiting = sessions.filter { $0.status == .needsInput }.count
                self?.statusItem.button?.title = waiting > 0 ? " \(waiting)" : ""
            }
            .store(in: &cancellables)

        if let index = CommandLine.arguments.firstIndex(of: "--export-diagnostics"), CommandLine.arguments.count > index + 1 {
            exportDiagnostics(to: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true))
        }
        NSLog("[Capri] запущен: хосты %@", store.hosts.map(\.name).joined(separator: ", "))
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    static func sources() -> [HostSource] {
        let args = CommandLine.arguments
        func value(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let hosts = value("--hosts").map { $0.split(separator: ",").map(String.init) }
            ?? UserDefaults.standard.stringArray(forKey: "capri.hosts") ?? ["timoserver", "quiz"]
        // Имя хоста уходит в ssh: только алиасы из ~/.ssh/config, без пробелов и ведущего «-».
        let valid = hosts.filter { !$0.isEmpty && !$0.hasPrefix("-") && $0.allSatisfy { $0.isLetter || $0.isNumber || "-_.@".contains($0) } }
        var sources: [HostSource] = args.contains("--no-local") ? [] : [.local()]
        sources += valid.map { HostSource.ssh($0) }
        if let prefix = value("--only-sessions") {
            for i in sources.indices { sources[i].streamArgs = ["--only-sessions", prefix] }
        }
        return sources
    }

    // MARK: меню

    private func installMainMenu() {
        let main = NSMenu()
        let application = NSMenuItem(); main.addItem(application)
        let applicationMenu = NSMenu(title: "Capri"); application.submenu = applicationMenu
        let quitItem = NSMenuItem(title: "Выйти из Capri", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self; applicationMenu.addItem(quitItem)
        let edit = NSMenuItem(); main.addItem(edit)
        let editMenu = NSMenu(title: "Правка"); edit.submenu = editMenu
        for (title, selector, key) in [
            ("Вырезать", #selector(NSText.cut(_:)), "x"),
            ("Копировать", #selector(NSText.copy(_:)), "c"),
            ("Вставить", #selector(NSText.paste(_:)), "v"),
            ("Выделить всё", #selector(NSText.selectAll(_:)), "a")
        ] { editMenu.addItem(NSMenuItem(title: title, action: selector, keyEquivalent: key)) }
        let windows = NSMenuItem(); main.addItem(windows)
        let windowMenu = NSMenu(title: "Окно"); windows.submenu = windowMenu
        windowMenu.addItem(NSMenuItem(title: "Закрыть окно", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        NSApplication.shared.mainMenu = main
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        for item in makeMenu().items { menu.addItem(item.copy() as! NSMenuItem) }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        func item(_ title: String, _ selector: Selector?, key: String = "", checked: Bool = false) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.target = self; item.state = checked ? .on : .off; item.isEnabled = selector != nil
            menu.addItem(item)
        }
        let waiting = store?.waiting.count ?? 0
        item(waiting > 0 ? "Ждут меня: \(waiting)" : "Никто не ждёт", nil)
        for h in store?.hosts ?? [] {
            item("   \(SessionStore.displayHost(h.name)): \(h.connected ? "на связи" : "нет связи")", nil)
        }
        menu.addItem(.separator())
        item("Показать notch-панель", #selector(showNotch))
        item("Окно сессий (демо, Этап 3)", #selector(openDashboard), key: "o")
        menu.addItem(.separator())
        item("Звук при «ждёт меня»", #selector(toggleSound), checked: soundEnabled)
        item(character == nil || character?.isHidden == true ? "Показать персонажа" : "Скрыть персонажа", #selector(toggleCharacter))
        menu.addItem(.separator())
        item("Выйти", #selector(quit), key: "q")
        return menu
    }

    @objc private func showNotch() { notch.go(.expanded, reason: "menu") }
    @objc private func toggleSound() { soundEnabled.toggle() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }

    @objc private func openDashboard() {
        let w = window ?? makeDashboard()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func toggleCharacter() {
        if let c = character, !c.isHidden { c.hide(); return }
        ensureCharacter().show()
    }

    private func ensureCharacter() -> CharacterController {
        if let c = character { return c }
        let c = CharacterController()
        c.onClick = { [weak self] in self?.openDashboard() }
        c.onContextMenu = { [weak self] event, view in
            guard let self else { return }
            NSMenu.popUpContextMenu(self.makeMenu(), with: event, for: view)
        }
        demo.onReaction = { [weak c] in c?.setState($0) }
        c.setState(demo.selected.state.character)
        c.hide()
        character = c
        return c
    }

    private func makeDashboard() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 720),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Capri — прототип"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 900, height: 650)
        w.backgroundColor = NSColor(calibratedRed: 0.085, green: 0.074, blue: 0.108, alpha: 1)
        let hostingView = NSHostingView(rootView: DashboardView(store: demo, character: ensureCharacter()))
        hostingView.sizingOptions = []
        w.contentView = hostingView
        w.setContentSize(NSSize(width: 1020, height: 720))
        w.center()
        return w
    }

    /// Диагностика персонажа (прототип): `--export-diagnostics DIR`, без снимков чужих окон.
    private func exportDiagnostics(to directory: URL) {
        let c = ensureCharacter()
        c.show()
        openDashboard()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, let w = self.window else { return }
            c.exportDiagnostics(to: directory)
            if let view = w.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: directory.appendingPathComponent("dashboard.png")) }
            }
        }
    }
}
