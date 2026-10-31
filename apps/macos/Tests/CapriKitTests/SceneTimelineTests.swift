import XCTest
import CoreGraphics
@testable import CapriKit

final class SceneTimelineTests: XCTestCase {
    let visible = CGRect(x: 0, y: 0, width: 1512, height: 944)
    var home: CGRect { CGRect(x: 600, y: 950, width: 32, height: 16) }

    func geometry(_ kind: SceneKind) -> SceneGeometry {
        let target = SceneLayout.corner(visible, size: SceneTimeline.eyesSize)
        switch kind {
        case .window: return SceneGeometry(home: home, target: target, area: SceneLayout.windowForm(visible), visible: visible)
        case .takeover: return SceneGeometry(home: home, target: target, area: SceneLayout.takeoverArea(window: nil, visible: visible), visible: visible)
        default: return SceneGeometry(home: home, target: target, visible: visible)
        }
    }

    let all: Set<String> = ["look", "close", "many", "slits", "appear", "talk", "burst", "tele_out", "tele_in", "melt"]

    func testOutsideDurationIsHome() {
        for k in SceneKind.allCases {
            for t in [-1, -0.001, SceneTimeline.duration(k), SceneTimeline.duration(k) + 3] {
                let f = SceneTimeline.frame(k, t: t, geometry: geometry(k), clips: all)
                XCTAssertTrue(f.done, "\(k) \(t)")
                XCTAssertNil(f.eyes)
                XCTAssertNil(f.bolt)
            }
            XCTAssertLessThanOrEqual(SceneTimeline.duration(k), 8)
        }
    }

    func testCalmPartsHaveNoBoltAndRunSlower() {
        for k in SceneKind.allCases {
            guard let c = SceneTimeline.calm(k) else {
                XCTAssertEqual(SceneTimeline.frameInterval(k, t: 2), 1.0 / 24); continue
            }
            var t = c.lowerBound
            while t < c.upperBound {
                let f = SceneTimeline.frame(k, t: t, geometry: geometry(k), clips: all)
                XCTAssertNil(f.bolt, "\(k) \(t)")
                XCTAssertEqual(f.flash, 0, "\(k) \(t)")
                XCTAssertNotNil(f.eyes, "\(k) \(t)")
                t += 1.0 / 48
            }
            XCTAssertEqual(SceneTimeline.frameInterval(k, t: c.lowerBound), 1.0 / 12)
            XCTAssertEqual(SceneTimeline.frameInterval(k, t: c.lowerBound, aborted: true), 1.0 / 24)
            XCTAssertEqual(SceneTimeline.frameInterval(k, t: c.upperBound), 1.0 / 24)
        }
    }

    func testTeleportPhases() {
        let g = geometry(.teleport)
        func at(_ t: Double) -> SceneFrame { SceneTimeline.frame(.teleport, t: t, geometry: g, clips: all) }
        XCTAssertEqual(at(0.1).phase, "out")
        XCTAssertEqual(at(0.1).clip, "tele_out")
        XCTAssertEqual(at(0.1).glitch, 3)
        XCTAssertEqual(at(0.1).eyes, g.home)
        XCTAssertEqual(at(0.35).phase, "jump")
        XCTAssertNil(at(0.35).eyes)
        XCTAssertNotNil(at(0.35).bolt)
        XCTAssertEqual(at(0.35).bolt?.to, CGPoint(x: g.target.midX, y: g.target.midY))
        // Вспышка в конце перелёта, 2 кадра.
        XCTAssertGreaterThan(at(0.43).flash, 0)
        XCTAssertEqual(at(0.6).phase, "in")
        XCTAssertEqual(at(0.6).clip, "tele_in")
        XCTAssertEqual(at(2).phase, "look")
        XCTAssertEqual(at(2).clip, "look")
        XCTAssertEqual(at(2).eyes, g.target)
        XCTAssertEqual(at(4.5).phase, "leave")
        XCTAssertEqual(at(4.75).phase, "back")
        XCTAssertEqual(at(4.75).bolt?.to, CGPoint(x: g.home.midX, y: g.home.midY))
        XCTAssertEqual(at(4.9).phase, "home")
        XCTAssertEqual(at(4.9).eyes, g.home)
    }

    func testFallbackWithoutTeleClips() {
        let g = geometry(.teleport)
        let old: Set<String> = ["look", "close", "appear"]
        let out = SceneTimeline.frame(.teleport, t: 0.25, geometry: g, clips: old)
        XCTAssertEqual(out.clip, "close")
        XCTAssertLessThan(out.squash, 0.3)
        let into = SceneTimeline.frame(.teleport, t: 0.55, geometry: g, clips: old)
        XCTAssertEqual(into.clip, "appear")
        XCTAssertEqual(into.glitch, 4)
        // Совсем без клипов (встроенные кадры) — look.
        XCTAssertEqual(SceneTimeline.frame(.teleport, t: 0.55, geometry: g, clips: []).clip, "look")
        XCTAssertEqual(SceneTimeline.frame(.window, t: 7.2, geometry: geometry(.window), clips: old).glitch, 4)
    }

    /// Глаза не прыгают больше чем на N pt за кадр 24 fps — кроме телепорта (между ними кадры без глаз).
    func testContinuousMotion() {
        for k in SceneKind.allCases {
            let g = geometry(k)
            var prev: CGRect?
            var t = 0.0
            while t < SceneTimeline.duration(k) {
                let f = SceneTimeline.frame(k, t: t, geometry: g, clips: all, text: 20, lines: [20, 10])
                if let e = f.eyes, let p = prev {
                    let d = hypot(e.midX - p.midX, e.midY - p.midY)
                    XCTAssertLessThan(d, 20, "\(k) t=\(t) \(f.phase)")
                }
                prev = f.eyes
                t += 1.0 / 24
            }
        }
    }

