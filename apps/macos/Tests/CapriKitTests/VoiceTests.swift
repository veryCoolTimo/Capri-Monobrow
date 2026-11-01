import XCTest
@testable import CapriKit

final class AsrProtocolTests: XCTestCase {
    func testCommandsRoundTripThroughChoppedStream() {
        let pcm: [Float] = [0, 0.5, -0.25, 1, -1]
        var data = Data()
        for c in [AsrCommand.begin(language: "ru"), .audio(pcm), .end, .begin(language: nil), .cancel, .quit] { data.append(c.encoded) }
        // По одному байту — как попало порезанный pipe.
        var r = AsrCommandReader()
        var got: [AsrCommand] = []
        for b in data { got += r.feed(Data([b])) }
        XCTAssertEqual(got, [.begin(language: "ru"), .audio(pcm), .end, .begin(language: nil), .cancel, .quit])
        XCTAssertNil(r.broken)
    }

    func testAudioWaitsForWholePayload() {
        var r = AsrCommandReader()
        let enc = AsrCommand.audio([0.25, 0.75]).encoded
        XCTAssertEqual(r.feed(enc.prefix(enc.count - 3)), [])
        XCTAssertEqual(r.feed(enc.suffix(3)), [.audio([0.25, 0.75])])
    }

    func testBrokenStreamStops() {
        var r = AsrCommandReader()
        XCTAssertEqual(r.feed(Data("begin\naudio 7\nend\n".utf8)), [.begin(language: nil)])
        XCTAssertNotNil(r.broken)
        XCTAssertEqual(r.feed(Data("end\n".utf8)), [])
        var r2 = AsrCommandReader()
        _ = r2.feed(Data("rm -rf\n".utf8))
        XCTAssertNotNil(r2.broken)
        var r3 = AsrCommandReader()
        _ = r3.feed(Data("audio \(AsrCommandReader.maxAudioBytes + 4)\n".utf8))
        XCTAssertNotNil(r3.broken, "слишком большой кусок звука")
    }

    func testLanguageHintIsSanitized() {
        XCTAssertEqual(String(decoding: AsrCommand.begin(language: "ru\n; quit").encoded, as: UTF8.self), "begin ruquit\n")
    }

    func testEventsRoundTrip() {
        let events: [AsrEvent] = [.ready(backend: "MTL0", loadMs: 432), .partial("Капри, вклю"), .final("Капри, включи «Daft Punk»", language: "ru"),
                                  .final("ok", language: nil), .cancelled, .error("нет модели"), .idle]
        for e in events { XCTAssertEqual(AsrEvent.parse(e.line), e, e.line) }
        XCTAssertFalse(AsrEvent.partial("a\nb").line.contains("\n"), "одна строка на событие")
    }

    func testGarbageLinesIgnored() {
        XCTAssertNil(AsrEvent.parse("ggml_metal_init: loaded kernel"))
        XCTAssertNil(AsrEvent.parse("{\"event\":\"partial\",\"te"))
        XCTAssertNil(AsrEvent.parse("{\"event\":\"weird\"}"))
        XCTAssertNil(AsrEvent.parse("{\"event\":\"final\"}"))
        XCTAssertNil(AsrEvent.parse(""))
    }

    func testLineSplitter() {
        var s = LineSplitter()
        XCTAssertEqual(s.feed(Data("{\"a\":1}\n{\"b\"".utf8)), ["{\"a\":1}"])
        XCTAssertEqual(s.feed(Data(":2}\n\n".utf8)), ["{\"b\":2}", ""])
    }

