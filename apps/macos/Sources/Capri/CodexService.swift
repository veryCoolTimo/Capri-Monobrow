import AppKit
import Combine
import CapriKit

/// Codex в Capri: вход через аккаунт ChatGPT, лимиты, сводки «что спрашивает сессия», чат и черновики.
/// Один служебный `codex app-server` с тем же CODEX_HOME, что у CLI; ходы — по одному, в эфемерных тредах,
/// без инструментов (`CodexBinary.serverArgs`): модель только читает присланный текст и отвечает.
final class CodexService: ObservableObject {
    enum State: Equatable {
        case off
        case noBinary
        case starting
        case signedOut
        case signingIn(url: String)
        case ready(CodexAccount)
        case failed(String)
    }

    struct ChatMessage: Identifiable, Equatable {
        /// `local` — ответ самой Capri без Codex.
        enum Role { case user, codex, error, local }
        let id = UUID()
        var role: Role
        var text: String
        /// Предложенные помощником действия «ответь сессии» — ждут подтверждения человека.
        var proposals: [Proposal] = []
    }

    struct Proposal: Identifiable, Equatable {
        enum State: Equatable { case pending, sending, sent, failed(String), cancelled }
        let id = UUID()
        var key: SessionKey
        /// Имя сессии на момент предложения.
        var title: String
        var action: ReplyAction
        /// Для выбора варианта — его подпись из диалога сессии.
        var choiceLabel: String?
        /// Что сессия спрашивала, когда Capri предложила действие: изменилось — отправлять нельзя.
        var fingerprint: String
        var status: SessionStatus
        var state: State = .pending
    }

    @Published private(set) var state: State = .off
    @Published private(set) var limits: CodexLimits?
    @Published private(set) var chat: [ChatMessage] = []
    @Published private(set) var chatBusy = false
    /// Capri «договаривает» ответ: рот двигается ещё столько, сколько его читать (по длине текста, 1,5–8 с).
    @Published private(set) var speaking = false
    private var speakingTask: DispatchWorkItem?
    /// Черновик готовится для этой сессии.
    @Published private(set) var drafting: SessionKey?

    var summariesEnabled: () -> Bool = { false }
    /// Хосты, содержимое сессий которых в Codex не уходит.
    var privateHosts: () -> Set<String> = { [] }

    private let store: SessionStore
    private var client: CodexClient?
    private var model: CodexModel?
    private var modelLoaded = false
    private var loginId: String?
    private var chatThread: String?
    private var jobs: [Job] = []
    private var running: Job?
    private var turn: (thread: String, id: String?)?
    private var collector: CodexTurnCollector?
    private var cancellables: Set<AnyCancellable> = []
    private var limitsTimer: Timer?
    private var restartWork: DispatchWorkItem?
    private var failures = 0
    /// Сводка уже запрошена для этого запроса сессии (отпечаток запроса).
    private var summaryAsked: Set<String> = []

    private struct Job {
        enum Kind { case summary, draft, chat }
        let id = UUID()
        var kind: Kind
        var prompt: String
        /// Текст по мере генерации (для чата).
        var onDelta: ((String) -> Void)? = nil
        var completion: (Result<String, CodexError>) -> Void
    }

    init(store: SessionStore) { self.store = store }

    var isReady: Bool { if case .ready = state { return true }; return false }

    // MARK: процесс

