import XCTest
@testable import CapriKit

final class CharacterDirectorTests: XCTestCase {
    func input(_ now: Double, _ edit: (inout CharacterDirector.Input) -> Void = { _ in }) -> CharacterDirector.Input {
        var i = CharacterDirector.Input(now: now)
        edit(&i)
        return i
    }

    func testEachBlockHasItsReason() {
        let cases: [(String, (inout CharacterDirector.Input) -> Void)] = [
            ("off", { $0.enabled = false }),
            ("hidden", { $0.hiddenUntil = 2000 }),
            ("paused", { $0.paused = true }),
            ("fullscreen", { $0.fullscreen = true }),
            ("asleep", { $0.displaysAsleep = true }),
            ("notch", { $0.notchOpen = true }),
            ("running", { $0.sceneRunning = true }),
            ("lowPower", { $0.lowPower = true }),
            ("reduceMotion", { $0.reduceMotion = true }),
            ("busy", { $0.idleSec = 1 }),
            ("away", { $0.idleSec = 300 }),
        ]
        for (why, edit) in cases {
            var d = CharacterDirector(now: 0)
            XCTAssertEqual(d.decide(.sessionFinished, input(1000, edit)), .skip(why), why)
        }
        var d = CharacterDirector(now: 0)
        XCTAssertEqual(d.decide(.sessionFinished, input(1000) { $0.sessionEvents = false }), .skip("sessionEventsOff"))
        XCTAssertEqual(d.decide(.sessionFinished, input(1000)), .play(.teleport))
    }

    func testCooldownsAndLimits() {
        var d = CharacterDirector(now: 0)
        XCTAssertEqual(d.decide(.sessionFinished, input(1000)), .play(.teleport))
        // Через 5 мин — кулдаун события; через 15 — общий зазор 20 мин.
        XCTAssertEqual(d.decide(.sessionFinished, input(1300)), .skip("cooldown"))
        XCTAssertEqual(d.decide(.sessionFinished, input(1000 + 15 * 60)), .skip("gap"))
        XCTAssertEqual(d.decide(.musicStarted, input(1000 + 15 * 60)), .skip("gap"))
        XCTAssertEqual(d.decide(.sessionFinished, input(1000 + 20 * 60)), .play(.teleport))
        XCTAssertEqual(d.decide(.musicStarted, input(1000 + 40 * 60)), .play(.vibe))
        XCTAssertEqual(d.decide(.sessionFinished, input(1000 + 59 * 60)), .skip("gap"))
    }

    func testNeverMoreThanLimitPerHour() {
        // Все события сразу, каждую минуту, сутки: в любом часе ≤ 4 сцен на столе, между сценами ≥ 20 мин.
        var d = CharacterDirector(now: 0, seed: 5)
        var plays: [Double] = []
        for m in 1..<(24 * 60) {
            let now = Double(m) * 60
            for e in [CharacterDirector.Event.sessionFinished, .musicStarted, .ambient] {
                if case .play = d.decide(e, input(now) { $0.takeover = true }) { plays.append(now) }
            }
        }
        XCTAssertGreaterThan(plays.count, 10)
        for (a, b) in zip(plays, plays.dropFirst()) { XCTAssertGreaterThanOrEqual(b - a, CharacterDirector.minGap) }
        for p in plays { XCTAssertLessThanOrEqual(plays.filter { $0 >= p && $0 - p < 3600 }.count, CharacterDirector.perHour) }
    }

