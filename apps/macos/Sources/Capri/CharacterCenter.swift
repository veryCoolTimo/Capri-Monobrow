import AppKit
import Combine
import IOKit
import CapriKit

/// Персонаж: когда и какие сцены играть (`CharacterDirector`), их показ (`StageController`), музыка
/// (`NowPlayingMonitor`) и кивание в notch. Без запросов разрешений: рамки окон — без названий, простой ввода —
/// IOKit `HIDIdleTime`, музыка — распределённые уведомления плееров.
final class CharacterCenter {
    let stage = StageController()
    private let monitor = NowPlayingMonitor()
    private let store: SessionStore
    private let notch: NotchController
    private let settings: Settings
    private let attention: AttentionCenter
    private(set) var director: CharacterDirector
    private var playing: NowPlayingState
    private var prevStatus: [SessionKey: SessionStatus] = [:]
    private var ambientTimer: Timer?
    /// Конец «спрятан на час» — снова взвести фоновые сцены.
    private var unhideTimer: Timer?
    private var vibeWork: DispatchWorkItem?
    private var musicRefresh: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []
    /// Решения и сцены в `~/.capri/tmp/debug.log` (только с `--debug-control`).
    var debugLog = false

    init(store: SessionStore, notch: NotchController, settings: Settings, attention: AttentionCenter) {
        self.store = store
        self.notch = notch
        self.settings = settings
        self.attention = attention
        let now = Date().timeIntervalSince1970
        director = CharacterDirector(now: now, seed: Int(now) & 0xFFFF, rate: settings.characterRate)
        playing = NowPlayingState(now: now)
    }

