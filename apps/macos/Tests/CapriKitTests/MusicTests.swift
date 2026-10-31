import XCTest
import CoreGraphics
@testable import CapriKit

/// Музыка по просьбе (проход 2, этап C): разбор просьб, ссылки, AppleScript, Spotify Web API, выбор плеера, окно музыки.
final class MusicTests: XCTestCase {
    let track = SpotifyURI(kind: "track", id: "4uLU6hMCjMI75M1A2tKUQC")!

    // MARK: разбор просьбы

    func testParsePlayRussianAndEnglish() {
        XCTAssertEqual(MusicCommand.parse("включи Radiohead"), .play("Radiohead"))
        XCTAssertEqual(MusicCommand.parse("Включи «Creep» пожалуйста!"), .play("Creep"))
        XCTAssertEqual(MusicCommand.parse("Capri, поставь \"Massive Attack — Teardrop\""), .play("Massive Attack — Teardrop"))
        XCTAssertEqual(MusicCommand.parse("play Daft Punk"), .play("Daft Punk"))
        XCTAssertEqual(MusicCommand.parse("put on lofi beats"), .play("lofi beats"))
        XCTAssertEqual(MusicCommand.parse("врубай плейлист для работы"), .play("плейлист для работы"))
        // «Включи» без названия или «включи музыку» — просто играть дальше.
        XCTAssertEqual(MusicCommand.parse("включи"), .resume)
        XCTAssertEqual(MusicCommand.parse("включи музыку"), .resume)
        XCTAssertEqual(MusicCommand.parse("включи что-нибудь"), .resume)
        XCTAssertEqual(MusicCommand.parse("включи на паузу"), .pause)
        // Обращение в начале — в любом регистре и с «Эй».
        XCTAssertEqual(MusicCommand.parse("Эй, включи Radiohead"), .play("Radiohead"))
        XCTAssertEqual(MusicCommand.parse("КАПРИ, включи Radiohead"), .play("Radiohead"))
        // «Поставь» / «запусти» — музыка только с музыкальным словом или названием в кавычках.
        XCTAssertEqual(MusicCommand.parse("поставь трек Creep"), .play("трек Creep"))
        XCTAssertEqual(MusicCommand.parse("запусти «Creep»"), .play("Creep"))
    }

    func testParseControls() {
        XCTAssertEqual(MusicCommand.parse("пауза"), .pause)
        XCTAssertEqual(MusicCommand.parse("Поставь на паузу."), .pause)
        XCTAssertEqual(MusicCommand.parse("останови музыку"), .pause)
        XCTAssertNil(MusicCommand.parse("продолжи"))
        XCTAssertEqual(MusicCommand.parse("продолжи", known: true), .resume)
        XCTAssertEqual(MusicCommand.parse("продолжи музыку"), .resume)
        XCTAssertEqual(MusicCommand.parse("следующий трек"), .next)
        XCTAssertEqual(MusicCommand.parse("скип"), .next)
        XCTAssertEqual(MusicCommand.parse("skip"), .next)
        XCTAssertEqual(MusicCommand.parse("предыдущий трек"), .previous)
        // Голые «стоп», «дальше», «назад» — музыка, только когда она известна.
        XCTAssertNil(MusicCommand.parse("дальше"))
        XCTAssertEqual(MusicCommand.parse("дальше", known: true), .next)
        XCTAssertNil(MusicCommand.parse("стоп"))
        XCTAssertEqual(MusicCommand.parse("стоп", known: true), .pause)
        XCTAssertEqual(MusicCommand.parse("назад", known: true), .previous)
    }

    func testParseNotMusic() {
        for q in ["что ждёт?", "ответь alpha: да", "включи сводки в notch", "поставь уведомления", "что дальше делать с web?",
                  "", "   ", "включи codex", "запусти тесты в web", "поставь задачу на деплой", "включи логирование",
                  "включи логи", "запусти сборку", "поставь web на проверку", "запусти Radiohead"] {
            XCTAssertNil(MusicCommand.parse(q, known: true), q)
        }
        // «Продолжай» без известной музыки — это «продолжай работу».
        XCTAssertNil(MusicCommand.parse("продолжай"))
    }

