import AppKit
// Запись в пайп уже вышедшего процесса (ssh упал раньше, чем прочитал stdin) не должна убивать Capri.
signal(SIGPIPE, SIG_IGN)
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
