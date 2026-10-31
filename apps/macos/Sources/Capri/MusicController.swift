import AppKit
import CapriKit

/// Откуда пришла команда — у `MusicController.perform` другого входа нет: музыку трогаем только по прямому
/// действию человека (кнопка Capri, просьба помощнику). Фон и директор сюда не ходят.
enum MusicIntent {
    /// Кнопка ⏮ ⏯ ⏭ (notch, peek, глаза на столе, окно музыки, меню) — где нажали.
    case button(String)
    /// Просьба помощнику: сам вопрос человека.
    case assistant(String)

    var log: String {
        switch self {
        case .button(let w): "button:\(w)"
        case .assistant: "assistant"
        }
    }
}

/// Чем кончилась команда (до события плеера — оно приходит через `NowPlayingMonitor`).
enum MusicResult: Equatable {
    /// Скрипт плееру ушёл.
    case sent(MusicSource)
    /// Spotify по названию без ключей (или ключи не сработали): найти трек нечем. Поиск в самом
    /// Spotify не открываем — он выходит на передний план и сам ничего не включает.
    case needsKeys(String?)
    case notFound
    /// Пауза/переключение, а плеер не запущен.
    case notRunning
    case noPlayer
    /// macOS не дала управлять плеером (Конфиденциальность → Автоматизация).
    case denied
    /// Команда прождала в очереди за зависшим скриптом и отброшена.
    case skipped
    case failed(String)
}

/// Исполнитель команд плееру. Настоящий — `osascript` в фоне; фейковый — только журнал (агенты и `--debug-control`).
protocol MusicBackend: AnyObject {
    var name: String { get }
    func run(_ script: String, completion: @escaping (Result<String, MusicBackendError>) -> Void)
    func open(_ url: URL)
    func launch(_ player: MusicSource, completion: @escaping (Bool) -> Void)
    func running() -> Set<MusicSource>
    func installed() -> Set<MusicSource>
}

struct MusicBackendError: Error { var kind: String; var message: String }

/// `osascript` в фоне: первый запрос разрешения «Автоматизация» блокирует вызов, главный поток держать нельзя.
/// Ответственный процесс — Capri, разрешение macOS спрашивает для Capri. Таймаут 10 с — когда плеер уже ответил
/// хоть раз; до этого 90 с: на первом скрипте macOS ждёт ответа человека на запрос разрешения.
/// Очередь последовательная: нажатия, прождавшие за зависшим скриптом дольше 3 с, отбрасываются (не играть их пачкой).
final class AppleScriptBackend: MusicBackend {
    let name = "applescript"
    private let queue = DispatchQueue(label: "capri.music", qos: .userInitiated)
    /// Плееры (bundle id), которым скрипт уже прошёл, — только на `queue`.
    private var answered: Set<String> = []