    func testAmbientWindowDeterministic() {
        let a = CharacterDirector(now: 0, seed: 7)
        let b = CharacterDirector(now: 0, seed: 7)
        XCTAssertEqual(a.nextAmbient, b.nextAmbient)
        XCTAssertTrue((30 * 60...60 * 60).contains(a.nextAmbient))
        for seed in 0..<50 {
            let d = CharacterDirector(now: 100, seed: seed, rate: .rare)
            XCTAssertTrue((100 + 45 * 60...100 + 90 * 60).contains(d.nextAmbient))
        }
        var d = CharacterDirector(now: 0, seed: 3)
        XCTAssertEqual(d.decide(.ambient, input(60)), .skip("notDue"))
        let due = d.nextAmbient
        guard case .play(let kind) = d.decide(.ambient, input(due)) else { return XCTFail() }
        XCTAssertTrue([.teleport, .window].contains(kind), "захват выключен")
        XCTAssertGreaterThanOrEqual(d.nextAmbient - due, 30 * 60)
        // Нельзя по «долгой» причине — перенос на 10 мин, а не каждую минуту.
        var e = CharacterDirector(now: 0, seed: 3)
        let at = e.nextAmbient
        XCTAssertEqual(e.decide(.ambient, input(at) { $0.fullscreen = true }), .skip("fullscreen"))
        XCTAssertEqual(e.nextAmbient, at + 600)
        // «Печатает прямо сейчас» — не переносим: следующая проверка через минуту.
        XCTAssertEqual(e.decide(.ambient, input(at + 600) { $0.idleSec = 0 }), .skip("busy"))
        XCTAssertEqual(e.nextAmbient, at + 600)
    }

    func testAmbientMixAndTakeover() {
        var kinds: [SceneKind: Int] = [:]
        for seed in 0..<200 {
            var d = CharacterDirector(now: 0, seed: seed)
            if case .play(let k) = d.decide(.ambient, input(d.nextAmbient) { $0.takeover = true }) { kinds[k, default: 0] += 1 }
        }
        XCTAssertGreaterThan(kinds[.teleport, default: 0], kinds[.window, default: 0])
        XCTAssertGreaterThan(kinds[.takeover, default: 0], 0)
        XCTAssertGreaterThan(kinds[.window, default: 0], 0)
        // Захват — не чаще раза в 2 ч.
        var d = CharacterDirector(now: 0, seed: 1)
        var takeovers: [Double] = []
        var now = 0.0
        while now < 24 * 3600 {
            now = max(now + 60, d.nextAmbient)
            if case .play(.takeover) = d.decide(.ambient, input(now) { $0.takeover = true }) { takeovers.append(now) }
        }
        for (a, b) in zip(takeovers, takeovers.dropFirst()) { XCTAssertGreaterThanOrEqual(b - a, 2 * 3600) }
    }

    func testNotchVibeBypassesLimitsWithOwnCooldown() {
        var d = CharacterDirector(now: 0)
        XCTAssertEqual(d.decide(.sessionFinished, input(1000)), .play(.teleport))
        // Персонаж выключен, человек печатает, сцена только что была — кивание в notch всё равно можно.
        XCTAssertEqual(d.decide(.trackChanged, input(1001) { $0.enabled = false; $0.idleSec = 0 }), .notchVibe)
        XCTAssertEqual(d.decide(.trackChanged, input(1100)), .skip("cooldown"))
        XCTAssertEqual(d.decide(.trackChanged, input(1001 + 180)), .notchVibe)
        XCTAssertEqual(d.decide(.trackChanged, input(2000) { $0.music = false }), .skip("musicOff"))
        XCTAssertEqual(d.decide(.trackChanged, input(2000) { $0.hiddenUntil = 3000 }), .skip("hidden"))
        // Пауза уведомлений, полноэкранное приложение и спящие экраны глушат и кивание.
        XCTAssertEqual(d.decide(.trackChanged, input(2000) { $0.paused = true }), .skip("paused"))
        XCTAssertEqual(d.decide(.trackChanged, input(2000) { $0.fullscreen = true }), .skip("fullscreen"))
        XCTAssertEqual(d.decide(.trackChanged, input(2000) { $0.displaysAsleep = true }), .skip("asleep"))
    }