    func start() {
        restartWork?.cancel()
        guard client == nil else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let override = UserDefaults.standard.string(forKey: "capri.codexPath")
        guard let exe = CodexBinary.find(override: override, home: home, exists: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            state = .noBinary
            return
        }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = CodexBinary.pathForChild + (env["PATH"].map { ":" + $0 } ?? "")
        let c = CodexClient(executable: exe, arguments: CodexBinary.serverArgs, environment: env)
        c.onNotification = { [weak self] m, p in self?.notification(m, p) }
        c.onExit = { [weak self] tail in self?.exited(tail) }
        do { try c.start() } catch {
            state = .failed("не запустился codex: \(error.localizedDescription)")
            return
        }
        client = c
        state = .starting
        let info: JSONValue = .object(["clientInfo": .object(["name": .string("capri"), "title": .string("Capri"), "version": .string("0.4")]),
                                       "capabilities": .object(["experimentalApi": .bool(false)])])
        c.call("initialize", info) { [weak self] r in
            guard let self, self.client === c else { return }
            if case .failure(let e) = r { self.restart("initialize: \(Self.message(e))"); return }
            c.notify("initialized")
            self.readAccount()
        }
        if cancellables.isEmpty {
            // Новое «ждёт меня» — попросить сводку. Пауза: варианты с экрана приходят чуть позже хука.
            store.$sessions
                .debounce(for: .seconds(1.5), scheduler: DispatchQueue.main)
                .sink { [weak self] _ in self?.summarizeWaiting() }
                .store(in: &cancellables)
        }
    }

    func stop() {
        restartWork?.cancel()
        let c = client
        client = nil
        leave(.off, error: .notRunning)
        c?.stop()
    }

    /// Состояние уходит из «готов»: ждущие задачи не должны висеть.
    private func leave(_ newState: State, error: CodexError) {
        state = newState
        limitsTimer?.invalidate()
        failJobs(error)
    }

    private func exited(_ tail: String) {
        client = nil
        restart(tail.isEmpty ? "codex app-server завершился" : "codex app-server завершился: \(tail)")
    }

    /// Ошибка процесса: остановить, сообщить и перезапустить с паузой 10 с, 20 с … до 5 минут.
    private func restart(_ message: String) {
        NSLog("[Capri] codex: %@", message)
        let c = client
        client = nil
        leave(.failed(message), error: .exited(message))
        c?.stop()
        failures += 1
        let delay = min(300, 10 * pow(2, Double(min(failures - 1, 5))))
        let work = DispatchWorkItem { [weak self] in self?.start() }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: аккаунт и лимиты

    private func readAccount() {
        guard let c = client else { return }
        c.call("account/read", .object(["refreshToken": .bool(false)])) { [weak self] r in
            guard let self, self.client === c else { return }
            switch r {
            case .failure(let e): self.restart("account/read: \(Self.message(e))")
            case .success(let v):
                if let a = CodexAccount.parse(v) {
                    self.state = .ready(a)
                    self.failures = 0
                    self.loadModel()
                    self.refreshLimits()
                    self.limitsTimer?.invalidate()
                    self.limitsTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.refreshLimits() }
                } else if case .signingIn = self.state {
                    // ждём account/login/completed
                } else {
                    self.leave(.signedOut, error: .server("нужно войти в Codex"))
                }
            }
        }
    }

    private func loadModel() {
        guard !modelLoaded, let c = client else { runNext(); summarizeWaiting(); return }
        c.call("model/list", .object([:])) { [weak self] r in
            guard let self else { return }
            // Без списка моделей сервер возьмёт модель по умолчанию — задачи не должны вставать.
            if case .success(let v) = r { self.model = CodexModel.pick(v) }
            self.modelLoaded = true
            self.runNext()
            self.summarizeWaiting()
        }
    }

    func refreshLimits() {
        client?.call("account/rateLimits/read") { [weak self] r in
            if case .success(let v) = r, let l = CodexLimits.parse(v) { self?.limits = l }
        }
    }

    /// Вход через ChatGPT: app-server даёт ссылку, открываем её в браузере и ждём `account/login/completed`.
    func signIn() {
        guard let c = client else { start(); return }
        c.call("account/login/start", .object(["type": .string("chatgpt")])) { [weak self] r in
            guard let self else { return }
            switch r {
            case .failure(let e): self.state = .failed("вход: \(Self.message(e))")
            case .success(let v):
                guard let url = v?["authUrl"]?.string, let u = URL(string: url), Self.isLoginURL(u) else {
                    self.state = .failed("вход: неожиданная ссылка от codex"); return
                }
                self.loginId = v?["loginId"]?.string
                self.state = .signingIn(url: url)
                NSWorkspace.shared.open(u)
            }
        }
    }

