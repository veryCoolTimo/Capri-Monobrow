import AppKit
import AVFoundation
import Combine
import CryptoKit
import CapriKit

/// Голос Capri (push-to-talk): держите ⌃⌥Space и говорите, отпустите — Capri выполнит. Короткое нажатие — как
/// раньше, открыть/закрыть помощника. Всё только в notch: на рабочий стол голос Capri не выводит.
///
/// Нажали — пока ничего (короткое нажатие — помощник: ни микрофона, ни модели). Держат ≥ 0.28 с → микрофон, хелпер,
/// notch «слушает»: глаза, молния вдоль края, частичный текст; в хелпер — `begin`, 500 мс тишины (первое слово не
/// теряется), дальше живой звук. Отпустили → `end`, микрофон стоп, финальный текст → `VoiceIntent` → действие.
/// Держат дольше 45 с, сон, блокировка экрана — фраза обрывается, микрофон выключается.
final class VoiceCenter: ObservableObject {
    enum ModelState: Equatable { case found(String), missing, downloading(Double), failed(String) }

    @Published private(set) var model: ModelState = .missing
    @Published private(set) var lastHeard = ""

    private let settings: Settings
    private let notch: NotchController
    private let codex: CodexService
    private let store: SessionStore
    private let automation: AutomationRunner
    /// Музыка голосом — через CharacterCenter, но без сцены на столе.
    var onMusic: ((MusicCommand, String, @escaping (String) -> Void) -> Void)?
    var debugLog = false

    let helper = AsrHelper()
    /// Входы звука для настроек и выбора при нажатии.
    let mics = MicDevices()
    private let mic = MicCapture()
    /// «Не слышу»: с начала фразы; громкость для рта/молнии — пик кусков между кадрами 12 fps.
    private var hearing: HearingWatch?
    private var levelPeak = 0.0
    private var levelTimer: Timer?
    /// Вход взяли не выбранный (выбранного нет) — строка в notch, пока нет текста.
    private var micNote = ""
    /// Отладка `voice file`: финал в журнал, без notch и без команд.
    private var probe = false
    private var ptt = PushToTalk()
    private var holdWork: DispatchWorkItem?
    /// Предохранитель: держат дольше `PushToTalk.maxHold` (залипла клавиша, потерялось отпускание).
    private var maxWork: DispatchWorkItem?
    /// Номер фразы: поздние ответы прошлой фразы (музыка, Заметки) не трогают строку новой.
    private var phrase = 0
    /// Хелперу ушёл `begin`, а `end`-с-финалом или `cancel` — ещё нет (иначе он «занят» навсегда и не уходит по простою).
    private var phraseOpen = false
    private var finalWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    /// Звук идёт в хелпер (на очереди микрофона): между `begin` и `end`.
    private var streaming = false
    /// Что открыто сейчас: UID входа (для «пропал — взять другой») и Bluetooth ли он (терпение «не слышу»).
    private var openUID: String?
    private var openSlow = false
    /// Фраза с микрофона (а не отладочный wav) — считается в подсказку «держи ⌃⌥Пробел».
    private var countsForHint = false
    private var hintWatch: AnyCancellable?
    /// Ждём финальный текст хелпера.
    private var awaitingFinal = false
    /// Фраза пришла из отладочного wav (не с микрофона).
    private var wavTimer: Timer?
    private var downloadTask: URLSessionDownloadTask?
    private var progressObservation: NSKeyValueObservation?

    /// 500 мс тишины в начале фразы: без неё модель теряет первое слово («Капри»).
    static let preSilence = [Float](repeating: 0, count: 8_000)

