import AppKit
import Combine
import IOKit
import CapriKit

/// Персонаж: когда и какие сцены играть (`CharacterDirector`), их показ (`StageController`), музыка
/// (`NowPlayingMonitor`) и кивание в notch. Сцены по действию человека: ответ сессии → телепорт к терминалу
/// (`reply`), вопрос помощнику при свёрнутом notch → «думает» → ответ в том же окне. Без запросов разрешений:
/// рамки окон — без названий, процессы — `sysctl` своего пользователя, простой ввода — IOKit `HIDIdleTime`, музыка —
/// распределённые уведомления плееров.
final class CharacterCenter {
    let stage = StageController()
    private let monitor = NowPlayingMonitor()
    private let store: SessionStore
    private let codex: CodexService
    private let notch: NotchController
    private let settings: Settings
    private let attention: AttentionCenter
    /// Единственная точка, через которую Capri трогает плеер (только по действию человека).
    let music: MusicController
    private(set) var director: CharacterDirector
    private var playing: NowPlayingState
    private var prevStatus: [SessionKey: SessionStatus] = [:]
    private var ambientTimer: Timer?
    /// Конец «спрятан на час» — снова взвести фоновые сцены.
    private var unhideTimer: Timer?
    private var vibeWork: DispatchWorkItem?
    private var musicRefresh: DispatchWorkItem?
    /// Погасить строку трека через 4 с после смены (одноразовый, не повторяющийся таймер).
    private var revealWork: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []
    /// Ответ сессии отправлен при раскрытом notch — телепорт, когда он свернётся (не позже 20 с).
    private var pendingReply: (key: SessionKey, until: Double)?
    /// Сессия идущей сцены `reply` (её «доставлено»/«не дошло»).
    private var replyKey: SessionKey?
    /// Когда спросили помощника (ответ без «думает» показываем, только если спросили недавно).
    private var askedAt: Double?
    /// Команда плееру ушла — ждём его событие (≤ 6 с): что просили и сообщение чата.
    private var musicWait: (cmd: MusicCommand, message: UUID?)?
    private var musicWaitWork: DispatchWorkItem?
    /// Решения и сцены в `~/.capri/tmp/debug.log` (только с `--debug-control`).
    var debugLog = false

