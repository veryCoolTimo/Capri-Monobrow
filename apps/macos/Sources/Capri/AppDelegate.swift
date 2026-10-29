import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var window: NSWindow!
    private var character: CharacterController!
    private let store = DemoStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        character = CharacterController()
        character.onClick = { [weak self] in self?.showDashboard() }
        character.onContextMenu = { [weak self] event, view in
            guard let self else { return }; NSMenu.popUpContextMenu(self.makeMenu(), with: event, for: view)
        }
        store.onReaction = { [weak self] in self?.character.setState($0) }
        character.setState(store.selected.state.character)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Capri")
        let menu = makeMenu(); menu.delegate = self; statusItem.menu = menu
        let content = DashboardView(store: store, character: character)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Capri — прототип"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 900, height: 650)
        window.backgroundColor = NSColor(calibratedRed: 0.085, green: 0.074, blue: 0.108, alpha: 1)
        let hostingView = NSHostingView(rootView: content)
        hostingView.sizingOptions = []
        window.contentView = hostingView
        window.setContentSize(NSSize(width: 1020, height: 720))
        window.center()
        showDashboard()
        // A purposeful, opt-in artifact export for local inspection; no screenshot of other apps.
        if let index = CommandLine.arguments.firstIndex(of: "--export-diagnostics"), CommandLine.arguments.count > index + 1 {
            let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self else { return }
                self.character.exportDiagnostics(to: directory)
                NSLog("[Capri] dashboard frame: %@", NSStringFromRect(self.window.frame))
                if let view = self.window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: directory.appendingPathComponent("dashboard.png")) }
                }
            }
        }
        NSLog("[Capri] prototype launched; no agents connected")
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    private func installMainMenu() {
        let main = NSMenu()
        let application = NSMenuItem(); main.addItem(application)
        let applicationMenu = NSMenu(title: "Capri"); application.submenu = applicationMenu
        let quitItem = NSMenuItem(title: "Завершить Capri", action: #selector(quit), keyEquivalent: "q")
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
        func item(_ title: String, _ selector: Selector, key: String = "", checked: Bool = false) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.target = self; item.state = checked ? .on : .off; menu.addItem(item)
        }
        item("Открыть Capri", #selector(openDashboard), key: "o")
        item("Вернуться к вырезу экрана", #selector(goToNotch))
        item("Телепорт", #selector(teleport))
        menu.addItem(.separator())
        item(character?.isHidden == true ? "Показать персонажа" : "Скрыть на 1 час", #selector(toggleHidden))
        item("Приостановить анимацию", #selector(togglePaused), checked: character?.paused == true)
        item("Оставаться на месте", #selector(togglePinned), checked: character?.pinned == true)
        menu.addItem(.separator())
        item("Размер: маленький", #selector(small), checked: character?.size == "small")
        item("Размер: средний", #selector(medium), checked: character?.size == "medium")
        item("Размер: большой", #selector(large), checked: character?.size == "large")
        menu.addItem(.separator())
        item("Завершить Capri", #selector(quit), key: "q")
        return menu
    }
    private func showDashboard() { window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true) }
    @objc private func openDashboard() { showDashboard() }
    @objc private func goToNotch() { character.returnToNotch() }
    @objc private func teleport() { character.teleport() }
    @objc private func toggleHidden() { if character.isHidden { character.show() } else { character.hideForOneHour() } }
    @objc private func togglePaused() { character.paused.toggle() }
    @objc private func togglePinned() { character.pinned.toggle() }
    @objc private func small() { character.size = "small" }
    @objc private func medium() { character.size = "medium" }
    @objc private func large() { character.size = "large" }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
