import Foundation
import CoreGraphics

/// Окно, на котором сидит Capri, пока она сидит: опрос рамки (2 Гц, при перетаскивании — 10 Гц) и мышь →
/// остаться, держаться (окно тащат), перепрыгнуть на новое место, уйти.
public struct PerchTracker: Equatable {
    public enum Sample: Equatable {
        /// Рамка окна (nil — пропало с экрана), переднее ли оно ещё, на весь ли экран, окна над ним, видимая часть
        /// экрана с окном.
        case bounds(CGRect?, frontmost: Bool, fullscreen: Bool, above: [CGRect], visible: CGRect, at: Double)
        /// Глобальная мышь: нажали и тянут / отпустили.
        case dragBegan(Double)
        case dragEnded(Double)
    }

    public enum Action: Equatable {
        case stay
        /// Окно едет — глаза держатся на месте (глитч 1, чуть сплющены).
        case hold
        case hop(PerchSpot)
        case leave(String)
    }

    /// Опрос рамки: обычно и во время перетаскивания (с).
    public static let calmPoll = 0.5
    public static let dragPoll = 0.1
    /// Окно встало после перетаскивания на столько — прыжок на новое место.
    public static let settle = 0.3

    public private(set) var spot: PerchSpot
    public private(set) var window: CGRect
    public private(set) var dragging = false
    /// Рамка менялась и ещё не устоялась.
    public private(set) var moving = false
    public private(set) var changedAt: Double

    public init(spot: PerchSpot, window: CGRect, at: Double = 0) {
        self.spot = spot; self.window = window; changedAt = at
    }

    public mutating func apply(_ s: Sample) -> Action {
        switch s {
        case .dragBegan:
            dragging = true
            return moving ? .hold : .stay
        case .dragEnded(let at):
            dragging = false
            if moving { changedAt = at; return .hold }
            return .stay
        case let .bounds(rect, frontmost, fullscreen, above, visible, at):
            guard let rect else { return .leave("gone") }
            if !frontmost { return .leave("switched") }
            if fullscreen { return .leave("fullscreen") }
            if rect != window {
                window = rect
                changedAt = at
                if dragging { moving = true; return .hold }
                // Сдвиг без мыши (ресайз, Stage Manager, другой Space): сразу на новое место. Мышь может быть ещё
                // зажата, а монитор её не увидел — тогда это просто следующий прыжок.
                moving = false
                return relocate(above: above, visible: visible)
            }
            if moving {
                guard !dragging, at - changedAt >= Self.settle else { return .hold }
                moving = false
                return relocate(above: above, visible: visible)
            }
            // Окно стоит, но его место накрыло другое окно.
            let probe = spot.eyes.insetBy(dx: 4, dy: 4)
            if above.contains(where: { $0.intersects(probe) }) { return .leave("covered") }
            return .stay
        }
    }

    private mutating func relocate(above: [CGRect], visible: CGRect) -> Action {
        guard let next = PerchLayout.place(spot, window: window, above: above, visible: visible) else { return .leave("noSpot") }
        if next == spot { return .stay }
        spot = next
        return .hop(next)
    }

    /// Когда опросить рамку снова.
    public func nextPoll(_ now: Double) -> Double { now + (dragging || moving ? Self.dragPoll : Self.calmPoll) }
}
