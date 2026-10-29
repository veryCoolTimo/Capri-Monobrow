import Foundation
import CoreGraphics

public enum OverlayGeometry {
    public static func clampedOrigin(_ origin: CGPoint, panelSize: CGSize, visibleFrame: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(origin.x, visibleFrame.minX), max(visibleFrame.minX, visibleFrame.maxX - panelSize.width)),
            y: min(max(origin.y, visibleFrame.minY), max(visibleFrame.minY, visibleFrame.maxY - panelSize.height))
        )
    }
}

public struct SpriteHitMap {
    private let width: Int
    private let height: Int
    private let alpha: [UInt8]

    public init(width: Int, height: Int, alpha: [UInt8]) {
        precondition(width > 0 && height > 0 && alpha.count == width * height)
        self.width = width
        self.height = height
        self.alpha = alpha
    }

    /// AppKit points have a bottom-left origin; texture pixels have a top-left origin.
    public func contains(_ point: CGPoint, canvasSize: CGSize) -> Bool {
        guard canvasSize.width > 0, canvasSize.height > 0,
              point.x >= 0, point.y >= 0, point.x < canvasSize.width, point.y < canvasSize.height else { return false }
        let x = min(width - 1, Int(point.x / canvasSize.width * Double(width)))
        let y = min(height - 1, Int((1 - point.y / canvasSize.height) * Double(height)))
        return alpha[y * width + x] > 24
    }
}

public enum OverlayPreferences {
    public static func hiddenDeadline(from now: Date) -> Date { now.addingTimeInterval(3600) }
    public static func isHidden(until: Date?, now: Date) -> Bool { until.map { $0 > now } ?? false }
}
