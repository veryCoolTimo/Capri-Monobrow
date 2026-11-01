import AppKit

/// Какое приложение человек открыл: `NSWorkspace` (без разрешений, 0 CPU в покое) + дебаунс 1,2 с — быстрый ⌘-Tab
/// сквозь несколько программ ничего не вызывает, доходит только то, что осталось передним.
final class AppWatcher {
    static let debounce = 1.2
    /// Приложение осталось передним `debounce` секунд. `launched` — только что запущено.
    var onSettled: ((NSRunningApplication, Bool) -> Void)?
    /// Переднее приложение сменилось (сразу, без дебаунса).
    var onActivated: ((NSRunningApplication) -> Void)?
    var onTerminated: ((String) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var pending: DispatchWorkItem?
    /// «Запуск» — приложение стало передним не позже стольких секунд после старта процесса (`launchDate`):
    /// запущенное ссылкой/файлом/скриптом в фоне и активированное позже — не запуск, ⌘-Tab — тем более.
    /// По `launchDate`, а не по порядку уведомлений: медленные приложения шлют `didActivate` раньше `didLaunch`.
    static let launchWindow = 10.0

    func start() {
        guard observers.isEmpty else { return }
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.activated(app)
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            if let id = app.bundleIdentifier { self?.onTerminated?(id) }
        })
    }

    func stop() {
        let ws = NSWorkspace.shared.notificationCenter
        for o in observers { ws.removeObserver(o) }
        observers.removeAll()
        pending?.cancel()
        pending = nil
    }

    private func activated(_ app: NSRunningApplication) {
        onActivated?(app)
        pending?.cancel()
        let pid = app.processIdentifier
        // Свежесть — на момент активации (не после дебаунса).
        let fresh = app.launchDate.map { Date().timeIntervalSince($0) < Self.launchWindow } ?? false
        let work = DispatchWorkItem { [weak self] in
            guard let self, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            self.onSettled?(app, fresh)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce, execute: work)
    }
}
