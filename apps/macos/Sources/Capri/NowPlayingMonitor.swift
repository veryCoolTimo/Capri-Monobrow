import AppKit
import CapriKit

/// Что играет в Spotify и Музыке: их распределённые уведомления (без разрешений macOS, без MediaRemote и
/// AppleScript). Приходят только при изменении — до первого события Capri ничего не знает. Названия треков
/// не логируем.
final class NowPlayingMonitor: NSObject {
    var onEvent: ((MusicSource, NowPlayingEvent) -> Void)?
    private(set) var running = false

    func start() {
        guard !running else { return }
        running = true
        let dnc = DistributedNotificationCenter.default()
        // Capri почти всегда неактивно: без .deliverImmediately уведомления копились бы до активации.
        dnc.addObserver(self, selector: #selector(spotify(_:)), name: Notification.Name(MusicSource.spotify.notification),
                        object: nil, suspensionBehavior: .deliverImmediately)
        dnc.addObserver(self, selector: #selector(music(_:)), name: Notification.Name(MusicSource.music.notification),
                        object: nil, suspensionBehavior: .deliverImmediately)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(terminated(_:)),
                                                          name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    }

    func stop() {
        guard running else { return }
        running = false
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func spotify(_ n: Notification) { deliver(.spotify, n.userInfo ?? [:]) }
    @objc private func music(_ n: Notification) { deliver(.music, n.userInfo ?? [:]) }

    @objc private func terminated(_ n: Notification) {
        guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let source = MusicSource.allCases.first(where: { $0.bundleID == app.bundleIdentifier }) else { return }
        onEvent?(source, .stopped)
    }

    private func deliver(_ source: MusicSource, _ info: [AnyHashable: Any]) {
        let e = NowPlayingParser.parse(source: source, userInfo: info)
        if Thread.isMainThread { onEvent?(source, e) } else { DispatchQueue.main.async { self.onEvent?(source, e) } }
    }
}