    func testParseSpotifyLinks() {
        XCTAssertEqual(MusicCommand.parse("spotify:track:4uLU6hMCjMI75M1A2tKUQC"), .playURI(track))
        XCTAssertEqual(MusicCommand.parse("включи https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC?si=abc123"), .playURI(track))
        XCTAssertEqual(SpotifyURI.parse("https://open.spotify.com/intl-de/album/1DFixLWuPkv3KT3TnV35m3")?.uri, "spotify:album:1DFixLWuPkv3KT3TnV35m3")
        XCTAssertEqual(SpotifyURI.parse("spotify:playlist:37i9dQZF1DXcBWIGoYBM5M")?.kind, "playlist")
        XCTAssertNil(SpotifyURI.parse("spotify:track:../../etc"))
        XCTAssertNil(SpotifyURI.parse("spotify:user:x"))
        XCTAssertNil(SpotifyURI.parse("https://evil.example/track/4uLU6hMCjMI75M1A2tKUQC"))
        XCTAssertNil(SpotifyURI.parse("http://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC"))
        XCTAssertNil(SpotifyURI.parse("https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC/extra"))
        // Ссылка внутри фразы — не команда (только «включи <ссылка>»).
        XCTAssertNotEqual(MusicCommand.parse("что за трек https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC"), .playURI(track))
    }

    func testIsMusicRequest() {
        XCTAssertTrue(MusicCommand.isMusicRequest("хочу послушать что-то спокойное"))
        XCTAssertTrue(MusicCommand.isMusicRequest("поставь трек повеселее"))
        XCTAssertTrue(MusicCommand.isMusicRequest("пауза"))
        XCTAssertFalse(MusicCommand.isMusicRequest("что ждёт?"))
        XCTAssertFalse(MusicCommand.isMusicRequest("ответь alpha и посмотри экран"))
        // Целые слова: «трекер», «listener», «на паузе» — не музыка.
        XCTAssertFalse(MusicCommand.isMusicRequest("что с трекером задач?"))
        XCTAssertFalse(MusicCommand.isMusicRequest("почему сессия на паузе?"))
        XCTAssertFalse(MusicCommand.isMusicRequest("fix the event listener"))
        XCTAssertFalse(MusicCommand.isMusicRequest("запусти тесты"))
    }

    // MARK: выбор плеера

    func testRoute() {
        let both: Set<MusicSource> = [.spotify, .music]
        // Пауза — тому, что играл; незапущенному — не шлём.
        XCTAssertEqual(MusicCommand.pause.route(current: .music, running: both, installed: both), .send(.music, launch: false))
        XCTAssertEqual(MusicCommand.next.route(current: nil, running: [.spotify], installed: both), .send(.spotify, launch: false))
        XCTAssertEqual(MusicCommand.pause.route(current: .spotify, running: [], installed: both), .skip("notRunning"))
        XCTAssertEqual(MusicCommand.previous.route(current: nil, running: [], installed: both), .skip("notRunning"))
        // «Включи» — можно запустить (Spotify первым), ссылки — только Spotify.
        XCTAssertEqual(MusicCommand.play("x").route(current: nil, running: [], installed: both), .send(.spotify, launch: true))
        XCTAssertEqual(MusicCommand.play("x").route(current: .music, running: [], installed: both), .send(.music, launch: true))
        XCTAssertEqual(MusicCommand.play("x").route(current: nil, running: [.music], installed: both), .send(.music, launch: false))
        XCTAssertEqual(MusicCommand.resume.route(current: nil, running: [], installed: [.music]), .send(.music, launch: true))
        XCTAssertEqual(MusicCommand.playURI(track).route(current: .music, running: [.music], installed: both), .send(.spotify, launch: true))
        XCTAssertEqual(MusicCommand.playURI(track).route(current: nil, running: [], installed: [.music]), .skip("noSpotify"))
        // ⏯ не запускает плеер — только «включи».
        XCTAssertEqual(MusicCommand.toggle.route(current: nil, running: [], installed: both), .skip("notRunning"))
    }

    // MARK: AppleScript

