import XCTest
@testable import CapriKit

enum Fixtures {
    static let root = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!

    static func text(_ path: String) -> String {
        try! String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    static func events(_ name: String) -> [CapriEvent] {
        text("events/\(name)").split(separator: "\n").map { line in
            guard let e = CapriEvent.decode(line: String(line)) else { fatalError("не разобрал строку из \(name): \(line)") }
            return e
        }
    }

    static func screen(_ name: String) -> [String] {
        text("screens-ansi/\(name).ansi").components(separatedBy: "\n")
    }
}

final class EventDecodingTests: XCTestCase {
    func testAllRecordedEventsDecode() {
        for name in ["stage0-claude-mac.jsonl", "stage0-claude-server.jsonl", "stage0-codex-mac.jsonl",
                     "stage0-codex-server.jsonl", "stage0-claude-mac-stopfailure.jsonl", "stage1-server-live.jsonl"] {
            XCTAssertFalse(Fixtures.events(name).isEmpty, name)
        }
    }

    func testLiveEventCarriesTmuxPane() {
        let e = Fixtures.events("stage1-server-live.jsonl")[0]
        XCTAssertEqual(e.agent, .claude)
        XCTAssertEqual(e.event, "SessionStart")
        XCTAssertEqual(e.tmux?.session, "capri-test-s1claude")
        XCTAssertTrue(e.tmux?.pane.hasPrefix("%") ?? false)
    }

