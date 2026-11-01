import XCTest
import CoreGraphics
@testable import CapriKit

/// Этап 3 плана присутствия: терминал с Claude — что под окном, когда вылезать, что говорить, кадры.
final class TerminalWatchTests: XCTestCase {
    typealias P = TerminalLocator.Proc

    // MARK: что под терминалом

    /// Terminal (100): login → zsh → tmux attach -t votek (свежий), login → zsh → ssh -t -- devbox tmux attach -t api,
    /// login → zsh → claude (старый); вложенный zsh → zsh → ssh prod. Сервер tmux (900) — под launchd.
    let procs: [P] = [
        P(pid: 100, ppid: 1, name: "Terminal"),
        P(pid: 101, ppid: 100, name: "login"),
        P(pid: 102, ppid: 101, name: "zsh"),
        P(pid: 103, ppid: 102, name: "tmux", start: 990, args: ["tmux", "attach", "-t", "votek"]),
        P(pid: 111, ppid: 100, name: "login"),
        P(pid: 112, ppid: 111, name: "zsh"),
        P(pid: 113, ppid: 112, name: "ssh", start: 950, args: ["/usr/bin/ssh", "-t", "--", "devbox", "tmux attach -t api"]),
        P(pid: 121, ppid: 100, name: "login"),
        P(pid: 122, ppid: 121, name: "zsh"),
        P(pid: 123, ppid: 122, name: "claude", start: 10, args: ["claude", "--dangerously-skip-permissions"]),
        P(pid: 131, ppid: 100, name: "login"),
        P(pid: 132, ppid: 131, name: "zsh"),
        P(pid: 133, ppid: 132, name: "zsh"),
        P(pid: 134, ppid: 133, name: "ssh", start: 500, args: ["ssh", "-p", "2222", "-i", "~/.ssh/k", "timo@prod"]),
        P(pid: 141, ppid: 100, name: "login"),
        P(pid: 142, ppid: 141, name: "zsh"),
        P(pid: 143, ppid: 142, name: "node", start: 800, args: ["node", "/Users/x/.nvm/versions/node/v22/bin/codex", "--yolo"]),
        P(pid: 900, ppid: 1, name: "tmux", args: ["tmux", "new", "-d"]),
        // Чужое приложение: ssh под ним — не под терминалом.
        P(pid: 300, ppid: 1, name: "Capri"),
        P(pid: 301, ppid: 300, name: "ssh", start: 999, args: ["/usr/bin/ssh", "-T", "devbox", "capri-hook", "stream"]),
    ]

    func testTargetsUnderTerminal() {
        let found = TerminalLocator.targets(underTerminal: 100, procs: procs)
        XCTAssertEqual(found.map(\.what), [
            .tmux(pid: 103, session: "votek"),
            .ssh(pid: 113, host: "devbox", session: "api"),
            .agent(pid: 143, agent: .codex),
            .ssh(pid: 134, host: "prod", session: nil),
            .agent(pid: 123, agent: .claude),
        ], "свежие сверху; сервер tmux и ssh сборщика Capri — не под терминалом")
        XCTAssertTrue(TerminalLocator.targets(underTerminal: 555, procs: procs).isEmpty)
    }

    func testSshAndTmuxArguments() {
        XCTAssertEqual(TerminalLocator.sshTarget(["ssh", "quiz"])?.host, "quiz")
        XCTAssertNil(TerminalLocator.sshTarget(["ssh", "quiz"])?.session)
        XCTAssertEqual(TerminalLocator.sshTarget(["ssh", "-o", "ServerAliveInterval=15", "-tt", "timoserver", "tmux", "a", "-t", "capri"])?.session,
                       "capri")
        XCTAssertEqual(TerminalLocator.sshTarget(["ssh", "-p22", "u@h"])?.host, "h")
        XCTAssertNil(TerminalLocator.sshTarget(["ssh", "-p", "22"]), "только опции — хоста нет")
        // Как открывает «Открыть»: по панели, цепочкой команд.
        let open = ["/usr/bin/ssh", "-t", "--", "timoserver",
                    "exec tmux select-window -t %5 \\; select-pane -t %5 \\; attach-session -t %5"]
        XCTAssertEqual(TerminalLocator.sshTarget(open)?.session, "%5")
        XCTAssertEqual(TerminalLocator.tmuxSession(["attach-session", "-t", "votek:1.0"]), "votek")
        XCTAssertEqual(TerminalLocator.tmuxSession(["new", "-A", "-s", "main"]), "main")
        XCTAssertEqual(TerminalLocator.tmuxSession(["a", "-tdev"]), "dev")
        XCTAssertNil(TerminalLocator.tmuxSession(["attach"]), "без имени — по list-clients")
        XCTAssertNil(TerminalLocator.tmuxSession(["ls"]))
    }