    func testMusicStartedAfterSilenceCooldown() {
        var d = CharacterDirector(now: 0)
        XCTAssertEqual(d.decide(.musicStarted, input(1000)), .play(.vibe))
        XCTAssertEqual(d.decide(.musicStarted, input(1000 + 25 * 60)), .skip("cooldown"))
        XCTAssertEqual(d.decide(.musicStarted, input(1000 + 31 * 60)), .play(.vibe))
        XCTAssertEqual(d.decide(.musicStarted, input(9000) { $0.music = false }), .skip("musicOff"))
    }

    func testFinishedTransitions() {
        let a = SessionKey(host: "h", agent: .claude, id: "a"), b = SessionKey(host: "h", agent: .claude, id: "b")
        let c = SessionKey(host: "h", agent: .claude, id: "c")
        XCTAssertEqual(SceneTriggers.finished(prev: [a: .running], next: [a: .idle]), [a])
        XCTAssertEqual(SceneTriggers.finished(prev: [a: .running], next: [a: .needsInput]), [])
        XCTAssertEqual(SceneTriggers.finished(prev: [a: .idle], next: [a: .idle]), [])
        XCTAssertEqual(SceneTriggers.finished(prev: [:], next: [b: .idle]), [])
        XCTAssertEqual(SceneTriggers.finished(prev: [c: .running], next: [:]), [])
        XCTAssertEqual(SceneTriggers.finished(prev: [a: .running, b: .running], next: [a: .idle, b: .idle]), [a, b])
        XCTAssertTrue(SceneTriggers.needsInputAppeared(prev: [a: .running], next: [a: .needsInput]))
        XCTAssertFalse(SceneTriggers.needsInputAppeared(prev: [a: .needsInput], next: [a: .needsInput]))
        XCTAssertTrue(SceneTriggers.needsInputAppeared(prev: [:], next: [c: .needsInput]))
    }

    func testActionScenesBypassLimitsButNotQuietReasons() {
        var d = CharacterDirector(now: 0)
        XCTAssertEqual(d.decide(.sessionFinished, input(1000)), .play(.teleport))
        // Только что была сцена, человек печатает, notch открыт, фоновый персонаж выключен — всё равно отвечаем.
        let busy = input(1001) { $0.idleSec = 0; $0.enabled = false; $0.notchOpen = true; $0.sceneRunning = true; $0.lowPower = true }
        XCTAssertEqual(d.decideAction(.replySent, busy), .play(.reply))
        XCTAssertEqual(d.decideAction(.askedAssistant, busy), .play(.thinking))
        XCTAssertEqual(d.decideAction(.answerReady, busy), .play(.answer))
        XCTAssertEqual(d.decideAction(.replySent, input(1002)), .play(.reply), "без кулдауна")
        // Лимиты фона не тратит.
        XCTAssertEqual(d.starts.count, 1)
        let quiet: [(String, (inout CharacterDirector.Input) -> Void)] = [
            ("actionOff", { $0.onAction = false }),
            ("hidden", { $0.hiddenUntil = 5000 }),
            ("paused", { $0.paused = true }),
            ("fullscreen", { $0.fullscreen = true }),
            ("asleep", { $0.displaysAsleep = true }),
            ("reduceMotion", { $0.reduceMotion = true }),
        ]
        for (why, edit) in quiet {
            XCTAssertEqual(d.decideAction(.replySent, input(1003, edit)), .skip(why), why)
        }
        XCTAssertEqual(d.lastDecision, "replySent: skip reduceMotion")
    }

    func testAmbientPicksSessionsWhenSomeoneWaits() {
        var kinds: [SceneKind: Int] = [:]
        for seed in 0..<200 {
            var d = CharacterDirector(now: 0, seed: seed)
            if case .play(let k) = d.decide(.ambient, input(d.nextAmbient) { $0.sessionsActive = true }) { kinds[k, default: 0] += 1 }
        }
        XCTAssertGreaterThan(kinds[.sessions, default: 0], 0)
        XCTAssertNil(kinds[.window], "кто-то ждёт или работает — окно сессий вместо статуса")
        XCTAssertGreaterThan(kinds[.teleport, default: 0], kinds[.sessions, default: 0])
    }
}
