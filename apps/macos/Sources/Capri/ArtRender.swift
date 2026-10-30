import SwiftUI
import AppKit

/// `Capri --render-art DIR`: рисует значок (AppIcon.png, 1024×1024) и превью настроений в PNG и выходит.
/// Запущенный экземпляр не трогает — им перерисовывают значок после правок персонажа и проверяют рисунки.
enum ArtRender {
    static func run(_ dir: String) -> Never {
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        do { try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true) }
        catch { print("render-art:", error.localizedDescription); exit(1) }
        let ok = MainActor.assumeIsolated { () -> Bool in
            var ok = save(IconView(), size: 1024, to: out.appendingPathComponent("AppIcon.png"))
            let moods: [(String, CapriMood)] = [("idle", .idle), ("listening", .listening), ("thinking", .thinking),
                                                ("speaking", .speaking), ("alert", .alert), ("error", .error)]
            for (name, mood) in moods {
                // Несколько рисунков подряд: видно моргание, слоги, подскок.
                for n in [0, 1, 5, 14] {
                    if !save(Still(mood: mood, n: n, style: .bust).background(Color.black), size: 160,
                         to: out.appendingPathComponent("\(name)-\(n).png")) { ok = false }
                }
                if !save(Still(mood: mood, n: 30, style: .mask).frame(width: 48, height: 26).background(Color.black),
                     size: nil, to: out.appendingPathComponent("mask-\(name).png")) { ok = false }
            }
            return ok
        }
        print(ok ? "ok" : "failed", out.path)
        exit(ok ? 0 : 1)
    }

    /// Ошибка одного рисунка не останавливает остальные, но итог — код 1.
    @MainActor private static func save<V: View>(_ view: V, size: CGFloat?, to url: URL) -> Bool {
        let r = ImageRenderer(content: size.map { AnyView(view.frame(width: $0, height: $0)) } ?? AnyView(view))
        r.scale = size == 1024 ? 1 : 3
        guard let cg = r.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            print("render-art: не нарисовался", url.lastPathComponent); return false
        }
        do { try png.write(to: url); return true } catch { print("render-art:", error.localizedDescription); return false }
    }

    /// Неподвижный рисунок настроения: `n` — номер рисунка.
    private struct Still: View {
        var mood: CapriMood
        var n: Int
        var style: CapriFace.Style
        var body: some View {
            Canvas { ctx, size in
                let p = CapriPose.at(mood, drawing: n, since: 10, still: false)
                if style == .mask { CapriDrawing.mask(&ctx, size: size, p) }
                else { CapriDrawing.bust(&ctx, size: size, p, boil: n % 3, drawing: n) }
            }
        }
    }

    /// Значок: тёмная плашка macOS-формы, Capri крупным планом (лицо по центру).
    private struct IconView: View {
        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 185, style: .continuous)
            ZStack {
                shape.fill(Color(red: 0.04, green: 0.03, blue: 0.06))
                Canvas { ctx, size in
                    CapriDrawing.bust(&ctx, size: size, CapriPose.at(.idle, drawing: 40, since: 10, still: true), boil: 0, drawing: 40, framed: false)
                }
                .frame(width: 900, height: 900)
                .offset(y: 30)
            }
            .frame(width: 824, height: 824)
            .clipShape(shape)
            .overlay(shape.stroke(Color(red: 0.91, green: 0.09, blue: 0.25), lineWidth: 10))
            .frame(width: 1024, height: 1024)
        }
    }
}