    func session(_ host: String, _ id: String, tmux: String? = nil, pane: String = "%1", agent: Agent = .claude, cwd: String = "/w",
                 status: SessionStatus = .running) -> Session {
        Session(key: SessionKey(host: host, agent: agent, id: id), tmux: tmux.map { TmuxRef(pane: pane, session: $0) }, cwd: cwd,
                status: status, confidence: .hook, statusSince: 0, lastEventAt: 0, request: nil, lastMessage: nil, typedInput: nil)
    }

    func testMatchSessionsUnderTerminal() {
        let sessions = [
            session("local", "a", tmux: "votek"),
            session("devbox", "b", tmux: "api"),
            session("devbox", "c", tmux: "web"),
            session("prod", "d", tmux: "x"),
            session("prod", "e", tmux: "y", status: .ended),
            session("local", "f", cwd: "/Users/x/app"),
            session("local", "g", agent: .codex, cwd: "/Users/x/codexy"),
            session("timoserver", "h", tmux: "capri", pane: "%5"),
        ]
        let found = TerminalLocator.targets(underTerminal: 100, procs: procs)
        let m = TerminalWatch.match(found, sessions: sessions, cwds: [123: "/Users/x/app", 143: "/Users/x/codexy"])
        XCTAssertEqual(m.map(\.key.id), ["a", "b", "g", "f"], "attach -t — только своя tmux-сессия; голый ssh — не повод; закрытые — нет")
        // tmux-клиент без имени — по list-clients; панель `%N` — по панели.
        let bare = [TerminalLocator.Found(.tmux(pid: 7, session: nil), start: 1),
                    TerminalLocator.Found(.ssh(pid: 8, host: "timoserver", session: "%5"), start: 2)]
        XCTAssertEqual(TerminalWatch.match(bare, sessions: sessions, clients: [7: "votek"]).map(\.key.id), ["a", "h"])
        XCTAssertTrue(TerminalWatch.match(bare.prefix(1).map { $0 }, sessions: sessions).isEmpty, "клиент без имени и без list-clients — нет")
        XCTAssertEqual(TerminalWatch.primary(m, sessions: sessions)?.key.id, "a", "работающая и самая свежая")
    }

    func testOpeningIsFreshAndUsedOnce() {
        let k = SessionKey(host: "local", agent: .claude, id: "a")
        let m = [TerminalWatch.Match(key: k, via: .tmux(pid: 103, session: "votek"), start: 1000),
                 TerminalWatch.Match(key: k, via: .ssh(pid: 9, host: "h", session: nil), start: 200)]
        XCTAssertEqual(TerminalWatch.opening(m, now: 1100)?.start, 1000, "подключился 100 с назад — повод")
        XCTAssertNil(TerminalWatch.opening(m, now: 1000 + TerminalWatch.freshFor + 1), "переключился на старое окно — нет")
        XCTAssertNil(TerminalWatch.opening(m, now: 1100, used: [m[0].opening]), "то же открытие второй раз — нет")
    }

    // MARK: PerchPolicy: терминал

    func input(_ now: Double) -> PerchPolicy.Input { PerchPolicy.Input(now: now, dayStart: now - 3600, category: .terminal) }

    func term(_ p: inout PerchPolicy, window: UInt32 = 7, sessions: [String] = ["local/claude/a"], opening: String? = "103@1000",
              working: Bool = true, _ i: PerchPolicy.Input) -> PerchPolicy.Decision {
        p.decide(.terminal(window: window, sessions: sessions, opening: opening, working: working), i)
    }