    func run(_ script: String, completion: @escaping (Result<String, MusicBackendError>) -> Void) {
        let queued = Date()
        queue.async {
            if Date().timeIntervalSince(queued) > 3 {
                DispatchQueue.main.async { completion(.failure(MusicBackendError(kind: "stale", message: "устарело в очереди"))) }
                return
            }
            let player = MusicSource.allCases.first { script.contains($0.bundleID) }?.bundleID ?? ""
            let limit: Double = self.answered.contains(player) ? 10 : 90
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = MusicScript.arguments(script)
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            let result: Result<String, MusicBackendError>
            do {
                try p.run()
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + limit, execute: killer)
                let o = out.fileHandleForReading.readDataToEndOfFile()
                let e = err.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                killer.cancel()
                let stdout = String(decoding: o, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                let stderr = String(decoding: e, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if p.terminationReason == .uncaughtSignal { result = .failure(MusicBackendError(kind: "timeout", message: "плеер не ответил за \(Int(limit)) с")) }
                else if p.terminationStatus == 0 { result = .success(stdout); self.answered.insert(player) }
                else {
                    // В журнал — только код ошибки: в stderr бывает текст скрипта с запросом.
                    let kind = MusicScript.failure(stderr)
                    let code = stderr.range(of: #"\(-?\d+\)"#, options: .regularExpression).map { String(stderr[$0]) } ?? ""
                    result = .failure(MusicBackendError(kind: kind, message: code))
                }
            } catch {
                result = .failure(MusicBackendError(kind: "error", message: error.localizedDescription))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func open(_ url: URL) {
        let c = NSWorkspace.OpenConfiguration()
        c.activates = false
        NSWorkspace.shared.open(url, configuration: c) { _, _ in }
    }

    func launch(_ player: MusicSource, completion: @escaping (Bool) -> Void) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.bundleID) else { completion(false); return }
        let c = NSWorkspace.OpenConfiguration()
        c.activates = false
        c.hides = true
        NSWorkspace.shared.openApplication(at: url, configuration: c) { app, _ in
            // Плеер только запустился — AppleScript ему ещё рано, секунда на загрузку.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { completion(app != nil) }
        }
    }

    func running() -> Set<MusicSource> {
        let ids = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return Set(MusicSource.allCases.filter { ids.contains($0.bundleID) })
    }

    func installed() -> Set<MusicSource> {
        Set(MusicSource.allCases.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil })
    }
}

/// Фейк для проверок без Тимофея: скрипты только в журнал, плеер «запущен», события плеера — выдуманные
/// (через `onEvent`, как будто от `NowPlayingMonitor`). Запрос со словом «nothing» — «не нашла».
final class FakeMusicBackend: MusicBackend {
    let name = "fake"
    var log: ((String) -> Void)?
    var onEvent: ((MusicSource, NowPlayingEvent) -> Void)?
    private var n = 0
    private var playing = true

    func run(_ script: String, completion: @escaping (Result<String, MusicBackendError>) -> Void) {
        // В журнал — без текста скрипта (в нём бывает запрос): только что за команда.
        let what = ["playpause", "pause", "next track", "previous track", "play track", "search", "play"].first { script.contains($0) } ?? "?"
        log?("fake osascript \(what) (\(script.count) зн.)")
        let notFound = script.contains("nothing")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            if notFound { completion(.success(MusicScript.notFound)); return }
            completion(.success(""))
            // Плеер «отвечает» уведомлением через секунду.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.event(for: script) }
        }
    }

    private func event(for script: String) {
        let source: MusicSource = script.contains(MusicSource.music.bundleID) ? .music : .spotify
        if script.hasSuffix(" to pause") || (script.hasSuffix(" to playpause") && playing) {
            playing = false
            onEvent?(source, .paused(track(source)))
            return
        }
        if script.contains("next track") || script.contains("previous track") || script.contains("play track") || script.contains("search") { n += 1 }
        playing = true
        onEvent?(source, .playing(track(source)))
    }

    private func track(_ s: MusicSource) -> Track {
        Track(source: s, id: "fake:\(n)", name: "Fake Track \(n)", artist: "Fake Artist")
    }

    func open(_ url: URL) { log?("fake open \(url.scheme ?? ""):… (\(url.absoluteString.count) зн.)") }

    func launch(_ player: MusicSource, completion: @escaping (Bool) -> Void) {
        log?("fake launch \(player.rawValue)")
        DispatchQueue.main.async { completion(true) }
    }

    func running() -> Set<MusicSource> { [.spotify] }
    func installed() -> Set<MusicSource> { [.spotify, .music] }
}

/// Единственная точка, через которую Capri трогает плеер. Решает, какому плееру, запускает его без активации
/// (только для «включи»), ищет по названию (Spotify Web API по ключам, без них — просит ссылку; Музыка — медиатека)
/// и отдаёт итог. Событие плеера (трек пошёл) ждёт `CharacterCenter`.
final class MusicController {
    let backend: MusicBackend
    let spotify: SpotifySearch
    /// Что играло последним (плеер, которому слать паузу/переключение).
    var current: () -> MusicSource? = { nil }
    var log: ((String) -> Void)?
    /// Разрешение «Автоматизация» по плеерам — для `dump` (по итогу настоящих скриптов, без запроса).
    private(set) var automation: [String: String] = [:]

