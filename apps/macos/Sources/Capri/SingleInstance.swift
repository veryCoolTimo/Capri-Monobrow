import AppKit

/// Один экземпляр Capri на пользователя: flock на `~/.capri/tmp/app.lock` (держится, пока процесс жив,
/// и снимается системой при падении) и распределённое уведомление «покажи окно» для уже запущенного.
enum SingleInstance {
    static let showNotification = Notification.Name("local.capri.show")
    private static var fd: Int32 = -1

    static func acquire() -> Bool {
        CapriPaths.ensureDir()
        let path = CapriPaths.tmp.appendingPathComponent("app.lock").path
        let f = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard f >= 0 else { return true }   // без lock-файла не мешаем запуску
        if flock(f, LOCK_EX | LOCK_NB) != 0 {
            close(f)
            return false
        }
        fd = f
        return true
    }

    static func askRunningToShow() {
        DistributedNotificationCenter.default().postNotificationName(showNotification, object: nil, userInfo: nil,
                                                                     deliverImmediately: true)
    }

    static func observe(_ handler: @escaping () -> Void) {
        DistributedNotificationCenter.default().addObserver(forName: showNotification, object: nil, queue: .main) { _ in handler() }
    }
}