    func testTerminalWatchRules() {
        let now = 1_000_000.0
        var p = PerchPolicy()
        XCTAssertEqual(term(&p, opening: nil, input(now)), .skip("notOpened"), "⌘-Tab на старое окно — не повод")
        XCTAssertEqual(term(&p, opening: "1@1", working: false, input(now)), .skip("notWorking"))
        XCTAssertEqual(term(&p, opening: "1@1", input(now)), .watch, "не работала → дал задачу: то же открытие ещё повод")
        XCTAssertEqual(term(&p, opening: "1@1", input(now + 3600)), .skip("notOpened"), "открытие тратится")
        // Окно — раз в 15 мин, сессия — раз в час, лимиты — общие с посадками.
        XCTAssertEqual(term(&p, window: 7, sessions: ["x"], opening: "2@2", input(now + 700)), .skip("windowCooldown"))
        XCTAssertEqual(term(&p, window: 8, opening: "3@3", input(now + 700)), .skip("sessionCooldown"))
        XCTAssertEqual(term(&p, window: 8, sessions: ["y"], opening: "4@4", input(now + 300)), .skip("gap"))
        XCTAssertEqual(term(&p, window: 8, sessions: ["y"], opening: "5@5", input(now + 700)), .watch)
        XCTAssertEqual(p.decide(.activated(bundle: "com.apple.Notes", launched: true),
                                PerchPolicy.Input(now: now + 1400, dayStart: now - 3600, category: .notes)), .skip("hourly"),
                       "две сцены за час — посадка на приложение ждёт")
        var off = input(now + 9000)
        off.enabled = false
        XCTAssertEqual(term(&p, window: 9, sessions: ["z"], opening: "6@6", off), .skip("off"), "одна настройка выключает и терминал")
        var quiet = input(now + 9000)
        quiet.minuteOfDay = 2 * 60
        XCTAssertEqual(term(&p, window: 9, sessions: ["z"], opening: "7@7", quiet), .skip("quiet"))
        var warm = input(now + 9000)
        warm.sinceStart = 30
        XCTAssertEqual(term(&p, window: 9, sessions: ["z"], opening: "8@8", warm), .skip("warmup"))
        var nospot = input(now + 9000)
        nospot.spot = "noSpot"
        XCTAssertEqual(term(&p, window: 9, sessions: ["z"], opening: "9@9", nospot), .skip("noSpot"))
        XCTAssertEqual(term(&p, window: 9, sessions: ["z"], opening: "9@9", input(now + 9001)), .watch, "места не было — открытие не потрачено")
    }

    func testTerminalIgnoresTirednessButCountsForLimits() {
        var p = PerchPolicy()
        p.shooed(at: 0)
        p.shooed(at: 1)
        XCTAssertEqual(term(&p, input(100)), .watch, "устала от посадок — терминал (его действие) всё равно")
        XCTAssertEqual(p.counts(now: 100, dayStart: 0).hour, 1)
    }

    func testOldStateDecodesWithoutTerminalFields() throws {
        var p = PerchPolicy()
        _ = p.decide(.activated(bundle: "com.apple.Notes", launched: true), PerchPolicy.Input(now: 1000, dayStart: 0, category: .notes))
        var obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as! [String: Any]
        for k in ["watchedWindows", "watchedSessions", "usedOpenings"] { obj[k] = nil }
        let back = try JSONDecoder().decode(PerchPolicy.self, from: JSONSerialization.data(withJSONObject: obj))
        XCTAssertFalse(back.isFirstToday("com.apple.Notes", dayStart: 0), "после обновления приложения не «первые за день» снова")
        var q = PerchPolicy()
        _ = term(&q, input(5000))
        let round = try JSONDecoder().decode(PerchPolicy.self, from: JSONEncoder().encode(q))
        XCTAssertEqual(round, q)
    }

    // MARK: реплики

    func testKeywordsFromTail() {
        XCTAssertEqual(SessionRemark.keyword(["$ npm test", "  12 passing", "  1 failing", "Tests FAILED"]), .failed)
        XCTAssertEqual(SessionRemark.keyword(["Compiling CapriKit", "Building for debugging"]), .build)
        XCTAssertEqual(SessionRemark.keyword(["⏺ Bash(git commit -m \"Add x\")"]), .commit)
        XCTAssertEqual(SessionRemark.keyword(["Executed 230 tests, with 0 failures"]), .passed)
        XCTAssertNil(SessionRemark.keyword(["> думаю над планом"]))
        XCTAssertNil(SessionRemark.keyword(nil), "приватный хост — без текста")
        // Смотрит только хвост.
        let old = ["error: old"] + Array(repeating: "ok", count: SessionRemark.tailLines)
        XCTAssertNil(SessionRemark.keyword(old))
    }