    func testModelLocate() {
        let home = "/Users/t"
        let dir = home + "/.cache/huggingface/hub/models--handy-computer--nemotron-3.5-asr-streaming-0.6b-gguf"
        let file = AsrModel.file
        var files: Set<String> = [dir + "/snapshots/bbb/" + file]
        let refs: [String: String] = [dir + "/refs/main": "bbb\n"]
        func find(_ override: String? = nil, env: [String: String] = [:]) -> String? {
            AsrModel.locate(override: override, home: home, env: env, exists: { files.contains($0) }, read: { refs[$0] },
                            list: { $0 == dir + "/snapshots" ? ["aaa", "bbb"] : [] })
        }
        XCTAssertEqual(find(), dir + "/snapshots/bbb/" + file)
        files = [dir + "/snapshots/aaa/" + file]
        XCTAssertEqual(find(), dir + "/snapshots/aaa/" + file, "refs/main без файла — другой снимок")
        files = []
        XCTAssertNil(find())
        files = [AsrModel.ownPath(home: home)]
        XCTAssertEqual(find(), AsrModel.ownPath(home: home), "скачанная самой Capri")
        files = ["/models/x.gguf", home + "/m.gguf"]
        XCTAssertEqual(find("/models/x.gguf"), "/models/x.gguf")
        XCTAssertEqual(find("~/m.gguf"), home + "/m.gguf")
        XCTAssertNil(find("/nope.gguf"), "путь из настроек есть, но файла нет — не подменяем кэшем")
        XCTAssertEqual(AsrModel.cacheDir(home: home, env: ["HF_HOME": "/hf"]),
                       "/hf/hub/models--handy-computer--nemotron-3.5-asr-streaming-0.6b-gguf")
    }
}

