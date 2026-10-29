import CoreGraphics

/// Геометрия notch-панели. Все прямоугольники — в глобальных координатах AppKit
/// (начало внизу слева, у дополнительных мониторов origin бывает отрицательным).
public struct NotchScreen: Equatable {
    public var frame: CGRect
    public var visibleFrame: CGRect
    /// `NSScreen.safeAreaInsets.top`; 0 — выреза нет.
    public var safeAreaTop: CGFloat
    /// `NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea` как их отдаёт AppKit.
    public var auxiliaryTopLeft: CGRect?
    public var auxiliaryTopRight: CGRect?

    public init(frame: CGRect, visibleFrame: CGRect, safeAreaTop: CGFloat,
                auxiliaryTopLeft: CGRect?, auxiliaryTopRight: CGRect?) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.safeAreaTop = safeAreaTop
        self.auxiliaryTopLeft = auxiliaryTopLeft
        self.auxiliaryTopRight = auxiliaryTopRight
    }
}

public enum NotchGeometry {
    public static let sideWidth: CGFloat = 76
    public static let pillSize = CGSize(width: 200, height: 26)
    public static let expandedSize = CGSize(width: 440, height: 320)

    /// Прямоугольник физического выреза или nil, если его нет.
    /// Вспомогательные области AppKit отдаёт в координатах экрана; если они уже
    /// глобальные (лежат внутри frame), смещение не добавляем.
    public static func notchRect(_ s: NotchScreen) -> CGRect? {
        guard s.safeAreaTop > 0, var left = s.auxiliaryTopLeft, var right = s.auxiliaryTopRight else { return nil }
        if !s.frame.contains(CGPoint(x: left.midX, y: left.midY)) {
            left = left.offsetBy(dx: s.frame.minX, dy: s.frame.minY)
            right = right.offsetBy(dx: s.frame.minX, dy: s.frame.minY)
        }
        let width = right.minX - left.maxX
        guard width > 0 else { return nil }
        return CGRect(x: left.maxX, y: s.frame.maxY - s.safeAreaTop, width: width, height: s.safeAreaTop)
    }

    public static func menuBarHeight(_ s: NotchScreen) -> CGFloat {
        max(0, s.frame.maxY - s.visibleFrame.maxY)
    }

    /// Свёрнутая панель: «продолжение» выреза с полями по бокам или пилюля под строкой меню.
    public static func collapsedFrame(_ s: NotchScreen) -> CGRect {
        if let notch = notchRect(s) {
            // AppKit округляет frame окна до целых точек; расширяем наружу, чтобы вырез был закрыт целиком.
            return CGRect(x: notch.minX - sideWidth, y: notch.minY,
                          width: notch.width + 2 * sideWidth, height: notch.height).integral
        }
        let top = s.frame.maxY - menuBarHeight(s)
        return CGRect(x: s.frame.midX - pillSize.width / 2, y: top - pillSize.height,
                      width: pillSize.width, height: pillSize.height).integral
    }

    /// Раскрытая панель: прижата к верху экрана под вырезом (или под строкой меню), по центру выреза.
    public static func expandedFrame(_ s: NotchScreen) -> CGRect {
        let collapsed = collapsedFrame(s)
        let top = notchRect(s) == nil ? collapsed.maxY : s.frame.maxY
        var x = collapsed.midX - expandedSize.width / 2
        x = max(min(x, s.frame.maxX - expandedSize.width), s.frame.minX)
        return CGRect(x: x, y: top - expandedSize.height, width: expandedSize.width, height: expandedSize.height).integral
    }
}
