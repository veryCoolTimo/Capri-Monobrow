import AppKit
// Запись в пайп уже вышедшего процесса (ssh упал раньше, чем прочитал stdin) не должна убивать Capri.
signal(SIGPIPE, SIG_IGN)
// Один экземпляр: второй запуск (из другой копии, `open -n`, терминала) просит первый показать окно и выходит.
guard SingleInstance.acquire() else {
    SingleInstance.askRunningToShow()
    exit(0)
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