    func start() {
        stage.home = { [weak notch] in notch?.eyesRect }
        stage.screen = { [weak notch] in notch?.notchScreen }
        stage.content = { [weak self] in self?.content() ?? SceneContent() }
        stage.onRunning = { [weak self] on in self?.notch.ui.faceAway = on }
        stage.log = { [weak self] line in self?.log(line) }
        notch.onStateChange = { [weak self] s in
            if s == .expanded || s == .assistant { self?.stage.abort("notch") }
        }
        attention.onFullscreen = { [weak self] on in self?.stage.setSuppressed(on) }
        stage.setSuppressed(attention.fullscreen)
        prevStatus = statuses(store.sessions)
        store.$sessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in self?.sessionsChanged(sessions) }
            .store(in: &cancellables)
        let ws = NSWorkspace.shared.notificationCenter
        // Сон системы или смена пользователя посреди сцены: таймер конца сцены идёт по uptime и во сне стоит —
        // гасим сцену сразу, иначе глаза в notch останутся спрятанными после пробуждения.
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.stage.stop()
                self?.stopNotchVibe()
            })
        }
        monitor.onEvent = { [weak self] source, e in self?.musicEvent(source, e) }
        musicSettingChanged()
        settingsChanged()
    }

    // MARK: настройки

    /// Персонаж включили/выключили/спрятали или сменили частоту — перевзвести фоновый таймер.
    func settingsChanged() {
        ambientTimer?.invalidate()
        ambientTimer = nil
        unhideTimer?.invalidate()
        unhideTimer = nil
        if notch.ui.characterHidden != settings.characterHidden { notch.ui.characterHidden = settings.characterHidden }
        if settings.characterHidden, let until = settings.characterHiddenUntil {
            stage.stop()
            stopNotchVibe()
            let t = Timer(timeInterval: until - Date().timeIntervalSince1970 + 1, repeats: false) { [weak self] _ in
                self?.settings.characterHiddenUntil = nil
            }
            RunLoop.main.add(t, forMode: .common)
            unhideTimer = t
            return
        }
        guard settings.character else { return }
        director.scheduleAmbient(Date().timeIntervalSince1970, rate: settings.characterRate)
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.ambientTick() }
        t.tolerance = 15
        RunLoop.main.add(t, forMode: .common)
        ambientTimer = t
    }

    func musicSettingChanged() {
        if settings.music { monitor.start() } else {
            monitor.stop()
            stopNotchVibe()
        }
        updateMusicUI()
    }

    func hide(hours: Double) {
        settings.characterHiddenUntil = Date().timeIntervalSince1970 + hours * 3600
        stage.stop()
        stopNotchVibe()
    }

    func unhide() { settings.characterHiddenUntil = nil }

    // MARK: события

    private func statuses(_ sessions: [Session]) -> [SessionKey: SessionStatus] {
        Dictionary(sessions.map { ($0.key, $0.status) }, uniquingKeysWith: { a, _ in a })
    }

    private func sessionsChanged(_ sessions: [Session]) {
        let next = statuses(sessions)
        defer { prevStatus = next }
        if SceneTriggers.needsInputAppeared(prev: prevStatus, next: next) {
            // «Ждёт меня» всегда выше: сцена — домой, кивание — стоп.
            stage.abort("needsInput")
            stopNotchVibe()
            return
        }
        if !SceneTriggers.finished(prev: prevStatus, next: next).isEmpty { trigger(.sessionFinished, retry: true) }
    }

    private func ambientTick() {
        guard director.ambientDue(Date().timeIntervalSince1970) else { return }
        trigger(.ambient)
    }

    private func musicEvent(_ source: MusicSource, _ e: NowPlayingEvent) {
        guard settings.music else { return }
        // Остановилась или встала на паузу не та программа, что играет, — не наше дело
        // (Музыка иногда шлёт «пауза» при запуске, пока играет Spotify).
        if let cur = playing.track?.source, cur != source {
            if case .stopped = e { return }
            if case .paused = e, playing.playing { return }
        }
        let now = Date().timeIntervalSince1970
        let change = playing.apply(e, now: now)
        log("music \(source.rawValue): \(change)")
        updateMusicUI()
        switch change {
        case .started(let afterSilence):
            if afterSilence, case .play = trigger(.musicStarted) { return }
            trigger(.trackChanged)
        case .changed:
            trigger(.trackChanged)
        case .paused, .stopped:
            stopNotchVibe()
            musicRefresh?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.updateMusicUI() }
            musicRefresh = work
            DispatchQueue.main.asyncAfter(deadline: .now() + NowPlayingState.pauseGrace + 0.2, execute: work)
        case .none:
            break
        }
    }

    private func updateMusicUI() {
        let now = Date().timeIntervalSince1970
        let line = settings.music ? playing.display(now: now)?.line : nil
        if notch.ui.music != line { notch.ui.music = line }
        let on = settings.music && playing.playing
        if notch.ui.musicPlaying != on { notch.ui.musicPlaying = on }
    }

    // MARK: решения

    var input: CharacterDirector.Input {
        CharacterDirector.Input(
            now: Date().timeIntervalSince1970, enabled: settings.character, hiddenUntil: settings.characterHiddenUntil,
            sessionEvents: settings.characterSessionEvents, takeover: settings.characterTakeover, music: settings.music,
            rate: settings.characterRate, paused: attention.isPaused, fullscreen: attention.fullscreen || stage.suppressed,
            displaysAsleep: attention.displaysAsleep || AttentionCenter.screenLocked, notchOpen: notch.state != .collapsed,
            sceneRunning: stage.running, idleSec: Self.idleSeconds(), lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    @discardableResult
    func trigger(_ event: CharacterDirector.Event, retry: Bool = false) -> CharacterDirector.Decision {
        let i = input
        let d = director.decide(event, i)
        log("director \(event.rawValue): \(d.log) (idle \(Int(i.idleSec)) с)")
        switch d {
        case .play(let kind): stage.play(kind)
        case .notchVibe: notchVibe()
        case .skip("busy") where retry:
            // Человек прямо сейчас печатает — одна повторная попытка через 4 с.
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.trigger(event) }
        case .skip: break
        }
        return d
    }

    /// Демо из меню и `scene …`: мимо директора, кроме полноэкранного режима.
    @discardableResult
    func demo(_ kind: SceneKind, variant: String? = nil) -> Bool {
        if stage.suppressed || attention.fullscreen {
            log("demo \(kind.rawValue): skip fullscreen")
            return false
        }
        if notch.state != .collapsed { notch.go(.collapsed, reason: "scene") }
        return stage.play(kind, variant: variant)
    }

    // MARK: кивание в notch

    func notchVibe(seconds: Double = 4) {
        vibeWork?.cancel()
        notch.ui.vibing = true
        notch.forceWings = true
        let work = DispatchWorkItem { [weak self] in self?.stopNotchVibe() }
        vibeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func stopNotchVibe() {
        vibeWork?.cancel()
        vibeWork = nil
        if notch.ui.vibing { notch.ui.vibing = false }
        notch.forceWings = false
    }

    // MARK: тексты сцен

    func content() -> SceneContent {
        var c = SceneContent()
        let waiting = store.waiting
        if let first = waiting.first {
            let n = waiting.count
            c.status = "\(n) \(n % 10 == 1 && n % 100 != 11 ? "ждёт" : "ждут") · \(store.name(first).title)"
        } else if let track = playing.display(now: Date().timeIntervalSince1970), settings.music {
            c.status = "♪ \(track.line)"
        } else if store.runningCount > 0 {
            let n = store.runningCount
            c.status = "\(n) \(n % 10 == 1 && n % 100 != 11 ? "работает" : "работают") · всё под контролем"
        } else {
            c.status = "всё тихо"
        }
        if c.status.count > 34 { c.status = String(c.status.prefix(33)) + "…" }
        let name = store.overview.first.map { store.name($0).title } ?? "tty"
        c.lines = ["> capri attach \(name.prefix(18))", "ACCESS ▮▮▮ GRANTED"]
        return c
    }

    // MARK: простой ввода

    /// Секунды без клавиатуры и мыши (IOHIDSystem `HIDIdleTime`, наносекунды; разрешений не требует).
    static func idleSeconds() -> Double {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return 0 }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() else { return 0 }
        if let n = value as? NSNumber { return n.doubleValue / 1e9 }
        if let d = value as? Data, d.count >= 8 { return Double(d.withUnsafeBytes { $0.load(as: UInt64.self) }) / 1e9 }
        return 0
    }

    // MARK: отладка

    private func log(_ line: String) {
        guard debugLog else { return }
        NotchController.debugWrite("character \(line)")
    }

    /// `scene …`, `music …`, `director …` из `~/.capri/tmp/control`.
    func debugCommand(_ cmd: String, _ arg: String) {
        let parts = arg.split(separator: " ").map(String.init)
        switch cmd {
        case "scene":
            guard let what = parts.first else { return }
            switch what {
            case "stop": stage.stop()
            case "abort": stage.abort("control")
            case "sheet":
                guard parts.count > 1, let kind = SceneKind(rawValue: parts[1]) else { return }
                let variant = parts.count > 2 ? parts[2] : nil
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let urls = self.stage.sheet(kind, variant: variant, name: kind.rawValue + (variant.map { "-\($0)" } ?? ""))
                    self.log("sheet \(kind.rawValue): \(urls.map(\.lastPathComponent).joined(separator: ", "))")
                }
            default:
                guard let kind = SceneKind(rawValue: what) else { return }
                demo(kind, variant: parts.count > 1 ? parts[1] : nil)
            }
        case "music":
            switch parts.first {
            case "play":
                let rest = parts.dropFirst().joined(separator: " ").split(separator: "|", maxSplits: 1).map(String.init)
                let artist = rest.first ?? "Test", name = rest.count > 1 ? rest[1] : "Track"
                musicEvent(.spotify, .playing(Track(source: .spotify, id: "debug:\(artist)|\(name)", name: name, artist: artist)))
            case "pause":
                if let t = playing.track { musicEvent(t.source, .paused(t)) }
            case "stop":
                musicEvent(playing.track?.source ?? .spotify, .stopped)
            default: break
            }
        case "director":
            guard let name = parts.first else { return }
            if name == "ambient" { director.scheduleAmbient(Date().timeIntervalSince1970 - 3 * 3600, rate: settings.characterRate) }
            if let e = CharacterDirector.Event(rawValue: name == "finished" ? "sessionFinished" : name) { trigger(e) }
        default: break
        }
    }

    var dump: [String: Any] {
        let now = Date().timeIntervalSince1970
        return [
            "stage": stage.status,
            "director": ["last": director.lastDecision, "nextAmbientIn": Int(director.nextAmbient - now),
                         "enabled": settings.character, "hidden": settings.characterHidden, "idleSec": Int(Self.idleSeconds()),
                         "fullscreen": attention.fullscreen],
            // Без названий треков.
            "nowPlaying": ["source": playing.track?.source.rawValue ?? "", "playing": playing.playing,
                           "known": playing.track != nil, "monitor": monitor.running, "shown": notch.ui.music != nil],
            "notchVibing": notch.ui.vibing,
            "faceAway": notch.ui.faceAway,
        ]
    }
}
