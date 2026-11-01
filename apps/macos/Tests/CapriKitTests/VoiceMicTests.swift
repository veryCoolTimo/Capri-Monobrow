import XCTest
import CoreGraphics
@testable import CapriKit

final class VoiceMicTests: XCTestCase {
    let builtIn = MicDevice(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", transport: .builtIn)
    let pods = MicDevice(uid: "00-11-22:input", name: "AirPods Pro", transport: .bluetooth)
    let usb = MicDevice(uid: "usb-mic", name: "USB Mic", transport: .usb)

    func testTransportCodes() {
        XCTAssertEqual(MicDevice.transport(code: 0x626C_746E), .builtIn)
        XCTAssertEqual(MicDevice.transport(code: 0x626C_7565), .bluetooth)
        XCTAssertEqual(MicDevice.transport(code: 0x626C_656F), .bluetooth)
        XCTAssertEqual(MicDevice.transport(code: 0x7573_6220), .usb)
        XCTAssertEqual(MicDevice.transport(code: 0x7669_7274), .virtual)
        XCTAssertEqual(MicDevice.transport(code: 0x6363_7764), .continuity)
        XCTAssertEqual(MicDevice.transport(code: 1), .other)
    }

    func testPreferenceStorage() {
        XCTAssertEqual(MicPreference(stored: nil), .builtIn, "по умолчанию — встроенный")
        XCTAssertEqual(MicPreference(stored: ""), .builtIn)
        XCTAssertEqual(MicPreference(stored: "default"), .systemDefault)
        XCTAssertEqual(MicPreference(stored: "uid:abc:input"), .device(uid: "abc:input"))
        XCTAssertEqual(MicPreference(stored: "uid:"), .builtIn)
        XCTAssertEqual(MicPreference(stored: "мусор"), .builtIn)
        for p in [MicPreference.builtIn, .systemDefault, .device(uid: "x:y")] { XCTAssertEqual(MicPreference(stored: p.stored), p) }
    }

    func testResolveBuiltInDefault() {
        let r = MicChoice.resolve(.builtIn, devices: [pods, builtIn])
        XCTAssertEqual(r.pick, .device(builtIn), "AirPods — системный, а слушаем встроенный")
        XCTAssertNil(r.note)
        let none = MicChoice.resolve(.builtIn, devices: [pods])
        XCTAssertEqual(none.pick, .systemDefault)
        XCTAssertNotNil(none.note)
    }

    func testResolveChosenDeviceAndFallback() {
        XCTAssertEqual(MicChoice.resolve(.device(uid: usb.uid), devices: [builtIn, usb]).pick, .device(usb))
        let gone = MicChoice.resolve(.device(uid: usb.uid), devices: [builtIn, pods], savedName: "USB Mic")
        XCTAssertEqual(gone.pick, .device(builtIn), "пропал — встроенный")
        XCTAssertEqual(gone.note, "«USB Mic» не подключён — слушаю встроенный")
        let both = MicChoice.resolve(.device(uid: usb.uid), devices: [pods])
        XCTAssertEqual(both.pick, .systemDefault, "нет и встроенного — системный")
        XCTAssertEqual(both.note, "Выбранный микрофон не подключён — слушаю системный")
        XCTAssertEqual(MicChoice.resolve(.systemDefault, devices: []).pick, .systemDefault)
    }

    func testOptions() {
        let o = MicChoice.options(devices: [pods, builtIn, usb], defaultUID: pods.uid, pref: .builtIn, savedName: nil)
        XCTAssertEqual(o.map(\.tag), ["builtin", "default", "uid:" + pods.uid, "uid:usb-mic"])
        XCTAssertEqual(o[0].title, "Встроенный — MacBook Pro Microphone")
        XCTAssertEqual(o[1].title, "Системный по умолчанию (AirPods Pro)")
        XCTAssertTrue(o[2].title.contains("Bluetooth"), "про потерю первых секунд")
        let gone = MicChoice.options(devices: [builtIn], defaultUID: nil, pref: .device(uid: "u"), savedName: "Rode")
        XCTAssertEqual(gone.last, MicChoice.Option(tag: "uid:u", title: "Rode (не подключён)"))
        XCTAssertEqual(gone[1].title, "Системный по умолчанию")
    }

    func testLevel() {
        XCTAssertEqual(VoiceLevel.level([]), 0)
        XCTAssertEqual(VoiceLevel.level([Float](repeating: 0, count: 1600)), 0)
        XCTAssertEqual(VoiceLevel.level(rms: 0.1), 0.75, accuracy: 0.01)   // −20 дБFS
        XCTAssertEqual(VoiceLevel.level(rms: 1), 1)
        XCTAssertLessThan(VoiceLevel.level(rms: 0.0018), VoiceLevel.heard, "шум встроенного микрофона ≈ −55 дБFS")
        XCTAssertGreaterThan(VoiceLevel.level(rms: 0.03), VoiceLevel.heard, "тихая речь ≈ −30 дБFS")
        var v = 0.0
        v = VoiceLevel.smooth(v, 1)
        XCTAssertGreaterThan(v, 0.7, "подскок сразу")
        let up = v
        v = VoiceLevel.smooth(v, 0)
        XCTAssertGreaterThan(v, up * 0.6, "спад плавный")
    }

    func testHearingWatchClockStartsAtFirstChunk() {
        var w = HearingWatch(start: 10)
        XCTAssertEqual(w.status(at: 12), .waiting, "кусков ещё нет, 2 с — ждём (микрофон включается)")
        w.feed(level: 0.1, at: 12, seconds: 0.02)
        XCTAssertEqual(w.status(at: 13.4), .waiting, "1.4 с с первого куска — ещё терпим")
        XCTAssertEqual(w.status(at: 13.5), .quiet, "1.5 с только шум — «тихо»")
        for k in 0..<5 { w.feed(level: 0.6, at: 13.6 + Double(k) * 0.02, seconds: 0.02) }
        XCTAssertEqual(w.status(at: 13.7), .heard)
        w.feed(level: 0, at: 14, seconds: 0.02)
        XCTAssertEqual(w.status(at: 20), .heard, "паузы после голоса — не «не слышу»")
        XCTAssertEqual(w.chunks, 7)
        XCTAssertEqual(w.peak, 0.6)
    }

    func testHearingWatchDeadAndBluetooth() {
        XCTAssertEqual(HearingWatch(start: 0).status(at: 2.4), .waiting)
        XCTAssertEqual(HearingWatch(start: 0).status(at: 2.5), .dead, "кусков нет совсем — микрофон молчит")
        XCTAssertEqual(HearingWatch(start: 0, slow: true).status(at: 3), .waiting, "Bluetooth включается дольше")
        XCTAssertEqual(HearingWatch(start: 0, slow: true).status(at: 3.5), .dead)
        var bt = HearingWatch(start: 0, slow: true)
        bt.feed(level: 0.05, at: 1.8, seconds: 0.02)
        XCTAssertEqual(bt.status(at: 3.7), .waiting, "Bluetooth: 2 с с первого куска")
        XCTAssertEqual(bt.status(at: 3.8), .quiet)
        XCTAssertEqual(HearingWatch.text(.dead), HearingWatch.deadText)
        XCTAssertEqual(HearingWatch.text(.quiet), HearingWatch.quietText)
        XCTAssertNil(HearingWatch.text(.heard))
    }

    func testClickIsNotVoice() {
        var w = HearingWatch(start: 0)
        w.feed(level: 0.9, at: 0.5, seconds: 0.02)   // щелчок клавиши
        w.feed(level: 0.05, at: 0.52, seconds: 0.02)
        w.feed(level: 0.9, at: 0.6, seconds: 0.02)
        XCTAssertNil(w.heardAt, "короткие громкие куски вразбивку — не голос")
        for k in 0..<4 { w.feed(level: 0.5, at: 0.7 + Double(k) * 0.02, seconds: 0.02) }
        XCTAssertNotNil(w.heardAt, "80 мс подряд — голос")
        var long = HearingWatch(start: 0)
        long.feed(level: 0.5, at: 0.3, seconds: 0.1)
        XCTAssertNotNil(long.heardAt, "кусок 100 мс громкий — голос")
    }

    func testStall() {
        var w = HearingWatch(start: 0)
        XCTAssertFalse(w.stalled(at: 5), "кусков не было — это «молчит», а не «встал»")
        w.feed(level: 0.6, at: 1, seconds: 0.1)
        XCTAssertFalse(w.stalled(at: 1.4))
        XCTAssertTrue(w.stalled(at: 1.5), "0.5 с без кусков после звука — захват встал")
    }

    func testFallbackSkipsLostDevice() {
        // Список CoreAudio ещё держит ушедшие AirPods — их не берём.
        let r = MicChoice.fallback(lost: pods.uid, devices: [pods, builtIn], defaultUID: pods.uid, why: "отключился")
        XCTAssertEqual(r?.pick, .device(builtIn))
        XCTAssertEqual(r?.note, "Микрофон отключился — слушаю встроенный")
        let noBuiltIn = MicChoice.fallback(lost: pods.uid, devices: [pods, usb], defaultUID: pods.uid, why: "x")
        XCTAssertEqual(noBuiltIn?.pick, .device(usb), "системный — это ушедший, берём оставшийся")
        let sys = MicChoice.fallback(lost: pods.uid, devices: [pods, usb], defaultUID: usb.uid, why: "x")
        XCTAssertEqual(sys?.pick, .systemDefault)
        XCTAssertEqual(MicChoice.fallback(lost: builtIn.uid, devices: [pods, builtIn], defaultUID: pods.uid, why: "x")?.pick, .systemDefault,
                       "встал встроенный — системный")
        XCTAssertNil(MicChoice.fallback(lost: builtIn.uid, devices: [builtIn], defaultUID: builtIn.uid, why: "x"))
    }

    func testSlowAndUID() {
        XCTAssertTrue(MicChoice.slow(.device(pods), devices: [pods, builtIn], defaultUID: nil))
        XCTAssertFalse(MicChoice.slow(.device(builtIn), devices: [pods, builtIn], defaultUID: pods.uid))
        XCTAssertTrue(MicChoice.slow(.systemDefault, devices: [pods, builtIn], defaultUID: pods.uid), "системный — это AirPods")
        XCTAssertEqual(MicChoice.uid(.systemDefault, defaultUID: "d"), "d")
        XCTAssertEqual(MicChoice.uid(.device(usb), defaultUID: "d"), usb.uid)
    }

    func testMouthFollowsLevel() {
        let r = CGRect(x: 0, y: 0, width: 20, height: 10)
        let quiet = VoiceMouth.points(in: r, tick: 3, level: 0)
        let loud = VoiceMouth.points(in: r, tick: 3, level: 1)
        func spread(_ p: [CGPoint]) -> CGFloat { (p.map(\.y).max() ?? 0) - (p.map(\.y).min() ?? 0) }
        XCTAssertEqual(quiet.count, 7)
        XCTAssertGreaterThan(spread(loud), r.height * 0.5)
        XCTAssertLessThanOrEqual(spread(loud), r.height + 0.01)
        XCTAssertEqual(spread(quiet), 0, "тишина — ровная черта: видно, что голоса нет")
        XCTAssertEqual(spread(VoiceMouth.points(in: r, tick: 3, level: VoiceLevel.heard - 0.01)), 0)
        XCTAssertFalse(VoiceLevel.speaking(0.1))
        XCTAssertTrue(VoiceLevel.speaking(VoiceLevel.heard))
        XCTAssertEqual(loud.first, CGPoint(x: 0, y: 5))
        XCTAssertEqual(loud.last, CGPoint(x: 20, y: 5))
        XCTAssertNotEqual(VoiceMouth.points(in: r, tick: 4, level: 0.5), VoiceMouth.points(in: r, tick: 5, level: 0.5), "кипит по кадрам")
        for p in loud { XCTAssertTrue(p.x >= 0 && p.x <= 20) }
    }

    func testHint() {
        XCTAssertTrue(VoiceHint.show(voiceOn: true, successes: 0))
        XCTAssertTrue(VoiceHint.show(voiceOn: true, successes: 2))
        XCTAssertFalse(VoiceHint.show(voiceOn: true, successes: 3))
        XCTAssertFalse(VoiceHint.show(voiceOn: false, successes: 0))
    }
}
