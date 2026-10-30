import XCTest
@testable import CapriKit

final class CodexProtocolTests: XCTestCase {
    /// Входящие сообщения записанного обмена (спайк Этапа 0) — строками, как их отдаёт app-server.
    static func incoming() -> [String] {
        Fixtures.text("codex-app-server/spike-turn.jsonl").split(separator: "\n").compactMap { line in
            guard let d = line.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  o["dir"] as? String == "in", let msg = o["msg"],
                  let raw = try? JSONSerialization.data(withJSONObject: msg) else { return nil }
            return String(decoding: raw, as: UTF8.self)
        }
    }

    func testRecordedExchangeDecodes() {
        let msgs = Self.incoming().compactMap(CodexMessage.decode)
        XCTAssertEqual(msgs.count, Self.incoming().count)
        XCTAssertTrue(msgs.contains { if case .response(1, _, nil) = $0 { return true }; return false })
        XCTAssertTrue(msgs.contains { if case .notification("turn/completed", _) = $0 { return true }; return false })
    }

    func testAccountLimitsAndModel() {
        var results: [Int: JSONValue] = [:]
        for case let .response(id, result?, _) in Self.incoming().compactMap(CodexMessage.decode) { results[id] = result }
        let account = CodexAccount.parse(results[2])
        XCTAssertEqual(account?.type, "chatgpt")
        XCTAssertEqual(account?.plan, "plus")
        let limits = CodexLimits.parse(results[3])
        XCTAssertEqual(limits?.primary?.usedPercent, 18)
        XCTAssertEqual(limits?.primary?.windowMinutes, 300)
        XCTAssertEqual(limits?.secondary?.windowMinutes, 10080)
        XCTAssertEqual(limits?.reached, false)
        let model = CodexModel.pick(results[4])
        XCTAssertEqual(model?.id, "gpt-5.6-sol")
        XCTAssertEqual(model?.effort, "low")
        XCTAssertNil(CodexAccount.parse(.object(["account": .null, "requiresOpenaiAuth": .bool(true)])))
    }

    func testTurnCollectorGetsFinalAnswer() {
        let msgs = Self.incoming().compactMap(CodexMessage.decode)
        var threadId: String?
        for case let .notification("thread/started", p) in msgs { threadId = p["thread"]?["id"]?.string }
        guard let tid = threadId else { return XCTFail("нет thread/started") }
        var c = CodexTurnCollector(threadId: tid)
        var outcome: CodexTurnCollector.Outcome?
        for case let .notification(m, p) in msgs where outcome == nil { outcome = c.apply(method: m, params: p) }
        XCTAssertEqual(outcome, .completed("pong"))
        // Чужой тред не учитывается.
        var other = CodexTurnCollector(threadId: "other")
        XCTAssertNil(msgs.compactMap { if case let .notification(m, p) = $0 { return other.apply(method: m, params: p) }; return nil }.first)
    }

    func testToolCallFailsTheTurn() {
        var c = CodexTurnCollector(threadId: "t")
        XCTAssertNil(c.apply(method: "item/started", params: .object(["threadId": .string("t"), "item": .object(["type": .string("reasoning")])])))
        let r = c.apply(method: "item/started", params: .object(["threadId": .string("t"), "item": .object(["type": .string("commandExecution")])]))
        guard case .failed(let m)? = r else { return XCTFail("ход с инструментом не прерван") }
        XCTAssertTrue(m.contains("commandExecution"))
    }

    func testTurnFailure() {
        var c = CodexTurnCollector(threadId: "t")
        XCTAssertNil(c.apply(method: "error", params: .object(["threadId": .string("t"), "willRetry": .bool(true),
                                                              "error": .object(["message": .string("retrying")])])))
        XCTAssertEqual(c.apply(method: "error", params: .object(["threadId": .string("t"), "willRetry": .bool(false),
                                                                 "error": .object(["message": .string("quota")])])), .failed("quota"))
    }