    init(settings: Settings, notch: NotchController, codex: CodexService, store: SessionStore, automation: AutomationRunner) {
        self.settings = settings
        self.notch = notch
        self.codex = codex
        self.store = store
        self.automation = automation
        helper.onEvent = { [weak self] e in self?.heard(e) }
        helper.onExit = { [weak self] idle in self?.helperExited(idle: idle) }
        helper.log = { [weak self] in self?.log($0) }
        mic.onAudio = { [weak self] pcm, level in self?.audio(pcm, level) }
        mic.onLost = { [weak self] why in self?.micLost(why) }
        refreshModel()
        updateHint()
        // Голос или клавишу выключили/включили в настройках — подсказка сразу (`@Published` шлёт новое значение
        // до записи — берём из аргументов).
        hintWatch = settings.$voice.combineLatest(settings.$assistantHotKey).dropFirst().sink { [weak self] voice, hotKey in
            guard let self else { return }
            let on = VoiceHint.show(voiceOn: voice && hotKey, successes: self.settings.voiceSuccesses)
            DispatchQueue.main.async { if self.notch.ui.voiceHint != on { self.notch.ui.voiceHint = on } }
        }
    }

    /// Подсказка «держи ⌃⌥Пробел» в помощнике — пока голосом не пользовались 3 раза.
    func updateHint() {
        let on = VoiceHint.show(voiceOn: settings.voice && settings.assistantHotKey, successes: settings.voiceSuccesses)
        if notch.ui.voiceHint != on { notch.ui.voiceHint = on }
    }

    // MARK: модель

    var modelPath: String? { if case .found(let p) = model { return p }; return nil }

    func refreshModel() {
        if case .downloading = model { return }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let path = AsrModel.locate(override: settings.voiceModelPath, home: home, env: ProcessInfo.processInfo.environment,
                                   exists: { fm.fileExists(atPath: $0) },
                                   read: { try? String(contentsOfFile: $0, encoding: .utf8) },
                                   list: { (try? fm.contentsOfDirectory(atPath: $0)) ?? [] })
        model = path.map(ModelState.found) ?? .missing
    }

