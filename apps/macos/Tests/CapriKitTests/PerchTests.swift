import XCTest
import CoreGraphics
@testable import CapriKit

/// Этап 2 плана присутствия: «сидит на окнах».
final class PerchTests: XCTestCase {
    let visible = CGRect(x: 0, y: 0, width: 1512, height: 944)
    let bubble = PerchLayout.bubbleSize(chars: 30)

    // MARK: PerchPolicy

    func input(_ now: Double, _ cat: AppCategory = .other) -> PerchPolicy.Input {
        PerchPolicy.Input(now: now, dayStart: now - 3600, category: cat)
    }

    func open(_ p: inout PerchPolicy, _ bundle: String, _ i: PerchPolicy.Input, launched: Bool = true) -> PerchPolicy.Decision {
        p.decide(.activated(bundle: bundle, launched: launched), i)
    }

    func testEachBlockHasItsReason() {
        let now = 1_000_000.0
        var cases: [(String, PerchPolicy.Input)] = []
        func add(_ why: String, _ f: (inout PerchPolicy.Input) -> Void) {
            var i = input(now)
            f(&i)
            cases.append((why, i))
        }
        add("off") { $0.enabled = false }
        add("hidden") { $0.hiddenUntil = now + 60 }
        add("paused") { $0.paused = true }
        add("quiet") { $0.minuteOfDay = 3 * 60 }
        add("fullscreen") { $0.fullscreen = true }
        add("call") { $0.inCall = true }
        add("asleep") { $0.displaysAsleep = true }
        add("notch") { $0.notchOpen = true }
        add("running") { $0.sceneRunning = true }
        add("lowPower") { $0.lowPower = true }
        add("reduceMotion") { $0.reduceMotion = true }
        add("away") { $0.idleSec = 600 }
        add("warmup") { $0.sinceStart = 30 }
        add("afterScene") { $0.sinceScene = 120 }
        add("blocked") { $0.userBlocked = ["com.google.Chrome"] }
        add("game") { $0.category = .game }
        add("call") { $0.category = .call }
        add("noSpot") { $0.spot = "noSpot" }
        for (why, i) in cases {
            var p = PerchPolicy()
            XCTAssertEqual(open(&p, "com.google.Chrome", i), .skip(why), why)
        }
        for b in ["local.capri", "com.1password.1password", "com.apple.loginwindow", "com.apple.dock", "com.bitwarden.desktop", ""] {
            var p = PerchPolicy()
            XCTAssertEqual(open(&p, b, input(now)), .skip("never"), b)
        }
        // Пользовательский блок сильнее категории; «никогда» — сильнее всего.
        var p = PerchPolicy()
        var i = input(now, .game)
        i.userBlocked = ["local.capri"]
        XCTAssertEqual(open(&p, "local.capri", i), .skip("never"))
        // После сцены — 5 мин тишины, потом можно.
        var q = PerchPolicy()
        var j = input(now)
        j.sinceScene = PerchPolicy.afterScene + 1
        XCTAssertEqual(open(&q, "com.google.Chrome", j), .perch(.other))
    }

    /// Отзыв Тимофея: только запуск, не ⌘-Tab; только первый запуск приложения за день; без жребия.
    func testOnlyFirstLaunchOfTheDay() {
        var p = PerchPolicy()
        let t0 = 2_000_000.0
        XCTAssertEqual(open(&p, "com.google.Chrome", input(t0, .browser), launched: false), .skip("notLaunched"), "⌘-Tab — не повод")
        XCTAssertEqual(open(&p, "com.google.Chrome", input(t0, .browser)), .perch(.browser), "первый запуск — всегда, без жребия")
        // Закрыл и снова запустил через час — тот же день, не повод.
        XCTAssertEqual(open(&p, "com.google.Chrome", input(t0 + 3600, .browser)), .skip("notFirst"))
        // Новый день — снова можно.
        var next = input(t0 + 86400, .browser)
        next.dayStart = t0 + 1
        XCTAssertEqual(open(&p, "com.google.Chrome", next), .perch(.browser))
        // Первый запуск в тихие часы тратится: вечером того же дня — нет.
        var q = PerchPolicy()
        var night = input(t0)
        night.minuteOfDay = 8 * 60
        night.dayStart = t0 - 100
        XCTAssertEqual(open(&q, "com.apple.mail", night), .skip("quiet"))
        var evening = input(t0 + 5 * 3600)
        evening.dayStart = t0 - 100
        XCTAssertEqual(open(&q, "com.apple.mail", evening), .skip("notFirst"))
        // Одинаковые входы — одинаковые решения (нет случайности).
        var a = PerchPolicy(), b = PerchPolicy()
        for k in 0..<20 {
            let t = t0 + Double(k) * 700
            XCTAssertEqual(open(&a, "app.\(k % 7)", input(t)), open(&b, "app.\(k % 7)", input(t)))
        }
    }

