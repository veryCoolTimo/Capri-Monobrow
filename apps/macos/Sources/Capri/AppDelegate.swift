import AppKit
import SwiftUI
import Combine
import CapriKit

/// Capri: notch над вырезом, основное окно сессий и значок в строке меню.
///
/// Аргументы: `--hosts timoserver,quiz` — ssh-хосты (по умолчанию из настроек `capri.hosts`);
/// `--no-local`; `--only-sessions PREFIX` — только tmux-сессии с префиксом (проверки);
/// `--debug-control` — команды из `~/.capri/tmp/control` (сквозные проверки без мыши);
/// `--background` — запуск без окна (скрипты установки, перезапуск из настроек).
///
/// Окно открывается только явным действием человека: «подробнее» в notch, клик по уведомлению, Dock,
/// Launchpad/Spotlight, пункт меню. События сессий, перезапуск и автозапуск окно не показывают.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var store: SessionStore!
    private var notch: NotchController!
    private var codex: CodexService!
    private var attention: AttentionCenter!
    private var window: NSWindow?
    private let windowUI = WindowUI()
    private let settings = Settings()
    private var cancellables: Set<AnyCancellable> = []
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        store = SessionStore(sources: Self.sources())
        codex = CodexService(store: store)
        notch = NotchController(store: store, codex: codex)
        codex.summariesEnabled = { [weak self] in self?.settings.codexSummaries ?? false }
        codex.privateHosts = { [weak self] in self?.settings.codexPrivateHosts ?? [] }
        settings.onCodexChange = { [weak self] on in
            guard let self else { return }
            if on { self.codex.start() } else { self.codex.stop() }
        }
        notch.makeMenu = { [weak self] in self?.makeMenu() ?? NSMenu() }
        notch.onDetails = { [weak self] key, draft in
            guard let self else { return }
            guard let key else { self.openWindow(); return }
            self.openWindow(select: key)
            // Набранное в notch не теряется при переходе в окно.
            if !draft.isEmpty, let k = self.store.resolve(key) { self.windowUI.drafts[k] = draft }
        }
        notch.onConversation = { [weak self] in
            self?.windowUI.chatOpen = true
            self?.openWindow()
        }
        settings.onHotKeyChange = { [weak self] in self?.updateHotKey() }
        updateHotKey()
        notch.onDebug = { [weak self] cmd, arg in self?.debugCommand(cmd, arg) }
        attention = AttentionCenter(store: store, notch: notch, settings: settings) { [weak self] key in self?.openWindow(select: key) }
        attention.onPauseChange = { [weak self] in self?.updateStatusIcon() }
        settings.onFullscreenChange = { [weak self] in self?.attention.checkFullscreen() }
        settings.onHostsChange = { [weak self] hosts in self?.store.setRemoteHosts(hosts) }
        notch.start()
        attention.start()
        LoginItem.setUpOnFirstRun()
        store.start()
        if settings.codexEnabled { codex.start() }
        if CommandLine.arguments.contains("--debug-control") { notch.startDebugControl() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()
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

        SingleInstance.observe { [weak self] in self?.openWindow() }
        // После сна: сборщики хостов переподключает CollectorSupervisor; здесь — лимиты Codex и полноэкранный режим.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.codex.refreshLimits()
            self?.attention.wake()
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] n in
            // Закрыли последнее своё окно (основное или настройки) — снова только строка меню.
            guard let self, let w = n.object as? NSWindow, w === self.window || w === self.settingsWindow else { return }
            let other = w === self.window ? self.settingsWindow : self.window
            if other.map({ $0.isVisible || $0.isMiniaturized }) != true { NSApp.setActivationPolicy(.accessory) }
        }
        // Запуск руками (Finder, Launchpad, Spotlight) — сразу окно; при входе в систему и с --background — тихо.
        if !launchedQuietly { openWindow() }
        NSLog("[Capri] запущен: хосты %@", store.hosts.map(\.name).joined(separator: ", "))
    }

    func applicationWillTerminate(_ notification: Notification) {
        codex?.stop()
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
        // keyAELaunchedAsLogInItem у SMAppService приходит не всегда: запуск в первые 5 минут после загрузки
        // при включённом автозапуске тоже считаем тихим.
        let earlyAfterBoot = LoginItem.enabled && ProcessInfo.processInfo.systemUptime < 300
        return launchedAsLoginItem || earlyAfterBoot || args.contains("--background") || args.contains("--debug-control")
    }

    static func sources() -> [HostSource] {
        let args = CommandLine.arguments
        func value(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let hosts = value("--hosts").map { $0.split(separator: ",").map(String.init) } ?? Settings.hosts
        let valid = hosts.filter(HostSource.isValidAlias)
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
        if let codex {
            switch codex.state {
            case .ready(let a):
                var line = "Codex: \(a.plan ?? a.type)"
                if let l = codex.limits {
                    if let p = l.primary { line += " · \(LimitsView.title(p, fallback: "5 ч")) \(Int(p.usedPercent.rounded()))%" }
                    if let w = l.secondary { line += " · \(LimitsView.title(w, fallback: "неделя")) \(Int(w.usedPercent.rounded()))%" }
                }
                item(line, nil)
            case .signedOut: item("Войти в Codex через ChatGPT…", #selector(codexSignIn))
            case .signingIn: item("Codex: вход в браузере…", nil)
            case .noBinary: item("Codex: не найден", nil)
            case .failed: item("Codex: ошибка (см. окно)", nil)
            case .starting: item("Codex: запуск…", nil)
            case .off: break
            }
        }
        menu.addItem(.separator())
        if let attention, attention.isPaused, let until = settings.pausedUntil {
            item("Снять паузу уведомлений (до \(Self.clock.string(from: Date(timeIntervalSince1970: until))))", #selector(resumeAlerts))
        } else {
            item("Пауза уведомлений на 1 час", #selector(pauseAlerts))
        }
        item("Спросить Capri (\(HotKey.assistant.label))", #selector(showAssistant))
        item("Открыть Capri", #selector(openDashboard), key: "o")
        item("Показать notch-панель", #selector(showNotch))
        menu.addItem(.separator())
        item("Настройки…", #selector(openSettings), key: ",")
        menu.addItem(.separator())
        item("Выйти", #selector(quit), key: "q")
        return menu
    }

    @objc private func showNotch() { notch.go(.expanded, reason: "menu") }
    @objc private func showAssistant() { notch.go(.assistant, reason: "menu") }

    private func updateHotKey() {
        hotKey = nil
        settings.hotKeyError = nil
        guard settings.assistantHotKey else { return }
        let k = HotKey.assistant
        hotKey = HotKey(keyCode: k.keyCode, modifiers: k.modifiers) { [weak self] in self?.notch.toggleAssistant() }
        if hotKey == nil { settings.hotKeyError = "\(k.label) занят другим приложением" }
    }
    @objc private func codexSignIn() { codex.signIn() }
    @objc private func pauseAlerts() { attention.pause(hours: 1) }
    @objc private func resumeAlerts() { attention.resume() }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// ✦ — обычный режим, луна — пауза уведомлений.
    private func updateStatusIcon() {
        let paused = attention?.isPaused ?? false
        statusItem?.button?.image = NSImage(systemSymbolName: paused ? "moon.zzz" : "sparkle",
                                            accessibilityDescription: paused ? "Capri — пауза" : "Capri")
    }
    private var settingsWindow: NSWindow?

    /// Настройки — отдельное обычное окно (как у любого приложения macOS).
    @objc private func openSettings() {
        let w = settingsWindow ?? {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "Настройки Capri"
            w.appearance = NSAppearance(named: .darkAqua)
            w.isReleasedWhenClosed = false
            w.isRestorable = false
            w.collectionBehavior = [.managed, .participatesInCycle, .fullScreenNone]
            let host = NSHostingView(rootView: SettingsView(settings: settings, hosts: store.hostList))
            w.contentView = host
            w.setContentSize(NSSize(width: 480, height: 600))
            w.center()
            return w
        }()
        settingsWindow = w
        NSApp.setActivationPolicy(.regular)
        w.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
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
        // Обычное окно: свой Space, не поверх полноэкранных приложений, не восстанавливается само при входе.
        w.level = .normal
        w.collectionBehavior = [.managed, .participatesInCycle, .fullScreenPrimary]
        w.isRestorable = false
        let actions = WindowActions(
            send: { [weak self] key, action in self?.sendFromWindow(key, action) },
            open: { [weak self] key in self?.store.openTerminal(key) },
            settings: { [weak self] in self?.openSettings() })
        let view = MainWindowView(store: store, ui: windowUI, codex: codex, actions: actions)
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
            if arg == "off" { settingsWindow?.close() } else { openSettings() }
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

    /// Снимок своего окна в `~/.capri/tmp/window.png` (окна настроек, если открыто, — в `window-settings.png`).
    private func snapshotWindow() {
        let settingsOpen = settingsWindow?.isVisible == true
        guard let w = settingsOpen ? settingsWindow : window, let target = w.contentView else { return }
        guard let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { return }
        target.cacheDisplay(in: target.bounds, to: rep)
        CapriPaths.ensureDir()
        let name = settingsOpen ? "window-settings.png" : "window.png"
        try? rep.representation(using: .png, properties: [:])?.write(to: CapriPaths.tmp.appendingPathComponent(name))
    }
}
