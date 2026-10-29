import XCTest
@testable import CapriKit

final class SessionHistoryTests: XCTestCase {
    func testRecordedClaudeSessionBecomesReadableHistory() {
        var h = SessionHistory()
        let events = Fixtures.events("stage0-claude-mac.jsonl")
        for e in events { h.record(host: "local", event: e) }
        let sid = events.first { $0.sessionId != nil }!.sessionId!
        let list = h.list(SessionKey(host: "local", agent: .claude, id: sid))
        XCTAssertEqual(list.first?.text, "сессия началась")
        XCTAssertTrue(list.contains { $0.text == "получила задачу" })
        XCTAssertTrue(list.contains { $0.kind == .attention })
        // Повтор журнала после переподключения не дублирует строки.
        let count = list.count
        for e in events { h.record(host: "local", event: e) }
        XCTAssertEqual(h.list(SessionKey(host: "local", agent: .claude, id: sid)).count, count)
    }

    func testConsecutiveToolCallsMerge() {
        var h = SessionHistory()
        let key = SessionKey(host: "h", agent: .claude, id: "s")
        func tool(_ name: String, _ ts: Double, id: String) -> CapriEvent {
            CapriEvent(v: 1, id: id, ts: ts, host: "h", agent: .claude, source: "hook", event: "PostToolUse",
                       sessionId: "s", cwd: nil, tmux: nil, data: .object(["tool_name": .string(name)]))
        }
        h.record(host: "h", event: tool("Bash", 1, id: "a"))
        h.record(host: "h", event: tool("Edit", 2, id: "b"))
        h.record(host: "h", event: tool("Bash", 3, id: "c"))
        XCTAssertEqual(h.list(key).count, 1)
        XCTAssertEqual(h.list(key).first?.text, "инструменты ×3: Bash, Edit")
        h.note(key, ts: 4, kind: .reply, text: "ты: да")
        h.record(host: "h", event: tool("Read", 5, id: "d"))
        XCTAssertEqual(h.list(key).map(\.kind), [.tools, .reply, .tools])
    }

    func testHistoryIsBoundedAndPruned() {
        var h = SessionHistory()
        let key = SessionKey(host: "h", agent: .codex, id: "s")
        for i in 0..<(SessionHistory.perSession + 10) { h.note(key, ts: Double(i), kind: .info, text: "\(i)") }
        XCTAssertEqual(h.list(key).count, SessionHistory.perSession)
        XCTAssertEqual(h.list(key).last?.text, "\(SessionHistory.perSession + 9)")
        h.keep(only: [])
        XCTAssertTrue(h.list(key).isEmpty)
    }
}

final class ScreenTextTests: XCTestCase {
    func testDimRunsAndPlainText() {
        let lines = ScreenText.lines(["\u{1B}[1m❯ \u{1B}[0m\u{1B}[2mTry \"fix\"\u{1B}[0m", "plain"])
        XCTAssertEqual(lines[0].plain, "❯ Try \"fix\"")
        XCTAssertEqual(lines[0].runs.map(\.dim), [false, true])
        XCTAssertEqual(lines[1].runs, [.init(text: "plain", dim: false)])
    }

    func testBlankRunsCollapse() {
        XCTAssertEqual(ScreenText.lines(["a", "", "  ", "", "b"]).map(\.plain), ["a", "", "b"])
    }

    func testRecordedScreenHasNoEscapes() {
        for line in ScreenText.lines(Fixtures.screen("claude-trust-folder")) {
            XCTAssertFalse(line.plain.contains("\u{1B}"))
        }
    }
}

final class SessionFilterTests: XCTestCase {
    func testFilters() {
        func s(_ status: SessionStatus) -> Session {
            Session(key: SessionKey(host: "h", agent: .claude, id: status.rawValue), tmux: nil, cwd: nil, status: status,
                    confidence: .hook, statusSince: 0, lastEventAt: 0, request: nil, lastMessage: nil, typedInput: nil)
        }
        let all = [s(.needsInput), s(.running), s(.idle), s(.ended)]
        XCTAssertEqual(all.filter(SessionFilter.waiting.matches).map(\.status), [.needsInput])
        XCTAssertEqual(all.filter(SessionFilter.running.matches).map(\.status), [.running])
        XCTAssertEqual(all.filter(SessionFilter.all.matches).count, 3)
    }
}
