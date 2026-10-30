import SwiftUI
import AppKit
import CapriKit

/// Настройки Capri (UserDefaults). Всё применяется сразу, без перезапуска.
final class Settings: ObservableObject {
    private let d = UserDefaults.standard
    static let defaultHosts = ["timoserver", "quiz"]

    @Published var sound: Bool { didSet { d.set(sound, forKey: "capri.sound") } }
    /// ssh-хосты (алиасы из ~/.ssh/config). Этот Mac подключён всегда.
    @Published private(set) var hosts: [String]
    var onHostsChange: (([String]) -> Void)?
    @Published var codexEnabled: Bool {
        didSet { guard codexEnabled != oldValue else { return }; d.set(codexEnabled, forKey: "capri.codex"); onCodexChange?(codexEnabled) }
    }
    @Published var codexSummaries: Bool { didSet { d.set(codexSummaries, forKey: "capri.codexSummaries") } }
    /// Путь к codex; пусто — искать самому. Применяется кнопкой (`applyCodexPath`).
    @Published var codexPath: String
    /// Хосты, содержимое сессий которых в Codex не уходит (по умолчанию прод).
    @Published var codexPrivateHosts: Set<String> { didSet { d.set(codexPrivateHosts.sorted(), forKey: "capri.codexPrivateHosts") } }
    var onCodexChange: ((Bool) -> Void)?
    /// Пауза уведомлений до этого времени (unix). nil — без паузы.
    @Published var pausedUntil: Double? { didSet { d.set(pausedUntil, forKey: "capri.pausedUntil") } }
    /// Уведомления macOS, когда notch не видно (экран спит, заблокирован, вы на другом мониторе).
    @Published var systemNotifications: Bool { didSet { d.set(systemNotifications, forKey: "capri.systemNotificationsOn") } }
    @Published var fullscreenQuiet: Bool { didSet { d.set(fullscreenQuiet, forKey: "capri.fullscreenQuiet"); onFullscreenChange?() } }
    var onFullscreenChange: (() -> Void)?
    /// Текст запроса в уведомлениях macOS (виден на экране блокировки). По умолчанию — только имя сессии.
    @Published var notificationText: Bool { didSet { d.set(notificationText, forKey: "capri.notificationText") } }
    @Published var loginItemError: String?
    var loginItem: Bool {
        get { LoginItem.enabled }
        set { loginItemError = LoginItem.set(newValue); objectWillChange.send() }
    }

    var notificationPolicy: AttentionPolicy.SystemNotifications { systemNotifications ? .whenHidden : .off }

    init() {
        Self.migrate()
        sound = d.object(forKey: "capri.sound") as? Bool ?? true
        pausedUntil = d.object(forKey: "capri.pausedUntil") as? Double
        systemNotifications = d.object(forKey: "capri.systemNotificationsOn") as? Bool ?? true
        fullscreenQuiet = d.object(forKey: "capri.fullscreenQuiet") as? Bool ?? true
        notificationText = d.object(forKey: "capri.notificationText") as? Bool ?? false
        codexEnabled = d.object(forKey: "capri.codex") as? Bool ?? true
        // Сводки отправляют экраны сессий в OpenAI — только по явному включению.
        codexSummaries = d.object(forKey: "capri.codexSummaries") as? Bool ?? false
        codexPrivateHosts = Set(d.stringArray(forKey: "capri.codexPrivateHosts") ?? ["quiz"])
        codexPath = d.string(forKey: "capri.codexPath") ?? ""
        hosts = Self.hosts
    }

    /// Настройки прототипа (`local.capri.prototype`) переезжают в `local.capri` один раз;
    /// трёхпозиционные уведомления (нет / когда не видно / всегда) стали переключателем.
    static func migrate() {
        let d = UserDefaults.standard
        if !d.bool(forKey: "capri.migrated"), let old = UserDefaults(suiteName: "local.capri.prototype") {
            for key in ["capri.hosts", "capri.sound"] where d.object(forKey: key) == nil {
                if let v = old.object(forKey: key) { d.set(v, forKey: key) }
            }
            d.set(true, forKey: "capri.migrated")
        }
        if let old = d.string(forKey: "capri.systemNotifications") {
            if d.object(forKey: "capri.systemNotificationsOn") == nil { d.set(old != "off", forKey: "capri.systemNotificationsOn") }
            d.removeObject(forKey: "capri.systemNotifications")
        }
    }

    static var hosts: [String] { UserDefaults.standard.stringArray(forKey: "capri.hosts") ?? defaultHosts }

    /// Добавить хост; nil — добавлен, иначе почему нет.
    func addHost(_ raw: String) -> String? {
        let h = raw.trimmingCharacters(in: .whitespaces)
        guard HostSource.isValidAlias(h) else { return "«\(h)» не похоже на алиас из ~/.ssh/config" }
        guard !hosts.contains(h) else { return "\(h) уже в списке" }
        // Новый хост может оказаться продом: в Codex его сессии уходят только после явного включения.
        codexPrivateHosts.insert(h)
        setHosts(hosts + [h])
        return nil
    }