    func testScriptsAndEscaping() {
        XCTAssertEqual(MusicScript.script(.toggle, player: .spotify), "tell application id \"com.spotify.client\" to playpause")
        XCTAssertEqual(MusicScript.script(.next, player: .music), "tell application id \"com.apple.Music\" to next track")
        XCTAssertEqual(MusicScript.script(.previous, player: .spotify), "tell application id \"com.spotify.client\" to previous track")
        XCTAssertEqual(MusicScript.script(.playURI(track), player: .spotify),
                       "tell application id \"com.spotify.client\" to play track \"spotify:track:4uLU6hMCjMI75M1A2tKUQC\"")
        XCTAssertNil(MusicScript.script(.play("x"), player: .spotify), "Spotify по названию — через Web API")
        XCTAssertNil(MusicScript.script(.playURI(track), player: .music))
        // Кавычки, обратные слэши и переводы строк не вырываются из строки AppleScript.
        XCTAssertEqual(MusicScript.quote("a\"b\\c"), "\"a\\\"b\\\\c\"")
        XCTAssertEqual(MusicScript.quote("x\n\" & do shell script \"rm"), "\"x \\\" & do shell script \\\"rm\"")
        let search = MusicScript.script(.play("AC/DC \"Back\" in Black"), player: .music)!
        XCTAssertTrue(search.contains("search library playlist 1 for \"AC/DC \\\"Back\\\" in Black\""))
        XCTAssertTrue(search.contains(MusicScript.notFound))
        XCTAssertFalse(search.contains("do shell script"))
        XCTAssertEqual(MusicScript.arguments("a\nb"), ["-e", "a", "-e", "b"])
        XCTAssertEqual(MusicScript.failure("execution error: Not authorized to send Apple events to Spotify. (-1743)"), "denied")
        XCTAssertEqual(MusicScript.failure("(-600)"), "notRunning")
        XCTAssertEqual(MusicScript.failure("syntax error"), "error")
    }

    // MARK: Spotify Web API