    init(store: SessionStore, codex: CodexService, notch: NotchController, settings: Settings, attention: AttentionCenter,
         music: MusicController) {
        self.music = music
        self.store = store
        self.codex = codex
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
        stage.onAction = { [weak self] kind, spot, mods in self?.stageAction(kind, spot, mods) }
        stage.makeMenu = { [weak notch] in notch?.makeMenu?() ?? NSMenu() }
        notch.onStateChange = { [weak self] s in self?.notchStateChanged(s) }
        store.onSent = { [weak self] key, _ in self?.replySent(key) }
        store.$deliveries
            .receive(on: DispatchQueue.main)
            .sink { [weak self] d in self?.deliveriesChanged(d) }
            .store(in: &cancellables)
        codex.$chatBusy
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] busy in self?.chatBusyChanged(busy) }
            .store(in: &cancellables)
        codex.$chat
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.chatChanged() }
            .store(in: &cancellables)
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
        music.current = { [weak self] in self?.playing.track?.source }
        music.log = { [weak self] line in self?.log(line) }
        if let fake = music.backend as? FakeMusicBackend {
            // Фейковый плеер «отвечает» событиями, как настоящий через уведомления.
            fake.log = { [weak self] line in self?.log(line) }
            fake.onEvent = { [weak self] source, e in self?.musicEvent(source, e) }
        }
        notch.onMusic = { [weak self] cmd, from in self?.musicButton(cmd, from: from) }
        codex.onMusic = { [weak self] cmd, q, id in self?.musicAsk(cmd, question: q, message: id) }
        codex.musicKnown = { [weak self] in self?.notch.ui.music != nil }
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
            // «Ждёт меня» всегда выше: сцена — домой (и закреплённая), кивание — стоп.
            stage.abort("needsInput")
            stopNotchVibe()
            return
        }
        // Окна статуса и сессий — живые.
        if let k = stage.kind, k == .sessions || k == .window {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.stage.kind == k else { return }
                self.stage.update(content: self.content())
            }
        }
        if !SceneTriggers.finished(prev: prevStatus, next: next).isEmpty { trigger(.sessionFinished, retry: true) }
    }

    /// Раскрытие notch обрывает сцену, кроме закреплённой и окон помощника (они и есть ответ на действие);
    /// помощник в notch гасит «думает»/ответ — он уже виден там. Свернулся — отложенный телепорт к терминалу.
    private func notchStateChanged(_ s: NotchState) {
        let assistantScene = stage.kind == .thinking || stage.kind == .answer
        // Окно музыки — ответ на просьбу (часто из самого помощника): раскрытие его не гасит.
        let keep = stage.pinned || stage.kind == .music
        switch s {
        case .assistant:
            if assistantScene { stage.stop() } else if !keep { stage.abort("notch") }
        case .expanded:
            if !assistantScene, !keep { stage.abort("notch") }
        case .collapsed:
            if let p = pendingReply {
                pendingReply = nil
                if Date().timeIntervalSince1970 <= p.until { startReply(p.key) }
            } else if codex.chatBusy, !stage.running {
                // Спросил помощника и свернул notch — Capri думает на столе.
                playAction(.askedAssistant)
            }
        default:
            break
        }
    }

    // MARK: сцены по действию человека

    var actionInput: CharacterDirector.Input {
        var i = input
        i.onAction = settings.characterOnAction
        return i
    }

    @discardableResult
    private func playAction(_ event: CharacterDirector.ActionEvent, content: SceneContent? = nil, variant: String? = nil,
                            terminal: CGRect? = nil, around: CGRect? = nil) -> Bool {
        let d = director.decideAction(event, actionInput)
        log("action \(event.rawValue): \(d.log)")
        guard case .play(let kind) = d else { return false }
        return stage.play(kind, variant: variant, terminal: terminal, content: content, around: around)
    }

    /// Ответ сессии ушёл (любой путь): телепорт к её терминалу; notch раскрыт — когда свернётся.
    private func replySent(_ key: SessionKey, waited: Bool = false) {
        // Отправили из окна ответа: сначала его вспышка «отправлено» (1 с от `burstAt`), потом телепорт.
        if !waited, stage.kind == .answer, let run = stage.model.run, let t = stage.elapsed {
            let left = run.burstAt.map { $0 + 1.0 - t } ?? 1.0
            if left > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + left + 0.05) { [weak self] in self?.replySent(key, waited: true) }
                return
            }
        }
        if notch.state != .collapsed {
            pendingReply = (key, Date().timeIntervalSince1970 + 20)
            log("reply \(key.host): ждём свёртывания notch")
            return
        }
        startReply(key)
    }

    /// Найти окно терминала сессии (без записи экрана) и телепортироваться туда. `demo` — мимо директора.
    func startReply(_ key: SessionKey?, variant: String? = nil, demo: Bool = false) {
        guard let screen = notch.notchScreen else { return }
        let s = key.flatMap { store.session($0) }
        var c = content()
        c.replyName = s.map { String(store.name($0).title.prefix(18)) } ?? "capri-test"
        c.delivered = key.flatMap { deliveredState($0) }
        let play: (CGRect?) -> Void = { [weak self] rect in
            guard let self else { return }
            // Пока искали, человек мог снова раскрыть notch.
            guard self.notch.state == .collapsed else { return }
            self.replyKey = s?.key
            if demo { self.stage.play(.reply, variant: variant, terminal: rect, content: c) }
            else { self.playAction(.replySent, content: c, variant: variant, terminal: rect) }
        }
        guard variant != "corner", let s, let transport = store.transport(s.key.host) else { return play(nil) }
        ProcessTable.locate(transport: transport, pane: s.tmux?.pane, screen: screen) { [weak self] loc, rect in
            self?.log("locate \(s.key.host): \(loc.path) pid=\(loc.pid ?? 0) window=\(rect.map { NSStringFromRect($0) } ?? "-")")
            play(rect)
        }
    }

    private func deliveredState(_ key: SessionKey) -> Bool? {
        switch store.deliveries[key] {
        case .delivered?: true
        case .refused?, .notDelivered?: false
        default: nil
        }
    }

    private func deliveriesChanged(_ d: DeliveryTracker) {
        guard stage.kind == .reply, let key = replyKey, var c = stage.model.run?.content else { return }
        let state: Bool?
        switch d[key] {
        case .delivered?: state = true
        case .refused?, .notDelivered?: state = false
        default: return
        }
        guard c.delivered != state else { return }
        c.delivered = state
        stage.update(content: c)
        if state == false { stage.mark(failed: true) }
    }

    /// Помощник начал/кончил думать.
    private func chatBusyChanged(_ busy: Bool) {
        let now = Date().timeIntervalSince1970
        if busy {
            askedAt = now
            if notch.state == .collapsed, !stage.running { playAction(.askedAssistant) }
            return
        }
        // Текст и предложения ответа записываются сразу после `chatBusy = false` — читаем на следующем такте.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let recent = self.askedAt.map { now - $0 < 180 } ?? false
            self.askedAt = nil
            if self.stage.kind == .thinking {
                self.stage.morph(to: .answer, content: self.answerContent())
            } else if recent, self.notch.state == .collapsed, !self.stage.running {
                self.playAction(.answerReady, content: self.answerContent())
            }
        }
    }

    /// Окно ответа живое: состояние предложения («отправляю…», «отправлено ✓»).
    private func chatChanged() {
        guard stage.kind == .answer else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stage.kind == .answer else { return }
            let c = self.answerContent()
            if c.proposal?.state == "sent" { self.stage.mark(burst: true) }
            self.stage.update(content: c)
        }
    }

    /// Клик по строке/кнопке окна сцены. Всё — явные действия человека (основное окно, помощник, терминал, плеер).
    private func stageAction(_ kind: SceneKind, _ spot: SceneHotspot.Kind, _ mods: NSEvent.ModifierFlags) {
        if case .button(let id) = spot, let cmd = MusicCommand(button: id) {
            musicButton(cmd, from: "stage")
            return
        }
        switch (kind, spot) {
        case (.window, .button("status")):
            stage.stop()
            notch.onDetails?(nil, "")
        case (.sessions, .row(let i)):
            guard let rows = stage.model.run?.content.rows, i < rows.count else { return }
            if mods.contains(.option) {
                store.openTerminal(rows[i].key)
            } else {
                stage.stop()
                notch.onDetails?(rows[i].key, "")
            }
        case (.thinking, .button("assistant")):
            notch.go(.assistant, reason: "scene")
        case (.answer, .button("send")):
            guard let p = stage.model.run?.content.proposal, p.state == "pending" else { return }
            // Обрезанный текст отсюда не отправляем — полный текст и «отправить» в помощнике.
            if p.clipped {
                stage.stop()
                notch.onConversation?()
                return
            }
            // Вспышку «отправлено» рисует окно ответа (`chatChanged`), телепорт к терминалу — после неё (`replySent`).
            codex.confirm(p.message, p.id)
        case (.answer, .button("cancel")):
            guard let p = stage.model.run?.content.proposal, p.state == "pending" else { return }
            codex.cancel(p.message, p.id)
        case (.answer, .button("conversation")):
            stage.stop()
            notch.onConversation?()
        default:
            break
        }
    }

    /// Текст окна ответа: последний ответ помощника (или локальная сводка), перенос, предложение — последней строкой.
    func answerContent() -> SceneContent {
        var c = content()
        let m = codex.chat.last { $0.role != .user }
        let text = m?.text.isEmpty == false ? m!.text : Assistant.localAnswer(sessions: store.sessions, names: store.names)
        let p = m?.proposals.first { $0.state != .cancelled } ?? m?.proposals.first
        var lines = SceneText.wrap(text, maxLines: p == nil ? SceneTimeline.answerMaxLines : SceneTimeline.answerMaxLines - 1)
        if let m, let p {
            let what: String
            switch p.action {
            case .text(let t): what = "«\(t.prefix(16))\(t.count > 16 ? "…" : "")»"
            case .choose(let n): what = "\(n)" + (p.choiceLabel.map { " \($0.prefix(12))" } ?? "")
            }
            var clipped: Bool
            switch p.action {
            case .text(let t): clipped = t.count > 16
            case .choose: clipped = false
            }
            let state: String
            switch p.state {
            case .pending: state = "pending"
            case .sending: state = "sending"
            case .sent: state = "sent"
            case .failed: state = "failed"
            case .cancelled: state = "cancelled"
            }
            let full = "→ \(p.title.prefix(14)): \(what)"
            let title = StageWindows.clip(full, SceneTimeline.answerColumns)
            if title != full { clipped = true }
            lines.append(title)
            c.proposal = SceneProposal(message: m.id, id: p.id, title: title, state: state, clipped: clipped)
        }
        c.answer = lines
        return c
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
        musicHeard(e, change)
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
        if var c = stage.model.run?.content {
            // Окно музыки и кнопки под глазами — живые.
            c.track = line
            c.trackPlaying = on
            stage.update(content: c)
        }
        // Строка трека сама видна 4 с после старта/смены трека, дальше — по наведению.
        let reveal = line != nil && playing.revealed(now: now)
        if notch.ui.musicReveal != reveal { notch.ui.musicReveal = reveal }
        revealWork?.cancel()
        revealWork = nil
        if reveal, let until = playing.revealUntil {
            let work = DispatchWorkItem { [weak self] in self?.updateMusicUI() }
            revealWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, until - now) + 0.05, execute: work)
        }
    }

    // MARK: музыка по действию человека

    /// ⏮ ⏯ ⏭: notch, peek, глаза на столе, окно музыки, меню. С глаз на столе (идёт сцена) — короткое окно музыки
    /// на том же месте; из notch ради паузы не телепортируемся — там кивок.
    func musicButton(_ cmd: MusicCommand, from: String) {
        if from == "stage", stage.running, stage.kind != .music {
            let at = stage.model.run.map { $0.geometry.area ?? $0.geometry.target }
            playAction(.musicRequested, content: content(), around: at)
        }
        performMusic(cmd, intent: .button(from), message: nil)
    }

    /// «Включи X», «пауза», «дальше» помощнику (локально или блоком от Codex): окно музыки на столе, «ищу…», команда,
    /// ждём событие плеера. `message` — ответ в чате, куда писать итог.
    func musicAsk(_ cmd: MusicCommand, question: String, message: UUID?) {
        var c = stage.kind == .music ? (stage.model.run?.content ?? content()) : content()
        c.note = nil
        switch cmd {
        case .play(let q): c.query = q
        case .playURI: c.query = "ссылка Spotify"
        default: c.query = nil
        }
        if stage.kind == .music { stage.update(content: c) } else { playAction(.musicRequested, content: c) }
        switch cmd {
        case .play, .playURI: stage.mark(music: .searching)
        default: break
        }
        performMusic(cmd, intent: .assistant(question), message: message)
    }

    private func performMusic(_ cmd: MusicCommand, intent: MusicIntent, message: UUID?) {
        musicWaitWork?.cancel()
        musicWaitWork = nil
        musicWait = nil
        let wasPlaying = playing.playing
        music.perform(cmd, intent: intent) { [weak self] r in
            self?.musicResult(cmd, r, intent: intent, message: message, wasPlaying: wasPlaying)
        }
    }

    private func musicResult(_ cmd: MusicCommand, _ r: MusicResult, intent: MusicIntent, message: UUID?, wasPlaying: Bool) {
        let q: String = { if case .play(let q) = cmd { return "«\(q)»" }; return "" }()
        switch r {
        case .sent(let player):
            log("music sent → \(player.rawValue)")
            let pausing: Bool = { if case .pause = cmd { return true }; if case .toggle = cmd { return wasPlaying }; return false }()
            if pausing {
                musicDone(.paused, message, status: "❚❚ пауза")
                return
            }
            if case .button(let from) = intent, from == "notch" || from == "peek", settings.music, !settings.characterHidden {
                notchVibe(seconds: 2.5)
            }
            guard monitor.running else {
                // Музыку Capri не слушает (настройка выкл.) — события не будет, верим скрипту.
                musicDone(.playing, message, status: "▶ отправила плееру")
                return
            }
            musicWait = (cmd, message)
            let work = DispatchWorkItem { [weak self] in
                guard let self, let w = self.musicWait else { return }
                self.musicWait = nil
                // Плеер уже играл («продолжи» поверх игры, «назад» в начало того же трека) — уведомления нет,
                // но скрипт прошёл и музыка идёт: это не провал.
                if self.playing.playing, let t = self.playing.track {
                    self.log("music: плеер молчит 6 с, но играет — считаем сделанным")
                    self.musicDone(.playing, w.message, status: "♪ " + t.line)
                    return
                }
                self.log("music: плеер молчит 6 с")
                self.musicDone(.failed, w.message, status: "✗ не включилось", note: "не включилось")
            }
            musicWaitWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
        case .openedSearch:
            log("music: открыла поиск в Spotify")
            musicDone(.info, message, status: "↗ поиск \(q) открыт в Spotify",
                      text: "Открыла поиск \(q) в Spotify — выбери трек. Чтобы включала сама, добавь ключи Spotify в настройках (Музыка).",
                      note: "открыла поиск в Spotify")
        case .notFound:
            musicDone(.failed, message, status: "✗ не нашла \(q)", text: "Не нашла \(q).", note: "не нашла \(q)")
        case .notRunning:
            musicDone(.info, message, status: "✗ плеер не запущен", text: "Ничего не играет — Spotify и Музыка не запущены.",
                      note: "плеер не запущен")
        case .noPlayer:
            musicDone(.failed, message, status: "✗ нет Spotify и Музыки", text: "Не нашла ни Spotify, ни Музыку.", note: "нет плеера")
        case .denied:
            musicDone(.failed, message, status: "✗ нет доступа к плееру",
                      text: "macOS не дала мне управлять плеером: Системные настройки → Конфиденциальность → Автоматизация → Capri.",
                      note: "нет доступа (Автоматизация)")
        case .skipped:
            musicDone(.info, message, status: "· пропущено (плеер был занят)", note: "пропущено")
        case .failed(let m):
            musicDone(.failed, message, status: "✗ \(m)", note: m)
        }
    }

    /// Итог музыки: строка в чате (и текст ответа), окно музыки — новое состояние.
    private func musicDone(_ state: SceneMusicState, _ message: UUID?, status: String, text: String? = nil, note: String? = nil) {
        if let message { codex.setMusic(message, status: status, text: text) }
        guard stage.kind == .music, var c = stage.model.run?.content else { return }
        c.note = note
        stage.update(content: c)
        stage.mark(music: state)
    }

    /// Событие плеера: окно музыки следует за ним; если ждали команду — итог.
    private func musicHeard(_ e: NowPlayingEvent, _ change: NowPlayingState.Change) {
        if stage.kind == .music {
            switch e {
            case .playing: if change != .none || musicWait != nil { stage.mark(music: .playing) }
            case .paused: stage.mark(music: .paused)
            case .stopped: break
            }
        }
        // ⏯ по устаревшему «не играет» оказался паузой — это тоже итог.
        if let w = musicWait, w.cmd == .toggle, case .paused = e {
            musicWait = nil
            musicWaitWork?.cancel()
            musicWaitWork = nil
            musicDone(.paused, w.message, status: "❚❚ пауза")
            return
        }
        guard let w = musicWait, case .playing(let t) = e else { return }
        // «Дальше/назад» — ждём именно смену трека.
        if change == .none, w.cmd == .next || w.cmd == .previous { return }
        musicWait = nil
        musicWaitWork?.cancel()
        musicWaitWork = nil
        musicDone(.playing, w.message, status: "♪ " + t.line)
    }

    // MARK: решения

    var input: CharacterDirector.Input {
        CharacterDirector.Input(
            now: Date().timeIntervalSince1970, enabled: settings.character, hiddenUntil: settings.characterHiddenUntil,
            sessionEvents: settings.characterSessionEvents, takeover: settings.characterTakeover, music: settings.music,
            rate: settings.characterRate, paused: attention.isPaused, fullscreen: attention.fullscreen || stage.suppressed,
            displaysAsleep: attention.displaysAsleep || AttentionCenter.screenLocked, notchOpen: notch.state != .collapsed,
            sceneRunning: stage.running, idleSec: Self.idleSeconds(), lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, onAction: settings.characterOnAction,
            sessionsActive: store.sessions.contains { $0.status == .needsInput || $0.status == .running })
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
        switch kind {
        case .reply:
            // Демо: к терминалу первой сессии (без ответа ей).
            startReply(store.overview.first?.key, variant: variant, demo: true)
            return true
        case .answer:
            return stage.play(.answer, variant: variant, content: answerContent())
        case .music:
            // Демо: окно музыки с тем, что играет (без команд плееру).
            var c = content()
            if c.track == nil { c.note = "ничего не играет" }
            let ok = stage.play(.music, variant: variant, content: c)
            if c.track == nil { stage.mark(music: .info) }
            return ok
        default:
            return stage.play(kind, variant: variant)
        }
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
        let now = Date().timeIntervalSince1970
        c.track = settings.music ? playing.display(now: now)?.line : nil
        c.trackPlaying = settings.music && playing.playing
        c.waiting = waiting.count
        c.rows = store.overview.prefix(12).map { s in
            SceneRow(key: s.key, name: store.name(s).title, detail: s.status == .needsInput ? s.kindLabel : s.statusLabel,
                     status: s.status, since: Self.ago(now - (s.status == .running ? s.statusSince : max(s.statusSince, s.lastEventAt))))
        }
        return c
    }

    /// «<1м», «5м», «2ч», «3д».
    static func ago(_ sec: Double) -> String {
        let m = Int(max(0, sec) / 60)
        if m < 1 { return "<1м" }
        if m < 60 { return "\(m)м" }
        if m < 60 * 24 { return "\(m / 60)ч" }
        return "\(m / 60 / 24)д"
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
                    var content = kind == .answer ? self.answerContent() : self.content()
                    if kind == .music, variant != "search" { content.note = variant == "fail" ? "не нашла «test track»" : nil }
                    // `scene sheet answer long|short`: предложение с обрезанным текстом («прочитать ↗») или целым.
                    if kind == .answer, variant == "long" || variant == "short", content.proposal == nil {
                        let title = variant == "long" ? "→ capri-test: «да, и потом пере…»" : "→ capri-test: «да»"
                        content.answer = Array(content.answer.prefix(SceneTimeline.answerMaxLines - 1)) + [title]
                        content.proposal = SceneProposal(message: UUID(), id: UUID(), title: title, state: "pending",
                                                         clipped: variant == "long")
                    }
                    if kind == .reply { content.replyName = self.store.overview.first.map { self.store.name($0).title } ?? "capri-test" }
                    let urls = self.stage.sheet(kind, variant: variant, name: kind.rawValue + (variant.map { "-\($0)" } ?? ""),
                                                content: content)
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
            case "cmd":
                // `music cmd play <q>|uri <ссылка>|pause|resume|next|previous|toggle [stage]` — через MusicController
                // (с --debug-control бэкенд фейковый: скрипт — в debug.log, события — выдуманные).
                let rest = Array(parts.dropFirst())
                guard let what = rest.first else { return }
                let arg = rest.dropFirst().joined(separator: " ")
                switch what {
                case "play": musicAsk(.play(arg), question: "включи \(arg)", message: nil)
                case "uri": if let u = SpotifyURI.parse(arg) { musicAsk(.playURI(u), question: "включи \(arg)", message: nil) }
                default:
                    guard let cmd = MusicCommand(button: what) else { return }
                    musicButton(cmd, from: arg == "stage" ? "stage" : "debug")
                }
            case "search":
                // Только сборка запроса Web API, без сети и без ключей.
                let q = parts.dropFirst().joined(separator: " ")
                let r = SpotifyAPI.searchRequest(query: q, token: "-")
                log("music search request: \(r.httpMethod ?? "GET") \(r.url?.host ?? "")\(r.url?.path ?? "") order=\(SpotifyAPI.plan(q).order.joined(separator: ",")) keys=\(music.spotify.hasKeys)")
            case "ask":
                // Просьба помощнику без раскрытия notch (не забирает клавиатуру): тот же `codex.ask`.
                codex.ask(parts.dropFirst().joined(separator: " "))
            case "parse":
                // Разбор просьбы без выполнения.
                let q = parts.dropFirst().joined(separator: " ")
                log("music parse: \(MusicCommand.parse(q, known: notch.ui.music != nil)?.log ?? "не музыка") request=\(MusicCommand.isMusicRequest(q))")
            default: break
            }
        case "stage":
            // Без мыши: `stage drag dx dy` (как перетаскивание за глаза), `stage pin`, `stage close`.
            switch parts.first {
            case "drag":
                guard parts.count > 2, let dx = Double(parts[1]), let dy = Double(parts[2]) else { return }
                stage.beginDrag()
                stage.drag(by: CGVector(dx: dx, dy: dy))
                stage.endDrag()
            case "pin": stage.activate(.pin)
            case "close": stage.activate(.close)
            // ⏮ ⏯ ⏭ под глазами без мыши; `stage button next` — клик по кнопке сцены.
            case "controls": stage.setControls(parts.count < 2 || parts[1] != "off")
            case "button": if parts.count > 1 { stage.activate(.button(parts[1])) }
            default: break
            }
        case "locate":
            // `locate <host> <pane>` → debug.log: как нашли окно терминала (без ответа сессии и без записи в tmux).
            guard parts.count > 1, let screen = notch.notchScreen else { return }
            let host = parts[0]
            let transport = store.transport(host) ?? (host == "local" ? .local : .ssh(host))
            ProcessTable.locate(transport: transport, pane: parts[1], screen: screen) { [weak self] loc, rect in
                self?.log("locate \(host) \(parts[1]): \(loc.path) pid=\(loc.pid ?? 0) window=\(rect.map { NSStringFromRect($0) } ?? "-")")
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
                         "enabled": settings.character, "onAction": settings.characterOnAction,
                         "hidden": settings.characterHidden, "idleSec": Int(Self.idleSeconds()),
                         "fullscreen": attention.fullscreen],
            // Без названий треков.
            "nowPlaying": ["source": playing.track?.source.rawValue ?? "", "playing": playing.playing,
                           "known": playing.track != nil, "monitor": monitor.running, "shown": notch.ui.music != nil,
                           "revealed": notch.ui.musicReveal, "hover": notch.ui.musicHover,
                           "backend": music.backend.name, "automation": music.automation, "spotifyKeys": music.spotify.hasKeys,
                           "waiting": musicWait != nil, "chatMusic": codex.chat.last?.music != nil,
                           "chatText": codex.chat.last.map { String($0.text.prefix(60)) } ?? ""],
            "notchVibing": notch.ui.vibing,
            "faceAway": notch.ui.faceAway,
        ]
    }
}