    func removeHost(_ h: String) {
        guard hosts.contains(h) else { return }
        setHosts(hosts.filter { $0 != h })
    }

    private func setHosts(_ list: [String]) {
        hosts = list
        d.set(list, forKey: "capri.hosts")
        onHostsChange?(list)
    }

    func applyCodexPath() {
        let p = codexPath.trimmingCharacters(in: .whitespaces)
        d.set(p.isEmpty ? nil : p, forKey: "capri.codexPath")
        if codexEnabled { onCodexChange?(false); onCodexChange?(true) }
    }

    var codexPathChanged: Bool {
        codexPath.trimmingCharacters(in: .whitespaces) != (d.string(forKey: "capri.codexPath") ?? "")
    }
}

/// Окно настроек: обычное окно macOS с формой, всё применяется сразу.
struct SettingsView: View {
    @ObservedObject var settings: Settings
    /// Только список хостов, а не весь стор: форма не перерисовывается на каждое событие сессий.
    @ObservedObject var hosts: HostList
    @State private var newHost = ""
    @State private var hostError: String?
    @State private var advanced = false

    var body: some View {
        Form {
            Section("Уведомления") {
                Toggle("Звук, когда сессия ждёт ответа", isOn: $settings.sound)
                Toggle("Уведомления macOS, когда notch не видно", isOn: $settings.systemNotifications)
                    .help("Экран спит или заблокирован, курсор на другом мониторе")
                Toggle("Текст запроса в уведомлениях", isOn: $settings.notificationText)
                    .disabled(!settings.systemNotifications)
                    .help("Виден на экране блокировки. Выключено — только имя сессии.")
                Toggle("Прятать notch в полноэкранных приложениях", isOn: $settings.fullscreenQuiet)
                    .help("Notch всплывёт только на новое «ждёт меня»")
            }
            Section {
                ForEach(hosts.rows) { h in
                    HStack {
                        Circle().fill(h.connected ? Palette.acid : Palette.crimson).frame(width: 7, height: 7)
                        Text(h.name == "local" ? "Этот Mac" : h.name)
                        Text(h.connected ? "на связи" : "нет связи").foregroundColor(.secondary).font(.caption)
                        Spacer()
                        if h.name != "local" {
                            Button(role: .destructive) { settings.removeHost(h.name) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .help("Убрать хост")
                        }
                    }
                }
                HStack {
                    TextField("алиас из ~/.ssh/config", text: $newHost)
                        .onSubmit(addHost)
                    Button("Добавить", action: addHost).disabled(newHost.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let e = hostError { Text(e).foregroundColor(Palette.crimson).font(.caption) }
            } header: {
                Text("Хосты")
            } footer: {
                Text("На хосте нужен capri-hook: scripts/install-hooks.sh <host> --apply.").font(.caption).foregroundColor(.secondary)
            }
            Section {
                Toggle("Запускать Capri при входе в систему", isOn: Binding(get: { settings.loginItem }, set: { settings.loginItem = $0 }))
                    .disabled(!LoginItem.available)
                if let e = settings.loginItemError ?? (LoginItem.available ? nil : "Доступно для Capri из /Applications.") {
                    Text(e).font(.caption).foregroundColor(.secondary)
                }
                if LoginItem.needsApproval {
                    HStack {
                        Text("macOS ждёт разрешения на автозапуск.").font(.caption).foregroundColor(Palette.crimson)
                        Button("Открыть Настройки") { LoginItem.openSystemSettings() }
                    }
                }
            } header: {
                Text("Запуск")
            }
            Section {
                Toggle("Codex в Capri (вход через ChatGPT)", isOn: $settings.codexEnabled)
                Toggle("Сводки «что спрашивает сессия» в notch", isOn: $settings.codexSummaries)
                    .disabled(!settings.codexEnabled)
                ForEach(hosts.rows.filter { $0.name != "local" }) { h in
                    Toggle("Отправлять в Codex сессии с \(h.name)", isOn: Binding(
                        get: { !settings.codexPrivateHosts.contains(h.name) },
                        set: { on in if on { settings.codexPrivateHosts.remove(h.name) } else { settings.codexPrivateHosts.insert(h.name) } }))
                        .disabled(!settings.codexEnabled)
                }
                DisclosureGroup("Дополнительно", isExpanded: $advanced) {
                    HStack {
                        TextField("путь к codex (пусто — найти самому)", text: $settings.codexPath)
                            .font(.system(.body, design: .monospaced))
                        Button("Применить") { settings.applyCodexPath() }.disabled(!settings.codexPathChanged)
                    }
                }
            } header: {
                Text("Codex")
            } footer: {
                Text("Помощник, сводки и черновики отправляют в OpenAI запросы сессий и низ их экранов. Токены, ключи, пароли и email вырезаются; инструменты у Codex выключены — он только читает текст. Сессии с выключенных хостов — только имя и статус.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .frame(minHeight: 420)
    }

    private func addHost() {
        hostError = settings.addHost(newHost)
        if hostError == nil { newHost = "" }
    }
}
