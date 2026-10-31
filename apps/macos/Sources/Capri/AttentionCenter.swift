import AppKit
import Combine
import CapriKit

/// Как Capri зовёт на новое «ждёт меня»: peek notch, звук, уведомление macOS — с учётом паузы на час
/// и полноэкранных приложений (`AttentionPolicy`). Здесь же автозапуск при входе в систему.
final class AttentionCenter: NSObject {
    private let store: SessionStore
    private let notch: NotchController
    private let settings: Settings
    private let notifier = SystemNotifier()
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private var pauseTimer: Timer?
    private(set) var displaysAsleep = false
    /// Полноэкранное приложение на экране notch (независимо от настройки «прятать notch»).
    private(set) var fullscreen = false
    /// Полноэкранный режим включился/выключился — персонаж гасит сцену.
    var onFullscreen: ((Bool) -> Void)?
    private var throttle = AttentionThrottle()
    /// Пауза включилась/кончилась — обновить значок в строке меню.
    var onPauseChange: (() -> Void)?

    init(store: SessionStore, notch: NotchController, settings: Settings, open: @escaping (SessionKey) -> Void) {
        self.store = store
        self.notch = notch
        self.settings = settings
        super.init()
        notifier.onOpen = open
    }

    func start() {
        store.onNeedsInput = { [weak self] s in self?.needsInput(s) }
        store.onUserResponded = { [weak self] key in self?.throttle.reset(key) }
        notifier.start()
        // Ответили или сессия ушла — её уведомление из Центра уведомлений больше не нужно.
        store.$sessions
            .sink { [weak self] sessions in
                let waiting = Set(sessions.filter { $0.status == .needsInput }.map(\.key))
                self?.notifier.removeExcept(waiting)
            }
            .store(in: &cancellables)
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.scheduleFullscreenCheck() })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            self?.scheduleFullscreenCheck()
        })
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                self?.displaysAsleep = n.name == NSWorkspace.screensDidSleepNotification
            })
        }
        checkFullscreen()
        armPauseTimer()
    }

    // MARK: «ждёт меня»

    private var policy: AttentionPolicy {
        AttentionPolicy(pausedUntil: settings.pausedUntil, sound: settings.sound,
                        system: settings.notificationPolicy, fullscreenQuiet: settings.fullscreenQuiet)
    }

    private func needsInput(_ s: Session) {
        let now = Date().timeIntervalSince1970
        guard throttle.allows(s.key, now: now) else { return }
        let d = policy.decide(now: now, notchHidden: !notchVisible)
        if d.peek || d.systemNotification { throttle.record(s.key, now: now) }
        if d.peek { notch.alert(s, sound: d.sound) }
        if d.systemNotification {
            notifier.post(s, text: settings.notificationText && !settings.codexPrivateHosts.contains(s.key.host)
                ? (store.summary(s) ?? s.headline) : nil)
        }
    }

    /// Человек увидит peek: экран не спит и не заблокирован, курсор на экране notch.
    /// В полноэкранном приложении notch всплывает поверх — это тоже «видно», баннер не нужен.
    private var notchVisible: Bool {
        if displaysAsleep || Self.screenLocked { return false }
        guard let screen = notch.notchScreen else { return false }
        return screen.frame.contains(NSEvent.mouseLocation)
    }

    static var screenLocked: Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return d["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// После сна таймер паузы мог проспать конец паузы.
    func wake() {
        armPauseTimer()
        checkFullscreen()
    }

    // MARK: пауза

    var isPaused: Bool { policy.paused(now: Date().timeIntervalSince1970) }

    func pause(hours: Double) {
        settings.pausedUntil = Date().timeIntervalSince1970 + hours * 3600
        armPauseTimer()
    }

    func resume() {
        settings.pausedUntil = nil
        armPauseTimer()
    }

    private func armPauseTimer() {
        pauseTimer?.invalidate()
        onPauseChange?()
        guard let until = settings.pausedUntil else { return }
        let left = until - Date().timeIntervalSince1970
        guard left > 0 else { settings.pausedUntil = nil; onPauseChange?(); return }
        // .common — чтобы сработал и при открытом меню.
        let t = Timer(timeInterval: left + 0.5, repeats: false) { [weak self] _ in
            self?.settings.pausedUntil = nil
            self?.onPauseChange?()
        }
        RunLoop.main.add(t, forMode: .common)
        pauseTimer = t
    }

    // MARK: полноэкранные приложения

    /// Смена пространства анимируется — смотрим чуть позже и ещё раз после анимации.
    private func scheduleFullscreenCheck() {
        for delay in [0.35, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.checkFullscreen() }
        }
    }

    static var menuBarAutoHides: Bool {
        UserDefaults(suiteName: ".GlobalPreferences")?.bool(forKey: "_HIHideMenuBar") ?? false
    }

    func checkFullscreen() {
        guard let screen = notch.notchScreen else {
            setFullscreen(false)
            notch.setSuppressed(false); return
        }
        let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let windows = raw.compactMap(WindowInfo.from)
        // NSScreen — от нижнего левого угла главного экрана, CGWindow — от верхнего левого.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let f = screen.frame
        let cgFrame = CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let own = ProcessInfo.processInfo.processIdentifier
        let top = screen.safeAreaInsets.top
        if Self.menuBarAutoHides {
            // При «всегда скрывать строку меню» развёрнутое окно не отличить от полноэкранного — notch не прячем,
            // а персонаж молчит при любом окне на весь экран.
            setFullscreen(Fullscreen.frontCoversScreen(windows: windows, screen: cgFrame, safeAreaTop: top, frontmost: front, ownPid: own))
            notch.setSuppressed(false)
            return
        }
        let active = Fullscreen.isActive(windows: windows, screen: cgFrame, safeAreaTop: top, frontmost: front, ownPid: own)
        setFullscreen(active)
        notch.setSuppressed(active && settings.fullscreenQuiet)
    }

    private func setFullscreen(_ value: Bool) {
        guard value != fullscreen else { return }
        fullscreen = value
        onFullscreen?(value)
    }
}

