import AppKit
// Запись в пайп уже вышедшего процесса (ssh упал раньше, чем прочитал stdin) не должна убивать Capri.
signal(SIGPIPE, SIG_IGN)
// Один экземпляр: второй запуск (из другой копии, `open -n`, терминала) просит первый показать окно и выходит.
// Фоновый запуск (скрипты, перезапуск, автозапуск вскоре после загрузки) окно уже запущенного не трогает.
guard SingleInstance.acquire() else {
    let quiet = CommandLine.arguments.contains("--background") || (LoginItem.enabled && ProcessInfo.processInfo.systemUptime < 300)
    if !quiet { SingleInstance.askRunningToShow() }
    exit(0)
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
