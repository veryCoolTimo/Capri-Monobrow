import AppKit
import SwiftUI
import Combine
import CapriKit

/// Capri: notch над вырезом, основное окно сессий и значок в строке меню. Персонаж по умолчанию выключен.
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
    private let windowUI = WindowUI()
    private let settings = Settings()
    private let characterBridge = CharacterVisibility()
    private var character: CharacterController?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        store = SessionStore(sources: Self.sources())
        notch = NotchController(store: store)
        notch.makeMenu = { [weak self] in self?.makeMenu() ?? NSMenu() }
        notch.soundEnabled = { [weak self] in self?.settings.sound ?? false }
        notch.onDetails = { [weak self] key, draft in
            self?.openWindow(select: key)
            // Набранное в notch не теряется при переходе в окно.
            if !draft.isEmpty, let k = self?.store.resolve(key) { self?.windowUI.drafts[k] = draft }
        }
        notch.onDebug = { [weak self] cmd, arg in self?.debugCommand(cmd, arg) }
        characterBridge.show = { [weak self] in self?.ensureCharacter().show() }
        characterBridge.hide = { [weak self] in self?.character?.hide() }
        characterBridge.isVisible = { [weak self] in self?.character.map { !$0.isHidden } ?? false }
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
                self?.character?.setState(waiting > 0 ? "approval" : sessions.contains { $0.status == .running } ? "working" : "idle")
            }
            .store(in: &cancellables)

        if let index = CommandLine.arguments.firstIndex(of: "--export-diagnostics"), CommandLine.arguments.count > index + 1 {
            exportDiagnostics(to: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true))
        }
        SingleInstance.observe { [weak self] in self?.openWindow() }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] n in
            if (n.object as? NSWindow) === self?.window { NSApp.setActivationPolicy(.accessory) }
        }
        // Запуск руками (Finder, Launchpad, Spotlight) — сразу окно; при входе в систему и с --background — тихо.
        if !launchedQuietly { openWindow() }
        NSLog("[Capri] запущен: хосты %@", store.hosts.map(\.name).joined(separator: ", "))
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Повторный запуск уже открытого Capri (Dock, Launchpad, двойной клик) — показать окно.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openWindow()
        return false
    }

    /// Запуск без окна: `--background`, отладочные флаги или вход в систему (объект входа).
    /// Событие запуска доступно только в willFinishLaunching — запоминаем признак там.
    private var launchedAsLoginItem = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        if let event = NSAppleEventManager.shared().currentAppleEvent, event.eventID == kAEOpenApplication {
            launchedAsLoginItem = event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        }
    }

    private var launchedQuietly: Bool {
        let args = CommandLine.arguments
        return launchedAsLoginItem || args.contains("--background") || args.contains("--debug-control")
            || args.contains("--export-diagnostics")
    }

    static func sources() -> [HostSource] {
        let args = CommandLine.arguments
        func value(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let hosts = value("--hosts").map { $0.split(separator: ",").map(String.init) } ?? Settings.hosts
        let valid = hosts.filter(Settings.validHost)
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
        item("Открыть Capri", #selector(openDashboard), key: "o")
        item("Показать notch-панель", #selector(showNotch))
        menu.addItem(.separator())
        item("Звук при «ждёт меня»", #selector(toggleSound), checked: settings.sound)
        item("Настройки…", #selector(openSettings), key: ",")
        item(character == nil || character?.isHidden == true ? "Показать персонажа" : "Скрыть персонажа", #selector(toggleCharacter))
        menu.addItem(.separator())
        item("Выйти", #selector(quit), key: "q")
        return menu
    }

    @objc private func showNotch() { notch.go(.expanded, reason: "menu") }
    @objc private func toggleSound() { settings.sound.toggle() }
    @objc private func openSettings() { openWindow(); windowUI.settings = true }
    @objc private func quit() { NSApplication.shared.terminate(nil) }

    @objc private func openDashboard() { openWindow() }

    /// Основное окно; `select` — сразу на эту сессию (из «Подробнее» в notch).
    private func openWindow(select key: SessionKey? = nil) {
        if let key {
            windowUI.selected = store.resolve(key) ?? key
            if let s = store.session(key), !windowUI.filter.matches(s) { windowUI.filter = .all }
            if let h = windowUI.host, h != key.host { windowUI.host = nil }
            store.clearDelivery(key)
        } else if windowUI.selected == nil {
            windowUI.selected = store.waiting.first?.key ?? store.sessions.first?.key
        }
        let w = window ?? makeWindow()
        window = w
        // Пока окно открыто, Capri — обычное приложение: значок в Dock и ⌘Tab. Закрыли — снова только строка меню.
        NSApp.setActivationPolicy(.regular)
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
        c.onClick = { [weak self] in self?.openWindow() }
        c.onContextMenu = { [weak self] event, view in
            guard let self else { return }
            NSMenu.popUpContextMenu(self.makeMenu(), with: event, for: view)
        }
        c.hide()
        character = c
        return c
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Capri"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 980, height: 600)
        w.backgroundColor = NSColor(calibratedRed: 0.035, green: 0.03, blue: 0.04, alpha: 1)
        w.setFrameAutosaveName("CapriMainWindow")
        let actions = WindowActions(
            send: { [weak self] key, action in self?.sendFromWindow(key, action) },
            open: { [weak self] key in self?.store.openTerminal(key) })
        let settings = settings, bridge = characterBridge, ui = windowUI
        let active = store.hosts.map(\.name).filter { $0 != "local" }
        let view = MainWindowView(store: store, ui: windowUI, actions: actions) {
            AnyView(SettingsView(settings: settings, character: bridge, active: active) { ui.settings = false })
        }
        let hostingView = NSHostingView(rootView: view)
        hostingView.sizingOptions = []
        w.contentView = hostingView
        if !w.setFrameUsingName("CapriMainWindow") {
            w.setContentSize(NSSize(width: 1120, height: 720))
            w.center()
        }
        return w
    }

    // MARK: отладочное управление окном (--debug-control)

    private func debugCommand(_ cmd: String, _ arg: String) {
        switch cmd {
        case "window":
            // window [tmux-сессия]
            openWindow(select: store.sessions.first { !arg.isEmpty && $0.tmux?.session == arg }?.key)
        case "window-filter":
            if let f = SessionFilter(rawValue: arg) { windowUI.filter = f }
        case "window-host":
            windowUI.host = arg.isEmpty ? nil : arg
        case "window-text":
            if let k = windowUI.selected { windowUI.drafts[k] = arg; sendFromWindow(k, .text(arg)) }
        case "window-choose":
            if let k = windowUI.selected, let n = Int(arg) { sendFromWindow(k, .choose(n)) }
        case "window-settings":
            windowUI.settings = arg != "off"
        case "window-close":
            window?.close()
        case "window-snapshot":
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.snapshotWindow() }
        default:
            break
        }
    }

    private func sendFromWindow(_ key: SessionKey, _ action: ReplyAction) {
        let key = store.resolve(key) ?? key
        store.send(key, action) { [weak self] ok in
            if ok, case .text = action { self?.windowUI.drafts[key] = nil }
        }
    }

    /// Снимок своего окна (с листом настроек, если открыт) в `~/.capri/tmp/window.png`.
    private func snapshotWindow() {
        guard let w = window, let view = w.contentView else { return }
        let target = w.attachedSheet?.contentView ?? view
        guard let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { return }
        target.cacheDisplay(in: target.bounds, to: rep)
        CapriPaths.ensureDir()
        let name = w.attachedSheet == nil ? "window.png" : "window-settings.png"
        try? rep.representation(using: .png, properties: [:])?.write(to: CapriPaths.tmp.appendingPathComponent(name))
    }

    /// Диагностика персонажа (прототип): `--export-diagnostics DIR`, без снимков чужих окон.
    private func exportDiagnostics(to directory: URL) {
        let c = ensureCharacter()
        c.show()
        openWindow()
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