    func testOpeningSaysWhatIsHappening() {
        let s = WatchedSession(name: "votek2", status: .running, since: 0, tail: ["swift test"])
        XCTAssertTrue(SessionRemark.opening(s, now: 60).contains("тест"))
        let plain = WatchedSession(name: "votek2", status: .running, since: 0)
        let line = SessionRemark.opening(plain, now: 7 * 60, seed: 0)
        XCTAssertTrue(line.contains("7 мин"), line)
        XCTAssertTrue(SessionRemark.opening(plain, others: 2, now: 0).contains("3 сессии"))
        let long = WatchedSession(name: "очень-длинное-имя-сессии", status: .running, since: 0)
        for seed in 0..<8 {
            let l = SessionRemark.opening(long, now: 30, seed: seed)
            XCTAssertFalse(l.contains("очень"), "длинное имя — без имени")
            XCTAssertLessThanOrEqual(l.count, SessionRemark.maxChars)
        }
    }

    func testStatusChanges() {
        let run = WatchedSession(name: "api", status: .running, since: 0)
        var idle = run
        idle.status = .idle
        let done = SessionRemark.change(from: run, to: idle, now: 300)
        XCTAssertEqual(done?.mood, .gloat, "доработала — злорадство и домой")
        XCTAssertTrue(done!.text!.contains("5 мин"))
        var asks = run
        asks.status = .needsInput
        XCTAssertEqual(SessionRemark.change(from: run, to: asks, now: 10), SessionRemark.Remark(nil, .leave), "ждёт ответа — молча, дальше alert")
        var gone = run
        gone.status = .ended
        XCTAssertEqual(SessionRemark.change(from: run, to: gone, now: 10)?.mood, .leave)
        var err = run
        err.status = .error
        XCTAssertEqual(SessionRemark.change(from: run, to: err, now: 10)?.mood, .gloat)
        XCTAssertNil(SessionRemark.change(from: run, to: run, now: 10), "ничего не изменилось — молчит")
    }

    func testKeywordRemarksNoRepeatsAndPrivate() {
        let a = WatchedSession(name: "api", status: .running, since: 0, tail: ["thinking"])
        var b = a
        b.tail = ["$ swift test", "Test Suite 'All tests' started"]
        let r1 = SessionRemark.change(from: a, to: b, now: 10)
        XCTAssertEqual(r1?.mood, .say)
        XCTAssertNil(SessionRemark.change(from: a, to: b, now: 20, lastKeyword: .test), "то же слово — не повторяет")
        var said: [String] = []
        for seed in 0..<6 {
            if let t = SessionRemark.change(from: a, to: b, now: 10, said: said, seed: seed)?.text { said.append(t) }
        }
        XCTAssertEqual(Set(said).count, said.count, "без повторов")
        XCTAssertLessThanOrEqual(said.count, 2)
        // Приватный хост: хвоста нет — только статус.
        var p = a
        p.tail = nil
        var q = p
        q.tail = nil
        XCTAssertNil(SessionRemark.change(from: p, to: q, now: 10))
    }

    func testAllRemarksFitAndAreValid() {
        let names = ["", "a", "votek2", "capri-test-x", "очень-длинное-имя"]
        for name in names {
            for status in [SessionStatus.running, .idle] {
                for m in [0.0, 120, 3600] {
                    let s = WatchedSession(name: name, status: status, since: 0, tail: nil)
                    for seed in 0..<4 {
                        let o = SessionRemark.opening(s, now: m, seed: seed)
                        XCTAssertTrue(PerchLines.valid(o) && o.count <= SessionRemark.maxChars, o)
                    }
                }
            }
            for k in SessionRemark.Keyword.allCases {
                let lines = SessionRemark.keywordLines(k, name: SessionRemark.who(WatchedSession(name: name, status: .running, since: 0)))
                XCTAssertFalse(lines.compactMap(SessionRemark.fit).isEmpty, "\(k) для «\(name)»")
            }
            let run = WatchedSession(name: name, status: .running, since: 0)
            for to in [SessionStatus.idle, .error, .rateLimited, .ended] {
                var b = run
                b.status = to
                let t = SessionRemark.change(from: run, to: b, now: 600)?.text
                XCTAssertNotNil(t, "\(name) → \(to)")
                XCTAssertLessThanOrEqual(t?.count ?? 0, SessionRemark.maxChars)
            }
        }
    }

