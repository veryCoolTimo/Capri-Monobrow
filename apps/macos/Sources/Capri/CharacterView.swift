import AppKit
import WebKit
import CapriKit

final class CharacterPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class CharacterInputView: NSView {
    weak var controller: CharacterController?
    let shape = CharacterAssets.inputShape()
    override var isOpaque: Bool { false }
    private var startMouse = NSPoint.zero
    private var startOrigin = NSPoint.zero
    private var dragged = false
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        // A native bitmap gives WindowServer an alpha-shaped input region. WKWebView
        // lives in a separate permanently click-through sibling panel.
        shape?.image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 0.01)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        shape?.map.contains(point, canvasSize: bounds.size) == true ? self : nil
    }
    override func mouseDown(with event: NSEvent) {
        startMouse = NSEvent.mouseLocation
        startOrigin = controller?.panel.frame.origin ?? .zero
        dragged = false
        controller?.dragging = true
    }
    override func mouseDragged(with event: NSEvent) {
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - startMouse.x, dy = mouse.y - startMouse.y
        if hypot(dx, dy) > 3 { dragged = true }
        controller?.move(to: NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
    }
    override func mouseUp(with event: NSEvent) {
        controller?.dragging = false
        controller?.savePosition()
        if !dragged { controller?.onClick?() }
    }
    override func rightMouseDown(with event: NSEvent) { controller?.onContextMenu?(event, self) }
}

enum CharacterAssets {
    static var directory: URL {
        if let resources = Bundle.main.resourceURL {
            let path = resources.appendingPathComponent("Capri_Capri.bundle/Character")
            if FileManager.default.fileExists(atPath: path.path) { return path }
        }
        return Bundle.module.resourceURL!.appendingPathComponent("Character")
    }
    static var face: NSImage? { NSImage(contentsOf: directory.appendingPathComponent("capri-face.png")) }
    static func inputShape() -> (image: NSImage, map: SpriteHitMap)? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("capri-full.png")),
              let image = NSBitmapImageRep(data: data),
              image.pixelsWide == 240, image.pixelsHigh == 420 else { return nil }
        let width = 352, height = 532, pad = 56
        var mask = [UInt8](repeating: 0, count: width * height)
        for y in 0..<420 { for x in 0..<240 {
            guard (image.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 else { continue }
            mask[(y + pad) * width + x + pad] = 255
            let top = 159.0 + Double(98 - x) * 0.5
            let bottom = x < 50 ? 234.0 : 178.0 + Double(98 - x) * 0.62
            if x <= 101 && y <= 234 && Double(y) >= top && Double(y) <= bottom {
                mask[(y + pad) * width + (234 - x) + pad] = 255
            }
        } }
        // Covers idle hair/head movement with a small margin around the silhouette.
        var expanded = mask
        for y in 4..<(height - 4) { for x in 4..<(width - 4) where mask[y * width + x] > 0 {
            for dy in -4...4 { for dx in -4...4 { expanded[(y + dy) * width + x + dx] = 255 } }
        } }
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32), let bytes = bitmap.bitmapData else { return nil }
        for index in expanded.indices {
            bytes[index * 4] = 0; bytes[index * 4 + 1] = 0; bytes[index * 4 + 2] = 0
            bytes[index * 4 + 3] = expanded[index]
        }
        let nativeImage = NSImage(size: NSSize(width: width, height: height))
        nativeImage.addRepresentation(bitmap)
        return (nativeImage, SpriteHitMap(width: width, height: height, alpha: expanded))
    }
}
