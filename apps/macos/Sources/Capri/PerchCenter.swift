import AppKit
import Combine
import CoreAudio
import CoreMediaIO
import CapriKit

/// «Сидит на окнах»: **запустили** приложение (первый раз за день) → решение `PerchPolicy` → место `PerchLayout` → сцена `perch` на краю окна.
/// Пока сидит — опрос одного окна 2 Гц (10 Гц, пока жмут мышь) и глобальный монитор нажатий мыши (без разрешений);
/// не сидит — ни таймеров, ни мониторов, только наблюдатели `NSWorkspace`. Фокус не крадёт: панель сцены не
/// активирует Capri и пропускает клики, кроме глаз («кыш») и пузыря (помощник с этой репликой).
final class PerchCenter {
    private let stage: StageController
    private let settings: Settings
    private let notch: NotchController
    private let codex: CodexService
    /// Общее состояние машины (пауза, полноэкранное, сон, notch, сцена, простой, энергосбережение, Reduce Motion).
    private let base: () -> CharacterDirector.Input
    private let watcher = AppWatcher()
    private(set) var policy: PerchPolicy
    private var tracker: PerchTracker?
    /// На чём сидит сейчас.
    private var current: (pid: Int32, bundle: String, name: String, number: UInt32, visible: CGRect, line: String)?
    private var pollWork: DispatchWorkItem?
    private var retryWork: DispatchWorkItem?
    private var mouse: Any?
    private var holding = false
    /// Последние показанные реплики (без повтора 10).
    private var recent: [String] = []
    /// bundle → `LSApplicationCategoryType` (Info.plist читается один раз).
    private var lsCategory: [String: String?] = [:]
    var log: ((String) -> Void)?
    /// Что происходит вокруг (для реплики): сессий работает / ждут, что играет.
    var facts: (() -> (working: Int, waiting: Int, track: String?))?
    private let startedAt = Date().timeIntervalSince1970
    /// Общий бюджет стола (`CharacterCenter`): спросить, записать появление, когда кончилась прошлая сцена.
    var recordScreen: (() -> Void)?
    var lastScreenEnd: (() -> Double?)?
    static let stateKey = "capri.perchPolicy"

    // Терминал с Claude (этап 3): сессии и их имена, хвост экрана (nil — приватный хост или экрана нет), смена экранов.
    var sessions: (() -> [Session])?
    var sessionName: ((Session) -> String)?
    var tail: ((Session) -> [String]?)?
    var screensChanged: (() -> AnyPublisher<Void, Never>)?
    /// Хост на связи (нет такого — считаем, что да).
    var hostOnline: ((String) -> Bool)?
    /// За чем смотрит сейчас (только пока сцена «смотрит в терминал»).
    private struct Watch {
        var keys: [SessionKey]
        /// Под окном больше одной сессии — какая из них видна, не знаем: реплики только по статусу.
        var statusOnly: Bool
        var last: [SessionKey: WatchedSession]
        var said: [String]
        var lastKeyword: SessionRemark.Keyword?
        var lastSayAt: Double
        var ending = false
    }
    private var watch: Watch?
    private var watchScreens: AnyCancellable?
    private var nudgeWork: DispatchWorkItem?
    /// Не чаще одной реплики по хвосту экрана за столько секунд и не больше стольких реплик за сцену.
    static let sayGap = 7.0
    static let maxSays = 6

    init(stage: StageController, settings: Settings, notch: NotchController, codex: CodexService,
         base: @escaping () -> CharacterDirector.Input) {
        self.stage = stage
        self.settings = settings
        self.notch = notch
        self.codex = codex
        self.base = base
        // Состояние правил переживает перезапуск Capri: иначе после установки каждое приложение снова «первое за день».
        policy = UserDefaults.standard.data(forKey: Self.stateKey).flatMap { try? JSONDecoder().decode(PerchPolicy.self, from: $0) }
            ?? PerchPolicy()
    }