    /// Открываем только https-страницу входа OpenAI/ChatGPT (или локальный колбэк codex).
    static func isLoginURL(_ u: URL) -> Bool {
        guard let host = u.host?.lowercased() else { return false }
        if u.scheme == "https" { return ["openai.com", "chatgpt.com"].contains { host == $0 || host.hasSuffix("." + $0) } }
        return u.scheme == "http" && (host == "localhost" || host == "127.0.0.1")
    }

    func cancelSignIn() {
        if let id = loginId { client?.call("account/login/cancel", .object(["loginId": .string(id)])) { _ in } }
        loginId = nil
        state = .signedOut
    }

    // MARK: уведомления

    private func notification(_ method: String, _ params: JSONValue) {
        switch method {
        case "account/login/completed":
            loginId = nil
            if params["success"]?.bool == true { state = .starting; readAccount() }
            else { state = .signedOut; NSLog("[Capri] codex: вход не удался: %@", params["error"]?.string ?? "?") }
        case "account/updated":
            readAccount()
        case "account/rateLimits/updated":
            if let l = CodexLimits.parse(params) { limits = l }
        default:
            guard var c = collector else { return }
            let outcome = c.apply(method: method, params: params)
            collector = c
            running?.onDelta?(c.streamed)
            if let outcome { finish(outcome) }
        }
    }

    // MARK: ходы

    /// Чат и черновики — то, чего человек ждёт сейчас, — вперёд сводок.
    private func enqueue(_ job: Job) {
        if job.kind == .summary { jobs.append(job) }
        else { jobs.insert(job, at: jobs.firstIndex { $0.kind == .summary } ?? jobs.endIndex) }
        runNext()
    }

    private func runNext() {
        guard running == nil, isReady, modelLoaded, let c = client, !jobs.isEmpty else { return }
        let job = jobs.removeFirst()
        running = job
        if job.kind == .chat, let tid = chatThread {
            startTurn(c, thread: tid, job: job)
            return
        }
        var params: [String: JSONValue] = [
            "ephemeral": .bool(true), "approvalPolicy": .string("never"), "sandbox": .string("read-only"),
            "cwd": .string(NSTemporaryDirectory()), "developerInstructions": .string(CodexPrompts.developer)
        ]
        if let m = model { params["model"] = .string(m.id) }
        c.call("thread/start", .object(params), timeout: 60) { [weak self] r in
            guard let self, self.running?.id == job.id else { return }
            switch r {
            case .failure(let e): self.finish(.failed(Self.message(e)))
            case .success(let v):
                guard let tid = v?["thread"]?["id"]?.string else { self.finish(.failed("нет треда")); return }
                if job.kind == .chat { self.chatThread = tid }
                self.startTurn(c, thread: tid, job: job)
            }
        }
    }

