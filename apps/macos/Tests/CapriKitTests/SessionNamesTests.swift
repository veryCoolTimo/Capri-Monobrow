import XCTest
@testable import CapriKit

final class SessionNamesTests: XCTestCase {
    func make(_ id: String, host: String = "quiz", tmux: String?, window: String? = "0", pane: String = "%1",
              cwd: String? = "/home/u/votek", status: SessionStatus = .idle, since: Double = 0, last: Double = 0) -> Session {
        Session(key: SessionKey(host: host, agent: .claude, id: id),
                tmux: tmux.map { TmuxRef(pane: pane, session: $0, window: window) } ?? (tmux == nil && pane.isEmpty ? nil : TmuxRef(pane: pane)),
                cwd: cwd, status: status, confidence: .hook, statusSince: since, lastEventAt: last,
                request: nil, lastMessage: nil, typedInput: nil)
    }

    func testSameFolderDifferentTmuxSessionsAreDistinct() {
        let list = [make("a", tmux: "votek", pane: "%2"), make("b", tmux: "votek2", pane: "%3"), make("c", tmux: "votek3", pane: "%5")]
        let n = SessionNames.names(list)
        XCTAssertEqual(list.map { n[$0.key]!.title }, ["votek", "votek2", "votek3"])
        XCTAssertNil(n[list[0].key]!.detail)
        XCTAssertEqual(n[list[1].key]!.detail, "votek")
        XCTAssertEqual(n[list[1].key]!.full, "votek2 · votek")
    }

    func testSeveralAgentsInOneTmuxSessionShowWindowAndPane() {
        let list = [make("a", tmux: "work", window: "1", pane: "%7", cwd: "/w/app"),
                    make("b", tmux: "work", window: "2", pane: "%9", cwd: "/w/app"),
                    make("c", host: "other", tmux: "work", pane: "%1", cwd: "/w/app")]
        let n = SessionNames.names(list)
        XCTAssertEqual(n[list[0].key]!.detail, "app · 1:%7")
        XCTAssertEqual(n[list[1].key]!.detail, "app · 2:%9")
        // На другом хосте tmux-сессия своя — уточнение по панели не нужно.
        XCTAssertEqual(n[list[2].key]!.detail, "app")
    }

    func testWithoutTmuxTitleIsProject() {
        let s = make("x", tmux: nil, pane: "", cwd: "/srv/site")
        XCTAssertEqual(s.title, "site")
        XCTAssertEqual(SessionNames.names([s])[s.key], SessionName(title: "site"))
    }

    func testOrderIsStableAcrossEventsAndGroupsByStatus() {
        var list = [make("r2", host: "timoserver", tmux: "vfx", pane: "%0", status: .running, last: 50),
                    make("w2", tmux: "quiz", pane: "%6", status: .needsInput, since: 20),
                    make("i1", host: "local", tmux: "notes", pane: "%1", status: .idle, last: 99),
                    make("r1", host: "timoserver", tmux: "archest", pane: "%1", status: .running, last: 10),
                    make("w1", host: "timoserver", tmux: "class", pane: "%2", status: .needsInput, since: 10)]
        let hosts = ["local", "timoserver", "quiz"]
        let order = SessionOrder.sorted(list, hosts: hosts).map(\.key.id)
        XCTAssertEqual(order, ["w1", "w2", "r1", "r2", "i1"])
        // Свежее событие у работающей сессии порядок не меняет.
        list[3].lastEventAt = 1000
        XCTAssertEqual(SessionOrder.sorted(list, hosts: hosts).map(\.key.id), order)
        // Хосты — в порядке настроек.
        let idle = [make("q", tmux: "a", status: .idle), make("l", host: "local", tmux: "z", status: .idle)]
        XCTAssertEqual(SessionOrder.sorted(idle, hosts: hosts).map(\.key.id), ["l", "q"])
    }

    func testPaneListFillsTmuxNameAndFollowsRename() {
        var state = CapriState()
        let e = CapriEvent(v: 1, id: "1", ts: 1, host: "h", agent: .claude, source: "hook", event: "SessionStart",
                           sessionId: "s", cwd: "/p", tmux: TmuxRef(pane: "%3"), data: .object([:]))
        SessionReducer.reduce(&state, .event(host: "h", e, replay: false))
        let key = SessionKey(host: "h", agent: .claude, id: "s")
        XCTAssertNil(state.sessions[key]?.tmux?.session)
        SessionReducer.reduce(&state, .panes(host: "h", [PaneInfo(pane: "%3", session: "votek2", window: "1", command: "claude")], ts: 2))
        XCTAssertEqual(state.sessions[key]?.tmux?.session, "votek2")
        XCTAssertEqual(state.sessions[key]?.tmux?.window, "1")
        SessionReducer.reduce(&state, .panes(host: "h", [PaneInfo(pane: "%3", session: "renamed", window: "1", command: "claude")], ts: 3))
        XCTAssertEqual(state.sessions[key]?.title, "renamed")
    }

    func testSupervisorKeepsCollectorsOnHostChange() {
        let sup = CollectorSupervisor(sources: [.local(), .ssh("a"), .ssh("b")]) { _ in }
        let a = sup.collectors[1]
        let removed = sup.setSources([.local(), .ssh("a"), .ssh("c")])
        XCTAssertEqual(removed, ["b"])
        XCTAssertTrue(sup.collectors[1] === a)
        XCTAssertEqual(sup.collectors.map(\.source.name), ["local", "a", "c"])
    }
}
