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

/// Свёрнутый — продолжение выреза; peek — чуть выехал вниз, одна строка; expanded — компактный список
/// ждущих с быстрым ответом; assistant — экранчик с Capri (персонаж, облачко, ввод).
public enum NotchState: String, CaseIterable {
    case collapsed, peek, expanded, assistant
}

public enum NotchGeometry {
    public static let sideWidth: CGFloat = 76
    public static let pillSize = CGSize(width: 200, height: 26)
    public static let peekExtraHeight: CGFloat = 34
    public static let peekExtraWidth: CGFloat = 40
    /// Компактный раскрытый notch: ширина постоянная, высота — по содержимому (`contentHeight`).
    public static let expandedWidth: CGFloat = 400
    public static let expandedHeight: ClosedRange<CGFloat> = 96...300
    public static let assistantWidth: CGFloat = 430
    public static let assistantHeight: ClosedRange<CGFloat> = 150...330
    /// Самая большая форма — под неё фиксированная прозрачная панель.
    public static let expandedSize = CGSize(width: max(expandedWidth, assistantWidth),
                                            height: max(expandedHeight.upperBound, assistantHeight.upperBound))
    /// Запас прозрачной панели вокруг самой большой формы: под перелёт пружины и тень.
    public static let hostMargin: CGFloat = 24

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

    /// Верхняя кромка капли: верх экрана при вырезе, низ строки меню без него.
    public static func anchorTop(_ s: NotchScreen) -> CGFloat {
        notchRect(s) == nil ? s.frame.maxY - menuBarHeight(s) : s.frame.maxY
    }

    public static func anchorX(_ s: NotchScreen) -> CGFloat {
        notchRect(s)?.midX ?? s.frame.midX
    }

    /// `quiet` — нет активности: свёрнутая капля совпадает с вырезом (без выреза — невидимая полоска).
    /// `contentHeight` — высота содержимого раскрытого notch и помощника (nil — нижняя граница).
    public static func shapeSize(_ state: NotchState, _ s: NotchScreen, quiet: Bool = false, contentHeight: CGFloat? = nil) -> CGSize {
        func clamp(_ h: CGFloat?, _ r: ClosedRange<CGFloat>) -> CGFloat { min(max(h ?? r.lowerBound, r.lowerBound), r.upperBound) }
        let collapsed: CGSize
        if let notch = notchRect(s) {
            collapsed = CGSize(width: notch.width + 2 * sideWidth, height: notch.height)
        } else {
            collapsed = pillSize
        }
        switch state {
        case .collapsed where quiet:
            return notchRect(s)?.size ?? CGSize(width: pillSize.width, height: 0)
        case .collapsed: return collapsed
        case .peek: return CGSize(width: collapsed.width + peekExtraWidth, height: collapsed.height + peekExtraHeight)
        case .expanded: return CGSize(width: expandedWidth, height: clamp(contentHeight, expandedHeight))
        case .assistant: return CGSize(width: assistantWidth, height: clamp(contentHeight, assistantHeight))
        }
    }

    /// Фиксированная прозрачная панель, внутри которой анимируется капля. Её frame не меняется.
    public static func hostFrame(_ s: NotchScreen) -> CGRect {
        let width = expandedSize.width + 2 * hostMargin
        let height = expandedSize.height + hostMargin
        var x = anchorX(s) - width / 2
        x = max(min(x, s.frame.maxX - width), s.frame.minX)
        return CGRect(x: x, y: anchorTop(s) - height, width: width, height: height).integral
    }

    /// Капля в состоянии `state` (глобальные координаты) — для отрисовки и проверки попадания мыши.
    public static func shapeRect(_ state: NotchState, _ s: NotchScreen, quiet: Bool = false, contentHeight: CGFloat? = nil) -> CGRect {
        let size = shapeSize(state, s, quiet: quiet, contentHeight: contentHeight)
        let host = hostFrame(s)
        var x = anchorX(s) - size.width / 2
        x = max(min(x, host.maxX - size.width), host.minX)
        return CGRect(x: x, y: anchorTop(s) - size.height, width: size.width, height: size.height)
    }
}