    // MARK: кадры

    let visible = CGRect(x: 0, y: 0, width: 1512, height: 944)
    let clips = Set(SceneClip.all)
    let window = CGRect(x: 300, y: 200, width: 800, height: 500)

    func geometry() -> SceneGeometry {
        let s = PerchLayout.spot(window: window, above: [], visible: visible, bubble: PerchLayout.bubbleSize(chars: 26))!
        return SceneGeometry(home: CGRect(x: 740, y: 950, width: 32, height: 16), target: s.eyes, area: window, visible: visible,
                             bubble: s.bubble)
    }

    func options(_ w: SceneWatch, seed: Int = 3) -> SceneOptions {
        var o = SceneOptions()
        o.seed = seed
        o.enter = .columnSmear
        o.watch = w
        return o
    }

    func testWatchPhases() {
        let w = SceneWatch(window: window, says: [SceneSay(at: WatchTimeline.firstSay, chars: 26)])
        let o = options(w)
        let g = geometry()
        func f(_ t: Double) -> SceneFrame { SceneTimeline.frame(.perch, t: t, geometry: g, clips: clips, options: o) }
        XCTAssertEqual(SceneTimeline.duration(.perch, o), WatchTimeline.maxWatch + WatchTimeline.leaveLen, accuracy: 1e-9, "≤ 60 с")
        XCTAssertEqual(f(0.1).phase, "out")
        XCTAssertNotNil(f(0.3).bolt, "молния в терминал")
        let smear = f(0.6)
        XCTAssertEqual(smear.phase, "smear")
        XCTAssertNil(smear.eyes)
        XCTAssertEqual(smear.smear?.clip, window, "капли — по самому окну терминала")
        let strip = smear.smear!.rect
        XCTAssertTrue(window.contains(strip), "полоса внутри окна")
        XCTAssertEqual(strip.maxY, window.maxY, accuracy: 0.01, "у верхнего края")
        XCTAssertLessThanOrEqual(strip.height, Transitions.stripDepth + 0.01, "не завеса на всё окно")
        XCTAssertLessThanOrEqual(strip.width, Transitions.stripWidth + 0.01)
        XCTAssertLessThanOrEqual(smear.smear!.alpha, 0.75, "полупрозрачные")
        XCTAssertEqual(smear.smear!.tint, 0, "без налёта на всё окно")
        XCTAssertFalse(smear.smear!.columns.isEmpty)
        XCTAssertEqual(f(1.2).phase, "climb")
        XCTAssertEqual(f(1.2).fx?.kind, .columnSmear, "вылезает столбцами")
        XCTAssertEqual(f(2.0).phase, "watch")
        XCTAssertEqual(f(2.0).eyes, g.target)
        XCTAssertNotNil(f(2.0).bubble)
        XCTAssertNil(f(30).bubble, "реплика дочитана — пузыря нет")
        XCTAssertEqual(f(60.2).phase, "leave")
        XCTAssertTrue(f(61).done)
    }

    func testWindowSmearFillsThenDrains() {
        func cover(_ p: CGFloat) -> CGFloat {
            guard let s = Transitions.windowSmear(window, progress: p, seed: 5) else { return 0 }
            return s.columns.reduce(0) { $0 + $1.w * max(0, min(1, $1.bottom) - min(1, $1.top)) }
        }
        XCTAssertNil(Transitions.windowSmear(window, progress: 0, seed: 5))
        XCTAssertNil(Transitions.windowSmear(window, progress: 1, seed: 5))
        XCTAssertGreaterThan(cover(0.45), 0.6, "к середине полоса капель заполнена")
        XCTAssertLessThan(cover(0.15), cover(0.45), "натекает")
        XCTAssertLessThan(cover(0.95), 0.2, "к концу стекло")
        for p in stride(from: CGFloat(0.05), to: 1, by: 0.05) {
            for c in Transitions.windowSmear(window, progress: p, seed: 5)?.columns ?? [] {
                XCTAssertLessThanOrEqual(c.bottom, 1.13, "капли не дальше 12 % ниже окна")
                XCTAssertLessThanOrEqual(c.top, c.bottom)
            }
        }
        XCTAssertEqual(Transitions.windowSmear(window, progress: 0.4, seed: 5), Transitions.windowSmear(window, progress: 0.4, seed: 5))
    }