    func testStreamMessages() {
        XCTAssertEqual(StreamMessage.decode(line: #"{"kind":"snapshot-end","ts":1,"now":7}"#), .snapshotEnd(now: 7))
        XCTAssertEqual(StreamMessage.decode(line: #"{"kind":"hello","proto":1,"version":2,"host":"h","now":5}"#),
                       .hello(host: "h", proto: 1, version: 2, now: 5))
        XCTAssertEqual(StreamMessage.decode(line: #"{"kind":"hello","host":"h"}"#), .hello(host: "h", proto: 0, version: 0, now: nil))
        XCTAssertEqual(StreamMessage.decode(line: #"{"kind":"panes","ts":1,"panes":null}"#), .panes(nil))
        let screen = StreamMessage.decode(line: #"{"kind":"screen","ts":5,"pane":"%3","session":"s","command":"bash","agent":"claude","lines":["a"]}"#)
        XCTAssertEqual(screen, .screen(pane: "%3", agent: .claude, lines: ["a"], ts: 5))
        XCTAssertNil(StreamMessage.decode(line: "мусор"))
    }
}

final class ScreenClassifierTests: XCTestCase {
    func classify(_ name: String, _ agent: Agent) -> ScreenState {
        ScreenClassifier.classify(lines: Fixtures.screen(name), agent: agent)
    }

    func testGreySuggestionIsNotTypedText() {
        XCTAssertEqual(classify("claude-fresh-placeholder", .claude), .idle(typed: nil))
        XCTAssertEqual(classify("claude-idle-suggestion", .claude), .idle(typed: nil))
        XCTAssertEqual(classify("codex-fresh-placeholder", .codex), .idle(typed: nil))
        XCTAssertEqual(classify("codex-idle", .codex), .idle(typed: nil))
    }

    func testTypedTextIsDetected() {
        XCTAssertEqual(classify("claude-typed", .claude), .idle(typed: "hello typed text"))
        XCTAssertEqual(classify("codex-typed", .codex), .idle(typed: "hello typed text"))
    }

    func testRunning() {
        XCTAssertEqual(classify("claude-running", .claude), .running)
        XCTAssertEqual(classify("codex-running", .codex), .running)
        XCTAssertEqual(classify("codex-running2", .codex), .running)
    }

    func testPermissionDialogs() {
        guard case .dialog(let c) = classify("claude-permission", .claude) else { return XCTFail() }
        XCTAssertEqual(c.kind, .permission)
        XCTAssertEqual(c.options.first, DialogOption(key: "1", label: "Yes"))
        XCTAssertEqual(c.options.last?.label, "No")
        XCTAssertEqual(c.title, "Do you want to proceed?")
        guard case .dialog(let x) = classify("codex-permission", .codex) else { return XCTFail() }
        XCTAssertEqual(x.kind, .permission)
        XCTAssertEqual(x.options.first?.key, "1")
        XCTAssertTrue(x.options.first?.label.hasPrefix("Yes, proceed") ?? false)
    }

    func testQuestionDialog() {
        guard case .dialog(let q) = classify("claude-ask-question", .claude) else { return XCTFail() }
        XCTAssertEqual(q.kind, .question)
        XCTAssertEqual(q.options.prefix(2).map(\.label), ["Red", "Blue"])
    }

    func testFolderTrustMenuWithoutNumbersIsDialog() {
        // Первый запуск в новой папке: хуков ещё нет, а «❯ No, exit» нельзя принять за набранный текст.
        guard case .dialog(let d) = classify("claude-trust-folder", .claude) else { return XCTFail() }
        XCTAssertEqual(d.kind, .permission)
        XCTAssertEqual(d.options.map(\.label), ["No, exit", "Yes, I trust this folder"])
        XCTAssertEqual(d.options.map(\.key), ["1", "2"])
    }

    func testNumberedListAboveDialogIsNotAnOption() {
        let lines = ["1. first step from the answer", "2. second step", "Do you want to proceed?",
                     "❯ 1. Yes", "  2. No", "Esc to cancel"]
        guard case .dialog(let d) = ScreenClassifier.classify(lines: lines, agent: .claude) else { return XCTFail() }
        XCTAssertEqual(d.options.map(\.label), ["Yes", "No"])
    }

    func testCodexUpdateMenuIsDialog() {
        guard case .dialog(let d) = classify("codex-update", .codex) else { return XCTFail() }
        XCTAssertEqual(d.options.map(\.key), ["1", "2", "3"])
        XCTAssertEqual(d.options[1].label, "Skip")
        XCTAssertTrue(d.title?.contains("Update available") ?? false)
    }

    func testAfterDenialOrEscItIsIdle() {
        XCTAssertEqual(classify("claude-denied", .claude), .idle(typed: nil))
        XCTAssertEqual(classify("claude-interrupted", .claude), .idle(typed: nil))
        XCTAssertEqual(classify("codex-denied", .codex), .idle(typed: nil))
        XCTAssertEqual(classify("codex-interrupted", .codex), .idle(typed: nil))
    }

    func testCodexWorkingLinePushedUpByQueuedMessagesIsStillRunning() {
        var lines = Fixtures.screen("codex-running")
        let composer = lines.lastIndex { $0.contains("›") }!
        lines.insert(contentsOf: ["  ↳ queued: second message", "  ↳ queued: third message", "", "› draft line 1", "  draft line 2"], at: composer)
        XCTAssertEqual(ScreenClassifier.classify(lines: lines, agent: .codex), .running)
    }

    func testBackgroundColourIsNotDim() {
        let l = ScreenClassifier.parseANSI("\u{1B}[48;5;2mtyped\u{1B}[0m")
        XCTAssertEqual(l.dim, [false, false, false, false, false])
        let g = ScreenClassifier.parseANSI("\u{1B}[48;5;90mx")
        XCTAssertEqual(g.dim, [false])
    }

    func testDimAndGreyParsing() {
        let l = ScreenClassifier.parseANSI("\u{1B}[39m❯\u{00A0}\u{1B}[2mTry it\u{1B}[0m x")
        XCTAssertEqual(l.plain, "❯\u{00A0}Try it x")
        XCTAssertEqual(l.dim.filter { $0 }.count, 6)
        let g = ScreenClassifier.parseANSI("\u{1B}[38;5;246mgrey\u{1B}[39mwhite")
        XCTAssertEqual(g.dim, [true, true, true, true, false, false, false, false, false])
    }
}

final class SessionReducerTests: XCTestCase {
    let live = Fixtures.events("stage1-server-live.jsonl")

    func run(_ events: [CapriEvent], into state: inout CapriState, replay: Bool = false) -> [CapriEffect] {
        events.flatMap { SessionReducer.reduce(&state, .event(host: "server", $0, replay: replay)) }
    }

    func session(_ state: CapriState, _ agent: Agent) -> Session {
        state.sessions.values.first { $0.key.agent == agent && !$0.key.id.hasPrefix("pane:") }!
    }

    func testPermissionRequestMakesNeedsInputWithCommand() {
        var state = CapriState()
        let claude = live.filter { $0.agent == .claude }
        let effects = run(Array(claude.prefix(3)), into: &state)
        let s = session(state, .claude)
        XCTAssertEqual(s.status, .needsInput)
        XCTAssertEqual(s.request?.kind, .permission)
        XCTAssertEqual(s.request?.tool, "Bash")
        XCTAssertEqual(s.request?.summary, "date > stamp.txt")
        XCTAssertEqual(effects, [.notifyNeedsInput(s.key)])
        XCTAssertEqual(state.waiting.map(\.key), [s.key])
    }

    func testHookPermissionGetsOptionsFromScreen() {
        var state = CapriState()
        let claude = live.filter { $0.agent == .claude }
        _ = run(Array(claude.prefix(3)), into: &state)
        var s = session(state, .claude)
        let effects = SessionReducer.reduce(&state, .screen(host: "server", pane: s.tmux!.pane, agent: .claude,
                                                            lines: Fixtures.screen("claude-permission"), ts: s.statusSince + 2))
        s = session(state, .claude)
        XCTAssertEqual(s.request?.summary, "date > stamp.txt")      // текст из хука остаётся
        XCTAssertEqual(s.request?.choices.map(\.label).first, "Yes")
        XCTAssertEqual(s.request?.choices.map(\.index), [1, 2, 3, 4])
        XCTAssertEqual(s.confidence, .hook)
        XCTAssertTrue(effects.isEmpty)
    }

    func testFollowingNotificationDoesNotNotifyAgainAndAnswerResumes() {
        var state = CapriState()
        let claude = live.filter { $0.agent == .claude }
        let effects = run(Array(claude.prefix(6)), into: &state)
        XCTAssertEqual(effects.count, 1)
        let s = session(state, .claude)
        XCTAssertEqual(s.status, .idle)
        XCTAssertNil(s.request)
        XCTAssertEqual(s.confidence, .hook)
    }

    func testAskUserQuestionCarriesOptions() {
        var state = CapriState()
        let claude = live.filter { $0.agent == .claude }
        _ = run(Array(claude.prefix(8)), into: &state)
        let s = session(state, .claude)
        XCTAssertEqual(s.status, .needsInput)
        XCTAssertEqual(s.request?.kind, .question)
        XCTAssertEqual(s.request?.options, ["Red", "Blue"])
    }

    func testOneNotificationPerNeedsInputEpisode() {
        var state = CapriState()
        let effects = run(live, into: &state)
        let claude = effects.filter { if case .notifyNeedsInput(let k) = $0 { return k.agent == .claude }; return false }
        let codex = effects.filter { if case .notifyNeedsInput(let k) = $0 { return k.agent == .codex }; return false }
        XCTAssertEqual(claude.count, 3)
        XCTAssertEqual(codex.count, 2)
    }

    func testEscWithoutHookFallsBackToScreen() {
        var state = CapriState()
        _ = run(live.filter { $0.agent == .claude }, into: &state)
        var s = session(state, .claude)
        XCTAssertEqual(s.status, .running, "после Esc у Claude хука нет — по хукам всё ещё работает")
        let pane = s.tmux!.pane
        let t = s.statusSince + 5
        SessionReducer.reduce(&state, .screen(host: "server", pane: pane, agent: .claude, lines: Fixtures.screen("claude-interrupted"), ts: t))
        SessionReducer.reduce(&state, .tick(t + 1))
        XCTAssertEqual(session(state, .claude).status, .running, "ещё не прошла пауза")
        SessionReducer.reduce(&state, .tick(t + SessionReducer.screenIdleGrace))
        s = session(state, .claude)
        XCTAssertEqual(s.status, .idle)
        XCTAssertEqual(s.confidence, .inferred)
    }

    func testDenialFallsBackToScreenButFreshEventWins() {
        var state = CapriState()
        let claude = live.filter { $0.agent == .claude }
        _ = run(Array(claude.prefix(11)), into: &state)   // PermissionRequest touch denied.txt
        let s = session(state, .claude)
        XCTAssertEqual(s.status, .needsInput)
        let t = s.statusSince + 4
        SessionReducer.reduce(&state, .screen(host: "server", pane: s.tmux!.pane, agent: .claude, lines: Fixtures.screen("claude-denied"), ts: t))
        // До истечения паузы пришёл новый промпт — он и решает.
        _ = run([claude[11], claude[12]], into: &state)
        SessionReducer.reduce(&state, .tick(t + 10))
        XCTAssertEqual(session(state, .claude).status, .running)
    }

    func testScreenTakenRightAfterStatusChangeIsIgnored() {
        var state = CapriState()
        _ = run(Array(live.filter { $0.agent == .claude }.prefix(2)), into: &state)  // UserPromptSubmit
        let s = session(state, .claude)
        SessionReducer.reduce(&state, .screen(host: "server", pane: s.tmux!.pane, agent: .claude,
                                              lines: Fixtures.screen("claude-idle-suggestion"), ts: s.statusSince + 0.3))
        SessionReducer.reduce(&state, .tick(s.statusSince + 10))
        XCTAssertEqual(session(state, .claude).status, .running)
    }

    func testLateNotificationDoesNotPinNeedsInputAfterDenial() {
        var state = CapriState()
        let claude = live.filter { $0.agent == .claude }
        _ = run(Array(claude.prefix(3)), into: &state)          // PermissionRequest
        let s = session(state, .claude)
        let pane = s.tmux!.pane
        let screen = Fixtures.screen("claude-denied")
        SessionReducer.reduce(&state, .screen(host: "server", pane: pane, agent: .claude, lines: screen, ts: s.statusSince + 2))
        var late = claude[3]                                     // Notification permission_prompt, на 6 с позже
        late.ts = s.statusSince + 6
        _ = run([late], into: &state)
        SessionReducer.reduce(&state, .tick(s.statusSince + 7))
        XCTAssertEqual(session(state, .claude).status, .needsInput)
        // Неизменный экран переслан повторно — ожидание начинается заново и подтверждается.
        SessionReducer.reduce(&state, .screen(host: "server", pane: pane, agent: .claude, lines: screen, ts: s.statusSince + 12))
        SessionReducer.reduce(&state, .tick(s.statusSince + 12 + SessionReducer.screenIdleGrace))
        XCTAssertEqual(session(state, .claude).status, .idle)
    }

    func testNewSessionInSamePaneEndsPreviousOne() {
        var state = CapriState()
        let claude = live.filter { $0.agent == .claude }
        _ = run(Array(claude.prefix(3)), into: &state)
        var next = claude[0]
        next.sessionId = "new-session"
        next.id = "new-id"
        next.ts = claude[2].ts + 100
        _ = run([next], into: &state)
        let old = state.sessions.values.first { $0.key.id == claude[0].sessionId }!
        XCTAssertEqual(old.status, .ended)
        XCTAssertTrue(state.waiting.isEmpty)
    }

    func testSameMillisecondEventsWithDifferentIdsBothApply() {
        var state = CapriState()
        var a = live[1]; a.id = "a"
        var b = live[2]; b.id = "b"; b.ts = a.ts
        _ = run([a, b], into: &state)
        XCTAssertEqual(session(state, .claude).status, .needsInput)
    }

    func testEndedSessionsExpire() {
        var state = CapriState()
        _ = run(Array(live.filter { $0.agent == .claude }.prefix(3)), into: &state)
        let s = session(state, .claude)
        SessionReducer.reduce(&state, .panes(host: "server", [], ts: s.lastEventAt + 1))
        SessionReducer.reduce(&state, .tick(s.lastEventAt + SessionReducer.endedTTL + 10))
        XCTAssertTrue(state.sessions.isEmpty)
    }

    func testCodexInterruptIsIdle() {
        var state = CapriState()
        _ = run(live.filter { $0.agent == .codex }, into: &state)
        let s = session(state, .codex)
        XCTAssertEqual(s.status, .idle)
        XCTAssertNil(s.request)
    }

    func testCodexTitleTurnNotifyIsIgnored() {
        var state = CapriState()
        let events = Fixtures.events("stage0-codex-server.jsonl")
        _ = run(events, into: &state)
        let ids = Set(state.sessions.keys.map(\.id))
        let notifyIds = Set(events.filter { $0.source == "notify" }.compactMap(\.sessionId))
        XCTAssertEqual(ids.count, 1)
        XCTAssertEqual(notifyIds.subtracting(ids).count, 1, "тред генерации заголовка не стал сессией")
    }

    func testStopFailureIsError() {
        var state = CapriState()
        _ = run(Fixtures.events("stage0-claude-mac-stopfailure.jsonl"), into: &state)
        XCTAssertEqual(state.sessions.values.first?.status, .error)
    }

    func testReplayAfterReconnectChangesNothingAndDoesNotNotify() {
        var state = CapriState()
        _ = run(live, into: &state)
        let snapshot = state.sessions
        let effects = run(live, into: &state, replay: true)
        XCTAssertEqual(effects, [])
        XCTAssertEqual(state.sessions, snapshot)
    }

    func testReplayedNeedsInputShowsButDoesNotNotify() {
        var state = CapriState()
        let effects = run(Array(live.filter { $0.agent == .claude }.prefix(3)), into: &state, replay: true)
        XCTAssertEqual(effects, [])
        XCTAssertEqual(state.waiting.count, 1)
    }

    func testDisconnectKeepsSessionStatus() {
        var state = CapriState()
        _ = run(Array(live.filter { $0.agent == .claude }.prefix(3)), into: &state)
        SessionReducer.reduce(&state, .connection(host: "server", connected: false, ts: 1))
        XCTAssertEqual(state.hosts["server"]?.connected, false)
        XCTAssertEqual(session(state, .claude).status, .needsInput)
    }

    func testPaneGoneEndsSession() {
        var state = CapriState()
        _ = run(Array(live.filter { $0.agent == .claude }.prefix(3)), into: &state)
        SessionReducer.reduce(&state, .panes(host: "server", [PaneInfo(pane: "%99", session: "x", command: "bash")], ts: 2e9))
        XCTAssertEqual(session(state, .claude).status, .ended)
        XCTAssertTrue(state.waiting.isEmpty)
    }

    func testSessionWithoutHooksIsSeenByScreenAndMergedWhenHooksArrive() {
        var state = CapriState()
        let first = live.filter { $0.agent == .claude }
        let pane = first[0].tmux!.pane
        let effects = SessionReducer.reduce(&state, .screen(host: "server", pane: pane, agent: .claude,
                                                            lines: Fixtures.screen("claude-permission"), ts: 100))
        let inferred = SessionKey(host: "server", agent: .claude, id: "pane:\(pane)")
        XCTAssertEqual(state.sessions[inferred]?.status, .needsInput)
        XCTAssertEqual(state.sessions[inferred]?.confidence, .inferred)
        XCTAssertEqual(state.sessions[inferred]?.request?.options.first, "1 Yes")
        XCTAssertEqual(effects, [.notifyNeedsInput(inferred)])
        _ = run([first[0]], into: &state)
        XCTAssertNil(state.sessions[inferred])
        XCTAssertEqual(state.sessions.count, 1)
    }

    func testTypedInputIsTrackedForHookedSession() {
        var state = CapriState()
        _ = run(Array(live.filter { $0.agent == .claude }.prefix(1)), into: &state)
        let s = session(state, .claude)
        SessionReducer.reduce(&state, .screen(host: "server", pane: s.tmux!.pane, agent: .claude,
                                              lines: Fixtures.screen("claude-typed"), ts: s.statusSince + 5))
        XCTAssertEqual(session(state, .claude).typedInput, "hello typed text")
    }
}

final class BackoffTests: XCTestCase {
    func testGrowsToCapAndResetsAfterStableConnection() {
        var b = Backoff(base: 1, cap: 30, stableAfter: 60)
        XCTAssertEqual((0..<7).map { _ in b.next(afterUptime: 1) }, [1, 2, 4, 8, 16, 30, 30])
        XCTAssertEqual(b.next(afterUptime: 120), 1)
    }
}


final class ReplyTests: XCTestCase {
    func waiting(options: [String] = ["1 Yes", "2 No"], typed: String? = nil, status: SessionStatus = .needsInput) -> Session {
        Session(key: SessionKey(host: "h", agent: .claude, id: "s"), tmux: TmuxRef(pane: "%5", session: "x", pid: "42"),
                cwd: "/p", status: status, confidence: .hook, statusSince: 0, lastEventAt: 0,
                request: status == .needsInput ? PendingRequest(kind: .permission, summary: "rm x", options: options) : nil,
                lastMessage: nil, typedInput: typed)
    }

    func testChoicesFromScreenAndHook() {
        XCTAssertEqual(PendingRequest(kind: .question, summary: "?", options: ["Red", "Green"]).choices,
                       [ReplyChoice(index: 1, label: "Red"), ReplyChoice(index: 2, label: "Green")])
        XCTAssertEqual(PendingRequest(kind: .permission, summary: "?", options: ["1 Yes", "2 Yes, and don't ask"]).choices.map(\.label),
                       ["Yes", "Yes, and don't ask"])
    }

    func testGuard() {
        let ok = waiting()
        XCTAssertNil(Reply.check(ok, .choose(2), hostConnected: true, hookVersion: 4))
        XCTAssertEqual(Reply.check(ok, .choose(3), hostConnected: true, hookVersion: 4), .noOption)
        XCTAssertEqual(Reply.check(ok, .text("hi"), hostConnected: true, hookVersion: 4), .dialogOpen)
        XCTAssertEqual(Reply.check(ok, .choose(1), hostConnected: false, hookVersion: 4), .hostOffline)
        XCTAssertEqual(Reply.check(ok, .choose(1), hostConnected: true, hookVersion: 3), .hookOutdated)
        XCTAssertEqual(Reply.check(waiting(status: .running), .text("hi"), hostConnected: true, hookVersion: 4), .running)
        XCTAssertEqual(Reply.check(waiting(status: .idle), .choose(1), hostConnected: true, hookVersion: 4), .notWaiting)
        XCTAssertEqual(Reply.check(waiting(typed: "draft", status: .idle), .text("hi"), hostConnected: true, hookVersion: 4), .typed("draft"))
        XCTAssertEqual(Reply.check(waiting(status: .idle), .text("  \n"), hostConnected: true, hookVersion: 4), .empty)
        XCTAssertNil(Reply.check(waiting(status: .idle), .text("сделай X"), hostConnected: true, hookVersion: 4))
        var noTmux = waiting(); noTmux.tmux = nil
        XCTAssertEqual(Reply.check(noTmux, .choose(1), hostConnected: true, hookVersion: 4), .noTmux)
    }

    func testCommandKeepsTextOutOfArgv() {
        let s = waiting(status: .idle)
        XCTAssertEqual(Reply.arguments(s, .text("rm -rf '$HOME'")),
                       ["send", "--pane", "%5", "--agent", "claude", "--pid", "42", "--text-stdin"])
        XCTAssertEqual(Reply.arguments(s, .choose(2)),
                       ["send", "--pane", "%5", "--agent", "claude", "--pid", "42", "--choose", "2", "--expect-stdin"])
        XCTAssertEqual(String(decoding: Reply.stdin(waiting(), .choose(2)), as: UTF8.self), #"{"label":"No","text":"rm x"}"#)
        var bad = s; bad.tmux = TmuxRef(pane: "%5; rm -rf ~")
        XCTAssertNil(Reply.arguments(bad, .choose(1)))
        let ssh = HostSource.ssh("timoserver").command(Reply.arguments(s, .choose(2))!)
        XCTAssertEqual(ssh.last, "python3 ~/.capri/bin/capri-hook send --pane %5 --agent claude --pid 42 --choose 2 --expect-stdin")
        XCTAssertEqual(shellQuote("it's"), "'it'\\''s'")
    }

    func testParseResult() {
        func out(_ s: String) -> HostCommand.Output { HostCommand.Output(status: 0, stdout: s, stderr: "", timedOut: false) }
        XCTAssertNil(Reply.parseResult(out(#"{"ok":true,"sent":"text"}"# + "\n")))
        XCTAssertEqual(Reply.parseResult(out(#"{"ok":false,"reason":"typed","detail":"abc"}"#)), .typed("abc"))
        XCTAssertEqual(Reply.parseResult(out(#"{"ok":false,"reason":"pane-changed"}"#)), .paneChanged)
        XCTAssertEqual(Reply.parseResult(HostCommand.Output(status: 255, stdout: "", stderr: "ssh: connect refused\n", timedOut: false)),
                       .failed("ssh: connect refused"))
    }

    func testHostCommandRunsWithStdin() {
        let done = expectation(description: "run")
        HostCommand.run(["/bin/sh", "-c", "tr a-z A-Z"], stdin: Data("привет abc".utf8)) { out in
            XCTAssertEqual(out.status, 0)
            XCTAssertEqual(out.stdout, "привет ABC")
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testHostCommandFinishesWhenChildKeepsPipeOpen() {
        // Как мастер-соединение ssh: процесс вышел, а его потомок ещё держит stderr.
        let done = expectation(description: "run")
        let started = Date()
        HostCommand.run(["/bin/sh", "-c", "(sleep 5 >&2 &); echo ok"], timeout: 10) { out in
            XCTAssertEqual(out.stdout, "ok\n")
            XCTAssertFalse(out.timedOut)
            XCTAssertLessThan(Date().timeIntervalSince(started), 2)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testHostCommandSurvivesChildThatIgnoresStdin() {
        signal(SIGPIPE, SIG_IGN)       // как в Capri и CapriCollect
        let done = expectation(description: "run")
        HostCommand.run(["/bin/sh", "-c", "exit 3"], stdin: Data(count: 1 << 20)) { out in
            XCTAssertEqual(out.status, 3)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testHostCommandTimeout() {
        let done = expectation(description: "run")
        HostCommand.run(["/bin/sleep", "5"], timeout: 0.5) { out in
            XCTAssertTrue(out.timedOut)
            XCTAssertEqual(Reply.parseResult(out), .unknown)
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
    }
}

final class DeliveryTests: XCTestCase {
    let key = SessionKey(host: "h", agent: .claude, id: "s")

    func session(_ status: SessionStatus, request: PendingRequest? = nil, key: SessionKey? = nil, pane: String = "%5") -> Session {
        Session(key: key ?? self.key, tmux: TmuxRef(pane: pane), cwd: "/p", status: status, confidence: .hook,
                statusSince: 0, lastEventAt: 0, request: request, lastMessage: nil, typedInput: nil)
    }

    func state(_ sessions: [Session]) -> CapriState {
        var st = CapriState()
        for s in sessions { st.sessions[s.key] = s }
        return st
    }

    func testTextConfirmedOnlyWhenSessionRuns() {
        var t = DeliveryTracker()
        t.sending(key)
        XCTAssertTrue(t.isBusy(key))
        t.sent(key, before: session(.idle), action: .text("go"), at: 100)
        XCTAssertTrue(t.isBusy(key))
        // Новый снимок экрана с той же «ждёт задачу» — ещё не доставлено.
        var st = state([session(.idle)])
        XCTAssertEqual(t.update(st.sessions, resolve: st.resolve), [])
        st = state([session(.running)])
        XCTAssertEqual(t.update(st.sessions, resolve: st.resolve), [key])
        XCTAssertEqual(t[key], .delivered)
        t.dropDelivered(key)
        XCTAssertNil(t[key])
    }

    func testChooseConfirmedWhenDialogGoneOrReplaced() {
        let ask = PendingRequest(kind: .permission, summary: "rm x", options: ["1 Yes", "2 No"])
        var t = DeliveryTracker()
        t.sent(key, before: session(.needsInput, request: ask), action: .choose(1), at: 100)
        var st = state([session(.needsInput, request: ask)])
        XCTAssertEqual(t.update(st.sessions, resolve: st.resolve), [])
        st = state([session(.needsInput, request: PendingRequest(kind: .permission, summary: "ls", options: ["1 Yes"]))])
        XCTAssertEqual(t.update(st.sessions, resolve: st.resolve), [key])
    }

    func testTimeoutAndVanishedSessionAreNotDelivered() {
        var t = DeliveryTracker()
        t.sent(key, before: session(.idle), action: .text("go"), at: 100)
        XCTAssertEqual(t.expire(now: 104), [])
        XCTAssertEqual(t.expire(now: 106), [key])
        XCTAssertEqual(t[key], .notDelivered)
        XCTAssertFalse(t.isBusy(key))

        t.sent(key, before: session(.idle), action: .text("go"), at: 200)
        let st = state([session(.ended)])
        XCTAssertEqual(t.update(st.sessions, resolve: st.resolve), [])
        XCTAssertEqual(t[key], .notDelivered)
    }

    func testPaneSessionMergedIntoHookedOne() {
        let paneKey = SessionKey(host: "h", agent: .claude, id: "pane:%5")
        var t = DeliveryTracker()
        t.sent(paneKey, before: session(.idle, key: paneKey), action: .text("go"), at: 100)
        let st = state([session(.running)])           // хуки пришли из той же панели
        XCTAssertEqual(st.resolve(paneKey), key)
        XCTAssertNil(st.resolve(SessionKey(host: "other", agent: .claude, id: "pane:%5")))
        XCTAssertEqual(t.update(st.sessions, resolve: st.resolve), [key])
        XCTAssertNil(t[paneKey])
    }
}