    private func save() {
        if let d = try? JSONEncoder().encode(policy) { UserDefaults.standard.set(d, forKey: Self.stateKey) }
    }

    func start() {
        watcher.onActivated = { [weak self] app in self?.activated(app) }
        watcher.onSettled = { [weak self] app, launched in self?.settled(app, launched: launched, attempt: 0) }
        watcher.start()
    }

    // MARK: решение

    var screens: [(frame: CGRect, visible: CGRect)] { NSScreen.screens.map { ($0.frame, $0.visibleFrame) } }
    var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }
    var ownPid: Int32 { ProcessInfo.processInfo.processIdentifier }

    func input(bundle: String) -> PerchPolicy.Input {
        let b = base()
        let now = b.now
        let cal = Calendar.current
        let c = cal.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: now))
        let hidden = [b.hiddenUntil, settings.perchHiddenUntil].compactMap { $0 }.max()
        let cat = category(bundle)
        let call = CallGuard.inCall(front: bundle, camera: DeviceBusy.camera(), mic: DeviceBusy.microphone(except: ownPid), ownVoice: false)
        return PerchPolicy.Input(now: now, dayStart: PerchPolicy.dayStart(now: now), minuteOfDay: (c.hour ?? 12) * 60 + (c.minute ?? 0),
                                 enabled: settings.perch, hiddenUntil: hidden, paused: b.paused, fullscreen: b.fullscreen, inCall: call,
                                 displaysAsleep: b.displaysAsleep, notchOpen: b.notchOpen, sceneRunning: b.sceneRunning,
                                 idleSec: b.idleSec, lowPower: b.lowPower, reduceMotion: b.reduceMotion, quiet: settings.quietHours,
                                 userBlocked: Set(settings.perchBlocked), category: cat, sinceStart: now - startedAt,
                                 sinceScene: lastScreenEnd?().map { now - $0 }, budget: b.budget)
    }

    func category(_ bundle: String) -> AppCategory {
        if lsCategory[bundle] == nil {
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
            lsCategory[bundle] = .some(url.flatMap { Bundle(url: $0)?.infoDictionary?["LSApplicationCategoryType"] as? String })
        }
        return AppCatalog.category(bundle: bundle, lsCategory: lsCategory[bundle] ?? nil)
    }

    /// Переднее сменилось: сидит на другом — уходит сразу (без реплики).
    private func activated(_ app: NSRunningApplication) {
        retryWork?.cancel()
        retryWork = nil
        if stage.kind == .perch, let cur = current, app.processIdentifier != cur.pid, app.processIdentifier != ownPid {
            stage.abort("switched")
        }
    }

    /// Приложение осталось передним. Окна после запуска может ещё не быть — ещё две попытки (через 0,8 и 1,8 с).
    /// `as` — отладка: решать как за это приложение (категория, списки), окно — переднего.
    func settled(_ app: NSRunningApplication, launched: Bool, attempt: Int, as fake: String? = nil, force: Bool = false) {
        guard app.processIdentifier != ownPid else { return }
        let bundle = fake ?? app.bundleIdentifier ?? ""
        // Терминал: сначала — есть ли под ним сессии Capri (тогда это сцена «смотрит», не посадка с репликой).
        if attempt == 0, fake == nil, !force, TerminalLocator.terminals.contains(bundle) {
            terminalCheck(app, why: "front") { [weak self] handled in
                if !handled { self?.settled(app, launched: launched, attempt: 1, as: fake, force: force) }
            }
            return
        }
        let event = PerchPolicy.Event.activated(bundle: bundle, launched: launched)
        var i = input(bundle: bundle)
        if !force, let why = policy.gate(event, i) {
            // Запуск всё равно тратит «первый за день» (решение записывает), окно не читаем.
            if launched { _ = policy.decide(event, i); save() }
            log?("perch \(bundle): skip \(why)")
            return
        }
        let line = pickLine(bundle, name: app.localizedName ?? bundle, i)
        let found = window(pid: app.processIdentifier)
        if found == nil, attempt < 2, !force {
            let work = DispatchWorkItem { [weak self] in
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return }
                self?.settled(app, launched: launched, attempt: attempt + 1, as: fake)
            }
            retryWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0.8 : 1.8), execute: work)
            return
        }
        var spot: PerchSpot?
        if let w = found {
            // Полноэкранное на любом экране (не только на экране notch).
            if Self.fullscreen(w) { i.fullscreen = true }
            spot = PerchLayout.spot(window: w.rect, above: w.above, visible: w.visible, bubble: PerchLayout.bubbleSize(chars: line.count))
        }
        i.spot = found == nil ? "noWindow" : spot == nil ? "noSpot" : nil
        if force {
            guard let w = found, let spot else { log?("perch demo \(bundle): \(i.spot ?? "?")"); return }
            show(app, bundle: bundle, window: w, spot: spot, line: line, record: false)
            return
        }
        let d = policy.decide(event, i)
        save()
        log?("perch \(bundle): \(d.log)\(found.map { " window=\(NSStringFromRect($0.rect))" } ?? "")")
        guard case .perch = d, let w = found, let spot else { return }
        show(app, bundle: bundle, window: w, spot: spot, line: line)
    }

    /// Реплика про то, что правда происходит: это приложение, сессии, трек, время, давно ли не открывал.
    private func pickLine(_ bundle: String, name: String, _ i: PerchPolicy.Input) -> String {
        let weekday = Calendar.current.component(.weekday, from: Date(timeIntervalSince1970: i.now))
        let around = facts?() ?? (working: 0, waiting: 0, track: nil)
        let f = PerchFacts(app: name, category: AppCategory.speaking.contains(i.category) ? i.category : .other,
                           minuteOfDay: i.minuteOfDay, weekday: weekday, working: around.working, waiting: around.waiting,
                           track: around.track, daysAway: policy.daysAway(bundle, now: i.now),
                           perchesToday: policy.counts(now: i.now, dayStart: i.dayStart).day)
        return PerchLines.compose(f, recent: recent, seed: Int(i.now * 10) & 0xFFFFF)
    }

    /// `record` — в общий счёт стола (демо — нет).
    private func show(_ app: NSRunningApplication, bundle: String, window w: PerchWindow, spot: PerchSpot, line: String,
                      record: Bool = true) {
        let ok = stage.perch(StageController.PerchShow(spot: spot, window: w.rect, screen: w.screen, visible: w.visible, line: line))
        guard ok else { return }
        if record { recordScreen?() }
        recent = Array((recent + [line]).suffix(PerchLines.memory))
        current = (app.processIdentifier, bundle, app.localizedName ?? bundle, w.number, w.visible, line)
        tracker = PerchTracker(spot: spot, window: w.rect, at: Date().timeIntervalSince1970)
        holding = false
        installMouse()
        schedulePoll()
    }

    // MARK: терминал с Claude

    /// Передний терминал: какие сессии Capri под ним (дерево процессов), открыл ли его человек только что
    /// (свежий ssh / tmux attach / запуск агента), работает ли хоть одна → `PerchPolicy` → сцена «смотрит».
    /// `done(true)` — под окном есть сессии Capri (посадки с репликой про приложение не будет).
    func terminalCheck(_ app: NSRunningApplication, why: String, force: Bool = false, attempt: Int = 0,
                       done: @escaping (Bool) -> Void) {
        let pid = app.processIdentifier
        let bundle = app.bundleIdentifier ?? ""
        guard settings.perch || force, stage.kind != .perch || force else { return done(false) }
        ProcessTable.underneath(terminal: pid) { [weak self] found, clients, cwds in
            guard let self else { return }
            let all = self.sessions?() ?? []
            let matches = TerminalWatch.match(found, sessions: all, clients: clients, cwds: cwds)
            guard !matches.isEmpty else { return done(false) }
            done(true)
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            let now = Date().timeIntervalSince1970
            let status = Dictionary(all.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
            let opening = TerminalWatch.opening(matches, now: now, used: Set(self.policy.usedOpenings.keys))
            let working = matches.contains { status[$0.key]?.status == .running }
            let found = self.window(pid: pid)
            let event = PerchPolicy.Event.terminal(window: found?.number ?? 0, sessions: matches.map(\.key.description),
                                                   opening: force ? (opening?.opening ?? "debug@\(Int(now))") : opening?.opening,
                                                   working: working || force)
            var i = self.input(bundle: bundle)
            if !force, let reason = self.policy.gate(event, i) {
                _ = self.policy.decide(event, i)
                self.save()
                self.log?("terminal \(why): skip \(reason) (\(matches.count) сесс.)")
                return
            }
            // Только что открытое окно может ещё не появиться в списке — одна повторная попытка через 0,8 с.
            if found == nil, attempt == 0, !force {
                self.log?("terminal \(why): окна ещё нет — ещё раз через 0,8 с")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    self?.terminalCheck(app, why: why, attempt: 1) { _ in }
                }
                return
            }
            guard let primary = TerminalWatch.primary(matches, sessions: all), let ps = status[primary.key] else { return }
            let statusOnly = matches.count > 1
            let first = self.watched(ps, statusOnly: statusOnly)
            let line = SessionRemark.opening(first, others: statusOnly ? matches.count - 1 : 0, now: now, seed: Int(now) & 0xFFFF)
            var spot: PerchSpot?
            if let w = found {
                if Self.fullscreen(w) { i.fullscreen = true }
                spot = PerchLayout.spot(window: w.rect, above: w.above, visible: w.visible, bubble: PerchLayout.bubbleSize(chars: line.count))
            }
            i.spot = found == nil ? "noWindow" : spot == nil ? "noSpot" : nil
            let d = force ? (i.spot == nil ? .watch : .skip(i.spot!)) : self.policy.decide(event, i)
            if !force { self.save() }
            self.log?("terminal \(why): \(d.log) (\(matches.count) сесс., \(opening == nil ? "старое окно" : "только что открыт"))")
            guard d == .watch, let w = found, let spot else { return }
            let keys = matches.map(\.key)
            var last: [SessionKey: WatchedSession] = [:]
            for k in keys { if let s = status[k] { last[k] = self.watched(s, statusOnly: statusOnly) } }
            self.showWatch(app, bundle: bundle, window: w, spot: spot, line: line, record: !force,
                           watch: Watch(keys: keys, statusOnly: statusOnly, last: last, said: [line],
                                        lastKeyword: SessionRemark.keyword(first.tail), lastSayAt: now))
        }
    }

    /// Что Capri видит в сессии: имя, статус, хвост экрана (только одна сессия под окном и хост не приватный).
    private func watched(_ s: Session, statusOnly: Bool) -> WatchedSession {
        WatchedSession(name: sessionName?(s) ?? s.project, status: s.status, since: s.statusSince,
                       tail: statusOnly ? nil : tail?(s))
    }

    private func showWatch(_ app: NSRunningApplication, bundle: String, window w: PerchWindow, spot: PerchSpot, line: String,
                           record: Bool = true, watch state: Watch) {
        let ok = stage.watch(StageController.WatchShow(spot: spot, window: w.rect, screen: w.screen, visible: w.visible, line: line))
        guard ok else { return }
        if record { recordScreen?() }
        current = (app.processIdentifier, bundle, app.localizedName ?? bundle, w.number, w.visible, line)
        tracker = PerchTracker(spot: spot, window: w.rect, at: Date().timeIntervalSince1970)
        holding = false
        watch = state
        installMouse()
        schedulePoll()
        // Экран сессии меняется — может, появилось что сказать (только пока смотрит; хвост — только не приватный).
        if !state.statusOnly, state.last.values.contains(where: { $0.tail != nil }) {
            watchScreens = screensChanged?()
                .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
                .sink { [weak self] in self?.watchUpdate() }
        }
        scheduleNudge()
    }

    /// Долго тихо — одна реплика про то, сколько уже идёт (одноразовый таймер только на время сцены).
    private func scheduleNudge() {
        nudgeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, var w = self.watch, self.stage.watching, let k = w.keys.first(where: { w.last[$0]?.status == .running }),
                  let s = w.last[k] else { return }
            let now = Date().timeIntervalSince1970
            guard now - w.lastSayAt >= 20, let text = SessionRemark.nudge(s, now: now, said: w.said, seed: Int(now)) else { return }
            w.said.append(text)
            w.lastSayAt = now
            self.watch = w
            self.say(SessionRemark.Remark(text))
        }
        nudgeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    /// Сессии изменились (из `CharacterCenter`): смотрит — реплика на перемену; не смотрит, но передний —
    /// терминал и какая-то сессия только что заработала (человек дал задачу в только что открытом окне) — проверка.
    func sessionsChanged(prev: [SessionKey: SessionStatus], next: [Session]) {
        if watch != nil { return watchUpdate(next) }
        guard settings.perch, !stage.running, let app = NSWorkspace.shared.frontmostApplication,
              TerminalLocator.terminals.contains(app.bundleIdentifier ?? ""),
              next.contains(where: { $0.status == .running && prev[$0.key] != .running }) else { return }
        terminalCheck(app, why: "running") { _ in }
    }

    /// Связь с хостами поменялась: смотрит в терминал сессии на пропавшем хосте — рассыпается призраком и уходит.
    func hostsChanged() {
        guard var w = watch, !w.ending, stage.watching, let online = hostOnline,
              let lost = w.keys.first(where: { !online($0.host) }) else { return }
        w.ending = true
        watch = w
        nudgeWork?.cancel()
        nudgeWork = nil
        log?("terminal: связь с \(lost.host) потеряна — призрак")
        stage.watchGhost()
    }

    private func watchUpdate(_ given: [Session]? = nil) {
        guard var w = watch, !w.ending, stage.watching else { return }
        let all = given ?? sessions?() ?? []
        let byKey = Dictionary(all.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let now = Date().timeIntervalSince1970
        var remark: SessionRemark.Remark?
        for k in w.keys {
            guard let before = w.last[k] else { continue }
            var after: WatchedSession
            if let s = byKey[k] { after = watched(s, statusOnly: w.statusOnly) } else {
                after = before
                after.status = .ended
            }
            w.last[k] = after
            guard remark == nil || remark?.mood == .say,
                  var r = SessionRemark.change(from: before, to: after, now: now, said: w.said, lastKeyword: w.lastKeyword,
                                               seed: Int(now) & 0xFFFF) else { continue }
            let statusChange = before.status != after.status
            // Реплики по хвосту — не чаще раза в `sayGap` и не больше `maxSays` за сцену.
            if !statusChange, now - w.lastSayAt < Self.sayGap || w.said.count >= Self.maxSays { continue }
            if !statusChange { w.lastKeyword = SessionRemark.keyword(after.tail) }
            // Одна из нескольких доработала, другие ещё пыхтят — просто сказать.
            let othersBusy = w.keys.contains { $0 != k && w.last[$0]?.status == .running }
            if r.mood != .say, othersBusy, r.text != nil { r.mood = .say }
            remark = r
        }
        watch = w
        guard let r = remark else { return }
        if r.mood == .leave, r.text == nil { return }   // ждёт ответа — notch сам оборвёт сцену
        say(r)
    }

    /// Сказать в идущей сцене: пузырь под длину реплики у того же места; злорадство/уход — после неё.
    private func say(_ r: SessionRemark.Remark) {
        guard let text = r.text else { return }
        if var w = watch {
            if !w.said.contains(text) { w.said.append(text) }
            w.lastSayAt = Date().timeIntervalSince1970
            if r.mood != .say { w.ending = true }
            watch = w
        }
        let size = PerchLayout.bubbleSize(chars: text.count)
        var bubble: CGRect?
        if let t = tracker, let cur = current {
            bubble = PerchLayout.bubble(for: t.spot.eyes, size: size, window: t.window, visible: cur.visible)
        }
        if let cur = current { current = (cur.pid, cur.bundle, cur.name, cur.number, cur.visible, text) }
        stage.watchSay(text, bubble: bubble, gloat: r.mood == .gloat, leave: r.mood == .leave)
        log?("terminal: реплика (\(r.mood.rawValue))")
        if r.mood == .say { scheduleNudge() } else { nudgeWork?.cancel(); nudgeWork = nil }
    }

    // MARK: окна

    /// Переднее окно приложения (на любом экране) и окна над ним.
    func window(pid: Int32) -> PerchWindow? {
        let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return PerchWindow.find(windows: raw.compactMap(WindowInfo.from), pid: pid, own: ownPid, screens: screens,
                                primaryHeight: primaryHeight)
    }

    /// Окно на весь свой экран (полноэкранное или развёрнутое без строки меню).
    static func fullscreen(_ w: PerchWindow) -> Bool {
        w.rect.minX <= w.screen.minX + 1 && w.rect.width >= w.screen.width - 1 && w.rect.height >= w.screen.height - 40
    }

    // MARK: пока сидит

    private func schedulePoll() {
        pollWork?.cancel()
        guard let t = tracker else { return }
        let now = Date().timeIntervalSince1970
        let work = DispatchWorkItem { [weak self] in self?.poll() }
        pollWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, t.nextPoll(now) - now), execute: work)
    }

    /// Одна рамка: само окно и окна над ним (`optionOnScreenAboveWindow`) — дешевле полного списка.
    private func poll() {
        guard stage.kind == .perch, var t = tracker, let cur = current else { return teardown() }
        let opts: CGWindowListOption = [.optionOnScreenAboveWindow, .optionIncludingWindow]
        let raw = CGWindowListCopyWindowInfo(opts, CGWindowID(cur.number)) as? [[String: Any]] ?? []
        let w = PerchWindow.find(windows: raw.compactMap(WindowInfo.from), pid: cur.pid, number: cur.number, own: ownPid,
                                 screens: screens, primaryHeight: primaryHeight)
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier == cur.pid
        let now = Date().timeIntervalSince1970
        let a = t.apply(.bounds(w?.rect, frontmost: front, fullscreen: w.map(Self.fullscreen) ?? false, above: w?.above ?? [],
                                visible: w?.visible ?? cur.visible, at: now))
        tracker = t
        handle(a)
        if tracker != nil { schedulePoll() }
    }

    private func handle(_ a: PerchTracker.Action) {
        switch a {
        case .stay:
            if holding { holding = false; stage.perchHold(false) }
        case .hold:
            if !holding { holding = true; stage.perchHold(true); log?("perch: окно тащат — держится") }
        case .hop(let s):
            holding = false
            stage.perchHop(to: s)
        case .leave(let why):
            log?("perch: уходит (\(why))")
            stage.abort(why)
            teardown()
        }
    }

    /// Нажатия мыши где угодно (без разрешений; только пока сидит): окно, может, сейчас потащат — опрос 10 Гц.
    private func installMouse() {
        removeMouse()
        mouse = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] e in
            guard let self, var t = self.tracker else { return }
            let now = Date().timeIntervalSince1970
            let a = t.apply(e.type == .leftMouseDown ? .dragBegan(now) : .dragEnded(now))
            self.tracker = t
            self.handle(a)
            if self.tracker != nil { self.schedulePoll() }
        }
    }

    private func removeMouse() {
        if let m = mouse { NSEvent.removeMonitor(m) }
        mouse = nil
    }

    /// Сцена кончилась (любым путём): опрос и монитор мыши — прочь.
    func teardown() {
        pollWork?.cancel()
        pollWork = nil
        watch = nil
        watchScreens = nil
        nudgeWork?.cancel()
        nudgeWork = nil
        removeMouse()
        tracker = nil
        current = nil
        holding = false
    }

    /// Сцена «на окне» доиграла сама — «кыш» не подряд.
    func finished() { policy.sat(); save() }

    // MARK: клики

    /// Клик по глазам: «кыш» — обиженно уходит; две подряд — час не садится.
    func shoo() {
        policy.shooed(at: Date().timeIntervalSince1970)
        save()
        log?("perch: кыш\(policy.tiredUntil.map { _ in " → устала на час" } ?? "")")
        stage.abort("shoo")
        teardown()
    }

    /// Клик по пузырю: помощник с этой репликой.
    func bubble() {
        guard let line = current?.line ?? stage.model.run?.content.bubble else { return }
        codex.remark(line)
        notch.go(.assistant, reason: "perch")
    }

    /// Пункты правого клика по Capri на окне (перед общим меню с «Выйти»).
    func menuItems() -> [NSMenuItem] {
        guard stage.kind == .perch, let cur = current else { return [] }
        let bundle = cur.bundle
        return [
            MenuAction.item("Не садиться на «\(cur.name)»") { [weak self] in
                guard let self else { return }
                if !self.settings.perchBlocked.contains(bundle) { self.settings.perchBlocked.append(bundle) }
                self.stage.abort("blocked")
                self.teardown()
            },
            MenuAction.item("Прогнать с окон на час") { [weak self] in self?.snooze(hours: 1) },
        ]
    }

    func snooze(hours: Double) {
        settings.perchHiddenUntil = Date().timeIntervalSince1970 + hours * 3600
        if stage.kind == .perch { stage.abort("snooze") }
        teardown()
    }

    // MARK: отладка

    /// `perch <bundle>` — решение как за это приложение (окно — переднего); `perch demo [bundle]` — мимо правил;
    /// `perch mock [left|side|bottom]` — на муляже окна посреди экрана notch; `perch shoo|bubble|reset|hop`.
    func debug(_ parts: [String]) {
        guard let what = parts.first else { return }
        switch what {
        case "shoo": stage.activate(.button("shoo"))
        case "bubble": stage.activate(.button("bubble"))
        case "reset":
            policy = PerchPolicy()
            save()
            settings.perchHiddenUntil = nil
            log?("perch: сброс правил")
        case "mock":
            stage.play(.perch, variant: "mock" + (parts.count > 1 ? parts[1] : ""))
        case "hop":
            // Как будто окно сдвинули на 120 pt влево.
            guard let t = tracker else { return }
            var s = t.spot
            s.eyes = s.eyes.offsetBy(dx: -120, dy: 0)
            s.bubble = s.bubble?.offsetBy(dx: -120, dy: 0)
            stage.perchHop(to: s)
        case "demo":
            guard let app = NSWorkspace.shared.frontmostApplication else { return }
            settled(app, launched: true, attempt: 0, as: parts.count > 1 ? parts[1] : nil, force: true)
        case "scan":
            // Только чтение: что под каждым запущенным терминалом (без показа и без записи в правила).
            for app in NSWorkspace.shared.runningApplications where TerminalLocator.terminals.contains(app.bundleIdentifier ?? "") {
                ProcessTable.underneath(terminal: app.processIdentifier) { [weak self] found, clients, cwds in
                    guard let self else { return }
                    let all = self.sessions?() ?? []
                    let m = TerminalWatch.match(found, sessions: all, clients: clients, cwds: cwds)
                    let now = Date().timeIntervalSince1970
                    let st = Dictionary(all.map { ($0.key, $0.status.rawValue) }, uniquingKeysWith: { a, _ in a })
                    self.log?("scan \(app.bundleIdentifier ?? "?"): найдено \(found.count), сессий \(m.count): "
                              + m.map { "\($0.key.host)/\($0.key.agent.rawValue) \(st[$0.key] ?? "?") \(Int(now - $0.start)) с" }.joined(separator: "; ")
                              + " · свежее: \(TerminalWatch.opening(m, now: now).map { "\($0.key.host)" } ?? "нет")")
                }
            }
        case "watch":
            // `perch watch` — решение за передний терминал (как если бы его только что открыли — свежесть не нужна
            // только с `force`); `perch watch force` — мимо правил; `perch watch say <текст>` — реплика в идущей сцене.
            if parts.count > 2, parts[1] == "say" {
                say(SessionRemark.Remark(parts.dropFirst(2).joined(separator: " ")))
                return
            }
            guard let app = NSWorkspace.shared.frontmostApplication else { return }
            terminalCheck(app, why: "debug", force: parts.count > 1 && parts[1] == "force") { [weak self] handled in
                if !handled { self?.log?("terminal: под окном нет сессий Capri") }
            }
        default:
            guard let app = NSWorkspace.shared.frontmostApplication else { return }
            // Как будто это приложение только что запустили.
            settled(app, launched: true, attempt: 2, as: what)
        }
    }

    var dump: [String: Any] {
        var out: [String: Any] = [
            "enabled": settings.perch, "last": policy.lastDecision, "starts": policy.starts.count,
            "launchedToday": policy.launchedToday.filter { $0.value >= PerchPolicy.dayStart(now: Date().timeIntervalSince1970) }.count,
            "tired": policy.tiredUntil.map { Int($0 - Date().timeIntervalSince1970) } ?? 0, "shoos": policy.shoos,
            "quiet": settings.quietHours.label, "blocked": settings.perchBlocked, "hidden": settings.perchHidden,
            "tracking": tracker != nil, "mouseMonitor": mouse != nil, "polling": pollWork != nil, "holding": holding,
            "camera": DeviceBusy.camera(), "mic": DeviceBusy.microphone(except: ownPid),
            "perDay": PerchPolicy.perDay,
        ]
        if let cur = current { out["on"] = cur.bundle; out["window"] = cur.number }
        if let w = watch {
            out["watch"] = ["sessions": w.keys.map(\.description), "statusOnly": w.statusOnly, "said": w.said.count,
                            "screens": watchScreens != nil, "nudge": nudgeWork != nil]
        }
        out["watchedWindows"] = policy.watchedWindows.count
        out["usedOpenings"] = policy.usedOpenings.count
        if let t = tracker { out["spot"] = t.spot.edge.rawValue; out["moving"] = t.moving; out["dragging"] = t.dragging }
        return out
    }
}

