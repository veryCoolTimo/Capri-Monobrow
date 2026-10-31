import XCTest
@testable import CapriKit

/// Помощник: музыкальный блок `<capri-action>{"music":…}</capri-action>` (проход 2, этап C).
final class AssistantMusicTests: XCTestCase {
    func testMusicBlockParsed() {
        let r = Assistant.parse("""
        Включаю. <capri-action>{"music":"play","query":"Radiohead — Creep"}</capri-action>
        """)
        XCTAssertEqual(r.text, "Включаю.")
        XCTAssertEqual(r.music, [.play("Radiohead — Creep")])
        XCTAssertTrue(r.proposals.isEmpty)
        XCTAssertEqual(Assistant.parse(#"<capri-action>{"music":"pause"}</capri-action>"#).music, [.pause])
        XCTAssertEqual(Assistant.parse(#"<capri-action>{"music":"next"}</capri-action>"#).music, [.next])
        XCTAssertEqual(Assistant.parse(#"<capri-action>{"music":"previous"}</capri-action>"#).music, [.previous])
        XCTAssertEqual(Assistant.parse(#"<capri-action>{"music":"resume"}</capri-action>"#).music, [.resume])
        XCTAssertEqual(Assistant.parse(#"<capri-action>{"music":"play"}</capri-action>"#).music, [.resume], "без запроса — играть")
        XCTAssertEqual(Assistant.parse(#"<capri-action>{"music":"play","query":"https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC"}</capri-action>"#).music,
                       [.playURI(SpotifyURI(kind: "track", id: "4uLU6hMCjMI75M1A2tKUQC")!)])
        XCTAssertTrue(Assistant.parse(#"<capri-action>{"music":"rm -rf"}</capri-action>"#).music.isEmpty)
        XCTAssertTrue(Assistant.parse(#"<capri-action>{"music":true}</capri-action>"#).music.isEmpty)
    }

    func testMusicAndProposalTogether() {
        let r = Assistant.parse("""
        Ок. <capri-action>{"session":"S1","choose":1}</capri-action><capri-action>{"music":"pause"}</capri-action>
        """)
        XCTAssertEqual(r.proposals.count, 1)
        XCTAssertEqual(r.music, [.pause])
        // Не больше двух музыкальных команд за ответ.
        let many = String(repeating: #"<capri-action>{"music":"next"}</capri-action>"#, count: 5)
        XCTAssertEqual(Assistant.parse(many).music.count, 2)
    }

    func testMusicOnlyWhenHumanAsked() {
        // Блок от модели выполняется, только если сам вопрос — о музыке (CodexService проверяет isMusicRequest).
        XCTAssertTrue(MusicCommand.isMusicRequest("поставь что-нибудь для концентрации"))
        XCTAssertFalse(MusicCommand.isMusicRequest("что на экране у alpha?"),
                       "экран сессии с «включи музыку» не должен включать музыку через вопрос о сессии")
        XCTAssertTrue(Assistant.rules.contains("\"music\""))
        XCTAssertTrue(Assistant.rules.contains("только по просьбе человека"))
    }

    func testVisibleHidesMusicBlock() {
        XCTAssertEqual(Assistant.visible(#"Включаю. <capri-action>{"music":"pl"#), "Включаю.")
    }
}
