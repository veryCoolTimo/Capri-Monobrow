import Foundation
import CoreGraphics

/// Где сидит Capri на окне: край, смещение глаз от угла окна (чтобы пересчитать место, когда окно сдвинули),
/// глаза и пузырь реплики (глобально, AppKit).
public struct PerchSpot: Equatable {
    public enum Edge: String, CaseIterable, Codable {
        /// На верхнем крае справа (глаза на ¾ над краем).
        case topRight
        /// На верхнем крае слева — правее кнопок окна.
        case topLeft
        /// Висит на правом боку (наполовину за краем, у верхней трети).
        case right
        /// Сидит на нижнем крае снаружи.
        case bottom
    }

    public var edge: Edge
    /// `eyes.origin` − угол окна для этого края.
    public var offset: CGVector
    public var eyes: CGRect
    public var bubble: CGRect?

    public init(edge: Edge, offset: CGVector, eyes: CGRect, bubble: CGRect?) {
        self.edge = edge; self.offset = offset; self.eyes = eyes; self.bubble = bubble
    }
}

/// Чистая геометрия посадки: кандидаты по порядку, перекрытия окнами сверху, кнопки окна, пузырь, панель.
public enum PerchLayout {
    /// Окно меньше — не садится.
    public static let minWindow = CGSize(width: 320, height: 200)
    /// Кнопки «закрыть/свернуть/развернуть»: левый верхний угол окна (их Capri никогда не закрывает).
    public static let lightsSize = CGSize(width: 84, height: 30)
    /// Ширина буквы пузыря (моно 11 pt) и поля.
    public static let charWidth: CGFloat = 6.7
    public static let bubbleHeight: CGFloat = 24

    /// Размер пузыря под реплику из `chars` знаков.
    public static func bubbleSize(chars: Int) -> CGSize {
        CGSize(width: (CGFloat(min(PerchLines.maxChars, max(4, chars))) * charWidth + 22).rounded(.up), height: bubbleHeight)
    }

    /// Кнопки окна (глобально).
    public static func lights(_ w: CGRect) -> CGRect {
        CGRect(x: w.minX, y: w.maxY - lightsSize.height, width: lightsSize.width, height: lightsSize.height)
    }

    /// Угол окна, от которого считается смещение глаз для края.
    static func anchor(_ e: PerchSpot.Edge, _ w: CGRect) -> CGPoint {
        switch e {
        case .topRight: CGPoint(x: w.maxX, y: w.maxY)
        case .topLeft: CGPoint(x: w.minX, y: w.maxY)
        case .right: CGPoint(x: w.maxX, y: w.maxY)
        case .bottom: CGPoint(x: w.maxX, y: w.minY)
        }
    }

    /// Глаза на краю `e` окна `w`.
    public static func candidate(_ e: PerchSpot.Edge, window w: CGRect, size s: CGSize = SceneTimeline.eyesSize) -> CGRect {
        switch e {
        case .topRight: CGRect(x: w.maxX - 48 - s.width, y: w.maxY - s.height * 0.25, width: s.width, height: s.height)
        case .topLeft: CGRect(x: w.minX + lightsSize.width + 8, y: w.maxY - s.height * 0.25, width: s.width, height: s.height)
        case .right: CGRect(x: w.maxX - s.width * 0.5, y: w.maxY - w.height * 0.3 - s.height / 2, width: s.width, height: s.height)
        case .bottom: CGRect(x: w.maxX - 48 - s.width, y: w.minY - s.height * 0.75, width: s.width, height: s.height)
        }
    }

    /// Глаза годятся: целиком на видимой части экрана, не под окнами выше целевого, кнопки окна не закрыты.
    static func fits(_ eyes: CGRect, window w: CGRect, above: [CGRect], visible: CGRect) -> Bool {
        guard visible.contains(eyes) else { return false }
        if eyes.intersects(lights(w)) { return false }
        let probe = eyes.insetBy(dx: 4, dy: 4)
        return !above.contains { $0.intersects(probe) }
    }

    /// Пузырь у глаз: над ними (по правому краю), слева, снизу — первый, что целиком на экране и не закрывает
    /// кнопки окна; сдвигается по горизонтали внутрь экрана.
    public static func bubble(for eyes: CGRect, size b: CGSize, window w: CGRect, visible: CGRect) -> CGRect? {
        let tries = [
            // Над волосами мини-маски (`hairClear`), а не поверх них.
            CGRect(x: eyes.maxX - b.width, y: eyes.maxY + hairClear(eyes.size), width: b.width, height: b.height),
            CGRect(x: eyes.minX - 6 - b.width, y: eyes.midY - b.height / 2, width: b.width, height: b.height),
            CGRect(x: eyes.maxX - b.width, y: eyes.minY - 4 - b.height, width: b.width, height: b.height),
        ]
        for var r in tries {
            r.origin.x = min(max(r.minX, visible.minX + 4), visible.maxX - 4 - r.width)
            guard visible.contains(r), !r.intersects(eyes), !r.intersects(lights(w)) else { continue }
            return r
        }
        return nil
    }

