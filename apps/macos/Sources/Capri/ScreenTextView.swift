import SwiftUI
import AppKit
import CapriKit

/// Экран tmux-панели в NSTextView: обновление без перерисовки всего вида и без прыжков прокрутки.
/// Были внизу — остаёмся внизу; читаете выше — позиция держится; выделили текст — экран не обновляется,
/// пока выделение не снимут (иначе копировать нечего).
struct ScreenTextView: NSViewRepresentable {
    var lines: [ScreenLine]

    final class Coordinator {
        var shown: [ScreenLine]?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let text = NSTextView(usingTextLayoutManager: false)
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.isRichText = true
        text.textContainerInset = NSSize(width: 8, height: 8)
        // Строки терминала не переносим: прокрутка по горизонтали.
        text.isHorizontallyResizable = true
        text.isVerticallyResizable = true
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.autoresizingMask = [.width]
        scroll.documentView = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView else { return }
        let c = context.coordinator
        guard c.shown != lines else { return }
        // Выделение снимут — применится следующий снимок (они приходят раз в 2 с).
        if c.shown != nil, text.selectedRange().length > 0 { return }
        let clip = scroll.contentView
        let first = c.shown == nil
        let atBottom = first || clip.bounds.maxY >= (text.frame.height - 6)
        let origin = clip.bounds.origin
        text.textStorage?.setAttributedString(Self.render(lines))
        c.shown = lines
        if let container = text.textContainer { text.layoutManager?.ensureLayout(for: container) }
        text.sizeToFit()
        if atBottom {
            text.scrollToEndOfDocument(nil)
        } else {
            clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        }
        scroll.reflectScrolledClipView(clip)
    }

    static let font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
    static let bright = NSColor(srgbRed: 0.95, green: 0.91, blue: 0.92, alpha: 0.92)
    static let dim = NSColor(srgbRed: 0.61, green: 0.54, blue: 0.55, alpha: 0.75)

    static func render(_ lines: [ScreenLine]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byClipping
        for (i, line) in lines.enumerated() {
            for run in line.runs {
                out.append(NSAttributedString(string: run.text, attributes: [
                    .font: font, .foregroundColor: run.dim ? dim : bright, .paragraphStyle: para
                ]))
            }
            if i < lines.count - 1 { out.append(NSAttributedString(string: "\n", attributes: [.font: font])) }
        }
        return out
    }
}