    /// Скачать модель (~750 МБ) в `~/.capri/models` — только по кнопке в настройках.
    func downloadModel() {
        guard downloadTask == nil else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dest = URL(fileURLWithPath: AsrModel.ownPath(home: home))
        model = .downloading(0)
        let task = URLSession.shared.downloadTask(with: AsrModel.downloadURL) { [weak self] tmp, response, error in
            var failure: String?
            if let error { failure = error.localizedDescription }
            else if let http = response as? HTTPURLResponse, http.statusCode != 200 { failure = "HTTP \(http.statusCode)" }
            else if let tmp {
                do {
                    // Чужой или битый файл в ggml не пускаем: сначала размер и SHA-256 закреплённого снимка.
                    guard let hash = Self.sha256(of: tmp), hash == AsrModel.sha256 else {
                        try? FileManager.default.removeItem(at: tmp)
                        throw NSError(domain: "capri", code: 1, userInfo: [NSLocalizedDescriptionKey: "файл модели не совпал по SHA-256"])
                    }
                    try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: tmp, to: dest)
                } catch { failure = error.localizedDescription }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.downloadTask = nil
                self.progressObservation = nil
                if let failure { self.model = .failed(failure) } else { self.model = .missing; self.refreshModel() }
            }
        }
        progressObservation = task.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            let f = p.fractionCompleted
            DispatchQueue.main.async {
                guard let self, case .downloading(let old) = self.model, f - old >= 0.01 || f >= 1 else { return }
                self.model = .downloading(f)
            }
        }
        downloadTask = task
        task.resume()
    }

    /// SHA-256 файла кусками по 8 МБ (750 МБ не грузим в память); nil — не прочитался.
    static func sha256(of url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while true {
            guard let chunk = try? h.read(upToCount: 8 << 20) else { return nil }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Прогрев при первом раскрытии notch после запуска (дальше — только по нажатию: хелпер уходит после простоя,
    /// и каждое раскрытие notch не должно поднимать модель в память).
    func warmOnOpen() {
        guard !warmedOnOpen else { return }
        warmedOnOpen = true
        warm()
    }
    private var warmedOnOpen = false

    /// Прогрев: модель грузится заранее (первая загрузка 2.5–6 с).
    func warm() {
        guard settings.voice, !helper.running, AsrHelper.binary != nil else { return }
        refreshModel()
        guard let p = modelPath else { return }
        helper.start(model: p)
    }

    // MARK: клавиша

    /// ⌃⌥Space нажали.
    func press() {
        guard settings.voice else { updateHint(); notch.toggleAssistant(); return }
        for a in ptt.press(at: now) { act(a) }
    }

    /// ⌃⌥Space отпустили.
    func release() {
        guard settings.voice else { return }
        for a in ptt.release(at: now) { act(a) }
    }

    private var now: Double { ProcessInfo.processInfo.systemUptime }

    private func act(_ a: PushToTalk.Action) {
        switch a {
        case .prepare:
            // Микрофон и модель — только когда точно держат (не на тап): иначе каждое открытие помощника зажигает
            // оранжевую точку, переключает AirPods в гарнитуру и поднимает ~180 МБ модели. Помощник уже открыт —
            // тогда, скорее всего, будут говорить: модель можно греть сразу.
            if notch.state == .assistant { warm() }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                for a in self.ptt.tick(at: self.now) { self.act(a) }
            }
            holdWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + PushToTalk.holdThreshold + 0.01, execute: work)
        case .tap:
            holdWork?.cancel()
            stopMic(discard: true)
            updateHint()
            notch.toggleAssistant()
        case .listen:
            holdWork?.cancel()
            hideWork?.cancel()
            listen()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let a = self.ptt.tick(at: self.now)
                if !a.isEmpty { self.log("voice: держат дольше \(Int(PushToTalk.maxHold)) с — стоп") }
                for x in a { self.act(x) }
            }
            maxWork?.cancel()
            maxWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + PushToTalk.maxHold, execute: work)
        case .finish:
            maxWork?.cancel()
            maxWork = nil
            finish()
        case .cancel:
            abortPhrase()
            hide(after: 0)
        }
    }

    /// Фраза обрывается целиком: микрофон стоп, хелперу — `cancel`, если `begin` ушёл.
    private func abortPhrase() {
        holdWork?.cancel()
        maxWork?.cancel()
        maxWork = nil
        stopMic(discard: true)
        notch.voiceListening(false)
        if phraseOpen, helper.running { helper.send(.cancel) }
        phraseOpen = false
        awaitingFinal = false
        finalWork?.cancel()
        probe = false
    }

    /// Сон, экран погас, сменился пользователь: отпускание клавиши может не прийти — фразу забыть сейчас.
    func sleep() {
        let active: Bool = { if case .idle = ptt.phase { return false }; return true }()
        guard active || phraseOpen || mic.running else { return }
        log("voice: сон/блокировка — фраза оборвана")
        ptt.reset()
        abortPhrase()
        hide(after: 0)
    }

    /// Держат: проверить, что всё есть, и начать фразу.
    private func listen() {
        if MicCapture.permission == .notDetermined {
            show(.failed, "Разреши Capri микрофон — и держи ⌃⌥Пробел снова")
            MicCapture.requestPermission { [weak self] ok in
                self?.show(ok ? .done : .failed, ok ? "Готово — держи ⌃⌥Пробел и говори" : "Без микрофона голоса не будет")
                self?.hide(after: 3)
            }
            ptt.reset()
            return
        }
        guard MicCapture.permission == .authorized else {
            fail("Нет доступа к микрофону — Системные настройки → Конфиденциальность → Микрофон")
            return
        }
        guard AsrHelper.binary != nil else { fail("В этой сборке нет распознавания речи (capri-asr)"); return }
        refreshModel()
        guard let path = modelPath else { fail("Нет модели речи — Настройки → Голос"); return }
        guard helper.start(model: path) else { fail("Распознавание не запустилось"); return }
        mics.refresh()
        let choice = MicChoice.resolve(MicPreference(stored: settings.voiceMic), devices: mics.devices,
                                       savedName: settings.voiceMicName.isEmpty ? nil : settings.voiceMicName)
        micNote = choice.note ?? ""
        if let n = choice.note { log("voice mic: \(n)") }
        // Notch «слушает» сразу, микрофон включается следом (Bluetooth — до секунды, на очереди микрофона).
        beginPhrase()
        countsForHint = true
        mic.queue.async {
            self.helper.send(.audio(Self.preSilence))
            self.streaming = true
        }
        openMic(choice.pick)
    }

    private func openMic(_ pick: MicChoice.Pick) {
        let id = phrase
        let def = MicDevices.defaultInput()
        openUID = MicChoice.uid(pick, defaultUID: def)
        openSlow = MicChoice.slow(pick, devices: mics.devices, defaultUID: def)
        hearing = HearingWatch(start: now, slow: openSlow)
        mic.start(pick) { [weak self] why in
            guard let self, let why else { return }
            self.log("voice mic: не открылся (\(why))")
            guard id == self.phrase, self.phraseOpen, !self.awaitingFinal else { return }
            self.ptt.reset()
            self.abortPhrase()
            self.fail("Микрофон: \(why) — Настройки → Голос")
        }
    }

    /// Вход пропал (или встал) посреди фразы: ушедший выкинуть из списка, взять встроенный → системный → любой
    /// и слушать дальше; в notch — что случилось.
    private func micLost(_ why: String) {
        guard phraseOpen, !awaitingFinal else { return }
        log("voice mic: \(why) — беру другой")
        let lost = openUID
        mic.stop()
        mics.refresh()
        guard let choice = MicChoice.fallback(lost: lost, devices: mics.devices, defaultUID: MicDevices.defaultInput(), why: why) else {
            ptt.reset()
            abortPhrase()
            fail("Микрофон \(why) — Настройки → Голос")
            return
        }
        micNote = choice.note ?? ""
        startLevels()
        show(.listening, lastHeard, note: micNote)
        openMic(choice.pick)
    }

    private func beginPhrase() {
        lastHeard = ""
        awaitingFinal = false
        finalWork?.cancel()
        probe = false
        countsForHint = false
        phrase += 1
        phraseOpen = true
        helper.send(.begin(language: nil))
        show(.listening, "", note: micNote)
        notch.voiceListening(true)
        startLevels()
        log("voice listen")
    }

    /// 12 fps, пока слушаем: громкость для рта и молнии (пик кусков, плавно), «не слышу»/«тихо» (`HearingWatch`),
    /// захват встал после голоса — как потеря входа.
    private func startLevels() {
        hearing = HearingWatch(start: now, slow: openSlow)
        levelPeak = 0
        notch.ui.voiceLevel = 0
        levelTimer?.invalidate()
        let t = Timer(timeInterval: 1 / CapriFace.fps, repeats: true) { [weak self] _ in self?.levelTick() }
        RunLoop.main.add(t, forMode: .common)
        levelTimer = t
    }

    private func stopLevels() {
        levelTimer?.invalidate()
        levelTimer = nil
        hearing = nil
        notch.ui.voiceLevel = 0
        notch.ui.voiceHeard = nil
    }

    private func levelTick() {
        notch.ui.voiceLevel = VoiceLevel.smooth(notch.ui.voiceLevel, levelPeak)
        levelPeak = 0
        guard let h = hearing, let v = notch.ui.voice, v.phase == .listening else { return }
        let t = now
        if mic.running, h.stalled(at: t) {
            log("voice: звук перестал приходить (кусков \(h.chunks))")
            mic.reportStall()
            return
        }
        let st = h.status(at: t)
        if notch.ui.voiceHeard != st { notch.ui.voiceHeard = st }
        let alarm = HearingWatch.text(st)
        if let alarm, v.note != alarm {
            log("voice: \(st == .dead ? "микрофон молчит" : "тихо") (кусков \(h.chunks), пик \(String(format: "%.2f", h.peak)))")
            show(.listening, v.text, note: alarm, alarm: true)
        } else if alarm == nil, v.alarm {
            show(.listening, v.text, note: micNote)
        }
    }

    /// Громкость куска (главная очередь).
    private func heardLevel(_ level: Double, seconds: Double) {
        levelPeak = max(levelPeak, level)
        hearing?.feed(level: level, at: now, seconds: seconds)
    }

    /// Звук с микрофона (очередь микрофона).
    private func audio(_ pcm: [Float], _ level: Double) {
        if streaming { helper.send(.audio(pcm)) }
        let sec = Double(pcm.count) / 16_000
        DispatchQueue.main.async { self.heardLevel(level, seconds: sec) }
    }

    /// Отпустили: дослать звук, финал.
    private func finish() {
        let watch = hearing
        stopMic(discard: false)
        notch.voiceListening(false)
        guard phraseOpen else { return }   // не дошли до `begin` (ошибка, разрешение)
        if let w = watch { log("voice: голос \(w.heardAt.map { String(format: "через %.1f с", $0 - w.start) } ?? "не услышан"), кусков \(w.chunks), пик \(String(format: "%.2f", w.peak))") }
        mic.queue.async {
            // Хвост после отпускания — короткая тишина: модель дописывает последнее слово.
            self.helper.send(.audio([Float](repeating: 0, count: 4_000)))
            self.helper.send(.end)
            self.streaming = false
        }
        awaitingFinal = true
        show(.working, lastHeard)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.awaitingFinal else { return }
            self.awaitingFinal = false
            if self.phraseOpen, self.helper.running { self.helper.send(.cancel) }
            self.phraseOpen = false
            self.fail(self.helper.state == .loading ? "Модель ещё грузится — попробуй через пару секунд" : "Распознавание не ответило")
        }
        finalWork = work
        // Первая загрузка модели — до 6 с; финал обычно за 30 мс.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    private func stopMic(discard: Bool) {
        mic.stop { [weak self] st in
            guard st.seconds > 0 || !st.device.isEmpty else { return }
            self?.log("voice mic: \(st.device) · \(st.format.isEmpty ? "звука нет" : st.format) · \(String(format: "%.1f", st.seconds)) с, пик \(String(format: "%.2f", st.peak))\(st.formatChanges > 0 ? ", формат менялся \(st.formatChanges)×" : "")")
        }
        stopLevels()
        if discard { mic.queue.async { self.streaming = false } }
    }

    // MARK: хелпер

    private func heard(_ e: AsrEvent) {
        switch e {
        case .partial(let t):
            lastHeard = t
            guard let v = notch.ui.voice, v.phase == .listening || v.phase == .working else { return }
            show(v.phase, t, hint: v.hint, note: v.note, alarm: v.alarm)
            if notch.state == .assistant { notch.ui.assistantText = t }
        case .final(let t, _):
            guard awaitingFinal else { return }
            awaitingFinal = false
            phraseOpen = false
            finalWork?.cancel()
            lastHeard = t
            log("voice final (\(t.count) зн.)")
            if probe {
                probe = false
                log("voice file final: «\(t)»")
                return
            }
            route(t)
        case .error(let m):
            log("asr error: \(m)")
            if awaitingFinal || phraseOpen {
                ptt.reset()
                abortPhrase()
                fail("Распознавание: \(m)")
            }
        case .ready, .cancelled, .idle: break
        }
    }

    /// Хелпер вышел (упал или по простою — простой мог совпасть с нажатием): идущая фраза потеряна — сказать сразу,
    /// а не ждать 10 с «не ответило».
    private func helperExited(idle: Bool) {
        guard awaitingFinal || phraseOpen else { return }
        phraseOpen = false
        ptt.reset()
        abortPhrase()
        fail(idle ? "Распознавание как раз выгружалось — держи ⌃⌥Пробел ещё раз" : "Распознавание упало — держи ⌃⌥Пробел ещё раз")
    }

    /// Ответ относится к фразе `id` (не к следующей).
    private func current(_ id: Int) -> Bool { id == phrase && !phraseOpen }

    // MARK: команды

    /// Финальный текст → действие. Всё, что идёт в сессии и в интернет, — через помощника (видно и подтверждаемо).
    func route(_ text: String) {
        let names = store.sessions.flatMap { s -> [String] in
            var n = [store.name(s).title]
            if let t = s.tmux?.session { n.append(t) }
            return n
        }
        let intent = VoiceIntent.parse(text, sessions: names, musicKnown: notch.ui.music != nil)
        let id = phrase
        log("voice intent \(Self.describe(intent))")
        if countsForHint, intent != .empty, settings.voiceSuccesses < VoiceHint.enough {
            settings.voiceSuccesses += 1
            updateHint()
        }
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let needsChat: Bool = { switch intent { case .search, .reply, .assistant: return true; default: return false } }()
        if needsChat, codex.chatBusy {
            fail("Capri ещё отвечает на прошлый вопрос — скажи чуть позже")
            return
        }
        switch intent {
        case .empty:
            fail("Не расслышала — держи ⌃⌥Пробел")
        case .music(let cmd):
            show(.working, CodexService.musicStarting(cmd))
            if let onMusic {
                onMusic(cmd, said) { [weak self] status in
                    guard let self, self.current(id) else { return }
                    self.show(status.hasPrefix("✗") ? .failed : .done, status)
                    self.hide(after: 3)
                }
            }
            hide(after: 8)
        case .note(let body):
            show(.working, "Записываю в Заметки…")
            let waitWork = waitingPermission(id, app: "Заметки")
            automation.run(AppleScripts.note(body)) { [weak self] err in
                waitWork.cancel()
                guard let self, self.current(id) else { return }
                if let err { self.fail(Self.automationError(err, app: "Заметки")) } else {
                    self.show(.done, "Записала в Заметки: \(Self.quote(body))")
                    self.hide(after: 3.5)
                }
            }
        case .reminder(let body, let due):
            show(.working, "Ставлю напоминание…")
            let waitWork = waitingPermission(id, app: "Напоминания")
            automation.run(AppleScripts.reminder(body, due: due)) { [weak self] err in
                waitWork.cancel()
                guard let self, self.current(id) else { return }
                if let err { self.fail(Self.automationError(err, app: "Напоминания")) } else {
                    let when = due.map { "Напомню " + Self.when($0) } ?? "В Напоминаниях"
                    self.show(.done, "\(when): \(Self.quote(body))")
                    self.hide(after: 4)
                }
            }
        case .search(let q):
            hide(after: 0)
            notch.go(.assistant, reason: "voice")
            codex.search(q, said: said)
        case .reply(let name, let body):
            guard let s = store.sessions.first(where: { store.name($0).title == name || $0.tmux?.session == name }) else {
                hide(after: 0); notch.go(.assistant, reason: "voice"); codex.askVoice(said); return
            }
            hide(after: 0)
            notch.go(.assistant, reason: "voice")
            codex.proposeReply(s.key, text: body, said: said)
        case .assistant(let q):
            hide(after: 0)
            notch.go(.assistant, reason: "voice")
            if notch.ui.assistantText == lastHeard { notch.ui.assistantText = "" }
            codex.askVoice(q)
        }
    }

    /// Скрипт не ответил за 3 с — скорее всего, macOS спрашивает «Автоматизацию» (или ждёт прошлый такой вопрос).
    private func waitingPermission(_ id: Int, app: String) -> DispatchWorkItem {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.current(id), self.notch.ui.voice?.phase == .working else { return }
            self.show(.working, "Жду разрешения macOS для «\(app)» — ответьте в окне запроса")
            self.hide(after: 90)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        return work
    }

    static func describe(_ i: VoiceIntent) -> String {
        switch i {
        case .music(let c): "music \(c.log)"
        case .note(let t): "note (\(t.count) зн.)"
        case .reminder(let t, let d): "reminder (\(t.count) зн.) due=\(d.map { Int($0.timeIntervalSinceNow) }.map(String.init) ?? "-") с"
        case .search(let q): "search (\(q.count) зн.)"
        case .reply(let s, let t): "reply \(s) (\(t.count) зн.)"
        case .assistant(let q): "assistant (\(q.count) зн.)"
        case .empty: "empty"
        }
    }

    static func quote(_ s: String) -> String { "«" + (s.count > 60 ? String(s.prefix(59)) + "…" : s) + "»" }

    static func automationError(_ kind: String, app: String) -> String {
        switch kind {
        case "denied", "consent": "\(app): нет разрешения — Системные настройки → Конфиденциальность → Автоматизация → Capri"
        default: "\(app): не получилось"
        }
    }

    /// «в 18:00», «завтра в 9:00», «3 нояб. в 10:00».
    static func when(_ d: Date) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "H:mm"
        if cal.isDateInToday(d) { return "в " + f.string(from: d) }
        if cal.isDateInTomorrow(d) { return "завтра в " + f.string(from: d) }
        f.dateFormat = "d MMM в H:mm"
        return f.string(from: d)
    }

    // MARK: notch

    private func show(_ phase: VoiceLine.Phase, _ text: String, hint: String = "", note: String = "", alarm: Bool = false) {
        hideWork?.cancel()
        // Помощник открыт — строки peek не видно: итог (записала, напомню, музыка) — его репликой в разговоре.
        if notch.state == .assistant, phase == .done || phase == .failed {
            if notch.ui.assistantText == lastHeard { notch.ui.assistantText = "" }
            codex.remark(text)
        }
        notch.voiceShow(VoiceLine(phase: phase, text: text, hint: hint, note: note, alarm: alarm))
    }

    private func fail(_ text: String) {
        show(.failed, text)
        hide(after: 3.5)
    }

    private func hide(after s: Double) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.notch.voiceHide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: work)
    }

    // MARK: отладка

    private func log(_ line: String) {
        guard debugLog else { return }
        NotchController.debugWrite("voice \(line)")
    }

    /// `voice wav <путь>` — фраза из wav (16 кГц mono s16) тем же путём, что с микрофона, в реальном темпе;
    /// `voice say <текст>` — сразу в разбор команд; `voice parse <текст>` — только разбор; `voice warm`; `voice sheet`.
    func debug(_ parts: [String]) {
        let rest = parts.dropFirst().joined(separator: " ")
        switch parts.first {
        case "wav":
            guard let d = FileManager.default.contents(atPath: (rest as NSString).expandingTildeInPath), d.count > 44 else {
                log("wav: нет файла"); return
            }
            let pcm: [Float] = d.subdata(in: 44..<d.count).withUnsafeBytes { raw in
                (0..<(raw.count / 2)).map { Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) / 32768 }
            }
            refreshModel()
            guard let path = modelPath, helper.start(model: path) else { fail("Нет модели речи — Настройки → Голос"); return }
            beginPhrase()
            helper.send(.audio(Self.preSilence))
            var i = 0
            wavTimer?.invalidate()
            wavTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] t in
                guard let self else { t.invalidate(); return }
                guard i < pcm.count else {
                    t.invalidate()
                    self.wavTimer = nil
                    self.stopLevels()
                    self.notch.voiceListening(false)
                    self.helper.send(.audio([Float](repeating: 0, count: 4_000)))
                    self.helper.send(.end)
                    self.awaitingFinal = true
                    self.show(.working, self.lastHeard)
                    return
                }
                let chunk = Array(pcm[i..<min(i + 1600, pcm.count)])
                i += 1600
                self.heardLevel(VoiceLevel.level(chunk), seconds: Double(chunk.count) / 16_000)
                self.helper.send(.audio(chunk))
            }
        case "file":
            // `voice file <путь>` — любой звук (24/48 кГц, стерео, Int16/Float32) через тот же `PcmResampler`, что
            // микрофон, в хелпер; финал — только в журнал (без notch и без команд).
            let url = URL(fileURLWithPath: (rest as NSString).expandingTildeInPath)
            // Не во время живой фразы: иначе её финал ушёл бы только в журнал.
            guard !phraseOpen, !awaitingFinal else { log("voice file: идёт фраза — позже"); return }
            guard let (pcm, desc) = Self.resample(file: url) else { log("voice file: не прочитался"); return }
            refreshModel()
            guard let path = modelPath, helper.start(model: path) else { log("voice file: нет модели"); return }
            log("voice file: \(desc) → \(pcm.count) кадров 16 кГц (\(String(format: "%.2f", Double(pcm.count) / 16_000)) с), пик \(String(format: "%.2f", pcm.map(abs).max() ?? 0))")
            phrase += 1
            phraseOpen = true
            probe = true
            lastHeard = ""
            helper.send(.begin(language: nil))
            helper.send(.audio(Self.preSilence))
            var i = 0
            while i < pcm.count { helper.send(.audio(Array(pcm[i..<min(i + 1600, pcm.count)]))); i += 1600 }
            helper.send(.audio([Float](repeating: 0, count: 4_000)))
            helper.send(.end)
            awaitingFinal = true
            // Финал не пришёл — не оставлять `probe`/фразу висеть (иначе следующая живая фраза уйдёт в журнал).
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.awaitingFinal, self.probe else { return }
                self.log("voice file: финал не пришёл")
                self.abortPhrase()
            }
            finalWork?.cancel()
            finalWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
        case "say":
            route(rest)
        case "parse":
            log("voice parse: \(Self.describe(VoiceIntent.parse(rest, sessions: store.sessions.map { store.name($0).title })))")
        case "warm":
            warm()
        case "stop":
            helper.stop()
        case "level":
            // `voice level 0.8` — показать «слушаю» с молнией без микрофона (кадр для скриншота).
            notch.ui.voiceLevel = Double(rest) ?? 0.5
            show(.listening, parts.count > 2 ? parts.dropFirst(2).joined(separator: " ") : "")
            notch.voiceListening(true)
        case "hide":
            notch.voiceListening(false)
            hide(after: 0)
        default: break
        }
    }

    /// Файл в родном формате кусками по 100 мс (как приходит с входа) → `PcmResampler` → 16 кГц.
    static func resample(file url: URL, int16: Bool = false) -> ([Float], String)? {
        guard let f = try? AVAudioFile(forReading: url, commonFormat: int16 ? .pcmFormatInt16 : .pcmFormatFloat32, interleaved: int16) else { return nil }
        let fmt = f.processingFormat
        let r = PcmResampler()
        var out: [Float] = []
        let step = AVAudioFrameCount(max(160, fmt.sampleRate / 10))
        while f.framePosition < f.length {
            guard let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: step), (try? f.read(into: b, frameCount: step)) != nil,
                  b.frameLength > 0 else { break }
            out += r.convert(b)
        }
        out += r.flush()
        return (out, MicCapture.describe(fmt))
    }

    var dump: [String: Any] {
        var m = "missing"
        switch model {
        case .found: m = "found"
        case .missing: m = "missing"
        case .downloading(let f): m = "downloading \(Int(f * 100))%"
        case .failed(let e): m = "failed: \(e)"
        }
        return ["enabled": settings.voice, "helper": AsrHelper.binary != nil, "running": helper.running, "state": "\(helper.state)",
                "model": m, "mic": MicCapture.permission.rawValue, "micRunning": mic.running, "micChoice": settings.voiceMic,
                "inputs": mics.devices.count, "hint": notch.ui.voiceHint, "successes": settings.voiceSuccesses, "line": notch.ui.voice?.text ?? "",
                "phase": notch.ui.voice.map { "\($0.phase)" } ?? "", "automation": automation.name]
    }
}