final class VoiceIntentTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return c
    }()
    /// 2026-11-01 15:00 по Москве.
    var now: Date { cal.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 15, minute: 0))! }

    func parse(_ s: String, sessions: [String] = ["votek2", "capri-test", "Timo-RAG"], known: Bool = false) -> VoiceIntent {
        VoiceIntent.parse(s, sessions: sessions, musicKnown: known, now: now, calendar: cal)
    }

    func at(_ day: Int, _ h: Int, _ m: Int = 0, month: Int = 11) -> Date {
        cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: h, minute: m))!
    }

    func testAddressStripped() {
        XCTAssertEqual(VoiceIntent.stripAddress("Капри, что с сессиями?"), "что с сессиями?")
        XCTAssertEqual(VoiceIntent.stripAddress("  Эй, Капри.  пауза."), "пауза")
        XCTAssertEqual(VoiceIntent.stripAddress("Capri! next"), "next")
        XCTAssertEqual(parse("Капри."), .empty)
        XCTAssertEqual(parse("   "), .empty)
    }

    func testMusic() {
        XCTAssertEqual(parse("Капри, включи Daft Punk"), .music(.play("Daft Punk")))
        XCTAssertEqual(parse("Пауза."), .music(.pause))
        XCTAssertEqual(parse("Капри, дальше", known: true), .music(.next))
        XCTAssertEqual(parse("play Around the World"), .music(.play("Around the World")))
    }

    func testNotes() {
        XCTAssertEqual(parse("Капри, запиши: купить молоко и хлеб."), .note("купить молоко и хлеб"))
        XCTAssertEqual(parse("Запиши в заметки идею про риг"), .note("идею про риг"))
        XCTAssertEqual(parse("сделай заметку позвонить папе"), .note("позвонить папе"))
        XCTAssertEqual(parse("take a note buy coffee"), .note("buy coffee"))
        XCTAssertEqual(parse("запиши"), .assistant("запиши"))
    }

    func testRelativeReminders() {
        XCTAssertEqual(parse("Капри, напомни через 20 минут проверить деплой"), .reminder(text: "проверить деплой", due: now.addingTimeInterval(1200)))
        XCTAssertEqual(parse("напомни мне через двадцать пять минут выпить воды"), .reminder(text: "выпить воды", due: now.addingTimeInterval(1500)))
        XCTAssertEqual(parse("напомни через полчаса позвонить"), .reminder(text: "позвонить", due: now.addingTimeInterval(1800)))
        XCTAssertEqual(parse("напомни через час про тесты"), .reminder(text: "тесты", due: now.addingTimeInterval(3600)))
        XCTAssertEqual(parse("напомни через 2 часа 15 минут забрать посылку"), .reminder(text: "забрать посылку", due: now.addingTimeInterval(8100)))
        XCTAssertEqual(parse("напомни выключить духовку через 10 минут"), .reminder(text: "выключить духовку", due: now.addingTimeInterval(600)))
        XCTAssertEqual(parse("remind me in 5 minutes to stretch"), .reminder(text: "stretch", due: now.addingTimeInterval(300)))
        XCTAssertEqual(parse("напомни через полтора часа выйти"), .reminder(text: "выйти", due: now.addingTimeInterval(5400)))
    }

    func testAbsoluteReminders() {
        XCTAssertEqual(parse("напомни в 18:00 созвон с Сержем"), .reminder(text: "созвон с Сержем", due: at(1, 18)))
        XCTAssertEqual(parse("напомни в 18.30 ужин"), .reminder(text: "ужин", due: at(1, 18, 30)))
        XCTAssertEqual(parse("напомни завтра в 9 отправить отчёт"), .reminder(text: "отправить отчёт", due: at(2, 9)))
        XCTAssertEqual(parse("напомни в 6 вечера пробежка"), .reminder(text: "пробежка", due: at(1, 18)))
        XCTAssertEqual(parse("напомни в 6 погулять"), .reminder(text: "погулять", due: at(1, 18)), "в 15:00 «в 6» — это вечер")
        XCTAssertEqual(parse("напомни в 9 утра йога"), .reminder(text: "йога", due: at(2, 9)), "утро прошло — завтра")
        XCTAssertEqual(parse("напомни в 14 часов 30 минут врач"), .reminder(text: "врач", due: at(2, 14, 30)), "14:30 сегодня прошло")
        XCTAssertEqual(parse("напомни завтра купить корм"), .reminder(text: "купить корм", due: at(2, 9)))
        XCTAssertEqual(parse("remind me at 6 pm to call mom"), .reminder(text: "call mom", due: at(1, 18)))
        XCTAssertEqual(parse("напомни сегодня в 21 полить цветы"), .reminder(text: "полить цветы", due: at(1, 21)))
    }

    func testRemindersWithoutTimeOrQuestions() {
        XCTAssertEqual(parse("напомни купить молоко"), .reminder(text: "купить молоко", due: nil))
        XCTAssertEqual(parse("напомни, что я вчера говорил про votek"), .assistant("напомни, что я вчера говорил про votek"))
        XCTAssertEqual(parse("напомни через 20 минут"), .assistant("напомни через 20 минут"), "нет текста — переспросит помощник")
    }

    func testSearch() {
        XCTAssertEqual(parse("Капри, найди в интернете, что нового в Swift 6.2"), .search("что нового в Swift 6.2"))
        XCTAssertEqual(parse("поищи рецепт борща"), .search("рецепт борща"))
        XCTAssertEqual(parse("посмотри в интернете курс доллара"), .search("курс доллара"))
        XCTAssertEqual(parse("look up transcribe.cpp benchmarks"), .search("transcribe.cpp benchmarks"))
        XCTAssertEqual(parse("найди сессию, которая ждёт"), .assistant("найди сессию, которая ждёт"))
        XCTAssertEqual(parse("посмотри что с votek2"), .assistant("посмотри что с votek2"), "«посмотри» без интернета — не поиск")
    }

    func testReply() {
        XCTAssertEqual(parse("Капри, ответь votek2: да, продолжай"), .reply(session: "votek2", text: "да, продолжай"))
        XCTAssertEqual(parse("ответь вотек два да"), .reply(session: "votek2", text: "да"))
        XCTAssertEqual(parse("ответь в капри тест запусти тесты ещё раз"), .reply(session: "capri-test", text: "запусти тесты ещё раз"))
        XCTAssertEqual(parse("скажи timo rag хватит"), .reply(session: "Timo-RAG", text: "хватит"))
        XCTAssertEqual(parse("ответь votek2"), .assistant("ответь votek2"), "без текста ответа")
        XCTAssertEqual(parse("ответь кому-нибудь да"), .assistant("ответь кому-нибудь да"), "нет такой сессии")
    }

    func testEverythingElseGoesToAssistant() {
        XCTAssertEqual(parse("что с сессиями?"), .assistant("что с сессиями?"))
        XCTAssertEqual(parse("Капри, кто меня ждёт"), .assistant("кто меня ждёт"))
    }

    func testSessionMatchKeys() {
        XCTAssertEqual(SessionMatch.key("Votek-2"), SessionMatch.key("вотек два"))
        XCTAssertEqual(SessionMatch.key("capri-test"), SessionMatch.key("Капри тест"))
        XCTAssertNotEqual(SessionMatch.key("votek2"), SessionMatch.key("votek3"))
    }
}