    func testTokenRequest() throws {
        let r = SpotifyAPI.tokenRequest(clientID: "id123", secret: "sec456")
        XCTAssertEqual(r.httpMethod, "POST")
        XCTAssertEqual(r.url?.absoluteString, "https://accounts.spotify.com/api/token")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Basic " + Data("id123:sec456".utf8).base64EncodedString())
        XCTAssertEqual(String(data: try XCTUnwrap(r.httpBody), encoding: .utf8), "grant_type=client_credentials")
        let t = SpotifyAPI.parseToken(Data(#"{"access_token":"tok","token_type":"Bearer","expires_in":3600}"#.utf8))
        XCTAssertEqual(t?.token, "tok")
        XCTAssertEqual(t?.expiresIn, 3600)
        XCTAssertNil(SpotifyAPI.parseToken(Data(#"{"error":"invalid_client"}"#.utf8)))
    }

    func testSearchRequestAndPlan() {
        let r = SpotifyAPI.searchRequest(query: "C++ & Radiohead", token: "tok")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        let q = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(q.host, "api.spotify.com")
        XCTAssertEqual(q.queryItems?.first { $0.name == "q" }?.value, "C++ & Radiohead")
        XCTAssertEqual(q.queryItems?.first { $0.name == "type" }?.value, "track,playlist,album")
        XCTAssertFalse(r.url!.absoluteString.contains("C++"), "плюс закодирован")
        XCTAssertEqual(SpotifyAPI.plan("Creep").order.first, "track")
        XCTAssertEqual(SpotifyAPI.plan("плейлист для работы").q, "для работы")
        XCTAssertEqual(SpotifyAPI.plan("плейлист для работы").order.first, "playlist")
        XCTAssertEqual(SpotifyAPI.plan("альбом OK Computer").order.first, "album")
    }

    func testParseSearch() {
        // Обезличенный ответ: плейлисты бывают null.
        let json = """
        {"tracks":{"items":[{"uri":"spotify:track:1111111111111111111111","name":"T"}]},
         "playlists":{"items":[null,{"uri":"spotify:playlist:2222222222222222222222"}]},
         "albums":{"items":[{"uri":"spotify:album:3333333333333333333333"}]}}
        """
        let d = Data(json.utf8)
        XCTAssertEqual(SpotifyAPI.parseSearch(d, query: "x")?.uri, "spotify:track:1111111111111111111111")
        XCTAssertEqual(SpotifyAPI.parseSearch(d, query: "плейлист x")?.uri, "spotify:playlist:2222222222222222222222")
        XCTAssertEqual(SpotifyAPI.parseSearch(d, query: "альбом x")?.uri, "spotify:album:3333333333333333333333")
        XCTAssertNil(SpotifyAPI.parseSearch(Data(#"{"tracks":{"items":[]}}"#.utf8), query: "x"))
        XCTAssertNil(SpotifyAPI.parseSearch(Data("not json".utf8), query: "x"))
    }

    // MARK: окно музыки

    let visible = CGRect(x: 0, y: 0, width: 1512, height: 944)
    let home = CGRect(x: 600, y: 950, width: 32, height: 16)
    var geometry: SceneGeometry {
        let w = SceneLayout.windowForm(visible, kind: .music)
        return SceneGeometry(home: home, target: SceneTimeline.faceIn(.music, window: w), area: w, visible: visible)
    }

    func frame(_ t: Double, _ marks: [SceneMusicMark], clips: Set<String> = Set(SceneClip.all), lag: Double = 0) -> SceneFrame {
        var o = SceneOptions()
        o.musicMarks = marks
        o.lag = lag
        return SceneTimeline.frame(.music, t: t, geometry: geometry, clips: clips, options: o)
    }

    func testMusicWindowClipsPerState() {
        let marks = [SceneMusicMark(t: 1.0, state: .searching), SceneMusicMark(t: 2.5, state: .playing),
                     SceneMusicMark(t: 4.5, state: .paused), SceneMusicMark(t: 5.2, state: .playing)]
        XCTAssertEqual(frame(0.8, marks).clip, "hair_bob", "раскрывается в волосах (не как «думает»)")
        XCTAssertEqual(frame(1.5, marks).clip, "side_look")
        XCTAssertTrue(frame(1.5, marks).clipMode == .bounce)
        XCTAssertNotNil(frame(1.5, marks).window?.scan, "ищет — сканлайн")
        XCTAssertEqual(frame(2.7, marks).clip, "eye_zoom", "трек пошёл — наезд в глаз")
        let nod = (0..<24).map { frame(3.5 + Double($0) / 24, marks) }
        XCTAssertEqual(Set(nod.map(\.clip)), ["hair_bob"], "кивает в волосах")
        XCTAssertGreaterThan(Set(nod.map { Int(($0.face!.shift.dy * 1000).rounded()) }).count, 3, "кивок")
        XCTAssertGreaterThan(Set(nod.map { Int(($0.face!.tilt * 10).rounded()) }).count, 3, "покачивание")
        XCTAssertTrue(nod.contains { $0.face!.zoom > 1.02 }, "удар на долю")
        XCTAssertFalse(nod.allSatisfy { $0.notes.isEmpty }, "ноты")
        XCTAssertEqual(frame(4.8, marks).clip, "face_nod", "пауза — прикрыла глаза")
        XCTAssertEqual(frame(5.1, marks).clipT, 1.9, accuracy: 1e-9, "держит закрытые глаза")
        XCTAssertGreaterThanOrEqual(frame(4.5, marks).clipT, 1.3, "пауза — сразу к закрытым глазам")
        XCTAssertEqual(frame(1.5, marks).face?.mirror, true, "ищет — зеркально, не как «думает»")
        XCTAssertEqual(frame(5.4, marks).clip, "face_nod", "снова играет — открывает глаза")
        XCTAssertGreaterThanOrEqual(frame(5.4, marks).clipT, 2.5)
        XCTAssertEqual(frame(6.0, marks).clip, "hair_bob")
        let failed = [SceneMusicMark(t: 1.0, state: .searching), SceneMusicMark(t: 7.0, state: .failed)]
        XCTAssertEqual(frame(7.2, failed).clip, "crazy")
        XCTAssertEqual(frame(7.2, failed).glitch, 3)
        // Старые клипы: как в проходе 2.
        let old = Set(SceneClip.all).subtracting([SceneClip.faceNod, SceneClip.hairBob, SceneClip.sideLook, SceneClip.eyeZoom])
        XCTAssertEqual(frame(1.5, marks, clips: old).clip, "slits")
        XCTAssertEqual(frame(2.7, marks, clips: old).clip, "burst")
        XCTAssertEqual(Set((0..<20).map { frame(3.5 + Double($0) / 24, marks, clips: old).clip }), ["look", "slits"])
        XCTAssertEqual(frame(4.8, marks, clips: old).clip, "close")
        XCTAssertEqual(frame(5.4, marks, clips: old).clip, "appear")
        // Без клипов сериала — look/close.
        for t in stride(from: 0.0, to: 10, by: 0.1) {
            let f = frame(t, marks, clips: [])
            XCTAssertTrue(["look", "close"].contains(f.clip) || f.eyes == nil, "\(t) \(f.clip)")
        }
    }

    /// Глитч сильной доли не теряется при 12 fps с любым сдвигом кадров.
    func testStrongBeatSeenAt12fps() {
        let beatLen = 60 / SceneTimeline.bpm
        for phase in stride(from: 0.0, to: 1.0 / 12, by: 0.01) {
            for bar in 0..<4 {
                let start = Double(bar * 4) * beatLen
                let hits = stride(from: start - 0.05 + phase, to: start + beatLen, by: 1.0 / 12).filter { $0 >= 0 && SceneTimeline.strongBeat($0) }
                XCTAssertFalse(hits.isEmpty, "доля \(bar * 4), сдвиг \(phase)")
            }
        }
    }

    func testGrooveStrongBeat() {
        let beat = 60 / SceneTimeline.bpm
        XCTAssertGreaterThan(SceneTimeline.groove(0.01, height: 200).pulse, 0.8, "сильная доля — вспышка")
        XCTAssertEqual(SceneTimeline.groove(beat + 0.01, height: 200).pulse, 0, "слабая — нет")
        XCTAssertGreaterThan(SceneTimeline.groove(beat + 0.01, height: 200).zoom, 1.03, "удар на каждую долю")
        XCTAssertEqual(SceneTimeline.groove(beat * 0.5, height: 200).zoom, 1)
        XCTAssertEqual(abs(SceneTimeline.groove(beat * 0.5, height: 200).tilt), 1.5, accuracy: 1e-6)
    }

    func testMusicWindowDurationFollowsMarks() {
        XCTAssertEqual(SceneTimeline.duration(.music), 8)
        var o = SceneOptions()
        o.musicMarks = [SceneMusicMark(t: 1.0, state: .searching), SceneMusicMark(t: 7.0, state: .failed)]
        XCTAssertEqual(SceneTimeline.duration(.music, o), 12)
        o.musicMarks.append(SceneMusicMark(t: 500, state: .playing))
        XCTAssertEqual(SceneTimeline.duration(.music, o), SceneTimeline.musicCap)
    }

    func testMusicMarkDuringHoldStartsFromClick() {
        // Держали мышью: таймлайн стоит на 3.0, стена — 9.0; клик «пауза» на стене 9.0, через 0.2 с — начало клипа.
        let marks = [SceneMusicMark(t: 1.0, state: .playing), SceneMusicMark(t: 3.0, wall: 9.0, state: .paused)]
        let f = frame(3.0, marks, lag: 6.2)
        XCTAssertEqual(f.clip, "face_nod")
        XCTAssertEqual(f.clipT, 1.5, accuracy: 1e-9, "кивок с 1,3 с клипа, 0,2 с от клика")
    }

    func testMusicHotspotsAndEyeControls() {
        let g = geometry
        let w = g.area!
        let spots = SceneLayout.hotspots(.music, t: 3, geometry: g, clips: Set(SceneClip.all))
        let ids = spots.compactMap { s -> String? in if case .button(let id) = s.kind { return id }; return nil }
        XCTAssertEqual(ids, ["prev", "toggle", "next"])
        for b in SceneTimeline.musicButtons(w) {
            XCTAssertTrue(w.contains(b.rect))
            XCTAssertEqual(SceneLayout.hit(spots, CGPoint(x: b.rect.midX, y: b.rect.midY))?.kind, .button(b.id))
        }
        // Строка трека — на полосе внизу лица, кнопки — под лицом.
        let face = SceneTimeline.faceIn(.music, window: w)
        XCTAssertGreaterThan(SceneTimeline.musicLine(w).y, face.minY)
        XCTAssertLessThan(SceneTimeline.musicLine(w).y, face.minY + SceneTimeline.faceBand(.music))
        XCTAssertGreaterThan(SceneTimeline.musicLine(w).y, SceneTimeline.musicButtons(w)[0].rect.maxY)
        // Под глазами телепорта: только если музыка известна и навели на глаза.
        let tg = SceneGeometry(home: home, target: SceneLayout.corner(visible, size: SceneTimeline.eyesSize), visible: visible)
        var o = SceneOptions()
        XCTAssertEqual(SceneLayout.hotspots(.teleport, t: 2, geometry: tg, options: o).map(\.kind), [.drag])
        o.musicKnown = true
        XCTAssertEqual(SceneLayout.hotspots(.teleport, t: 2, geometry: tg, options: o).map(\.kind), [.drag])
        o.controls = true
        let c = SceneLayout.hotspots(.teleport, t: 2, geometry: tg, options: o)
        XCTAssertEqual(c.map(\.kind), [.button("prev"), .button("toggle"), .button("next"), .drag])
        // Кнопки вплотную под глазами (курсор переходит с глаз на кнопки, не теряя наведения) и на экране.
        let grab = c.last!.rect
        for s in c.dropLast() {
            XCTAssertGreaterThanOrEqual(s.rect.maxY, grab.minY)
            XCTAssertTrue(visible.contains(s.rect), "\(s.rect)")
        }
        XCTAssertTrue(SceneLayout.hotspots(.takeover, t: 2, geometry: tg, options: o).isEmpty)
    }
}
