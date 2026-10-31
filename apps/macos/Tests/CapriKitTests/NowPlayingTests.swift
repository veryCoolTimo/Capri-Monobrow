import XCTest
@testable import CapriKit

/// Обезличенные словари уведомлений Spotify и Музыки.
final class NowPlayingTests: XCTestCase {
    let spotifyPlaying: [AnyHashable: Any] = [
        "Player State": "Playing", "Name": "Track A", "Artist": "Artist A", "Album": "Album A",
        "Track ID": "spotify:track:0000000000000000000001", "Duration": NSNumber(value: 215_000),
        "Playback Position": NSNumber(value: 1.5),
    ]

    func testSpotifyPlayingPausedStopped() {
        guard case .playing(let t) = NowPlayingParser.parse(source: .spotify, userInfo: spotifyPlaying) else { return XCTFail() }
        XCTAssertEqual(t.line, "Artist A — Track A")
        XCTAssertEqual(t.duration, 215, accuracy: 0.001)
        XCTAssertEqual(t.kind, .song)
        var paused = spotifyPlaying
        paused["Player State"] = "Paused"
        guard case .paused = NowPlayingParser.parse(source: .spotify, userInfo: paused) else { return XCTFail() }
        XCTAssertEqual(NowPlayingParser.parse(source: .spotify, userInfo: ["Player State": "Stopped"]), .stopped)
        XCTAssertEqual(NowPlayingParser.parse(source: .spotify, userInfo: [:]), .stopped)
    }

    func testMusicNumbersOfAnyType() {
        for total in [NSNumber(value: 200_000), 200_000 as Any, 200_000.0 as Any, "200000" as Any] {
            let info: [AnyHashable: Any] = ["Player State": "Playing", "Name": "Song", "Artist": "Band", "Album": "LP",
                                            "Total Time": total, "PersistentID": NSNumber(value: 1234)]
            guard case .playing(let t) = NowPlayingParser.parse(source: .music, userInfo: info) else { return XCTFail() }
            XCTAssertEqual(t.duration, 200, accuracy: 0.001)
            XCTAssertEqual(t.id, "1234")
        }
        // Секунды остаются секундами.
        let secs: [AnyHashable: Any] = ["Player State": "Playing", "Name": "S", "Artist": "B", "Total Time": 180]
        guard case .playing(let t) = NowPlayingParser.parse(source: .music, userInfo: secs) else { return XCTFail() }
        XCTAssertEqual(t.duration, 180)
    }

    func testAdsAndEpisodes() {
        var ad = spotifyPlaying
        ad["Track ID"] = "spotify:ad:000000000000000000000a"
        guard case .playing(let a) = NowPlayingParser.parse(source: .spotify, userInfo: ad) else { return XCTFail() }
        XCTAssertEqual(a.kind, .ad)
        XCTAssertEqual(a.line, "реклама")
        let blank: [AnyHashable: Any] = ["Player State": "Playing", "Name": "", "Artist": "", "Track ID": ""]
        guard case .playing(let b) = NowPlayingParser.parse(source: .spotify, userInfo: blank) else { return XCTFail() }
        XCTAssertEqual(b.kind, .ad)
        var ep = spotifyPlaying
        ep["Track ID"] = "spotify:episode:000000000000000000000e"
        ep["Artist"] = ""
        guard case .playing(let e) = NowPlayingParser.parse(source: .spotify, userInfo: ep) else { return XCTFail() }
        XCTAssertEqual(e.kind, .podcast)
        XCTAssertEqual(e.line, "подкаст · Track A")
    }

    func testStateChangesAndSilence() {
        let a = Track(source: .spotify, id: "spotify:track:a", name: "A", artist: "X")
        let b = Track(source: .spotify, id: "spotify:track:b", name: "B", artist: "X")
        var s = NowPlayingState(now: 0)
        // Через 5 мин после запуска — тишина короткая.
        XCTAssertEqual(s.apply(.playing(a), now: 300), .started(afterSilence: false))
        XCTAssertEqual(s.apply(.playing(a), now: 310), .none)
        XCTAssertEqual(s.apply(.playing(b), now: 400), .changed)
        XCTAssertEqual(s.apply(.paused(b), now: 500), .paused)
        XCTAssertEqual(s.display(now: 503), b)
        XCTAssertNil(s.display(now: 506))
        XCTAssertEqual(s.apply(.playing(b), now: 600), .started(afterSilence: false))
        XCTAssertEqual(s.apply(.stopped, now: 700), .stopped)
        XCTAssertNil(s.display(now: 700))
        XCTAssertEqual(s.apply(.stopped, now: 701), .none)
        XCTAssertEqual(s.apply(.playing(a), now: 700 + 601), .started(afterSilence: true))
    }

    func testRevealFourSecondsAfterStartOrChange() {
        let a = Track(source: .spotify, id: "spotify:track:a", name: "A", artist: "X")
        let b = Track(source: .spotify, id: "spotify:track:b", name: "B", artist: "X")
        var s = NowPlayingState(now: 0)
        XCTAssertFalse(s.revealed(now: 1))
        _ = s.apply(.playing(a), now: 100)
        XCTAssertEqual(s.revealUntil, 100 + NowPlayingState.revealSeconds)
        XCTAssertTrue(s.revealed(now: 103.9))
        XCTAssertFalse(s.revealed(now: 104))
        // Тот же трек ещё раз (позиция, громкость) — не смена, строка не всплывает.
        _ = s.apply(.playing(a), now: 110)
        XCTAssertFalse(s.revealed(now: 110))
        _ = s.apply(.playing(b), now: 120)
        XCTAssertTrue(s.revealed(now: 121))
        // Пауза не продлевает показ, продолжение после паузы — показывает снова.
        _ = s.apply(.paused(b), now: 130)
        XCTAssertFalse(s.revealed(now: 130))
        _ = s.apply(.playing(b), now: 140)
        XCTAssertTrue(s.revealed(now: 141))
        _ = s.apply(.stopped, now: 142)
        XCTAssertNil(s.revealUntil)
        XCTAssertFalse(s.revealed(now: 142))
    }
}