    func testNoWindowDoesNotSpendFirstLaunch() {
        var p = PerchPolicy()
        var i = input(5_000_000)
        i.spot = "noWindow"
        XCTAssertEqual(open(&p, "com.figma.Desktop", i), .skip("noWindow"))
        i.spot = nil
        i.category = .design
        XCTAssertEqual(open(&p, "com.figma.Desktop", i), .perch(.design))
        XCTAssertTrue(p.starts.count == 1)
    }

    func testGapHourlyDaily() {
        var p = PerchPolicy()
        let t0 = 3_000_000.0
        XCTAssertEqual(open(&p, "a.one", input(t0)), .perch(.other))
        XCTAssertEqual(open(&p, "a.two", input(t0 + 9 * 60)), .skip("gap"), "≥ 10 мин между посадками")
        XCTAssertEqual(open(&p, "a.three", input(t0 + 10 * 60 + 1)), .perch(.other))
        XCTAssertEqual(open(&p, "a.four", input(t0 + 25 * 60)), .skip("hourly"), "≤ 2 в час")
        XCTAssertEqual(open(&p, "a.five", input(t0 + 3601)), .perch(.other))
        // За день — не больше 8 (по запуску новых приложений каждые 31 мин).
        var d = PerchPolicy()
        var now = t0
        var n = 0
        for k in 0..<40 {
            now += 31 * 60
            var i = input(now)
            i.dayStart = t0
            if case .perch = open(&d, "b.app\(k)", i) { n += 1 }
        }
        XCTAssertEqual(n, PerchPolicy.perDay)
        var i = input(now + 3600)
        i.dayStart = t0
        XCTAssertEqual(d.gate(.activated(bundle: "b.new", launched: true), i), "daily")
        i.dayStart = now + 1
        XCTAssertNil(d.gate(.activated(bundle: "b.new", launched: true), i), "новый день — снова можно")
        // Не чаще ~2 в час при любом потоке запусков.
        var r = PerchPolicy()
        let shown = (0..<120).filter { k in
            if case .perch = open(&r, "c.app\(k)", input(t0 + Double(k) * 60)) { return true }
            return false
        }.count
        XCTAssertLessThanOrEqual(shown, 4, "2 часа запусков каждую минуту")
    }

    func testTwoShoosInARowTireHerForAnHour() {
        var p = PerchPolicy()
        let t0 = 4_000_000.0
        _ = open(&p, "a.one", input(t0))
        p.shooed(at: t0 + 5)
        p.sat()
        _ = open(&p, "a.two", input(t0 + 3700))
        p.shooed(at: t0 + 3705)
        XCTAssertNil(p.tiredUntil, "между «кыш» досидела — не подряд")
        _ = open(&p, "a.three", input(t0 + 7400))
        p.shooed(at: t0 + 7405)
        XCTAssertEqual(open(&p, "a.four", input(t0 + 7405 + 3599)), .skip("tired"))
        XCTAssertEqual(open(&p, "a.five", input(t0 + 7405 + 3601)), .perch(.other))
    }

    func testStateSurvivesRestartAndRemembersDaysAway() throws {
        var p = PerchPolicy()
        let t0 = 7_000_000.0
        var i = input(t0)
        i.dayStart = t0 - 100
        _ = open(&p, "md.obsidian", i)
        let back = try JSONDecoder().decode(PerchPolicy.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back, p)
        var q = back
        XCTAssertEqual(open(&q, "md.obsidian", i), .skip("notFirst"), "после перезапуска Capri — всё ещё не первый")
        // Через 3 дня: «не открывал 3 дня».
        var later = input(t0 + 3 * 86400 + 60)
        later.dayStart = t0 + 3 * 86400
        _ = open(&q, "md.obsidian", later)
        XCTAssertEqual(q.daysAway("md.obsidian", now: later.now), 3)
        XCTAssertNil(q.daysAway("never.seen", now: later.now))
    }