    func testSaysGloatAndEnd() {
        var w = SceneWatch(window: window, says: [SceneSay(at: WatchTimeline.firstSay, chars: 26), SceneSay(at: 6, chars: 10)])
        let g = geometry()
        var o = options(w)
        func f(_ t: Double) -> SceneFrame { SceneTimeline.frame(.perch, t: t, geometry: g, clips: clips, options: o) }
        XCTAssertEqual(f(6.3).bubble?.typed, Int(0.3 * 18), "вторая реплика печатается с 6-й секунды")
        XCTAssertEqual(f(5.9).bubble?.glitch, true, "первая рассыпается перед второй")
        // Доработала на 8-й: злорадство (прищур, дрожь) и уход.
        w.says.append(SceneSay(at: 8, chars: 29))
        w.gloatAt = 8
        o = options(w)
        let leave = 8 + WatchTimeline.gloatLen
        XCTAssertEqual(SceneTimeline.duration(.perch, o), leave + WatchTimeline.leaveLen, accuracy: 1e-9)
        let a = f(8.5), b = f(8.6)
        XCTAssertEqual(a.phase, "gloat")
        XCTAssertEqual(a.clip, SceneClip.slits)
        XCTAssertNotEqual(a.eyes, b.eyes, "дрожит")
        XCTAssertGreaterThanOrEqual(a.glitch, 1)
        XCTAssertNotNil(a.bubble, "и говорит")
        XCTAssertEqual(f(leave + 0.1).phase, "leave")
        // Закрыли сессию — уход с того момента.
        var e = SceneWatch(window: window, says: [SceneSay(at: WatchTimeline.firstSay, chars: 26)])
        e.end = 4
        o = options(e)
        XCTAssertEqual(f(4.1).phase, "leave")
        XCTAssertTrue(f(4 + WatchTimeline.leaveLen + 0.01).done)
    }

    func testWatchDrawsOnlyOnChanges() {
        let w = SceneWatch(window: window, says: [SceneSay(at: WatchTimeline.firstSay, chars: 26), SceneSay(at: 20, chars: 12)])
        let o = options(w)
        let g = geometry()
        let calm = SceneTimeline.calm(.perch, o)!
        XCTAssertEqual(calm.lowerBound, WatchTimeline.arrive, accuracy: 1e-9)
        var t = calm.lowerBound
        var frames = 0
        var prev = SceneTimeline.frame(.perch, t: t, geometry: g, clips: clips, options: o)
        while t < calm.upperBound {
            let next = t + SceneTimeline.frameInterval(.perch, t: t, options: o)
            var k = t + 1.0 / 96
            while k < min(next, calm.upperBound) - 0.002 {
                let f = SceneTimeline.frame(.perch, t: k, geometry: g, clips: clips, options: o)
                XCTAssertEqual(f.clip, prev.clip, "\(k)")
                XCTAssertEqual(f.glitch, prev.glitch, "\(k)")
                XCTAssertEqual(f.clipT, prev.clipT, accuracy: 1.0 / 6 + 1e-6, "\(k)")
                k += 1.0 / 96
            }
            t = next
            frames += 1
            prev = SceneTimeline.frame(.perch, t: t, geometry: g, clips: clips, options: o)
        }
        let rate = Double(frames) / (calm.upperBound - calm.lowerBound)
        XCTAssertLessThan(rate, 6, "минуту смотрит — кадр по событию, а не 12 fps")
    }

    func testWatchHotspots() {
        let w = SceneWatch(window: window, says: [SceneSay(at: WatchTimeline.firstSay, chars: 26)])
        let o = options(w)
        let g = geometry()
        XCTAssertTrue(SceneLayout.hotspots(.perch, t: 0.7, geometry: g, clips: clips, options: o).isEmpty, "размаз — сквозь")
        XCTAssertEqual(SceneLayout.hotspots(.perch, t: 2.5, geometry: g, clips: clips, options: o).map(\.kind),
                       [.button("bubble"), .button("shoo")])
        XCTAssertEqual(SceneLayout.hotspots(.perch, t: 20, geometry: g, clips: clips, options: o).map(\.kind), [.button("shoo")])
    }
}