    func testServerRequestAndEncoding() {
        let req = CodexMessage.decode(#"{"id":"abc","method":"item/commandExecution/requestApproval","params":{}}"#)
        XCTAssertEqual(req, .request(id: .string("abc"), method: "item/commandExecution/requestApproval", params: .object([:])))
        let err = CodexMessage.decode(#"{"id":7,"error":{"code":-1,"message":"nope"}}"#)
        XCTAssertEqual(err, .response(id: 7, result: nil, error: "nope"))
        let data = CodexMessage.encode(method: "turn/start", params: .object(["a": .bool(true)]), id: 3)
        XCTAssertEqual(data.last, 0x0A)
        XCTAssertEqual(CodexMessage.decode(String(decoding: data.dropLast(), as: UTF8.self)),
                       .request(id: .number(3), method: "turn/start", params: .object(["a": .bool(true)])))
    }

    func testBinaryChoice() {
        let home = "/Users/u"
        XCTAssertEqual(CodexBinary.find(override: nil, home: home) { $0 == "\(home)/.local/bin/codex" }, "\(home)/.local/bin/codex")
        XCTAssertEqual(CodexBinary.find(override: nil, home: home) { _ in true }, "/opt/homebrew/bin/codex")
        XCTAssertNil(CodexBinary.find(override: "/nope", home: home) { _ in true == false })
        XCTAssertTrue(CodexBinary.serverArgs.contains("features.shell_tool=false"))
        XCTAssertTrue(CodexBinary.serverArgs.contains("features.hooks=false"))
        XCTAssertTrue(CodexBinary.serverArgs.contains(#"web_search="disabled""#))
    }
}

final class RedactorTests: XCTestCase {
    func testSecretsAreRemoved() {
        let text = """
        export OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwxyz123456
        curl -H "Authorization: Bearer abcdefghijklmnop1234567890" https://user:hunter2@example.com/x
        token: ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789
        mail me at someone.private@example.org
        aws AKIAABCDEFGHIJKLMNOP and sha 0123456789abcdef0123456789abcdef01
        password = "correct horse"
        """
        let out = Redactor.redact(text)
        for secret in ["sk-proj-abc", "abcdefghijklmnop1234567890", "hunter2", "ghp_ABC", "someone.private@example.org",
                       "AKIAABCDEFGHIJKLMNOP", "0123456789abcdef0123456789abcdef01", "correct horse"] {
            XCTAssertFalse(out.contains(secret), "осталось: \(secret)\n\(out)")
        }
    }

    func testOrdinaryTextSurvives() {
        let text = "Run npm test in /home/u/proj/apps/macos/Sources/Kit — author: Alex, 3 files changed, session capri-test-session-for-reply-2"
        XCTAssertEqual(Redactor.redact(text), text)
    }

    func testPromptsAreRedacted() {
        var s = Session(key: SessionKey(host: "host-a", agent: .claude, id: "x"), tmux: nil, cwd: "/srv/app", status: .needsInput,
                        confidence: .hook, statusSince: 0, lastEventAt: 0, request: nil, lastMessage: nil, typedInput: nil)
        s.request = PendingRequest(kind: .permission, tool: "Bash", summary: "curl -H 'Authorization: Bearer abcdefghijklmnopqrstu' x",
                                   options: ["1 Yes", "2 No"])
        let p = CodexPrompts.summary(s, screen: ["\u{1B}[1mDB_PASSWORD=s3cr3t-value\u{1B}[0m", "", "Do you want to proceed?"])
        XCTAssertFalse(p.contains("abcdefghijklmnopqrstu"))
        XCTAssertFalse(p.contains("s3cr3t-value"))
        XCTAssertFalse(p.contains("\u{1B}"))
        XCTAssertTrue(p.contains("Do you want to proceed?"))
        XCTAssertTrue(p.contains("1. Yes; 2. No"))
    }

    func testMoreSecretShapes() {
        let text = """
        mysql -u root -p'Sup3rS3cret' db
        tool --password hunter22 --token abc123
        "api_key": "plainsecretvalue"
        Cookie: session=abcdef; other=1
        sk_live_ABCDEF1234567890xyz
        123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawZ
        machine example.org login bob password pw123
        """
        let out = Redactor.redact(text)
        for secret in ["Sup3rS3cret", "hunter22", "abc123", "plainsecretvalue", "session=abcdef", "sk_live_ABC",
                       "AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawZ", "pw123"] {
            XCTAssertFalse(out.contains(secret), "осталось: \(secret)\n\(out)")
        }
    }

    func testWrappedTokenIsJoinedBeforeRedaction() {
        let token = "ghp_" + String(repeating: "A1b2", count: 10)
        let width = 50
        let line = "export GH=" + token + " && echo done   "
        let rows = stride(from: 0, to: line.count, by: width).map { i -> String in
            let start = line.index(line.startIndex, offsetBy: i)
            return String(line[start..<(line.index(start, offsetBy: width, limitedBy: line.endIndex) ?? line.endIndex)])
        } + ["\u{276F} "]
        let out = CodexPrompts.screenText(rows)
        XCTAssertFalse(out.contains("A1b2A1b2"), out)
    }

    func testPrivateHostsStayOutOfChat() {
        func s(_ host: String, _ summary: String) -> Session {
            Session(key: SessionKey(host: host, agent: .claude, id: host), tmux: nil, cwd: "/srv/\(host)", status: .needsInput,
                    confidence: .hook, statusSince: 0, lastEventAt: 0,
                    request: PendingRequest(kind: .permission, summary: summary), lastMessage: nil, typedInput: nil)
        }
        let secret = HistoryEntry(id: 1, ts: 0, kind: .info, text: "SECRET HISTORY")
        let p = Assistant.prompt(question: "что ждёт?", sessions: [s("prod", "rm -rf /data/clients"), s("dev", "npm test")],
                                 private: ["prod"], history: { $0.key.host == "prod" ? [secret] : [] }, screens: { _ in ["SCREEN LINE"] }).text
        XCTAssertFalse(p.contains("rm -rf"))
        XCTAssertFalse(p.contains("SECRET HISTORY"))
        XCTAssertTrue(p.contains("prod"))
        XCTAssertTrue(p.contains("npm test"))
        XCTAssertEqual(p.components(separatedBy: "SCREEN LINE").count, 2, "экран только у не скрытого хоста")
    }

    func testCleanSummary() {
        XCTAssertEqual(CodexPrompts.cleanSummary("\n«Просит удалить dist/ — безопасно»\nвторая строка"), "Просит удалить dist/ — безопасно")
        XCTAssertEqual(CodexPrompts.cleanSummary("- пункт"), "пункт")
        XCTAssertNil(CodexPrompts.cleanSummary("  \n "))
        XCTAssertEqual(CodexPrompts.cleanSummary(String(repeating: "я", count: 200))?.count, 120)
    }
}

/// CodexClient против поддельного app-server (python3): ответы, ошибки, уведомления, отказ на одобрение, выход.
final class CodexClientTests: XCTestCase {
    static let fake = #"""
import json, sys
for line in sys.stdin:
    m = json.loads(line)
    if "id" in m and "method" not in m:
        print(json.dumps({"method": "seen/reply", "params": m}), flush=True); continue
    meth = m.get("method")
    if meth == "boom":
        print(json.dumps({"id": m["id"], "error": {"code": 1, "message": "boom"}}), flush=True)
    elif meth == "ask":
        print(json.dumps({"id": "srv-1", "method": "item/commandExecution/requestApproval", "params": {}}), flush=True)
        print(json.dumps({"id": m["id"], "result": {}}), flush=True)
    elif meth == "silent":
        pass
    elif meth == "die":
        sys.stderr.write("bye\n"); sys.stderr.flush(); sys.exit(3)
    elif "id" in m:
        print(json.dumps({"method": "note", "params": {"x": 1}}), flush=True)
        print(json.dumps({"id": m["id"], "result": {"echo": meth, "params": m.get("params")}}), flush=True)
"""#

    func makeClient() throws -> CodexClient {
        let c = CodexClient(executable: "/usr/bin/python3", arguments: ["-c", Self.fake], environment: ["PATH": "/usr/bin:/bin"])
        try c.start()
        return c
    }

    func wait(_ timeout: Double = 5, until: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !until() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    func testCallsNotificationsAndErrors() throws {
        let c = try makeClient()
        defer { c.stop() }
        var notes: [String] = []
        c.onNotification = { m, _ in notes.append(m) }
        var echo: JSONValue?
        var err: CodexError?
        var timedOut: CodexError?
        c.call("hello", .object(["a": .string("б")])) { r in echo = try? r.get() }
        c.call("boom") { r in if case .failure(let e) = r { err = e } }
        c.call("silent", timeout: 0.3) { r in if case .failure(let e) = r { timedOut = e } }
        wait { echo != nil && err != nil && timedOut != nil }
        XCTAssertEqual(echo?["echo"]?.string, "hello")
        XCTAssertEqual(echo?["params"]?["a"]?.string, "б")
        XCTAssertEqual(err, .server("boom"))
        XCTAssertEqual(timedOut, .timeout)
        XCTAssertTrue(notes.contains("note"))
    }

    func testApprovalRequestsAreDeclined() throws {
        let c = try makeClient()
        defer { c.stop() }
        var reply: JSONValue?
        c.onNotification = { m, p in if m == "seen/reply" { reply = p } }
        c.call("ask") { _ in }
        wait { reply != nil }
        XCTAssertEqual(reply?["id"]?.string, "srv-1")
        XCTAssertEqual(reply?["result"]?["decision"]?.string, "decline")
    }

    func testExitFailsPendingAndReports() throws {
        let c = try makeClient()
        var exitTail: String?
        var pending: CodexError?
        c.onExit = { exitTail = $0 }
        c.call("silent", timeout: 10) { r in if case .failure(let e) = r { pending = e } }
        c.notify("die")
        wait { exitTail != nil && pending != nil }
        XCTAssertEqual(exitTail, "bye")
        if case .exited? = pending {} else { XCTFail("ожидание не снято: \(String(describing: pending))") }
        XCTAssertFalse(c.isRunning)
        // stop() после выхода и повторный вызов — без падений.
        var after: CodexError?
        c.call("hello") { r in if case .failure(let e) = r { after = e } }
        XCTAssertEqual(after, .notRunning)
        c.stop()
    }
}

final class AssistantTests: XCTestCase {
    func session(_ id: String, tmux: String, status: SessionStatus = .idle) -> Session {
        Session(key: SessionKey(host: "h", agent: .claude, id: id), tmux: TmuxRef(pane: "%\(id.count)", session: tmux),
                cwd: "/w/votek", status: status, confidence: .hook, statusSince: 0, lastEventAt: 0,
                request: status == .needsInput ? PendingRequest(kind: .question, summary: "Какой формат?", options: ["1 JSON", "2 CSV"]) : nil,
                lastMessage: "готово: тесты зелёные", typedInput: nil)
    }

    func testPromptNamesSessionsWithRefsHistoryAndMentionedScreens() {
        let a = session("a", tmux: "votek"), b = session("bb", tmux: "votek2", status: .needsInput)
        let token = "ghp_" + String(repeating: "x", count: 36)
        let hist = HistoryEntry(id: 1, ts: 0, kind: .info, text: "запустила деплой \(token)")
        let p = Assistant.prompt(question: "что сделала votek?", sessions: [a, b],
                                 history: { $0.key.id == "a" ? [hist] : [] }, screens: { ["экран \($0.key.id)"] })
        XCTAssertEqual(p.refs, ["S1": a.key, "S2": b.key])
        XCTAssertTrue(p.text.contains("S1 · votek ·"), p.text)
        XCTAssertTrue(p.text.contains("запустила деплой"))
        XCTAssertFalse(p.text.contains(token), "история проходит через Redactor")
        XCTAssertTrue(p.text.contains("экран a"), "упомянутая в вопросе сессия — с экраном")
        XCTAssertTrue(p.text.contains("экран bb"), "ждущая — с экраном")
    }

    func testPrivateHostsGetNoRefsAndNoFolder() {
        var prod = session("p", tmux: "votek3")
        prod.key.host = "quiz"
        let p = Assistant.prompt(question: "ответь votek3", sessions: [prod, session("a", tmux: "dev")], private: ["quiz"],
                                 history: { _ in [] }, screens: { _ in ["SCREEN"] })
        XCTAssertEqual(Array(p.refs.keys), ["S1"])
        XCTAssertEqual(p.refs["S1"]?.id, "a")
        XCTAssertTrue(p.text.contains("— · votek3 · хост quiz"))
        XCTAssertFalse(p.text.contains("готово: тесты зелёные · хост quiz"))
    }

    func testParseExtractsActionsAndCleansText() {
        let r = Assistant.parse("""
        Отвечу votek2 форматом JSON.
        <capri-action>{"session":"S2","choose":1}</capri-action>
        <capri-action>{"session":"S1","text":"запусти тесты"}</capri-action>
        <capri-action>{"session":"S3","rm":"-rf"}</capri-action>
        """)
        XCTAssertEqual(r.text, "Отвечу votek2 форматом JSON.")
        XCTAssertEqual(r.proposals, [Assistant.Proposal(ref: "S2", action: .choose(1)),
                                     Assistant.Proposal(ref: "S1", action: .text("запусти тесты"))])
        XCTAssertTrue(Assistant.parse("<capri-action>{\"session\":\"S1\",\"choose\":42}</capri-action>").proposals.isEmpty)
        XCTAssertTrue(Assistant.parse("<capri-action>{\"session\":\"S1\",\"choose\":true}</capri-action>").proposals.isEmpty)
    }

    func testStreamingHidesUnfinishedActionBlock() {
        XCTAssertEqual(Assistant.visible("Готово. <capri-action>{\"session\":\"S"), "Готово.")
        XCTAssertEqual(Assistant.visible("Готово. <capr"), "Готово.")
        XCTAssertEqual(Assistant.visible("a < b"), "a < b")
    }

    func testLocalAnswerListsWaiting() {
        let w = session("w", tmux: "votek2", status: .needsInput), r = session("r", tmux: "vfx", status: .running)
        let text = Assistant.localAnswer(sessions: [w, r], names: [:])
        XCTAssertTrue(text.contains("votek2 — Какой формат?"), text)
        XCTAssertTrue(text.contains("Работают: vfx"), text)
        XCTAssertEqual(Assistant.localAnswer(sessions: [], names: [:]), "Никто не ждёт.")
    }
}