    func testWindowUnfoldsTypesAndCloses() {
        let g = geometry(.window)
        let w = g.area!
        let line = SceneTimeline.frame(.window, t: 0.7, geometry: g, clips: all).window!
        XCTAssertLessThanOrEqual(line.rect.height, 2)
        XCTAssertFalse(line.chrome)
        let full = SceneTimeline.frame(.window, t: 3, geometry: g, clips: all, text: 12).window!
        XCTAssertEqual(full.rect, w)
        XCTAssertTrue(full.chrome)
        XCTAssertEqual(full.typed, 12)
        let early = SceneTimeline.frame(.window, t: 1.3, geometry: g, clips: all, text: 12).window!
        XCTAssertLessThan(early.typed, 12)
        XCTAssertTrue(w.contains(SceneTimeline.closeRect(w)))
        XCTAssertTrue(w.contains(SceneTimeline.eyesInWindow(w)))
        XCTAssertEqual(SceneTimeline.frame(.window, t: 7.3, geometry: g, clips: all).clip, "melt")
    }

    func testTakeoverCursorTextAndCollapse() {
        let g = geometry(.takeover)
        let mid = SceneTimeline.frame(.takeover, t: 3.0, geometry: g, clips: all, lines: [20, 10]).takeover!
        XCTAssertEqual(mid.wave, 1)
        XCTAssertTrue(g.area!.contains(mid.cursor!))
        XCTAssertEqual(mid.typed[0], 20)
        XCTAssertGreaterThan(mid.graffiti, 0.9)
        XCTAssertEqual(SceneTimeline.frame(.takeover, t: 1.85, geometry: g, clips: all, lines: [20, 10]).takeover!.rings.count, 1)
        let end = SceneTimeline.frame(.takeover, t: 4.25, geometry: g, clips: all, lines: [20, 10])
        XCTAssertEqual(end.glitch, 4)
        XCTAssertLessThan(end.takeover!.collapse, 0.2)
    }

    func testAbortRecallsHome() {
        let g = geometry(.teleport)
        let f = SceneTimeline.frame(.teleport, t: 2.05, geometry: g, clips: all, abortedAt: 2.0)
        XCTAssertEqual(f.phase, "recall")
        XCTAssertEqual(f.eyes, g.target)
        let b = SceneTimeline.frame(.teleport, t: 2.3, geometry: g, clips: all, abortedAt: 2.0)
        XCTAssertEqual(b.bolt?.to, CGPoint(x: g.home.midX, y: g.home.midY))
        XCTAssertTrue(SceneTimeline.frame(.teleport, t: 2.0 + SceneTimeline.recallDuration, geometry: g, abortedAt: 2.0).done)
    }

    func testVibeNodsAndNotes() {
        let g = geometry(.vibe)
        let frames = stride(from: 1.0, to: 6.4, by: 1.0 / 24).map { SceneTimeline.frame(.vibe, t: $0, geometry: g, clips: all) }
        XCTAssertTrue(frames.allSatisfy { $0.phase == "vibe" })
        let ys = Set(frames.compactMap { $0.eyes.map { Int($0.minY) } })
        XCTAssertGreaterThan(ys.count, 2, "кивает")
        XCTAssertTrue(frames.contains { $0.clip == "slits" })
        XCTAssertTrue(frames.contains { !$0.notes.isEmpty })
        XCTAssertNil(frames.first { $0.bolt != nil })
    }

    func testLayoutClampsToVisible() {
        let c = SceneLayout.corner(visible, size: CGSize(width: 5000, height: 60))
        XCTAssertTrue(visible.contains(c))
        XCTAssertEqual(SceneLayout.clamp(CGRect(x: -50, y: 2000, width: 100, height: 50), to: visible),
                       CGRect(x: 0, y: 894, width: 100, height: 50))
        // Окно у строки меню — сидеть негде; окно ниже — глаза на его верхнем крае.
        XCTAssertNil(SceneLayout.onWindow(CGRect(x: 100, y: 100, width: 800, height: 830), visible: visible))
        let w = CGRect(x: 100, y: 100, width: 800, height: 500)
        let on = SceneLayout.onWindow(w, visible: visible)!
        XCTAssertTrue(on.minY < w.maxY && on.maxY > w.maxY)
        XCTAssertTrue(visible.contains(on))
        XCTAssertNil(SceneLayout.onWindow(CGRect(x: -200, y: 100, width: 800, height: 500), visible: visible))
        // Захват: окно обрезается по экрану; крошечное — угол.
        let big = SceneLayout.takeoverArea(window: CGRect(x: 1000, y: 100, width: 900, height: 600), visible: visible)
        XCTAssertEqual(big.maxX, visible.maxX)
        XCTAssertEqual(SceneLayout.takeoverArea(window: CGRect(x: 0, y: 0, width: 100, height: 100), visible: visible).size,
                       SceneTimeline.takeoverSize)
        XCTAssertEqual(SceneLayout.appKit(CGRect(x: 10, y: 20, width: 100, height: 50), primaryHeight: 982),
                       CGRect(x: 10, y: 912, width: 100, height: 50))
    }
}