    func testDayStartIsFiveAM() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let noon = 1_700_000_000.0 - 1_700_000_000.0.truncatingRemainder(dividingBy: 86400) + 12 * 3600
        XCTAssertEqual(PerchPolicy.dayStart(now: noon, calendar: cal), noon - 7 * 3600)
        let three = noon - 9 * 3600
        XCTAssertEqual(PerchPolicy.dayStart(now: three, calendar: cal), noon - 7 * 3600 - 86400)
    }

    // MARK: QuietHours, AppCatalog, CallGuard

    func testQuietHoursAcrossMidnight() {
        let q = QuietHours.standard
        XCTAssertEqual(q.label, "00:30–09:00")
        XCTAssertTrue(q.contains(minuteOfDay: 3 * 60))
        XCTAssertTrue(q.contains(minuteOfDay: 30))
        XCTAssertFalse(q.contains(minuteOfDay: 29))
        XCTAssertFalse(q.contains(minuteOfDay: 9 * 60))
        XCTAssertFalse(q.contains(minuteOfDay: 12 * 60))
        let night = QuietHours(start: 23 * 60, end: 7 * 60)
        XCTAssertTrue(night.contains(minuteOfDay: 23 * 60 + 30))
        XCTAssertTrue(night.contains(minuteOfDay: 60))
        XCTAssertFalse(night.contains(minuteOfDay: 8 * 60))
        XCTAssertFalse(QuietHours(start: 600, end: 600).contains(minuteOfDay: 600), "start == end — тихих часов нет")
    }

    func testAppCatalog() {
        XCTAssertEqual(AppCatalog.category(bundle: "com.google.Chrome"), .browser)
        XCTAssertEqual(AppCatalog.category(bundle: "com.APPLE.safari"), .browser, "без учёта регистра")
        XCTAssertEqual(AppCatalog.category(bundle: "ru.keepcoder.Telegram"), .messenger)
        XCTAssertEqual(AppCatalog.category(bundle: "com.apple.dt.Xcode"), .ide)
        XCTAssertEqual(AppCatalog.category(bundle: "com.mitchellh.ghostty"), .terminal)
        XCTAssertEqual(AppCatalog.category(bundle: "com.apple.finder"), .files)
        XCTAssertEqual(AppCatalog.category(bundle: "us.zoom.xos"), .call)
        XCTAssertEqual(AppCatalog.category(bundle: "com.valvesoftware.steam"), .game)
        XCTAssertEqual(AppCatalog.category(bundle: "com.example.x", lsCategory: "public.app-category.action-games"), .game)
        XCTAssertEqual(AppCatalog.category(bundle: "com.example.x", lsCategory: "public.app-category.developer-tools"), .ide)
        XCTAssertEqual(AppCatalog.category(bundle: "com.example.x"), .other)
        XCTAssertEqual(AppCatalog.reason(bundle: "local.capri", category: .other, userBlocked: []), "never")
        XCTAssertEqual(AppCatalog.reason(bundle: "com.x", category: .other, userBlocked: ["com.x"]), "blocked")
        XCTAssertTrue(AppCatalog.allowed(bundle: "com.x", category: .other, userBlocked: []))
        // У каждой «говорящей» категории есть реплики; у игр и звонков — нет.
        for c in AppCategory.speaking { XCTAssertNotNil(PerchLines.bank[c], c.rawValue) }
        XCTAssertNil(PerchLines.bank[.game])
        XCTAssertGreaterThanOrEqual(AppCategory.speaking.count, 12)
    }

    func testCallGuard() {
        XCTAssertTrue(CallGuard.inCall(front: "us.zoom.xos", camera: false, mic: false, ownVoice: false))
        XCTAssertTrue(CallGuard.inCall(front: "com.google.Chrome", camera: true, mic: false, ownVoice: false))
        XCTAssertTrue(CallGuard.inCall(front: "com.google.Chrome", camera: false, mic: true, ownVoice: false))
        XCTAssertFalse(CallGuard.inCall(front: "com.google.Chrome", camera: false, mic: true, ownVoice: true), "свой голосовой ввод — не звонок")
        XCTAssertFalse(CallGuard.inCall(front: nil, camera: false, mic: false, ownVoice: false))
    }

    // MARK: PerchLines

    func testBankLinesAreValidUniqueAndEnough() {
        var all: [String] = []
        for c in AppCategory.speaking {
            let lines = PerchLines.bank[c]!
            XCTAssertGreaterThanOrEqual(lines.count, 6, c.rawValue)
            for l in lines {
                XCTAssertTrue(PerchLines.valid(l.text), "\(c): \(l.text) (\(l.text.count))")
                XCTAssertLessThanOrEqual(PerchLayout.bubbleSize(chars: l.text.count).width, 360)
            }
            all += lines.map(\.text)
        }
        XCTAssertEqual(Set(all).count, all.count, "нет дублей")
    }

    func testTemplatesNameTheAppAndFit() {
        // Самое длинное допустимое имя — все шаблоны всё равно влезают в пузырь.
        let long = String(repeating: "Ж", count: PerchLines.maxName)
        var all: [String] = []
        for c in AppCategory.speaking {
            let ts = PerchLines.templates[c]!
            XCTAssertGreaterThanOrEqual(ts.count, 6, c.rawValue)
            for t in ts {
                XCTAssertTrue(t.contains("{app}"), "реплика про само приложение: \(t)")
                let s = t.replacingOccurrences(of: "{app}", with: long)
                XCTAssertTrue(PerchLines.valid(s), "\(c): \(s) (\(s.count))")
            }
            all += ts
        }
        XCTAssertEqual(Set(all).count, all.count, "нет дублей")
    }

    func testLinesAreAboutWhatIsHappening() {
        let base = PerchFacts(app: "Telegram", category: .messenger)
        // Просто запуск днём — про это приложение.
        for s in 0..<30 { XCTAssertTrue(PerchLines.compose(base, seed: s).contains("Telegram")) }
        // Ждут сессии — первым делом про них, с правильным склонением.
        var f = base
        f.waiting = 2
        f.working = 3
        f.track = "Midnight City"
        for s in 0..<30 {
            let l = PerchLines.compose(f, seed: s)
            XCTAssertTrue(l.contains("2 сессии"), l)
        }
        f.waiting = 1
        XCTAssertTrue(PerchLines.compose(f, seed: 1).contains("сессия"))
        // Нет ждущих, играет трек — про трек.
        f.waiting = 0
        for s in 0..<30 { XCTAssertTrue(PerchLines.compose(f, seed: s).contains("Midnight City"), PerchLines.compose(f, seed: s)) }
        // Длинный трек — обрезан, реплика годна.
        f.track = "A Very Long Song Title That Never Ends"
        let l = PerchLines.compose(f, seed: 2)
        XCTAssertTrue(l.contains("…"), l)
        XCTAssertTrue(PerchLines.valid(l))
        // Давно не открывал.
        var away = base
        away.daysAway = 3
        XCTAssertTrue(PerchLines.compose(away, seed: 4).contains("3 дня"))
        // Работают сессии.
        var work = base
        work.working = 5
        XCTAssertTrue(PerchLines.compose(work, seed: 4).contains("5 сессий") || PerchLines.compose(work, seed: 4).contains("Сессии"))
        // Ночь — со временем.
        var night = base
        night.minuteOfDay = 2 * 60 + 7
        let nights = (0..<60).map { PerchLines.compose(night, seed: $0) }
        XCTAssertTrue(nights.contains { $0.contains("02:07") })
        // Имя не влезает — без имени, из банка категории.
        var longName = base
        longName.app = "Some Extremely Long Application Name"
        XCTAssertTrue(PerchLines.bank[.messenger]!.map(\.text).contains(PerchLines.compose(longName, seed: 1)))
        // Не повторяет недавние, пока есть другие; детерминирован.
        var recent: [String] = []
        for s in 0..<6 {
            let l = PerchLines.compose(base, recent: recent, seed: s)
            XCTAssertFalse(recent.contains(l), l)
            recent.append(l)
        }
        XCTAssertEqual(PerchLines.compose(base, seed: 7), PerchLines.compose(base, seed: 7))
        // Склонение.
        XCTAssertEqual([1, 2, 5, 11, 21, 22, 25].map { PerchLines.plural($0, "день", "дня", "дней") },
                       ["день", "дня", "дней", "дней", "день", "дня", "дней"])
    }

    func testValidator() {
        XCTAssertTrue(PerchLines.valid("Сдвинь на пиксель. Нет, обратно."))
        XCTAssertFalse(PerchLines.valid(String(repeating: "а", count: 49)))
        XCTAssertFalse(PerchLines.valid(" пробел"))
        XCTAssertFalse(PerchLines.valid("две\nстроки"))
        XCTAssertFalse(PerchLines.valid("смотри https://x.y"))
        XCTAssertFalse(PerchLines.valid("**жирно**"))
        XCTAssertFalse(PerchLines.valid("ну ты блин бля"))
        XCTAssertFalse(PerchLines.valid("ok"))
    }

    func testParseGenerated() {
        XCTAssertTrue(PerchLines.parseGenerated("{не json").isEmpty)
        XCTAssertTrue(PerchLines.parseGenerated("[1,2]").isEmpty)
        let json = """
        {"browser": ["Опять вкладки?", "Опять вкладки?", "\(String(repeating: "я", count: 60))", "https://spam.example"],
         "game": ["нельзя"], "nope": ["x y z"], "ide": [" Код. "]}
        """
        let r = PerchLines.parseGenerated(json)
        XCTAssertEqual(r[.browser]?.map(\.text), ["Опять вкладки?"])
        XCTAssertEqual(r[.ide]?.map(\.text), ["Код."])
        XCTAssertNil(r[.game])
        XCTAssertEqual(r.count, 2)
    }

    // MARK: PerchLayout

    func testMiddleWindowSitsTopRight() {
        let w = CGRect(x: 300, y: 200, width: 800, height: 500)
        let s = PerchLayout.spot(window: w, above: [], visible: visible, bubble: bubble)!
        XCTAssertEqual(s.edge, .topRight)
        XCTAssertEqual(s.eyes.minY, w.maxY - s.eyes.height * 0.25, accuracy: 0.01, "на ¾ над краем")
        XCTAssertEqual(s.eyes.maxX, w.maxX - 48, accuracy: 0.01)
        XCTAssertTrue(visible.contains(s.eyes))
        XCTAssertTrue(visible.contains(s.bubble!))
        XCTAssertFalse(s.bubble!.intersects(s.eyes))
    }

    func testWindowAtMenuBarHangsOnSideThenBottomThenNothing() {
        // Упирается в строку меню, справа место есть — висит на боку.
        let w = CGRect(x: 200, y: 300, width: 900, height: visible.maxY - 300)
        XCTAssertEqual(PerchLayout.spot(window: w, above: [], visible: visible, bubble: bubble)?.edge, .right)
        // Справа места нет — нижний край.
        let w2 = CGRect(x: 600, y: 300, width: visible.maxX - 600, height: visible.maxY - 300)
        XCTAssertEqual(PerchLayout.spot(window: w2, above: [], visible: visible, bubble: bubble)?.edge, .bottom)
        // Развёрнутое на всю видимую часть — сесть некуда.
        XCTAssertNil(PerchLayout.spot(window: visible, above: [], visible: visible, bubble: bubble))
        // Маленькое окно — нет.
        XCTAssertNil(PerchLayout.spot(window: CGRect(x: 400, y: 300, width: 300, height: 180), above: [], visible: visible, bubble: bubble))
    }

    func testCoveredTopRightGoesLeftAndLightsAreNeverCovered() {
        let w = CGRect(x: 300, y: 200, width: 800, height: 500)
        let cover = CGRect(x: 900, y: 600, width: 400, height: 300)
        let s = PerchLayout.spot(window: w, above: [cover], visible: visible, bubble: bubble)!
        XCTAssertEqual(s.edge, .topLeft)
        XCTAssertFalse(s.eyes.intersects(cover.insetBy(dx: 4, dy: 4)))
        // Кнопки окна никогда не закрыты — ни глазами, ни пузырём, ни для какого края и окна.
        for x in stride(from: 0.0, to: 1300, by: 97) {
            for y in stride(from: 0.0, to: 800, by: 83) {
                for (wd, h) in [(330.0, 210.0), (700, 420), (1200, 700)] {
                    let win = CGRect(x: x, y: y, width: wd, height: h)
                    guard let sp = PerchLayout.spot(window: win, above: [], visible: visible, bubble: bubble) else { continue }
                    XCTAssertFalse(sp.eyes.intersects(PerchLayout.lights(win)), "\(win) \(sp.edge)")
                    XCTAssertFalse(sp.bubble!.intersects(PerchLayout.lights(win)), "\(win) \(sp.edge)")
                    XCTAssertTrue(visible.contains(sp.eyes))
                    XCTAssertTrue(visible.contains(sp.bubble!))
                }
            }
        }
    }

    func testPlaceFollowsWindowAndLeavesWhenOffScreen() {
        let w = CGRect(x: 300, y: 200, width: 800, height: 500)
        let s = PerchLayout.spot(window: w, above: [], visible: visible, bubble: bubble)!
        let moved = w.offsetBy(dx: -120, dy: -60)
        let p = PerchLayout.place(s, window: moved, above: [], visible: visible)!
        XCTAssertEqual(p.edge, s.edge)
        XCTAssertEqual(p.eyes.minX - s.eyes.minX, -120, accuracy: 0.01)
        XCTAssertEqual(p.eyes.minY - s.eyes.minY, -60, accuracy: 0.01)
        // Подняли к строке меню — перебирается на другой край.
        let up = CGRect(x: 300, y: visible.maxY - 500, width: 800, height: 500)
        XCTAssertEqual(PerchLayout.place(s, window: up, above: [], visible: visible)?.edge, .right)
        // Унесли за экран — уходит.
        XCTAssertNil(PerchLayout.place(s, window: w.offsetBy(dx: 3000, dy: 0), above: [], visible: visible))
    }

    func testPanelHoldsEyesAndBubble() {
        let w = CGRect(x: 300, y: 200, width: 800, height: 500)
        let s = PerchLayout.spot(window: w, above: [], visible: visible, bubble: PerchLayout.bubbleSize(chars: 48))!
        let p = PerchLayout.panel(s, visible: visible)
        XCTAssertTrue(p.contains(s.eyes))
        XCTAssertTrue(p.contains(s.bubble!))
        XCTAssertLessThan(p.width * p.height, 420 * 160, "маленькая панель, а не от notch до окна")
        let g = SceneGeometry(home: CGRect(x: 740, y: 950, width: 32, height: 16), target: s.eyes, visible: visible, bubble: s.bubble)
        let c = SceneLayout.compactPanel(.perch, geometry: g)!
        XCTAssertTrue(c.contains(s.eyes) && c.contains(s.bubble!))
    }

    func testFindWindowAboveAndScreen() {
        let primary: CGFloat = 982
        let screens = [(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visible: visible),
                       (frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080), visible: CGRect(x: 1512, y: 0, width: 1920, height: 1055))]
        let wins = [
            WindowInfo(pid: 99, layer: 25, bounds: CGRect(x: 600, y: 0, width: 300, height: 30), number: 1),   // Capri/строка меню
            WindowInfo(pid: 7, layer: 0, bounds: CGRect(x: 1700, y: 100, width: 300, height: 300), number: 2),
            WindowInfo(pid: 5, layer: 0, bounds: CGRect(x: 1600, y: 80, width: 900, height: 600), number: 3),
            WindowInfo(pid: 5, layer: 0, bounds: CGRect(x: 10, y: 80, width: 900, height: 600), number: 4),
        ]
        let f = PerchWindow.find(windows: wins, pid: 5, own: 99, screens: screens, primaryHeight: primary)!
        XCTAssertEqual(f.number, 3, "переднее окно приложения — первое в списке")
        XCTAssertEqual(f.screen, screens[1].frame, "любой монитор (решение Тимофея)")
        XCTAssertEqual(f.above.count, 1)
        XCTAssertEqual(f.rect, CGRect(x: 1600, y: primary - 680, width: 900, height: 600))
        XCTAssertEqual(PerchWindow.find(windows: wins, pid: 5, number: 4, own: 99, screens: screens, primaryHeight: primary)?.number, 4)
        XCTAssertNil(PerchWindow.find(windows: wins, pid: 42, own: 99, screens: screens, primaryHeight: primary))
    }

    // MARK: PerchTracker

    func tracker() -> (PerchTracker, CGRect) {
        let w = CGRect(x: 300, y: 200, width: 800, height: 500)
        let s = PerchLayout.spot(window: w, above: [], visible: visible, bubble: bubble)!
        return (PerchTracker(spot: s, window: w), w)
    }

    func b(_ r: CGRect?, front: Bool = true, full: Bool = false, above: [CGRect] = [], at: Double) -> PerchTracker.Sample {
        .bounds(r, frontmost: front, fullscreen: full, above: above, visible: visible, at: at)
    }

    func testTrackerStayHopLeave() {
        var (t, w) = tracker()
        XCTAssertEqual(t.apply(b(w, at: 1)), .stay)
        XCTAssertEqual(t.nextPoll(1), 1.5)
        // Сдвиг без мыши — сразу на новое место.
        guard case .hop(let s) = t.apply(b(w.offsetBy(dx: 50, dy: 0), at: 2)) else { return XCTFail() }
        XCTAssertEqual(s.eyes.minX, t.spot.eyes.minX)
        XCTAssertEqual(t.apply(b(nil, at: 3)), .leave("gone"))
        XCTAssertEqual(t.apply(b(t.window, front: false, at: 3)), .leave("switched"))
        XCTAssertEqual(t.apply(b(t.window, full: true, at: 3)), .leave("fullscreen"))
        XCTAssertEqual(t.apply(b(t.window, above: [t.spot.eyes], at: 3)), .leave("covered"))
        XCTAssertEqual(t.apply(b(t.window.offsetBy(dx: 5000, dy: 0), at: 4)), .leave("noSpot"))
    }

    func testTrackerDragHoldsThenHopsAfterSettle() {
        var (t, w) = tracker()
        XCTAssertEqual(t.apply(.dragBegan(1)), .stay, "нажали — ещё ничего")
        XCTAssertEqual(t.nextPoll(1), 1.1, "10 Гц во время перетаскивания")
        XCTAssertEqual(t.apply(b(w.offsetBy(dx: 30, dy: 10), at: 1.1)), .hold)
        XCTAssertEqual(t.apply(b(w.offsetBy(dx: 80, dy: 20), at: 1.2)), .hold)
        XCTAssertEqual(t.apply(.dragEnded(1.3)), .hold)
        XCTAssertEqual(t.nextPoll(1.3), 1.4, accuracy: 1e-9)
        XCTAssertEqual(t.apply(b(w.offsetBy(dx: 80, dy: 20), at: 1.4)), .hold, "ещё не устоялось")
        guard case .hop(let s) = t.apply(b(w.offsetBy(dx: 80, dy: 20), at: 1.65)) else { return XCTFail() }
        XCTAssertEqual(s.eyes.minX, PerchLayout.spot(window: w, above: [], visible: visible, bubble: bubble)!.eyes.minX + 80, accuracy: 0.01)
        XCTAssertEqual(t.nextPoll(2), 2.5)
        // Тянули, но окно не двигалось (выделение текста) — сидит.
        var (u, w2) = tracker()
        _ = u.apply(.dragBegan(1))
        XCTAssertEqual(u.apply(b(w2, at: 1.1)), .stay)
        XCTAssertEqual(u.apply(.dragEnded(1.2)), .stay)
    }

    // MARK: PerchTimeline

    func geometry() -> SceneGeometry {
        let w = CGRect(x: 300, y: 200, width: 800, height: 500)
        let s = PerchLayout.spot(window: w, above: [], visible: visible, bubble: bubble)!
        return SceneGeometry(home: CGRect(x: 740, y: 950, width: 32, height: 16), target: s.eyes, visible: visible, bubble: s.bubble)
    }

    func options(_ chars: Int = 30, seed: Int = 4) -> SceneOptions {
        var o = SceneOptions()
        o.perchChars = chars
        o.seed = seed
        return o
    }

    let clips = Set(SceneClip.all)

    func testPerchPhasesAndDuration() {
        for seed in 0..<40 {
            for chars in [5, 30, 48] {
                let o = options(chars, seed: seed)
                let d = SceneTimeline.duration(.perch, o)
                XCTAssertGreaterThanOrEqual(d, 7)
                XCTAssertLessThanOrEqual(d, 14)
                XCTAssertGreaterThan(d - PerchTimeline.leaveLen, PerchTimeline.speakEnd(o), "пузырь успевает дочитаться")
            }
        }
        let o = options()
        let g = geometry()
        let d = SceneTimeline.duration(.perch, o)
        func f(_ t: Double) -> SceneFrame { SceneTimeline.frame(.perch, t: t, geometry: g, clips: clips, options: o) }
        XCTAssertEqual(f(0.1).phase, "out")
        XCTAssertEqual(f(0.3).phase, "jump")
        XCTAssertNotNil(f(0.3).bolt)
        XCTAssertEqual(f(0.6).phase, "in")
        XCTAssertEqual(f(1.2).phase, "speak")
        XCTAssertEqual(f(1.2).clip, SceneClip.talk, "печатает — говорит")
        XCTAssertEqual(f(1.2).bubble?.typed, Int(0.2 * 18))
        XCTAssertEqual(f(PerchTimeline.typedAt(o) + 0.5).bubble?.typed, 30)
        XCTAssertEqual(f(PerchTimeline.speakEnd(o) + 0.5).phase, "sit")
        XCTAssertNil(f(PerchTimeline.speakEnd(o) + 0.5).bubble)
        XCTAssertEqual(f(d - 0.6).phase, "leave")
        XCTAssertEqual(f(d - 0.4).phase, "back")
        XCTAssertTrue(f(d).done)
        XCTAssertTrue(f(d + 1).done)
        // Без клипов сериала — `look`.
        XCTAssertEqual(SceneTimeline.frame(.perch, t: 1.2, geometry: g, clips: [], options: o).clip, SceneClip.look)
        // Спокойная часть — без молнии и вспышки, глаза на месте.
        var t = SceneTimeline.calm(.perch, o)!.lowerBound
        while t < SceneTimeline.calm(.perch, o)!.upperBound {
            XCTAssertNil(f(t).bolt, "\(t)")
            XCTAssertEqual(f(t).eyes, g.target, "\(t)")
            t += 1.0 / 48
        }
    }

    func testPerchDrawsOnlyOnChanges() {
        let o = options()
        let g = geometry()
        let calm = SceneTimeline.calm(.perch, o)!
        // Печать — 12 fps; перелёт — 24 fps; сидение — реже 4 fps в среднем.
        XCTAssertEqual(SceneTimeline.frameInterval(.perch, t: 1.5, options: o), 1.0 / 12, accuracy: 0.001)
        XCTAssertEqual(SceneTimeline.frameInterval(.perch, t: 0.3, options: o), 1.0 / 24, accuracy: 1e-9)
        XCTAssertEqual(SceneTimeline.frameInterval(.perch, t: 1.5, aborted: true, options: o), 1.0 / 24)
        var t = PerchTimeline.speakEnd(o) + 0.2
        var frames = 0
        let start = t
        var prev = SceneTimeline.frame(.perch, t: t, geometry: g, clips: clips, options: o)
        while t < calm.upperBound {
            let next = t + SceneTimeline.frameInterval(.perch, t: t, options: o)
            // Между кадрами картинка не меняется (проверка по 1/96 с).
            var k = t + 1.0 / 96
            while k < min(next, calm.upperBound) - 0.002 {
                let f = SceneTimeline.frame(.perch, t: k, geometry: g, clips: clips, options: o)
                XCTAssertEqual(f.clip, prev.clip, "\(k)")
                XCTAssertEqual(f.glitch, prev.glitch, "\(k)")
                XCTAssertEqual(f.clipT, prev.clipT, accuracy: 1.0 / 6 + 1e-6, "\(k)")
                k += 1.0 / 96
            }
            t = next
            frames += 1
            prev = SceneTimeline.frame(.perch, t: t, geometry: g, clips: clips, options: o)
        }
        let rate = Double(frames) / (calm.upperBound - start)
        XCTAssertLessThan(rate, 6, "сидит — кадр по событию, а не 12 fps")
        XCTAssertGreaterThan(frames, 2, "но моргает")
        XCTAssertLessThanOrEqual(SceneTimeline.frameInterval(.perch, t: start, options: o), 1)
    }

    func testPerchHopHoldAndAbort() {
        var o = options()
        let g = geometry()
        o.hopAt = 5
        o.hopFrom = g.target.offsetBy(dx: -200, dy: -50)
        let mid = SceneTimeline.frame(.perch, t: 5.1, geometry: g, clips: clips, options: o)
        XCTAssertEqual(mid.phase, "hop")
        XCTAssertGreaterThan(mid.eyes!.minX, o.hopFrom!.minX)
        XCTAssertLessThan(mid.eyes!.minX, g.target.minX)
        XCTAssertLessThan(mid.squash, 1)
        XCTAssertNotNil(SceneTimeline.frame(.perch, t: 5.05, geometry: g, clips: clips, options: o).bolt, "далеко — короткая молния")
        XCTAssertEqual(SceneTimeline.frame(.perch, t: 5.25, geometry: g, clips: clips, options: o).eyes, g.target)
        XCTAssertEqual(SceneTimeline.frameInterval(.perch, t: 5.1, options: o), 1.0 / 24, accuracy: 0.001)
        o.hopAt = nil
        o.perchHold = true
        let held = SceneTimeline.frame(.perch, t: 6, geometry: g, clips: clips, options: o)
        XCTAssertEqual(held.squash, 0.9)
        XCTAssertGreaterThanOrEqual(held.glitch, 1)
        // Обрыв — молния домой за `recallDuration`.
        let o2 = options()
        XCTAssertEqual(SceneTimeline.frame(.perch, t: 4.1, geometry: g, clips: clips, options: o2, abortedAt: 4).phase, "recall")
        XCTAssertTrue(SceneTimeline.frame(.perch, t: 4 + SceneTimeline.recallDuration + 0.001, geometry: g, clips: clips, options: o2, abortedAt: 4).done)
    }

    func testPerchHotspotsShooAndBubble() {
        let o = options()
        let g = geometry()
        let speak = SceneLayout.hotspots(.perch, t: 2.5, geometry: g, clips: clips, options: o)
        XCTAssertEqual(speak.map(\.kind), [.button("bubble"), .button("shoo")])
        XCTAssertEqual(SceneLayout.hit(speak, CGPoint(x: g.target.midX, y: g.target.midY))?.kind, .button("shoo"))
        XCTAssertEqual(SceneLayout.hit(speak, CGPoint(x: g.bubble!.midX, y: g.bubble!.midY))?.kind, .button("bubble"))
        XCTAssertNil(SceneLayout.hit(speak, CGPoint(x: g.target.minX - 200, y: g.target.midY)), "мимо — сквозь панель")
        let sit = SceneLayout.hotspots(.perch, t: PerchTimeline.speakEnd(o) + 1, geometry: g, clips: clips, options: o)
        XCTAssertEqual(sit.map(\.kind), [.button("shoo")])
        XCTAssertTrue(SceneLayout.hotspots(.perch, t: 0.5, geometry: g, clips: clips, options: o).isEmpty, "в перелёте — сквозь")
    }
}
