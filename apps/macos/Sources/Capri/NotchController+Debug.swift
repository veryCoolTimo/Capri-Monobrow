import AppKit
import CapriKit

// Отладочное управление notch (`--debug-control`) и снимки собственного окна — для сквозных проверок без мыши.
extension NotchController {

    /// Только с `--debug-control`: команды из `~/.capri/tmp/control` идут по тем же путям, что клики, —
    /// для сквозной проверки без мыши. Файл в каталоге 0700, читается и удаляется раз в 0.3 с.
    func startDebugControl() {
        debugLog = true
        let file = CapriPaths.tmp.appendingPathComponent("control")
        CapriPaths.ensureDir()
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            // Только обычный файл владельца, не ссылка.
            var st = stat()
            guard lstat(file.path, &st) == 0 else { return }
            defer { try? FileManager.default.removeItem(at: file) }
            guard (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid(),
                  let data = FileManager.default.contents(atPath: file.path) else { return }
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") { self?.debugCommand(String(line)) }
        }
        NSLog("[Capri] отладочное управление: %@", file.path)
    }

    /// Строка в `~/.capri/tmp/debug.log` (только с `--debug-control`).
    static func debugWrite(_ line: String) {
        let url = CapriPaths.tmp.appendingPathComponent("debug.log")
        let data = Data("\(Date().timeIntervalSince1970) \(line)\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() }
        else { try? data.write(to: url) }
    }

    func debugCommand(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        NSLog("[Capri] control: %@", parts.first ?? "")
        switch parts.first {
        case "expand": go(.expanded, reason: "control")
        case "assistant": go(.assistant, reason: "control")
        case "ask": go(.assistant, reason: "control"); codex.ask(arg)
        case "fx": CapriFX.forced = Int(arg).map { ($0, Date().addingTimeInterval(4)) }
        case "confirm": if let p = codex.pendingProposal { codex.confirm(p.message, p.proposal.id) }
        case "collapse": go(.collapsed, reason: "control")
        case "peek": go(.peek, reason: "control")
        case "select":
            // select <tmux-сессия>: первая сессия Capri в этой tmux-сессии
            if let s = store.sessions.first(where: { $0.tmux?.session == arg }) { select(s.key) }
        case "choose": if let k = ui.selected, let n = Int(arg) { send(k, .choose(n)) }
        case "text": if let k = ui.selected { ui.reply = arg; send(k, .text(arg)) }
        case "open": if let k = ui.selected { open(k) }
        case "snapshot": snapshot()
        case "dump": dumpState()
        default: if let cmd = parts.first { onDebug?(cmd, arg) }
        }
    }

    func dumpState() {
        let rows = store.sessions.map { s -> [String: Any] in
            var r: [String: Any] = ["key": s.key.description, "status": s.status.rawValue, "project": s.project, "title": store.name(s).full,
                                    "tmux": s.tmux?.session ?? "", "headline": s.headline]
            if let c = s.request?.choices { r["choices"] = c.map { "\($0.index) \($0.label)" } }
            if let d = store.deliveries[s.key] { r["delivery"] = "\(d)" }
            return r
        }
        let out: [String: Any] = ["state": state.rawValue, "selected": ui.selected?.description ?? "", "sessions": rows,
                                  "hosts": store.hosts.map { "\($0.name)=\($0.connected)" },
                                  // Видимые обычные окна Capri и политика активации — проверка «окно само не вылезает».
                                  "windows": NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel) }.map(\.title),
                                  "regular": NSApp.activationPolicy() == .regular]
        if let d = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: CapriPaths.tmp.appendingPathComponent("state.json"))
        }
    }

    /// Снимок собственного окна без записи экрана (маска слоя не учитывается).
    func snapshot() {
        let scale = screen.backingScaleFactor
        let size = container.bounds.size
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setFillColor(NSColor(calibratedWhite: 0.55, alpha: 1).cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        container.layer?.render(in: ctx)
        guard let image = ctx.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        CapriPaths.ensureDir()
        try? rep.representation(using: .png, properties: [:])?.write(to: CapriPaths.tmp.appendingPathComponent("notch-\(state.rawValue).png"))
    }
}
