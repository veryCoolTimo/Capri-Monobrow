import XCTest
@testable import CapriKit

/// Повтор неизменного экрана (`screenSame`) — без разбора JSON и без повторной классификации.
final class ScreenDedupTests: XCTestCase {
    let live = Fixtures.events("stage1-server-live.jsonl")
    static let names = ["claude-ask-question", "claude-denied", "claude-fresh-placeholder", "claude-idle-suggestion",
                        "claude-interrupted", "claude-permission", "claude-running", "claude-trust-folder", "claude-typed",
                        "codex-denied", "codex-fresh-placeholder", "codex-idle", "codex-interrupted", "codex-permission",
                        "codex-running", "codex-running2", "codex-typed", "codex-update"]

    func fp(_ s: String) -> (pane: String, ts: Double, payload: Data)? { StreamMessage.screenFingerprint(Data(s.utf8)) }

    // MARK: отпечаток

    func testFingerprintReadsPaneTsAndTail() {
        let line = #"{"kind":"screen","ts":1730000000.125,"pane":"%12","session":"s","command":"node","agent":"claude","pid":"7","lines":["a \"q\" \\ b","❯ "]}"#
        let f = fp(line)
        XCTAssertEqual(f?.pane, "%12")
        XCTAssertEqual(f?.ts, 1730000000.125)
        XCTAssertEqual(f.map { String(decoding: $0.payload, as: UTF8.self) },
                       #""pane":"%12","session":"s","command":"node","agent":"claude","pid":"7","lines":["a \"q\" \\ b","❯ "]}"#)
        // Разбор целиком даёт ту же панель и время.
        XCTAssertEqual(StreamMessage.decode(line: line), .screen(pane: "%12", agent: .claude, lines: ["a \"q\" \\ b", "❯ "], ts: 1730000000.125))
    }

    func testSameScreenLaterGivesSamePayload() {
        let a = fp(#"{"kind":"screen","ts":5,"pane":"%3","agent":"codex","lines":["x"]}"#)
        let b = fp(#"{"kind":"screen","ts":15.5,"pane":"%3","agent":"codex","lines":["x"]}"#)
        let c = fp(#"{"kind":"screen","ts":25,"pane":"%3","agent":"codex","lines":["y"]}"#)
        let d = fp(#"{"kind":"screen","ts":35,"pane":"%3","agent":"claude","lines":["x"]}"#)
        XCTAssertEqual(a?.payload, b?.payload)
        XCTAssertEqual(b?.ts, 15.5)
        XCTAssertNotEqual(a?.payload, c?.payload)
        XCTAssertNotEqual(a?.payload, d?.payload, "сменился агент панели — это другой снимок")
    }

    func testFingerprintRejectsOtherShapes() {
        XCTAssertNil(fp(#"{"kind":"panes","ts":1,"panes":[]}"#))
        XCTAssertNil(fp(#"{"ts":1,"kind":"screen","pane":"%1","lines":[]}"#), "другой порядок полей — обычный разбор")
        XCTAssertNil(fp(#"{"kind":"screen","ts":1,"session":"s","pane":"%1","lines":[]}"#))
        XCTAssertNil(fp(#"{"kind":"screen","ts":"1","pane":"%1","lines":[]}"#))
        XCTAssertNil(fp(#"{"kind":"screen","ts":1,"pane":"%\"1","lines":[]}"#))
        XCTAssertNil(fp(#"{"kind":"screen","ts":1,"pane":"%1"#))
        XCTAssertNil(fp(#"{"kind":"screen","ts":"#))
        XCTAssertNil(fp(""))
        XCTAssertNil(fp("мусор"))
    }

    // MARK: reducer: screenSame ≡ screen с теми же строками

    func run(_ events: [CapriEvent], into state: inout CapriState) {
        for e in events { SessionReducer.reduce(&state, .event(host: "server", e, replay: false)) }
    }

    /// Снимок, затем `repeats` повторов через 2 с с тиками между ними: полный разбор каждого и `screenSame`
    /// должны дать одинаковое состояние и одинаковые эффекты.
    func assertEquivalent(_ start: CapriState, pane: String, agent: Agent?, lines: [String], t0: Double,
                          repeats: Int = 6, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        var full = start, same = start
        var fullFx: [CapriEffect] = [], sameFx: [CapriEffect] = []
        fullFx += SessionReducer.reduce(&full, .screen(host: "server", pane: pane, agent: agent, lines: lines, ts: t0))
        sameFx += SessionReducer.reduce(&same, .screen(host: "server", pane: pane, agent: agent, lines: lines, ts: t0))
        for k in 1...repeats {
            let t = t0 + Double(k) * 2
            fullFx += SessionReducer.reduce(&full, .screen(host: "server", pane: pane, agent: agent, lines: lines, ts: t))
            sameFx += SessionReducer.reduce(&same, .screenSame(host: "server", pane: pane, ts: t))
            fullFx += SessionReducer.reduce(&full, .tick(t + 1))
            sameFx += SessionReducer.reduce(&same, .tick(t + 1))
        }
        XCTAssertEqual(full, same, label, file: file, line: line)
        XCTAssertEqual(fullFx, sameFx, label, file: file, line: line)
    }

    func testScreenSameMatchesFullScreenOnAllFixtures() {
        let claude = live.filter { $0.agent == .claude }
        // Сессия из хуков: работает (1 событие — SessionStart… берём префиксы с разными статусами) и ждёт разрешения.
        var starts: [(String, CapriState)] = []
        for n in [1, 2, 3, 6, 8] {
            var s = CapriState()
            run(Array(claude.prefix(n)), into: &s)
            starts.append(("claude×\(n)", s))
        }
        for name in Self.names {
            let lines = Fixtures.screen(name)
            let agent: Agent = name.hasPrefix("codex") ? .codex : .claude
            for (label, start) in starts {
                let s = start.sessions.values.first { !$0.key.id.hasPrefix("pane:") }!
                assertEquivalent(start, pane: s.tmux!.pane, agent: agent, lines: lines, t0: s.statusSince + 2, "\(name) \(label)")
            }
            // Панель без хуков: сессия видна только по экрану.
            assertEquivalent(CapriState(), pane: "%99", agent: agent, lines: lines, t0: 100, "\(name) без хуков")
            assertEquivalent(CapriState(), pane: "%98", agent: nil, lines: lines, t0: 100, "\(name) без агента")
        }
    }

    func testScreenSameWithoutMemoIsIgnored() {
        var state = CapriState()
        XCTAssertEqual(SessionReducer.reduce(&state, .screenSame(host: "server", pane: "%1", ts: 10)), [])
        XCTAssertEqual(state, CapriState())
    }

    func testAgentChangeReclassifiesStoredLines() {
        // Экран codex увиден без хуков как claude-панель, потом пришли хуки codex в эту панель: повтор того же
        // экрана классифицируется для codex — как полный разбор.
        let lines = Fixtures.screen("codex-running")
        let pane = "%42"
        var full = CapriState(), same = CapriState()
        SessionReducer.reduce(&full, .screen(host: "server", pane: pane, agent: .claude, lines: lines, ts: 100))
        SessionReducer.reduce(&same, .screen(host: "server", pane: pane, agent: .claude, lines: lines, ts: 100))
        let start = CapriEvent(v: 1, id: "e1", ts: 101, host: "server", agent: .codex, source: "hook", event: "UserPromptSubmit",
                               sessionId: "codex-1", cwd: "/tmp/p", tmux: TmuxRef(pane: pane), data: .object([:]))
        SessionReducer.reduce(&full, .event(host: "server", start, replay: false))
        SessionReducer.reduce(&same, .event(host: "server", start, replay: false))
        SessionReducer.reduce(&full, .screen(host: "server", pane: pane, agent: .claude, lines: lines, ts: 104))
        SessionReducer.reduce(&same, .screenSame(host: "server", pane: pane, ts: 104))
        XCTAssertEqual(full.sessions, same.sessions)
        XCTAssertEqual(full.screenMemo["server \(pane)"]?.agent, .codex)
        XCTAssertEqual(same.screenMemo["server \(pane)"]?.agent, .codex)
        XCTAssertEqual(same.screenMemo["server \(pane)"]?.screen, ScreenClassifier.classify(lines: lines, agent: .codex))
    }

    func testPanesAndForgetDropMemo() {
        var state = CapriState()
        SessionReducer.reduce(&state, .screen(host: "server", pane: "%1", agent: .claude, lines: ["a"], ts: 1))
        SessionReducer.reduce(&state, .screen(host: "server", pane: "%2", agent: .claude, lines: ["b"], ts: 1))
        SessionReducer.reduce(&state, .screen(host: "mac", pane: "%1", agent: .claude, lines: ["c"], ts: 1))
        SessionReducer.reduce(&state, .panes(host: "server", [PaneInfo(pane: "%2", session: "s", command: "node")], ts: 2))
        XCTAssertEqual(Set(state.screenMemo.keys), ["server %2", "mac %1"])
        // panes == nil (tmux не ответил) — ничего не трогаем.
        SessionReducer.reduce(&state, .panes(host: "server", nil, ts: 3))
        XCTAssertEqual(state.screenMemo.count, 2)
        state.forget(host: "mac")
        XCTAssertEqual(Set(state.screenMemo.keys), ["server %2"])
    }

    func testUnchangedScreenDoesNotTouchSessions() {
        // Повтор неизменного экрана не должен менять сессии (иначе список переиздаётся каждые 10 с на панель).
        for name in ["codex-idle", "claude-running", "codex-permission"] {
            var state = CapriState()
            let agent: Agent = name.hasPrefix("codex") ? .codex : .claude
            SessionReducer.reduce(&state, .screen(host: "server", pane: "%7", agent: agent, lines: Fixtures.screen(name), ts: 100))
            let before = state.sessions
            SessionReducer.reduce(&state, .screenSame(host: "server", pane: "%7", ts: 110))
            SessionReducer.reduce(&state, .screen(host: "server", pane: "%7", agent: agent, lines: Fixtures.screen(name), ts: 120))
            XCTAssertEqual(state.sessions, before, name)
        }
    }
}