    /// Идёт команда из `~/.capri/tmp/control` (главный поток, на время её разбора).
    nonisolated(unsafe) static var inControlCommand = false

    init(backend: MusicBackend, spotify: SpotifySearch) {
        self.backend = backend
        self.spotify = spotify
    }

    func perform(_ cmd: MusicCommand, intent: MusicIntent, completion: @escaping (MusicResult) -> Void) {
        // Файл отладки пишет кто угодно на машине — настоящему плееру от него ничего (только фейку).
        if Self.inControlCommand, !(backend is FakeMusicBackend) {
            log?("music \(intent.log): \(cmd.log) — команда из файла отладки, настоящий плеер не трогаю")
            completion(.skipped)
            return
        }
        let route = cmd.route(current: current(), running: backend.running(), installed: backend.installed())
        log?("music \(intent.log): \(cmd.log) → \(route) via \(backend.name)")
        switch route {
        case .skip(let why):
            completion(why == "notRunning" ? .notRunning : .noPlayer)
        case .send(let player, let launch):
            if case .play(let q) = cmd, player == .spotify {
                playSpotify(q, launch: launch, completion: completion)
                return
            }
            guard let script = MusicScript.script(cmd, player: player) else { completion(.failed("нечем выполнить")); return }
            let go = { [weak self] in self?.run(script, player, completion) }
            if launch { backend.launch(player) { ok in ok ? go() : completion(.noPlayer) } } else { go() }
        }
    }

    /// Spotify по названию: ключи есть — Web API → `play track` в фоне; нет — честно просим ключи или ссылку.
    private func playSpotify(_ q: String, launch: Bool, completion: @escaping (MusicResult) -> Void) {
        guard spotify.hasKeys else { completion(.needsKeys(nil)); return }
        spotify.find(q) { [weak self] r in
            guard let self else { return }
            switch r {
            case .success(let uri?):
                self.log?("music spotify search → \(uri.kind)")
                let go = { self.run(MusicScript.spotifyPlay(uri), .spotify, completion) }
                if launch { self.backend.launch(.spotify) { ok in ok ? go() : completion(.noPlayer) } } else { go() }
            case .success(nil):
                completion(.notFound)
            case .failure(let e):
                self.log?("music spotify search failed: \(e.text)")
                completion(.needsKeys(e.text))
            }
        }
    }

    private func run(_ script: String, _ player: MusicSource, _ completion: @escaping (MusicResult) -> Void) {
        backend.run(script) { [weak self] r in
            if self?.backend is AppleScriptBackend { self?.note(player, r) }
            switch r {
            case .success(let out):
                completion(out == MusicScript.notFound ? .notFound : .sent(player))
            case .failure(let e):
                self?.log?("music \(player.rawValue): \(e.kind) \(e.message)")
                switch e.kind {
                case "denied", "consent": completion(.denied)
                case "notRunning": completion(.notRunning)
                // Нажатие прождало за зависшим скриптом — молча пропущено, не провал.
                case "stale": completion(.skipped)
                default: completion(.failed(e.kind == "timeout" ? "плеер не ответил" : "не вышло"))
                }
            }
        }
    }

    /// Разрешение по итогу последнего настоящего скрипта: `granted` — прошёл, `denied` — −1743/−1744.
    /// `AEDeterminePermissionToAutomateTarget` не используем: на живом Маке он вис в фоне (Spotify запущен),
    /// а рисковать запросом разрешения без действия человека нельзя.
    private func note(_ player: MusicSource, _ r: Result<String, MusicBackendError>) {
        switch r {
        case .success: automation[player.rawValue] = "granted"
        case .failure(let e) where e.kind == "denied" || e.kind == "consent": automation[player.rawValue] = "denied"
        case .failure: break
        }
    }
}