final class VoiceActionsTests: XCTestCase {
    func testNoteScriptEscapes() {
        let s = AppleScripts.note("идея: \"риг\" <b> & \\ всё")
        XCTAssertTrue(s.contains("tell application id \"com.apple.Notes\""))
        XCTAssertTrue(s.contains("&lt;b&gt; &amp;"))
        XCTAssertTrue(s.contains("\\\"риг\\\""))
        XCTAssertFalse(s.contains("<b>"))
        XCTAssertEqual(MusicScript.arguments(s).count, 6, "три строки — три -e")
    }

    func testReminderScriptSetsDateByParts() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Moscow")!
        let due = cal.date(from: DateComponents(year: 2026, month: 2, day: 28, hour: 18, minute: 5))!
        let s = AppleScripts.reminder("созвон \"с Сержем\"", due: due, calendar: cal)
        let lines = s.components(separatedBy: "\n")
        XCTAssertEqual(lines[1], "set day of d to 1", "сначала день = 1 — без переполнения месяца")
        XCTAssertTrue(lines.contains("set month of d to 2"))
        XCTAssertTrue(lines.contains("set day of d to 28"))
        XCTAssertTrue(lines.contains("set hours of d to 18"))
        XCTAssertTrue(lines.contains("set minutes of d to 5"))
        XCTAssertTrue(s.contains("due date:d, remind me date:d"))
        XCTAssertTrue(s.contains("\\\"с Сержем\\\""))
        XCTAssertFalse(AppleScripts.reminder("x", due: nil).contains("due date"))
    }

    func testSearchAnswerLinks() {
        let text = """
        Swift 6.2 добавил InlineArray и строгую изоляцию по умолчанию [Swift.org](https://www.swift.org/blog/swift-6.2-released/).
        Подробнее — https://example.com/a.
        Источники: [Swift.org](https://www.swift.org/blog/swift-6.2-released/), [HN](https://news.ycombinator.com/item?id=1)
        javascript:alert(1) [плохо](javascript:alert(1))
        """
        let r = SearchAnswer.split(text)
        XCTAssertEqual(r.links.map(\.url.absoluteString), ["https://www.swift.org/blog/swift-6.2-released/", "https://news.ycombinator.com/item?id=1",
                                                          "https://example.com/a"])
        XCTAssertEqual(r.links.first?.title, "Swift.org")
        XCTAssertEqual(r.links.last?.title, "example.com")
        XCTAssertFalse(r.text.contains("http"))
        XCTAssertFalse(r.text.lowercased().contains("источники"))
        XCTAssertTrue(r.text.hasPrefix("Swift 6.2 добавил InlineArray"))
        XCTAssertEqual(SearchAnswer.split("нет ссылок").links, [])
        XCTAssertEqual(SearchAnswer.split("a https://a.com b https://b.com c https://c.com d https://d.com").links.count, 3)
    }

    func testPushToTalkTapVsHold() {
        var p = PushToTalk()
        XCTAssertEqual(p.press(at: 0), [.prepare])
        XCTAssertEqual(p.press(at: 0.05), [], "автоповтор")
        XCTAssertEqual(p.tick(at: 0.1), [])
        XCTAssertEqual(p.release(at: 0.15), [.tap])
        XCTAssertEqual(p.phase, .idle)

        XCTAssertEqual(p.press(at: 10), [.prepare])
        XCTAssertEqual(p.tick(at: 10.3), [.listen])
        XCTAssertEqual(p.tick(at: 11), [])
        XCTAssertEqual(p.release(at: 12), [.finish])

        // Таймер не успел — отпустили после порога: всё равно голос.
        XCTAssertEqual(p.press(at: 20), [.prepare])
        XCTAssertEqual(p.release(at: 20.5), [.listen, .finish])

        // Залипла клавиша.
        _ = p.press(at: 30)
        _ = p.tick(at: 30.3)
        XCTAssertEqual(p.tick(at: 30 + PushToTalk.maxHold), [.finish])
        XCTAssertEqual(p.release(at: 80), [], "отпускание после обрыва")
    }
}