    private func startTurn(_ c: CodexClient, thread: String, job: Job) {
        collector = CodexTurnCollector(threadId: thread)
        turn = (thread, nil)
        var params: [String: JSONValue] = [
            "threadId": .string(thread),
            "input": .array([.object(["type": .string("text"), "text": .string(job.prompt), "text_elements": .array([])])])
        ]
        if let e = model?.effort { params["effort"] = .string(e) }
        c.call("turn/start", .object(params), timeout: 60) { [weak self] r in
            guard let self, self.running?.id == job.id else { return }
            switch r {
            case .failure(let e): self.finish(.failed(Self.message(e)))
            case .success(let v): self.turn = (thread, v?["turn"]?["id"]?.string)
            }
        }
        // Страховка: ход не закончился за 2 минуты — прервать и идти дальше.
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            guard let self, self.running?.id == job.id else { return }
            self.finish(.failed("Codex не ответил за 2 минуты"))
        }
    }

    private func finish(_ outcome: CodexTurnCollector.Outcome) {
        guard let job = running else { return }
        if case .failed = outcome { interruptTurn() }
        running = nil
        collector = nil
        turn = nil
        switch outcome {
        case .completed(let text): job.completion(.success(text))
        case .failed(let m):
            if job.kind == .chat { chatThread = nil }   // сломанный тред чата не переиспользуем
            job.completion(.failure(.server(m)))
        }
        runNext()
    }

    /// Прервать ход на сервере, чтобы он не жёг лимит и не шёл параллельно со следующим.
    private func interruptTurn() {
        guard let t = turn, let id = t.id else { return }
        client?.call("turn/interrupt", .object(["threadId": .string(t.thread), "turnId": .string(id)])) { _ in }
    }

    private func failJobs(_ e: CodexError) {
        let all = (running.map { [$0] } ?? []) + jobs
        jobs.removeAll()
        running = nil
        collector = nil
        turn = nil
        chatThread = nil
        for j in all { j.completion(.failure(e)) }
    }

    // MARK: сводки, черновики, чат

    private func summarizeWaiting() {
        guard isReady, modelLoaded, summariesEnabled() else { return }
        let hidden = privateHosts()
        for s in store.waiting where !hidden.contains(s.key.host) {
            let fp = s.requestFingerprint
            guard !summaryAsked.contains(fp), store.summary(s) == nil else { continue }
            // Не копить очередь: сводка нужна сейчас, а не через минуту.
            guard jobs.filter({ $0.kind == .summary }).count < 4 else { break }
            summaryAsked.insert(fp)
            if summaryAsked.count > 500 { summaryAsked.removeAll() }
            let key = s.key
            enqueue(Job(kind: .summary, prompt: CodexPrompts.summary(s, screen: store.details.rawScreen(s))) { [weak self] r in
                guard let self else { return }
                switch r {
                case .success(let text):
                    if let line = CodexPrompts.cleanSummary(text) { self.store.setSummary(key, fingerprint: fp, text: line) }
                case .failure:
                    self.summaryAsked.remove(fp)   // повторим при следующем изменении
                }
            })
        }
    }

    /// Черновик ответа сессии — в поле ввода окна, отправляет человек.
    func draft(_ key: SessionKey, completion: @escaping (Result<String, CodexError>) -> Void) {
        guard let s = store.session(key) else { return }
        if privateHosts().contains(s.key.host) {
            completion(.failure(.server("хост \(s.key.host) не отправляется в Codex (настройки)")))
            return
        }
        drafting = s.key
        enqueue(Job(kind: .draft, prompt: CodexPrompts.draft(s, screen: store.details.rawScreen(s))) { [weak self] r in
            self?.drafting = nil
            completion(r.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        })
    }

    /// Вопрос помощнику. Codex видит все сессии (`Assistant.prompt`); без Codex Capri отвечает сама,
    /// по локальным данным. Пока ответ идёт, его текст — пустая строка (облачко показывает «думает»).
    func ask(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !chatBusy else { return }
        // Неподтверждённые действия прошлых ответов больше не актуальны.
        for i in chat.indices { for j in chat[i].proposals.indices where chat[i].proposals[j].state == .pending { chat[i].proposals[j].state = .cancelled } }
        chat.append(ChatMessage(role: .user, text: q))
        guard isReady else {
            var text = Assistant.localAnswer(sessions: store.sessions, names: store.names)
            text += state == .signedOut ? " Чтобы отвечать на другое, войдите в Codex (меню ✦)." : " Codex сейчас не подключён."
            chat.append(ChatMessage(role: .local, text: text))
            return
        }
        let reply = ChatMessage(role: .codex, text: "")
        chat.append(reply)
        chatBusy = true
        let id = reply.id
        let details = store.details
        let prompt = Assistant.prompt(question: q, sessions: store.sessions, names: store.names, private: privateHosts(),
                                      history: { details.history.list($0.key) }, screens: { details.rawScreen($0) })
        let delta: (String) -> Void = { [weak self] text in
            guard let self, let i = self.chat.firstIndex(where: { $0.id == id }) else { return }
            let shown = Assistant.visible(text)
            if !shown.isEmpty { self.chat[i].text = shown }
        }
        enqueue(Job(kind: .chat, prompt: prompt.text, onDelta: delta) { [weak self] r in
            guard let self else { return }
            self.chatBusy = false
            guard let i = self.chat.firstIndex(where: { $0.id == id }) else { return }
            switch r {
            case .success(let t):
                let parsed = Assistant.parse(t)
                self.chat[i].proposals = parsed.proposals.compactMap { p in
                    guard let key = prompt.refs[p.ref], let s = self.store.session(key) else { return nil }
                    var label: String?
                    if case .choose(let n) = p.action {
                        // Выбор — только существующего варианта ждущей сессии.
                        guard s.status == .needsInput, let c = s.request?.choices.first(where: { $0.index == n }) else { return nil }
                        label = c.label
                    }
                    return Proposal(key: s.key, title: self.store.name(s).title, action: p.action, choiceLabel: label,
                                    fingerprint: s.requestFingerprint, status: s.status)
                }
                self.chat[i].text = parsed.text.isEmpty && self.chat[i].proposals.isEmpty ? "(пустой ответ)" : parsed.text
                self.speak(for: self.chat[i].text)
            case .failure(let e): self.chat[i] = ChatMessage(role: .error, text: Self.message(e))
            }
        })
    }

    private func speak(for text: String) {
        speakingTask?.cancel()
        speaking = true
        let task = DispatchWorkItem { [weak self] in self?.speaking = false }
        speakingTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + min(8, max(1.5, Double(text.count) / 18)), execute: task)
    }

    /// Человек подтвердил действие помощника — отправка теми же путями и проверками, что и ответ руками.
    func confirm(_ message: UUID, _ proposal: UUID) {
        guard let i = chat.firstIndex(where: { $0.id == message }),
              let j = chat[i].proposals.firstIndex(where: { $0.id == proposal }),
              chat[i].proposals[j].state == .pending else { return }
        let p = chat[i].proposals[j]
        guard let s = store.session(p.key), s.requestFingerprint == p.fingerprint, s.status == p.status else {
            chat[i].proposals[j].state = .failed("сессия уже спрашивает другое — спросите Capri ещё раз")
            return
        }
        chat[i].proposals[j].state = .sending
        store.send(p.key, p.action) { [weak self] ok in
            guard let self, let i = self.chat.firstIndex(where: { $0.id == message }),
                  let j = self.chat[i].proposals.firstIndex(where: { $0.id == proposal }) else { return }
            if ok {
                self.chat[i].proposals[j].state = .sent
            } else if case .refused(let m)? = self.store.deliveries[p.key] {
                self.chat[i].proposals[j].state = .failed(m)
            } else {
                self.chat[i].proposals[j].state = .failed("не отправлено")
            }
        }
    }

    func cancel(_ message: UUID, _ proposal: UUID) {
        guard let i = chat.firstIndex(where: { $0.id == message }),
              let j = chat[i].proposals.firstIndex(where: { $0.id == proposal }),
              chat[i].proposals[j].state == .pending else { return }
        chat[i].proposals[j].state = .cancelled
    }

    /// Первое неподтверждённое действие последнего ответа (Enter в помощнике подтверждает его).
    var pendingProposal: (message: UUID, proposal: Proposal)? {
        guard let m = chat.last, let p = m.proposals.first(where: { $0.state == .pending }) else { return nil }
        return (m.id, p)
    }

    func clearChat() {
        guard !chatBusy else { return }
        chat.removeAll()
        chatThread = nil
    }

    static func message(_ e: CodexError) -> String {
        switch e {
        case .notRunning: return "Codex не запущен"
        case .timeout: return "Codex не ответил вовремя"
        case .server(let m): return m
        case .exited(let m): return m.isEmpty ? "codex app-server завершился" : m
        }
    }
}
