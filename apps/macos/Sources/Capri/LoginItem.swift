import AppKit
import ServiceManagement

/// Запуск при входе в систему (`SMAppService.mainApp`, macOS 13+). Только для установленного .app.
enum LoginItem {
    static var available: Bool {
        let path = Bundle.main.bundlePath
        return path.hasSuffix(".app") && (path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/"))
    }

    static var enabled: Bool { available && SMAppService.mainApp.status == .enabled }

    /// Пояснение, если автозапуск включён, но macOS ждёт подтверждения в Настройках.
    static var needsApproval: Bool { available && SMAppService.mainApp.status == .requiresApproval }

    static func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }

    @discardableResult
    static func set(_ on: Bool) -> String? {
        guard available else { return "автозапуск — только для Capri из /Applications" }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// План: автозапуск. Включаем один раз при первом запуске установленного Capri; дальше решает человек
    /// (Настройки → «Запускать при входе»).
    static func setUpOnFirstRun() {
        let d = UserDefaults.standard
        guard available, !d.bool(forKey: "capri.loginItemSetUp") else { return }
        d.set(true, forKey: "capri.loginItemSetUp")
        if let err = set(true) { NSLog("[Capri] автозапуск: %@", err) }
    }
}