/// Пункт меню с замыканием (цель держится через `representedObject`).
final class MenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }

    static func item(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem {
        let a = MenuAction(run)
        let item = NSMenuItem(title: title, action: #selector(fire), keyEquivalent: "")
        item.target = a
        item.representedObject = a
        return item
    }
}

/// Камера и микрофон заняты кем-то — свойства устройств (CoreMediaIO «работает где-то», CoreAudio «процесс пишет
/// вход»), без захвата и без запроса доступа. Читается только в момент решения.
enum DeviceBusy {
    static func camera() -> Bool {
        var addr = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                             mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                             mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, &size) == 0, size > 0 else { return false }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, size, &used, &ids) == 0 else { return false }
        for id in ids {
            var a = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                                              mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                              mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            var v: UInt32 = 0
            var u: UInt32 = 0
            if CMIOObjectGetPropertyData(id, &a, 0, nil, 4, &u, &v) == 0, v != 0 { return true }
        }
        return false
    }

    /// Какой-то процесс (кроме `except`) пишет звук со входа (macOS 14.2+; раньше — не знаем, значит нет).
    static func microphone(except own: Int32) -> Bool {
        guard #available(macOS 14.2, *) else { return false }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return false }
        for id in ids {
            var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput, mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
            var v: UInt32 = 0
            var s = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(id, &a, 0, nil, &s, &v) == noErr, v != 0 else { continue }
            var p = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
            var pid: pid_t = 0
            var ps = UInt32(MemoryLayout<pid_t>.size)
            if AudioObjectGetPropertyData(id, &p, 0, nil, &ps, &pid) == noErr, pid == own { continue }
            return true
        }
        return false
    }
}
