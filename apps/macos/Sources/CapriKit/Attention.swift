import Foundation
import CoreGraphics

/// Окно другого приложения на экране notch (из `CGWindowListCopyWindowInfo`; координаты CG — от верхнего левого угла
/// главного экрана). Имя окна не нужно — без разрешения на запись экрана его и нет.
public struct WindowInfo: Equatable {
    public var pid: Int32
    public var layer: Int
    public var bounds: CGRect
    /// Прозрачное окно (alpha 0) на экране не видно — так может «прятаться» строка меню.
    public var alpha: Double

    public init(pid: Int32, layer: Int, bounds: CGRect, alpha: Double = 1) {
        self.pid = pid; self.layer = layer; self.bounds = bounds; self.alpha = alpha
    }

    public static func from(_ dict: [String: Any]) -> WindowInfo? {
        guard let pid = dict["kCGWindowOwnerPID"] as? Int32 ?? (dict["kCGWindowOwnerPID"] as? Int).map(Int32.init),
              let layer = dict["kCGWindowLayer"] as? Int,
              let b = dict["kCGWindowBounds"] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: b as CFDictionary) else { return nil }
        let alpha = (dict["kCGWindowAlpha"] as? Double) ?? (dict["kCGWindowAlpha"] as? NSNumber)?.doubleValue ?? 1
        return WindowInfo(pid: pid, layer: layer, bounds: rect, alpha: alpha)
    }
}

public enum Fullscreen {
    /// Уровень окна строки меню (kCGMainMenuWindowLevel).
    public static let menuBarLayer = 24

    /// Полноэкранное приложение на экране notch. Признаки вместе:
    /// - нет окна строки меню у верхнего края этого экрана (в полноэкранном пространстве оно скрыто);
    /// - обычное окно (слой 0) переднего приложения на всю ширину и высоту экрана; верх — не ниже выреза
    ///   (на Маках с вырезом полноэкранное окно начинается под ним).
    /// Только по размеру окна нельзя: развёрнутое окно выглядит так же, но строка меню при нём видна.
    public static func isActive(windows: [WindowInfo], screen: CGRect, safeAreaTop: CGFloat,
                                frontmost: Int32?, ownPid: Int32) -> Bool {
        guard let front = frontmost, front != ownPid else { return false }
        let menuBar = windows.contains { w in
            w.layer == menuBarLayer && w.alpha > 0 && w.bounds.height < 80 && abs(w.bounds.minY - screen.minY) < 2
                && w.bounds.intersects(screen)
        }
        if menuBar { return false }
        return windows.contains { w in
            w.pid == front && w.layer == 0
                && abs(w.bounds.minX - screen.minX) < 1 && w.bounds.width >= screen.width - 1
                && w.bounds.minY <= screen.minY + safeAreaTop + 1 && w.bounds.maxY >= screen.maxY - 1
        }
    }
}

/// Как Capri зовёт человека при новом «ждёт меня».
public struct AttentionPolicy: Equatable {
    public enum SystemNotifications: String, CaseIterable { case off, whenHidden, always }

    public var pausedUntil: Double?
    public var sound: Bool
    public var system: SystemNotifications
    /// В полноэкранном приложении notch спрятан и всплывает только на новое «ждёт меня».
    public var fullscreenQuiet: Bool

    public init(pausedUntil: Double? = nil, sound: Bool = true, system: SystemNotifications = .whenHidden, fullscreenQuiet: Bool = true) {
        self.pausedUntil = pausedUntil; self.sound = sound; self.system = system; self.fullscreenQuiet = fullscreenQuiet
    }

    public struct Decision: Equatable {
        public var peek: Bool
        public var sound: Bool
        public var systemNotification: Bool
    }

    public func paused(now: Double) -> Bool { (pausedUntil ?? 0) > now }

    /// `notchHidden` — notch сейчас не виден (полноэкранное приложение).
    public func decide(now: Double, notchHidden: Bool) -> Decision {
        if paused(now: now) { return Decision(peek: false, sound: false, systemNotification: false) }
        let system: Bool
        switch self.system {
        case .off: system = false
        case .whenHidden: system = notchHidden
        case .always: system = true
        }
        return Decision(peek: true, sound: sound, systemNotification: system)
    }
}