    /// Первое подходящее место по порядку `prefer`. nil — сесть некуда (в угол не уходит).
    public static func spot(window w: CGRect, above: [CGRect], visible: CGRect, bubble b: CGSize,
                            prefer: [PerchSpot.Edge] = PerchSpot.Edge.allCases,
                            size: CGSize = SceneTimeline.eyesSize) -> PerchSpot? {
        guard w.width >= minWindow.width, w.height >= minWindow.height else { return nil }
        for e in prefer {
            let eyes = candidate(e, window: w, size: size)
            guard fits(eyes, window: w, above: above, visible: visible),
                  let bub = bubble(for: eyes, size: b, window: w, visible: visible) else { continue }
            let a = anchor(e, w)
            return PerchSpot(edge: e, offset: CGVector(dx: eyes.minX - a.x, dy: eyes.minY - a.y), eyes: eyes, bubble: bub)
        }
        return nil
    }

    /// Окно сдвинули/поменяли размер: то же место относительно угла; не годится — то же правило с этим краем
    /// первым. nil — сесть некуда (уходит).
    public static func place(_ s: PerchSpot, window w: CGRect, above: [CGRect], visible: CGRect,
                             size: CGSize = SceneTimeline.eyesSize) -> PerchSpot? {
        let a = anchor(s.edge, w)
        let eyes = CGRect(x: a.x + s.offset.dx, y: a.y + s.offset.dy, width: size.width, height: size.height)
        let b = s.bubble?.size ?? bubbleSize(chars: 20)
        if w.width >= minWindow.width, w.height >= minWindow.height, fits(eyes, window: w, above: above, visible: visible),
           let bub = bubble(for: eyes, size: b, window: w, visible: visible) {
            var out = s
            out.eyes = eyes
            out.bubble = bub
            return out
        }
        let order = [s.edge] + PerchSpot.Edge.allCases.filter { $0 != s.edge }
        return spot(window: w, above: above, visible: visible, bubble: b, prefer: order, size: size)
    }

    /// Запас вокруг полосы глаз под мини-маску: руки машут вверх, держатся вниз, волосы и «z» — над маской.
    public static func rigMargin(_ eyes: CGSize) -> CGSize { CGSize(width: eyes.width * 0.4, height: eyes.height * 0.9) }

    /// Сколько над полосой глаз занимают волосы мини-маски (`RigMoments.hair`): пузырь сверху — выше них.
    public static func hairClear(_ eyes: CGSize) -> CGFloat { (eyes.height * 0.45).rounded() }

    /// Полоса глаз с запасом рига.
    public static func rigBox(_ eyes: CGRect) -> CGRect {
        let m = rigMargin(eyes.size)
        return eyes.insetBy(dx: -m.width, dy: -m.height)
    }

    /// Панель сидения: глаза (с запасом на наклон, глитч и сплющивание) и пузырь; в пределах `visible`.
    public static func panel(_ s: PerchSpot, visible: CGRect) -> CGRect {
        var r = rigBox(s.eyes)
        if let b = s.bubble { r = r.union(b.insetBy(dx: -4, dy: -4)) }
        return r.integral.intersection(visible.insetBy(dx: -40, dy: -40))
    }
}

/// Окно, на которое садится Capri: рамка (AppKit), номер, окна над ним и экран, где оно (по центру окна).
public struct PerchWindow: Equatable {
    public var rect: CGRect
    public var number: UInt32
    public var above: [CGRect]
    /// Рамка и видимая часть экрана (AppKit).
    public var screen: CGRect
    public var visible: CGRect

    public init(rect: CGRect, number: UInt32, above: [CGRect], screen: CGRect, visible: CGRect) {
        self.rect = rect; self.number = number; self.above = above; self.screen = screen; self.visible = visible
    }

    /// Переднее обычное окно приложения `pid` из списка `CGWindowListCopyWindowInfo` (спереди назад, координаты CG).
    /// `screens` — рамка и видимая часть каждого экрана (AppKit). Над ним — обычные и плавающие окна других
    /// приложений (не Capri, не строка меню/Dock). `number` — только это окно (опрос, пока сидит). nil — окна нет.
    public static func find(windows: [WindowInfo], pid: Int32, number: UInt32? = nil, own: Int32,
                            screens: [(frame: CGRect, visible: CGRect)], primaryHeight: CGFloat) -> PerchWindow? {
        guard let i = windows.firstIndex(where: { w in
            if let n = number { return w.number == n }
            return w.pid == pid && w.layer == 0 && w.alpha > 0 && w.bounds.width >= 120 && w.bounds.height >= 80
        }) else { return nil }
        let r = SceneLayout.appKit(windows[i].bounds, primaryHeight: primaryHeight)
        let mid = CGPoint(x: r.midX, y: r.midY)
        guard let s = screens.first(where: { $0.frame.contains(mid) }) else { return nil }
        let above = windows[..<i].filter { o in
            o.pid != own && o.alpha > 0 && o.layer >= 0 && o.layer < 20 && o.bounds.width > 4 && o.bounds.height > 4
        }.map { SceneLayout.appKit($0.bounds, primaryHeight: primaryHeight) }
        return PerchWindow(rect: r, number: windows[i].number, above: above, screen: s.frame, visible: s.visible)
    }
}
