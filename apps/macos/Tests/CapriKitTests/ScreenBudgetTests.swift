import XCTest
@testable import CapriKit

/// Общий бюджет стола: все пути (музыка, сессии, ответ, посадка, терминал) делят один счёт.
final class ScreenBudgetTests: XCTestCase {
    let day = 0.0

    func testGapHourDayAndAfterScene() {
        var b = ScreenBudget()
        let t0 = 10_000.0
        XCTAssertNil(b.limited(now: t0, dayStart: day))
        b.record(t0)
        XCTAssertEqual(b.limited(now: t0 + 60, dayStart: day), "budgetGap")
        XCTAssertNil(b.limited(now: t0 + ScreenBudget.minGap, dayStart: day))
        b.record(t0 + ScreenBudget.minGap)
        XCTAssertEqual(b.limited(now: t0 + 30 * 60, dayStart: day), "budgetHourly", "≤ 2 в час")
        XCTAssertNil(b.limited(now: t0 + 3600 + 1, dayStart: day))
        // Конец сцены — 5 мин тишины, даже если счёт позволяет.
        b.ended(t0 + 2 * 3600)
        XCTAssertEqual(b.limited(now: t0 + 2 * 3600 + 60, dayStart: day), "budgetAfterScene")
        XCTAssertNil(b.limited(now: t0 + 2 * 3600 + ScreenBudget.afterScene, dayStart: day))
        // День.
        var c = ScreenBudget()
        for k in 0..<ScreenBudget.perDay { c.record(t0 + Double(k) * 3 * 3600) }
        let late = t0 + Double(ScreenBudget.perDay) * 3 * 3600
        XCTAssertEqual(c.limited(now: late, dayStart: day), "budgetDaily")
        XCTAssertNil(c.limited(now: late, dayStart: late - 60), "новый день — снова можно")
    }

    func testQuietReasons() {
        let noon = ScreenBudget.Conditions(now: 0, minuteOfDay: 12 * 60)
        XCTAssertNil(ScreenBudget.blocked(noon))
        var c = noon; c.desktop = false
        XCTAssertEqual(ScreenBudget.blocked(c), "desktopOff", "один выключатель на весь стол")
        c = noon; c.minuteOfDay = 3 * 60
        XCTAssertEqual(ScreenBudget.blocked(c), "quiet")
        c = noon; c.inCall = true
        XCTAssertEqual(ScreenBudget.blocked(c), "call")
        XCTAssertTrue(ScreenBudget.isQuiet("quiet"))
        XCTAssertTrue(ScreenBudget.isQuiet("call"))
        XCTAssertFalse(ScreenBudget.isQuiet("budgetGap"))
        XCTAssertFalse(ScreenBudget.isQuiet(nil))
        var b = ScreenBudget()
        b.record(100)
        XCTAssertEqual(b.gate(c, dayStart: 0), "call", "тихие причины — раньше счёта")
        XCTAssertEqual(b.gate(ScreenBudget.Conditions(now: 160), dayStart: 0), "budgetGap")
    }

    func testCodableRoundTrip() throws {
        var b = ScreenBudget()
        b.record(1)
        b.ended(2)
        let back = try JSONDecoder().decode(ScreenBudget.self, from: JSONEncoder().encode(b))
        XCTAssertEqual(back, b)
    }

    // MARK: все пути спрашивают бюджет

    func testDirectorPathsRespectBudget() {
        var d = CharacterDirector(now: 0)
        let i = CharacterDirector.Input(now: 1000, budget: "budgetGap")
        XCTAssertEqual(d.decide(.sessionFinished, i), .skip("budgetGap"), "телепорт «сессия доработала»")
        XCTAssertEqual(d.decide(.musicStarted, i), .skip("budgetGap"), "вайб на столе — нет; дальше кивок в notch")
        XCTAssertEqual(d.decideAction(.replySent, i), .skip("budgetGap"), "телепорт к терминалу после ответа")
        XCTAssertEqual(d.decideAction(.askedAssistant, i), .skip("budgetGap"))
        XCTAssertEqual(d.decideAction(.answerReady, i), .skip("budgetGap"))
        XCTAssertEqual(d.decideAction(.musicRequested, i), .skip("budgetGap"))
        XCTAssertEqual(d.decideAction(.musicRequested, i, continuing: true), .play(.music), "уже на столе — не новое появление")
        XCTAssertEqual(d.decideAction(.replySent, CharacterDirector.Input(now: 1000, budget: "desktopOff")), .skip("desktopOff"))
        XCTAssertEqual(d.decide(.trackChanged, i), .notchVibe, "счёт стола кивок в notch не трогает")
        var e = CharacterDirector(now: 0)
        XCTAssertEqual(e.decide(.trackChanged, CharacterDirector.Input(now: 1000, budget: "quiet")), .skip("quiet"), "тихие часы — и в notch")
        XCTAssertEqual(e.decide(.musicStarted, CharacterDirector.Input(now: 1000, budget: "call")), .skip("call"))
        XCTAssertEqual(e.decide(.trackChanged, CharacterDirector.Input(now: 1000, sceneRunning: true)), .skip("running"),
                       "она на столе — вторая в notch не кивает")
    }

    func testMusicStartedByCapriStaysInNotch() {
        var d = CharacterDirector(now: 0)
        XCTAssertEqual(d.decide(.musicStarted, CharacterDirector.Input(now: 1000, musicByCapri: true)), .skip("byCapri"))
        XCTAssertEqual(d.decide(.musicStarted, CharacterDirector.Input(now: 1001)), .play(.vibe), "кулдаун не потрачен")
    }

    func testPerchRespectsBudget() {
        var p = PerchPolicy()
        let i = PerchPolicy.Input(now: 100_000, budget: "budgetHourly")
        XCTAssertEqual(p.decide(.activated(bundle: "md.obsidian", launched: true), i), .skip("budgetHourly"))
        XCTAssertFalse(p.isFirstToday("md.obsidian", dayStart: i.dayStart), "запуск потрачен, как и в тихие часы")
        XCTAssertEqual(PerchPolicy.perDay, 4)
    }

    func testDayStartAcrossDST() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        // 2026-10-25: переход с летнего времени (сутки 25 часов). В 03:00 «день» начался вчера в 05:00 местного.
        let three = cal.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 3))!.timeIntervalSince1970
        let expect = cal.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 5))!.timeIntervalSince1970
        XCTAssertEqual(PerchPolicy.dayStart(now: three, calendar: cal), expect)
        let after = cal.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 3))!.timeIntervalSince1970
        let five25 = cal.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 5))!.timeIntervalSince1970
        XCTAssertEqual(PerchPolicy.dayStart(now: after, calendar: cal), five25, "после перевода — тоже 05:00, не 04:00")
    }

    func testModelDownloadIsPinned() {
        XCTAssertFalse(AsrModel.downloadURL.absoluteString.contains("/resolve/main/"))
        XCTAssertTrue(AsrModel.downloadURL.absoluteString.contains(AsrModel.revision))
        XCTAssertEqual(AsrModel.sha256.count, 64)
    }
}
